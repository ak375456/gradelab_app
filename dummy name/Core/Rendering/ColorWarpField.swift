@preconcurrency import Metal
import Foundation
import simd

// ---------------------------------------------------------------------------
// Color Warper field textures
//
// The same bargain the curve tables make, for the same reason: interactions
// happen a few dozen times a second and pixels happen a few hundred million
// times a second, so the deformation is solved on the CPU into a small texture
// and the GPU does one filtered fetch.
//
// WHY A 2D FIELD AND NOT A 3D LUT. The obvious route is to bake the warp into a
// cube LUT and reuse the look pipeline. Two things rule it out:
//
//   - The warp is a function of two coordinates, not three. A 33-cube spends its
//     resolution on an axis the warp does not read, costs 287 KB to rebuild on
//     every drag frame, and still gives each real axis fewer samples than the
//     36 KB table here does.
//   - A cube LUT is a 0...1 transform. The HDR path already has to split the
//     signal at diffuse white and rejoin it to use one at all (`applyLUTHDR`).
//     A field indexed by HUE AND SATURATION needs no such trick, because hue and
//     saturation are bounded in both working spaces - so SDR, Apple Log and HDR
//     share one implementation instead of three.
//
// Format is `rg16Float`: the stored values are signed displacements, which the
// curves' `r16Unorm` could only carry by biasing, and half float is filterable
// on every Apple GPU where 32-bit float is not.
//
// The table is one block per plane, stacked: hue/saturation first, then
// chroma/luma. A caller addresses its own block by row offset, exactly as a
// masked local grade addresses its own curve block.
//
// Column 0 and column W-1 both hold hue 0. The builder measures hue the short
// way round, so those two columns come out identical and plain clamp-to-edge
// addressing is continuous across the red boundary - there is no seam to hide,
// and no wrap-aware sampler to write.
// ---------------------------------------------------------------------------

enum ColorWarpFieldFactory {
    static let pixelFormat: MTLPixelFormat = .rg16Float
    /// Samples along x. 192 gives just under two per degree of hue, which is
    /// finer than the eye resolves a hue boundary on a smooth gradient.
    static let width = 192
    /// Samples along y, per plane.
    static let blockHeight = 48
    static let blockCount = ColorWarpMode.allCases.count
    static var height: Int { blockHeight * blockCount }
    /// Two channels: displacement along x, displacement along y.
    static let components = 2

    /// How sharply influence falls away inside a point's range. Paired with the
    /// window below so the two together are a Gaussian that actually reaches
    /// zero: a bare Gaussian never does, and a point with a small range would
    /// then put a faint tint across the whole colour wheel.
    static let falloff: Float = 4
    /// Where the compact window starts closing. Smoothstep has zero slope at
    /// both ends, so the product stays smooth where it lands on zero.
    static let windowStart: Float = 0.7

    static var samplesPerBlock: Int { width * blockHeight * components }

    /// How much one point pulls at a normalised distance of `distance` (1 being
    /// the edge of its range).
    ///
    /// A bare Gaussian and a bare smoothstep each have a flaw: the Gaussian
    /// never reaches zero, so a small range still tints the whole plane, and a
    /// smoothstep alone is flat-topped where the pull should be strongest. Their
    /// product is strong at the centre, smooth everywhere, and exactly zero at
    /// the edge - smoothstep has zero slope at both ends, so it lands on zero
    /// without a crease.
    static func falloffWeight(distanceSquared: Float) -> Float {
        guard distanceSquared < 1 else { return 0 }
        let distance = distanceSquared.squareRoot()
        return expf(-distanceSquared * falloff)
            * (1 - ColorWarpMath.smoothstep(windowStart, 1, distance))
    }

    /// The displacement at one coordinate, gathered rather than scattered.
    ///
    /// The block builder below produces the same answer for every cell at once,
    /// and is written as a scatter because that is much faster over a whole
    /// plane. This exists for the editor, which needs the field at a few hundred
    /// points along the drawn mesh and none of the rest - and it shares
    /// `falloffWeight` and the same normalisation, so the mesh on screen is the
    /// deformation the GPU applies rather than an impression of it.
    static func displacement(
        at x: Float,
        _ y: Float,
        points: [ColorWarpPoint],
        mode: ColorWarpMode
    ) -> SIMD2<Float> {
        var accumulated = SIMD2<Float>.zero
        var total: Float = 0
        for point in points where point.weight > 0 {
            let radius = max(point.radius, ColorWarpPoint.minimumRadius)
            let dx = (mode.wrapsHorizontally ? ColorWarpMath.wrappedDelta(from: point.sourceX, to: x)
                                             : x - point.sourceX) / radius
            let dy = (y - point.sourceY) / radius
            let weight = falloffWeight(distanceSquared: dx * dx + dy * dy) * point.weight
            guard weight > 0 else { continue }
            accumulated += point.displacement * weight
            total += weight
        }
        return accumulated / max(1, total)
    }

    /// A neutral block: no displacement anywhere.
    static var neutralBlock: [Float16] {
        [Float16](repeating: 0, count: samplesPerBlock)
    }

