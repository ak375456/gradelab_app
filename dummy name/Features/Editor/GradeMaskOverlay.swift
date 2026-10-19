import SwiftUI

/// `softShapeMaskWeight` rotates in source UVs, before aspect fit, source
/// orientation or clip placement. Applying a screen-space rotation instead
/// stretches the wrong axes on every non-square picture.
struct GradeMaskGuideGeometry {
    let mask: GradeMask
    let picture: CGRect
    let sourceToView: CGAffineTransform

    init(mask: GradeMask, picture: CGRect, sourceToPicture: CGAffineTransform = .identity) {
        self.mask = mask.clamped
        self.picture = picture
        sourceToView = sourceToPicture.concatenating(
            CGAffineTransform(a: picture.width, b: 0, c: 0, d: picture.height,
                              tx: picture.minX, ty: picture.minY))
    }

    var center: CGPoint {
        sourcePoint(CGPoint(x: CGFloat(mask.centerX / 100), y: CGFloat(mask.centerY / 100)))
    }

    private var localToView: CGAffineTransform {
        CGAffineTransform(rotationAngle: CGFloat(mask.rotation) * .pi / 180)
            .concatenating(.init(translationX: CGFloat(mask.centerX / 100),
                                y: CGFloat(mask.centerY / 100)))
            .concatenating(sourceToView)
    }

    func sourcePoint(_ point: CGPoint) -> CGPoint { point.applying(sourceToView) }

    func sourceTranslation(_ translation: CGSize) -> CGPoint {
        let inverse = sourceToView.inverted()
        let origin = CGPoint.zero.applying(inverse)
        let endpoint = CGPoint(x: translation.width, y: translation.height).applying(inverse)
        return CGPoint(x: endpoint.x - origin.x, y: endpoint.y - origin.y)
    }

    /// The outer edge is zero coverage when feathered; the inset is the full
    /// coverage edge. This is the same normalized distance as the shader.
    func outline(insetFraction: CGFloat = 0) -> Path {
        if mask.shape == .linear { return gradientBoundary(offset: 0) }
        let scale = max(0, 1 - insetFraction)
        let halfWidth = max(CGFloat(mask.width / 200), 0.005) * scale
        let halfHeight = max(CGFloat(mask.height / 200), 0.005) * scale
        let bounds = CGRect(x: -halfWidth, y: -halfHeight,
                            width: halfWidth * 2, height: halfHeight * 2)
        let path = mask.shape == .ellipse ? Path(ellipseIn: bounds) : Path(bounds)
        return path.applying(localToView)
    }

    func gradientBoundary(offset: CGFloat) -> Path {
        // Enough reach to cross the visible picture even on a scaled layer.
        let inverse = localToView.inverted()
        let corners = [CGPoint(x: picture.minX, y: picture.minY),
                       CGPoint(x: picture.maxX, y: picture.minY),
                       CGPoint(x: picture.maxX, y: picture.maxY),
                       CGPoint(x: picture.minX, y: picture.maxY)]
        let reach = (corners.map { abs($0.applying(inverse).y) }.max() ?? 1) + 1
        var path = Path()
        path.move(to: CGPoint(x: offset, y: -reach).applying(localToView))
        path.addLine(to: CGPoint(x: offset, y: reach).applying(localToView))
        return path
    }
}

/// An editor-only outline of the legacy Color → Local window. The rendering
/// and saved mask stay unchanged; the guide follows their actual geometry.
struct GradeMaskOverlay<Model: GradingModel>: View {
    @ObservedObject var model: Model
    let displayedRect: () -> CGRect?
    var sourceToPicture: () -> CGAffineTransform = { .identity }
    var isZooming = false
    @Environment(\.previewMagnification) private var magnification
    @State private var dragOrigin: CGPoint?
    @State private var snappedToVerticalCenter = false
    @State private var snappedToHorizontalCenter = false
    @GestureState private var isInteracting = false

