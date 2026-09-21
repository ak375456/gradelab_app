import CoreGraphics
import ImageIO
import Foundation

/// The only boundary between encoded, top-left mask UVs and oriented Vision UVs.
/// The renderer grades encoded source pixels before applying preferredTransform.
struct MaskTrackingCoordinates: Sendable {
    let encodedSize: CGSize
    let preferredTransform: CGAffineTransform
    let displayBounds: CGRect
    let orientation: CGImagePropertyOrientation

    init(encodedSize: CGSize, preferredTransform: CGAffineTransform) throws {
        let t = preferredTransform
        guard encodedSize.width > 0, encodedSize.height > 0,
              [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite),
              abs(t.a * t.d - t.b * t.c) > 0.0001 else {
            throw MaskTrackingError.message(String(localized: "This video has an invalid source transform."))
        }
        // Vision's EXIF orientation covers all eight camera rotations/reflections.
        // Reject skew instead of silently using the wrong tracking coordinates.
        let candidates: [(CGImagePropertyOrientation, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (.up, 1, 0, 0, 1), (.upMirrored, -1, 0, 0, 1),
            (.down, -1, 0, 0, -1), (.downMirrored, 1, 0, 0, -1),
            (.leftMirrored, 0, 1, 1, 0), (.right, 0, 1, -1, 0),
            (.rightMirrored, 0, -1, -1, 0), (.left, 0, -1, 1, 0)
        ]
        let sx = hypot(t.a, t.b), sy = hypot(t.c, t.d)
        guard let match = candidates.first(where: {
            abs(t.a / sx - $0.1) < 0.001 && abs(t.b / sx - $0.2) < 0.001 &&
            abs(t.c / sy - $0.3) < 0.001 && abs(t.d / sy - $0.4) < 0.001
        }) else { throw MaskTrackingError.message(String(localized: "Tracking cannot interpret this video's source orientation.")) }
        self.encodedSize = encodedSize
        self.preferredTransform = t
        displayBounds = CGRect(origin: .zero, size: encodedSize).applying(t).standardized
        orientation = match.0
    }

    var aspect: Double { encodedSize.width / encodedSize.height }

    func sourceToDisplay(_ point: CGPoint) -> CGPoint {
        let pixel = CGPoint(x: point.x * encodedSize.width, y: point.y * encodedSize.height)
            .applying(preferredTransform)
        return CGPoint(x: (pixel.x - displayBounds.minX) / displayBounds.width,
                       y: (pixel.y - displayBounds.minY) / displayBounds.height)
    }

    func displayToSource(_ point: CGPoint) -> CGPoint {
        let pixel = CGPoint(x: displayBounds.minX + point.x * displayBounds.width,
                            y: displayBounds.minY + point.y * displayBounds.height)
            .applying(preferredTransform.inverted())
        return CGPoint(x: pixel.x / encodedSize.width, y: pixel.y / encodedSize.height)
    }

    /// The existing compositor's top-left placement transform, before its CI
    /// origin flips. Used only to put editor handles over a transformed layer.
    func sourceToCanvasTransform(_ placement: VisualTransform, canvas: CGSize) -> CGAffineTransform {
        let fit = min(canvas.width / displayBounds.width, canvas.height / displayBounds.height)
        return CGAffineTransform(scaleX: encodedSize.width, y: encodedSize.height)
            .concatenating(preferredTransform)
            .concatenating(.init(translationX: -displayBounds.minX - displayBounds.width * placement.anchorX,
                                 y: -displayBounds.minY - displayBounds.height * placement.anchorY))
            .concatenating(.init(scaleX: fit * placement.scale * placement.widthScale,
                                y: fit * placement.scale * placement.heightScale))
            .concatenating(.init(rotationAngle: placement.rotationDegrees * .pi / 180))
            .concatenating(.init(translationX: canvas.width * placement.positionX, y: canvas.height * placement.positionY))
            .concatenating(.init(scaleX: 1 / canvas.width, y: 1 / canvas.height))
    }

    func visionBox(fromSource box: CGRect) -> CGRect {
        Self.bounds(Self.corners(box).map {
            let p = sourceToDisplay($0)
            return CGPoint(x: p.x, y: 1 - p.y)
        })
    }

    func sourceBox(fromVision box: CGRect) -> CGRect {
        Self.bounds(Self.corners(box).map { displayToSource(CGPoint(x: $0.x, y: 1 - $0.y)) })
    }

    func region(for geometry: MaskGeometry) throws -> CGRect {
        let g = geometry.clamped
        guard g.shape != .linear, g.isRenderable else {
            throw MaskTrackingError.message(String(localized: "Tracking needs an Ellipse, Rectangle or completed Freehand window."))
        }
        let points: [CGPoint]
        if g.shape == .freehand {
            points = g.points.map { Self.placedVertex($0, geometry: g, aspect: aspect) }
        } else {
            // Sample the actual ellipse; rectangle bounds include its rotated corners.
            let local: [CGPoint] = g.shape == .ellipse ? (0..<128).map {
                let angle = Double($0) * 2 * .pi / 128
                return CGPoint(x: cos(angle) * g.width * aspect / 2, y: sin(angle) * g.height / 2)
            } : Self.corners(CGRect(x: -g.width * aspect / 2, y: -g.height / 2,
                                   width: g.width * aspect, height: g.height))
            points = local.map { Self.placeLocal($0, geometry: g, aspect: aspect) }
        }
        let box = Self.bounds(points).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard Self.isValid(box), box.width * encodedSize.width >= 8,
              box.height * encodedSize.height >= 8 else {
            throw MaskTrackingError.message(String(localized: "Place a larger part of the mask inside the picture before tracking."))
        }
        return box
    }

    static func placedVertex(_ point: MaskPoint, geometry g: MaskGeometry, aspect: Double) -> CGPoint {
        placeLocal(CGPoint(x: (point.x - g.pivotX) * aspect * g.width,
                           y: (point.y - g.pivotY) * g.height), geometry: g, aspect: aspect)
    }

    private static func placeLocal(_ p: CGPoint, geometry g: MaskGeometry, aspect: Double) -> CGPoint {
        let angle = g.rotationDegrees * .pi / 180
        return CGPoint(x: g.centerX + (cos(angle) * p.x - sin(angle) * p.y) / aspect,
                       y: g.centerY + sin(angle) * p.x + cos(angle) * p.y)
    }

    static func isValid(_ box: CGRect) -> Bool {
        !box.isNull && [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) &&
            box.width > 0.00001 && box.height > 0.00001
    }

    private static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }
    private static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var x0 = first.x, x1 = first.x, y0 = first.y, y1 = first.y
        for p in points { x0 = min(x0, p.x); x1 = max(x1, p.x); y0 = min(y0, p.y); y1 = max(y1, p.y) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
