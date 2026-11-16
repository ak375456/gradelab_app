import CoreGraphics
import CoreImage
import Foundation

/// A viewfinder in the upright source picture. Pan runs between the furthest
/// legal edges at the current zoom and roll, so a move cannot expose empty pixels.
struct ClipCamera: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case fill
        case crop
    }

    var mode: Mode = .fill
    var x: Double = 0.5
    var y: Double = 0.5
    var zoom: Double = 1
    var roll: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1
    var focusAmount: Double = 0
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    var focusRadius: Double = 0.24
    /// Read for migration of older saved projects.
    var dolly: Double? = nil

    static let framingProperties: [AnimatableProperty] = [
        .cameraX, .cameraY, .cameraZoom, .cameraRoll, .cameraCropWidth, .cameraCropHeight,
        .cameraFocusAmount, .cameraFocusX, .cameraFocusY, .cameraFocusRadius
    ]
    static let properties = framingProperties

    static func keyPath(_ property: AnimatableProperty) -> WritableKeyPath<Self, Double>? {
        switch property {
        case .cameraX: \.x
        case .cameraY: \.y
        case .cameraZoom: \.zoom
        case .cameraRoll: \.roll
        case .cameraCropWidth: \.cropWidth
        case .cameraCropHeight: \.cropHeight
        case .cameraFocusAmount: \.focusAmount
        case .cameraFocusX: \.focusX
        case .cameraFocusY: \.focusY
        case .cameraFocusRadius: \.focusRadius
        default: nil
        }
    }

    var isValid: Bool {
        (dolly.map(AnimatableProperty.cameraDolly.range.contains) ?? true) && Self.properties.allSatisfy { property in
            guard let key = Self.keyPath(property) else { return false }
            return property.range.contains(self[keyPath: key])
        }
    }

    struct Frame: Equatable {
        let center: CGPoint
        let size: CGSize
        let travel: CGSize
        let radians: CGFloat

        func localPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - center.x, y: point.y - center.y)
                .applying(.init(rotationAngle: -radians))
        }

        func cameraCoordinate(of point: CGPoint) -> CGPoint {
            let local = localPoint(point)
            return CGPoint(x: min(1, max(0, 0.5 + local.x / size.width)),
                           y: min(1, max(0, 0.5 + local.y / size.height)))
        }
    }

    enum CropHandle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var direction: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: -1, y: -1)
            case .top: CGPoint(x: 0, y: -1)
            case .topRight: CGPoint(x: 1, y: -1)
            case .left: CGPoint(x: -1, y: 0)
            case .right: CGPoint(x: 1, y: 0)
            case .bottomLeft: CGPoint(x: -1, y: 1)
            case .bottom: CGPoint(x: 0, y: 1)
            case .bottomRight: CGPoint(x: 1, y: 1)
            }
        }

        func position(in size: CGSize) -> CGPoint {
            CGPoint(x: direction.x * size.width / 2, y: direction.y * size.height / 2)
        }

        static func hit(at point: CGPoint, in size: CGSize, tolerance: CGFloat) -> Self? {
            var closest: Self?
            var distance = tolerance
            for handle in allCases {
                let grip = handle.position(in: size)
                let candidate = hypot(point.x - grip.x, point.y - grip.y)
                if candidate <= distance { closest = handle; distance = candidate }
            }
            return closest
        }
    }

    private static let panZoom = 1.12

    func adjusting(_ property: AnimatableProperty, to number: Double,
                   source: CGSize, canvas: CGSize) -> Self {
        guard let key = Self.keyPath(property) else { return self }
        var updated = self
        let value = property.clamped(number)
        if mode == .fill, (property == .cameraX || property == .cameraY), value != 0.5 {
            let travel = frame(source: source, canvas: canvas).travel
            let available = property == .cameraX ? travel.width : travel.height
            if available < 1 { updated.zoom = max(zoom, Self.panZoom) }
        }
        updated[keyPath: key] = value
        return updated
    }

    func moving(by offset: CGPoint, zoomFactor: CGFloat, rotation: CGFloat,
                source: CGSize, canvas: CGSize, sourcePointsPerScreenPoint: CGFloat) -> Self {
        let before = frame(source: source, canvas: canvas)
        var updated = self
        updated.zoom = AnimatableProperty.cameraZoom.clamped(zoom * zoomFactor)
        updated.roll = AnimatableProperty.cameraRoll.clamped(roll + rotation * 180 / .pi)
        let travel = updated.frame(source: source, canvas: canvas).travel
        let threshold = 3 * sourcePointsPerScreenPoint
        let hasMovedOnLockedAxis = (travel.width < 1 && abs(offset.x) > threshold) ||
            (travel.height < 1 && abs(offset.y) > threshold)
        if mode == .fill, hasMovedOnLockedAxis, abs(zoomFactor - 1) < 0.01, abs(rotation) < 0.01 {
            updated.zoom = max(updated.zoom, Self.panZoom)
        }
        return updated.centered(at: CGPoint(x: before.center.x + offset.x, y: before.center.y + offset.y),
                                source: source, canvas: canvas, snapDistance: 4 * sourcePointsPerScreenPoint)
    }

    func resizing(_ handle: CropHandle, by offset: CGPoint, source: CGSize, canvas: CGSize) -> Self {
        let before = frame(source: source, canvas: canvas)
        let direction = handle.direction
        let local = offset.applying(.init(rotationAngle: -before.radians))
        let delta = CGSize(width: local.x * direction.x, height: local.y * direction.y)
        guard delta != .zero else { return self }
        let width = min(source.width, max(before.size.width + delta.width, source.width * 0.05 / zoom))
        let height = min(source.height, max(before.size.height + delta.height, source.height * 0.05 / zoom))
        let c = abs(cos(before.radians)), s = abs(sin(before.radians))
        let zoomLimit = min(source.width / (c * width + s * height),
                            source.height / (s * width + c * height))
        var updated = self
        // A crop grip can use available footage even when a previous zoom has
        // exhausted the crop slider. Preserve the requested frame dimensions.
        updated.zoom = max(1, min(zoom, zoomLimit))
        updated.cropWidth = AnimatableProperty.cameraCropWidth.clamped(width * updated.zoom / source.width)
        updated.cropHeight = AnimatableProperty.cameraCropHeight.clamped(height * updated.zoom / source.height)
        let after = updated.frame(source: source, canvas: canvas)
        let shift = CGPoint(x: direction.x * (after.size.width - before.size.width) / 2,
                            y: direction.y * (after.size.height - before.size.height) / 2)
            .applying(.init(rotationAngle: before.radians))
        return updated.centered(at: CGPoint(x: before.center.x + shift.x, y: before.center.y + shift.y),
                                source: source, canvas: canvas)
    }

    private func centered(at center: CGPoint, source: CGSize, canvas: CGSize, snapDistance: CGFloat = 0) -> Self {
        var updated = self
        let travel = frame(source: source, canvas: canvas).travel
        func position(_ center: CGFloat, length: CGFloat, travel: CGFloat) -> Double {
            let value = AnimatableProperty.cameraX.clamped(0.5 + (center - length / 2) / travel)
            let nearest = (value * 2).rounded() / 2
            return abs(value - nearest) * travel < min(snapDistance, travel * 0.12) ? nearest : value
        }
        if travel.width > 0.001 {
            updated.x = position(center.x, length: source.width, travel: travel.width)
        }
        if travel.height > 0.001 {
            updated.y = position(center.y, length: source.height, travel: travel.height)
        }
        return updated
    }

    func frame(source: CGSize, canvas: CGSize) -> Frame {
        let radians = CGFloat(roll) * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        let width = mode == .fill ? canvas.width / canvas.height : source.width * cropWidth
        let height = mode == .fill ? 1 : source.height * cropHeight
        let maxScale = min(source.width / (c * width + s * height),
                           source.height / (s * width + c * height))
        let scale = (mode == .fill ? maxScale : min(1, maxScale)) / zoom
        let size = CGSize(width: width * scale, height: height * scale)
        let travel = CGSize(width: max(0, source.width - c * size.width - s * size.height),
                            height: max(0, source.height - s * size.width - c * size.height))
        return Frame(center: CGPoint(x: source.width / 2 + (x - 0.5) * travel.width,
                                     y: source.height / 2 + (y - 0.5) * travel.height),
                     size: size, travel: travel, radians: radians)
    }
}