    var body: some View {
        GeometryReader { proxy in
            let picture = pictureRect(in: proxy.size)
            let geometry = GradeMaskGuideGeometry(mask: model.displayedGradeMask,
                picture: picture, sourceToPicture: sourceToPicture())
            Canvas { context, _ in
                context.clip(to: Path(picture))
                drawGuides(geometry, context: &context)
                let tint = geometry.mask.isEnabled ? AppColors.accent : AppColors.textSecondary
                let outline = geometry.outline()
                context.stroke(outline, with: .color(.black.opacity(0.8)), lineWidth: 4 / magnification)
                context.stroke(outline, with: .color(tint),
                    style: StrokeStyle(lineWidth: 1.75 / magnification,
                                       dash: [7 / magnification, 5 / magnification]))
                let feather = CGFloat(geometry.mask.feather / 100)
                if feather > 0 {
                    let boundaries = geometry.mask.shape == .linear
                        ? [-1.0, 1.0].map { geometry.gradientBoundary(offset: $0 * feather * 0.25) }
                        : [geometry.outline(insetFraction: feather)]
                    for boundary in boundaries {
                        context.stroke(boundary, with: .color(tint.opacity(0.48)),
                            style: StrokeStyle(lineWidth: 1 / magnification,
                                               dash: [3 / magnification, 4 / magnification]))
                    }
                }
                let radius = 7 / magnification
                let handle = Path(ellipseIn: CGRect(x: geometry.center.x - radius,
                    y: geometry.center.y - radius, width: radius * 2, height: radius * 2))
                context.fill(handle, with: .color(tint))
                context.stroke(handle, with: .color(.black.opacity(0.75)), lineWidth: 2 / magnification)
            }
            .contentShape(hitRegion(geometry))
            .gesture(moveGesture(geometry))
        }
        .onChange(of: isZooming) { _, zooming in if zooming { finishInteraction() } }
        .onChange(of: isInteracting) { _, active in if !active { finishInteraction() } }
        .onChange(of: model.gradeSubjectID) { _, _ in finishInteraction() }
        .onDisappear { finishInteraction() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.displayedGradeMask.shape.title + " grading mask")
        .accessibilityValue(model.displayedGradeMask.isEnabled ? "On" : "Off")
        .accessibilityHint("Drag to move the mask on the picture")
    }

    private func hitRegion(_ geometry: GradeMaskGuideGeometry) -> Path {
        if geometry.mask.shape == .linear { return Path(geometry.picture) }
        var region = geometry.outline()
        region.addPath(Path(region.cgPath.copy(strokingWithWidth: 44 / magnification,
            lineCap: .round, lineJoin: .round, miterLimit: 10)))
        return region
    }

    private func drawGuides(_ geometry: GradeMaskGuideGeometry, context: inout GraphicsContext) {
        for (snapped, start, end) in [
            (snappedToVerticalCenter, CGPoint(x: 0.5, y: -2), CGPoint(x: 0.5, y: 3)),
            (snappedToHorizontalCenter, CGPoint(x: -2, y: 0.5), CGPoint(x: 3, y: 0.5))
        ] where snapped {
            var guide = Path()
            guide.move(to: geometry.sourcePoint(start))
            guide.addLine(to: geometry.sourcePoint(end))
            context.stroke(guide, with: .color(AppColors.accent.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1 / magnification, dash: [4, 4]))
        }
    }

    private func pictureRect(in size: CGSize) -> CGRect {
        guard let rect = displayedRect(), rect.width > 0, rect.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                      width: rect.width * size.width, height: rect.height * size.height)
    }

    private func moveGesture(_ geometry: GradeMaskGuideGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isInteracting) { _, active, _ in if !isZooming { active = true } }
            .onChanged { value in
                guard !isZooming, model.canGrade else { return }
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: CGFloat(model.displayedGradeMask.centerX / 100),
                                         y: CGFloat(model.displayedGradeMask.centerY / 100))
                }
                guard let origin = dragOrigin else { return }
                let delta = geometry.sourceTranslation(value.translation)
                var x = min(1, max(0, origin.x + delta.x))
                var y = min(1, max(0, origin.y + delta.y))
                let t = geometry.sourceToView
                let snapX = abs(x - 0.5) <= 12 / max(hypot(t.a, t.b) * magnification, 1)
                let snapY = abs(y - 0.5) <= 12 / max(hypot(t.c, t.d) * magnification, 1)
                if snapX { x = 0.5 }
                if snapY { y = 0.5 }
                if (snapX && !snappedToVerticalCenter) || (snapY && !snappedToHorizontalCenter) {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                snappedToVerticalCenter = snapX
                snappedToHorizontalCenter = snapY
                if let editor = model as? EditorViewModel {
                    editor.setAnimatableValue(.localMaskPositionX, .number(Double(x)))
                    editor.setAnimatableValue(.localMaskPositionY, .number(Double(y)))
                } else {
                    model.gradeMaskBinding(\.centerX).wrappedValue = Float(x * 100)
                    model.gradeMaskBinding(\.centerY).wrappedValue = Float(y * 100)
                }
            }
            .onEnded { _ in finishInteraction() }
    }

    private func finishInteraction() {
        if dragOrigin != nil { model.flushGradeHistory() }
        dragOrigin = nil
        snappedToVerticalCenter = false
        snappedToHorizontalCenter = false
    }
}