    /// Solves `points` into one block of the field.
    ///
    /// Accumulated by scattering each point over the cells it can reach rather
    /// than by asking every cell about every point. A point's range is usually a
    /// small part of the plane, so this is the difference between a table that
    /// rebuilds inside a frame and one that does not.
    static func block(for points: [ColorWarpPoint], mode: ColorWarpMode) -> [Float16] {
        guard !points.isEmpty else { return neutralBlock }

        let cells = width * blockHeight
        var accumulated = [SIMD2<Float>](repeating: .zero, count: cells)
        var weights = [Float](repeating: 0, count: cells)
        let lastColumn = Float(width - 1)
        let lastRow = Float(blockHeight - 1)
        let wraps = mode.wrapsHorizontally

        for point in points {
            let radius = max(point.radius, ColorWarpPoint.minimumRadius)
            let displacement = point.displacement
            guard point.weight > 0 else { continue }

            let rowLow = max(0, Int(((point.sourceY - radius) * lastRow).rounded(.down)))
            let rowHigh = min(blockHeight - 1, Int(((point.sourceY + radius) * lastRow).rounded(.up)))
            guard rowLow <= rowHigh else { continue }

            // Column span, in index units. A range that reaches halfway round
            // the circle touches every column, so the wrap case stops being
            // worth computing and the loop simply covers the row.
            let span = Int((radius * lastColumn).rounded(.up)) + 1
            let centre = Int((point.sourceX * lastColumn).rounded())
            let coversRow = !wraps || span * 2 >= width
            let columnLow = coversRow ? 0 : centre - span
            let columnHigh = coversRow ? width - 1 : centre + span

            for row in rowLow...rowHigh {
                let y = Float(row) / lastRow
                let dy = (y - point.sourceY) / radius
                let dySquared = dy * dy
                if dySquared >= 1 { continue }
                for rawColumn in columnLow...columnHigh {
                    var column = rawColumn
                    if wraps {
                        column %= width
                        if column < 0 { column += width }
                    } else if column < 0 || column >= width {
                        continue
                    }
                    let x = Float(column) / lastColumn
                    let dx = (wraps ? ColorWarpMath.wrappedDelta(from: point.sourceX, to: x)
                                    : x - point.sourceX) / radius
                    let weight = falloffWeight(distanceSquared: dx * dx + dySquared) * point.weight
                    guard weight > 0 else { continue }
                    let index = row * width + column
                    accumulated[index] += displacement * weight
                    weights[index] += weight
                }
            }
        }

        // Normalising by the accumulated weight - but never by less than one -
        // is what stops two overlapping points from stacking their
        // displacements. Without it, a second point dropped beside the first
        // doubles the move in the overlap and leaves a discontinuity at its
        // edge, which is the single ugliest way this feature can fail.
        var payload = [Float16](repeating: 0, count: samplesPerBlock)
        for index in 0..<cells {
            let value = accumulated[index] / max(1, weights[index])
            payload[index * components] = Float16(value.x)
            payload[index * components + 1] = Float16(value.y)
        }
        return payload
    }

    /// A texture holding every plane, neutral blocks included so the shader can
    /// address a block by its fixed index.
    static func makeTexture(
        blocks: [[Float16]],
        device: MTLDevice,
        label: String
    ) -> MTLTexture? {
        precondition(blocks.count == blockCount,
                     "The warp field needs one block per Color Warper plane")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        #if os(iOS)
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        var payload = [Float16]()
        payload.reserveCapacity(samplesPerBlock * blockCount)
        for block in blocks {
            precondition(block.count == samplesPerBlock, "Warp block is the wrong size")
            payload.append(contentsOf: block)
        }
        payload.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width * components * MemoryLayout<Float16>.size
            )
        }
        return texture
    }
}

/// Keeps warp field textures ready for the render thread.
///
/// Two caches, for the same reasons `CurveLUTLibrary` has two: a drag changes
/// one plane sixty times a second and re-solving the other one would be wasted
/// work, and an unchanged grade during playback should cost one comparison.
///
/// Textures are never mutated after upload. A change allocates a new one (36 KB)
/// and leaves the old for whichever command buffer still references it, so there
/// is no hazard between the CPU writing a field and the GPU reading it.
final class ColorWarpFieldLibrary: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var neutralTexture: MTLTexture?
    private var blockCache: [(points: [ColorWarpPoint], mode: ColorWarpMode, samples: [Float16])] = []
    private var textureCache: [(warp: ColorWarp, texture: MTLTexture)] = []
    /// Enough for the plane being dragged plus a few recently used grades. The
    /// caches exist to skip work, not to hold memory.
    private static let blockCacheLimit = 8
    private static let textureCacheLimit = 4

    init(device: MTLDevice) {
        self.device = device
        neutralTexture = ColorWarpFieldFactory.makeTexture(
            blocks: Array(repeating: ColorWarpFieldFactory.neutralBlock,
                          count: ColorWarpFieldFactory.blockCount),
            device: device,
            label: "Neutral color warp")
    }

    /// Render-thread safe. Always returns something bindable: the neutral field
    /// stands in if a texture cannot be allocated, and it cannot change a pixel.
    func texture(for warp: ColorWarp?) -> MTLTexture? {
        guard let warp, !warp.isNeutral else { return neutralTexture }
        lock.lock()
        defer { lock.unlock() }
        if let hit = textureCache.first(where: { $0.warp == warp })?.texture { return hit }

        let blocks = ColorWarpMode.allCases.map { mode -> [Float16] in
            let points = warp.activePoints(mode)
            guard !points.isEmpty else { return ColorWarpFieldFactory.neutralBlock }
            if let cached = blockCache.first(where: { $0.points == points && $0.mode == mode })?.samples {
                return cached
            }
            let samples = ColorWarpFieldFactory.block(for: points, mode: mode)
            blockCache.insert((points, mode, samples), at: 0)
            if blockCache.count > Self.blockCacheLimit { blockCache.removeLast() }
            return samples
        }

        guard let texture = ColorWarpFieldFactory.makeTexture(
            blocks: blocks, device: device, label: "Color warp") else { return neutralTexture }
        textureCache.insert((warp, texture), at: 0)
        if textureCache.count > Self.textureCacheLimit { textureCache.removeLast() }
        return texture
    }
}