/// Places already graded, masked and stabilized source pixels through the
/// viewfinder, then places the resulting frame using the clip's authored Transform.
struct ClipPicturePlacement {
    let sourceToCanvas: CGAffineTransform
    let sourceToFrame: CGAffineTransform
    let frameToCanvas: CGAffineTransform
    let frameBounds: CGRect?
    let focus: ClipCamera?

    init(clip: VideoClip, encoded: CGSize, preferred: CGAffineTransform, canvas: CGSize) {
        guard let camera = clip.camera else {
            sourceToCanvas = LayerCompositor.transform(clip.transform, encoded: encoded,
                                                       preferred: preferred, canvas: canvas)
            sourceToFrame = sourceToCanvas
            frameToCanvas = .identity
            frameBounds = nil
            focus = nil
            return
        }
        let display = CGRect(origin: .zero, size: encoded).applying(preferred).standardized
        let frame = camera.frame(source: display.size, canvas: canvas)
        let fit = min(canvas.width / frame.size.width, canvas.height / frame.size.height)
        let size = CGSize(width: frame.size.width * fit, height: frame.size.height * fit)
        let bounds = CGRect(origin: .zero, size: size)
        sourceToFrame = Self.flip(encoded.height)
            .concatenating(preferred)
            .concatenating(.init(translationX: -display.minX - frame.center.x,
                                 y: -display.minY - frame.center.y))
            .concatenating(.init(rotationAngle: -frame.radians))
            .concatenating(.init(scaleX: fit, y: fit))
            .concatenating(.init(translationX: size.width / 2, y: size.height / 2))
            .concatenating(Self.flip(size.height))
        frameToCanvas = clip.transform.placement(bounds: bounds, canvas: canvas)
        sourceToCanvas = sourceToFrame.concatenating(frameToCanvas)
        frameBounds = bounds
        focus = camera.focusAmount > 0 ? camera : nil
    }

