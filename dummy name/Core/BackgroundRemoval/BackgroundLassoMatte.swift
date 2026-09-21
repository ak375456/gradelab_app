import CoreGraphics
import Foundation

/// Rasterizes a lasso outline into the same single-channel plane the Vision
/// path produces, so everything downstream — feather, edge shift, the Add and
/// Remove brushes, invert, the matte view and export — is shared code.
///
/// There is no analysis pass and nothing on disk: the outline is authored
/// vector data, and a polygon fill is cheap enough to do for the frame being
/// shown. That is what makes a lasso feel immediate where the old Vision
/// selection had to grind through the clip before showing anything.
enum BackgroundLassoMatte {
    /// Bounded rather than full resolution: the matte is sampled bilinearly
    /// onto the source, so paying for 4K here would buy nothing a 1536-long
    /// edge does not already give, while costing a 33MB allocation per frame.
    static let maximumLongEdge = 1_536.0

    static func plane(for selection: BackgroundLassoSelection, atLocal local: TimelineTime?,
                      aspectWidth: Int, aspectHeight: Int) -> BackgroundMaskPlane? {
        let outline = selection.clamped.outline(atLocal: local)
        guard outline.count >= 3, aspectWidth > 0, aspectHeight > 0 else { return nil }
        let factor = min(1, maximumLongEdge / Double(max(aspectWidth, aspectHeight)))
        let width = max(2, Int((Double(aspectWidth) * factor).rounded()))
        let height = max(2, Int((Double(aspectHeight) * factor).rounded()))
        let key = Key(outline: outline, width: width, height: height)
        if let cached = cache.value(for: key) { return cached }
        guard let rendered = rasterize(outline, width: width, height: height) else { return nil }
        cache.store(rendered, for: key)
        return rendered
    }

    private static func rasterize(_ outline: [CGPoint], width: Int,
                                  height: Int) -> BackgroundMaskPlane? {
        var pixels = Data(repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setShouldAntialias(true)
            context.setFillColor(gray: 1, alpha: 1)
            context.beginPath()
            // Core Graphics draws from the bottom left while authored points
            // and the Metal matte sampler are both top-left, so y is flipped
            // here exactly as the refinement brushes flip it.
            context.move(to: CGPoint(x: outline[0].x * Double(width),
                                     y: (1 - outline[0].y) * Double(height)))
            for point in outline.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * Double(width),
                                            y: (1 - point.y) * Double(height)))
            }
            context.closePath()
            // Nonzero winding, not even-odd: a traced outline crosses itself
            // constantly and even-odd would punch holes through the subject at
            // every crossing.
            context.fillPath()
            return true
        }
        guard drawn else { return nil }
        return .init(width: width, height: height, values: pixels)
    }

    /// Keyed on the evaluated outline rather than the authored one, so a
    /// tracked clip paused on a frame reuses its plane while scrubbing to a
    /// different frame correctly rebuilds it.
    private struct Key: Hashable {
        let width: Int
        let height: Int
        let digest: [Int64]

        init(outline: [CGPoint], width: Int, height: Int) {
            self.width = width
            self.height = height
            // Quantized to well under a matte pixel: two outlines this close
            // rasterize identically, and an exact Double compare would miss
            // every cache hit during playback.
            digest = outline.flatMap {
                [Int64(($0.x * 100_000).rounded()), Int64(($0.y * 100_000).rounded())]
            }
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Key: BackgroundMaskPlane] = [:]
        private var order: [Key] = []
        /// Small on purpose. The editor shows one frame at a time and export
        /// walks forward, so anything beyond a handful is retained memory that
        /// will never be read again.
        private let capacity = 6

        func value(for key: Key) -> BackgroundMaskPlane? {
            lock.lock(); defer { lock.unlock() }
            guard let plane = entries[key] else { return nil }
            order.removeAll { $0 == key }; order.append(key)
            return plane
        }

        func store(_ plane: BackgroundMaskPlane, for key: Key) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = plane
            order.removeAll { $0 == key }; order.append(key)
            while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        }
    }

    private static let cache = Cache()
}