    init(clip: VideoClip, metadata: VideoMetadata, canvas: CGSize) {
        self.init(clip: clip, encoded: metadata.encodedSize,
                  preferred: metadata.preferredTransform.cgTransform, canvas: canvas)
    }

    func place(_ image: CIImage, applyingFocus: Bool = false) -> CIImage {
        guard let frameBounds else { return image.transformed(by: sourceToCanvas) }
        var framed = image.transformed(by: sourceToFrame).cropped(to: frameBounds)
        if applyingFocus, let focus {
            let shortEdge = min(frameBounds.width, frameBounds.height)
            let center = CIVector(x: focus.focusX * frameBounds.width,
                                  y: (1 - focus.focusY) * frameBounds.height)
            let selection = CIImage(color: .white).applyingFilter("CIRadialGradient", parameters: [
                "inputCenter": center, "inputRadius0": focus.focusRadius * shortEdge,
                "inputRadius1": (focus.focusRadius + 0.18) * shortEdge,
                "inputColor0": CIColor.black, "inputColor1": CIColor.white
            ]).cropped(to: frameBounds)
            let blurred = framed.clampedToExtent()
                .applyingGaussianBlur(sigma: focus.focusAmount * shortEdge * 0.016)
                .cropped(to: frameBounds)
            framed = blurred.applyingFilter("CIBlendWithMask", parameters: [
                "inputBackgroundImage": framed, "inputMaskImage": selection
            ]).cropped(to: frameBounds)
        }
        return framed.transformed(by: frameToCanvas)
    }

    private static func flip(_ height: CGFloat) -> CGAffineTransform {
        .init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}
