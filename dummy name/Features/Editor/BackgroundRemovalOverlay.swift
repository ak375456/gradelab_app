import SwiftUI

/// Direct, source-normalized interaction over the preview. This view is editor
/// furniture only; its paths never enter a rendered or exported frame.
struct BackgroundRemovalOverlay: View {
    @ObservedObject var model: EditorViewModel
    let displayedRect: () -> CGRect?
    /// True while the preview is being pinched. The pinch's first finger lands
    /// as an ordinary drag on this overlay, so without this a zoom would leave
    /// a stray dab or replace the outline with the two inches the finger
    /// travelled before its partner arrived.
    var isZooming = false
    @State private var stroke: [MaskPoint] = []
    @State private var displayStroke: [CGPoint] = []
    @State private var cursor: CGPoint?
    @State private var loupeImage: CGImage?

    private var isDrawingLasso: Bool { model.isDrawingBackgroundLasso }
    private var isArmed: Bool {
        model.backgroundBrush != nil || isDrawingLasso || model.isPickingBackgroundColor
    }

    /// The committed outline, where there is one to show. Drawn even when no
    /// tool is armed, because the whole point of a lasso is that you can see
    /// what you selected — and, once tracked, watch it hold on the object as
    /// you scrub.
    private var committedOutline: [CGPoint]? {
        guard let settings = model.selectedBackgroundRemoval, settings.mode == .lasso,
              let lasso = settings.lasso, lasso.isDrawn, !isDrawingLasso else { return nil }
        let local = model.selectedClip?.localTime(for: model.playheadTime)
        return lasso.outline(atLocal: local)
    }

    var body: some View {
        GeometryReader { proxy in
            let picture = pictureRect(proxy.size)
            ZStack {
                Canvas { context, _ in
                    if let outline = committedOutline {
                        drawCommitted(outline, in: &context, picture: picture)
                    }
                    if isDrawingLasso, displayStroke.count > 1 {
                        drawLassoInProgress(&context)
                    }
                    guard model.backgroundBrush != nil, let cursor else { return }
                    drawBrushCursor(&context, cursor: cursor, picture: picture)
                }.allowsHitTesting(false)
                if let cursor, isArmed, model.backgroundBrush != nil || isDrawingLasso,
                   let loupeImage {
                    magnifier(image: loupeImage, cursor: cursor, picture: picture, canvas: proxy.size)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(interaction(in: picture))
                    .allowsHitTesting(isArmed)
            }
        }
        .accessibilityLabel(model.backgroundBrush == .add ? "Add cutout brush" :
                            model.backgroundBrush == .remove ? "Remove cutout brush" :
                            isDrawingLasso ? "Lasso selection" : "Background selection")
    }

    // MARK: - Drawing

    /// A dark underlay beneath every line: an accent-only outline disappears
    /// over the many pictures that happen to be that colour.
    private func drawCommitted(_ outline: [CGPoint], in context: inout GraphicsContext,
                               picture: CGRect) {
        var path = Path()
        let points = outline.map { displayPoint($0, picture) }
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 3)
        context.stroke(path, with: .color(AppColors.accent),
                       style: .init(lineWidth: 1.5, dash: [6, 4]))
    }

    private func drawLassoInProgress(_ context: inout GraphicsContext) {
        var path = Path()
        path.move(to: displayStroke[0])
        for point in displayStroke.dropFirst() { path.addLine(to: point) }
        context.stroke(path, with: .color(.black.opacity(0.55)),
                       style: .init(lineWidth: 4, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(AppColors.accent),
                       style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
        // The closing edge, shown dashed while the drag is live, so it is
        // obvious the shape closes itself and a full circuit is not required.
        if let last = displayStroke.last, let first = displayStroke.first {
            var closing = Path()
            closing.move(to: last)
            closing.addLine(to: first)
            context.stroke(closing, with: .color(.white.opacity(0.75)),
                           style: .init(lineWidth: 1.5, dash: [5, 5]))
            context.fill(Path(ellipseIn: CGRect(x: first.x - 4, y: first.y - 4, width: 8, height: 8)),
                         with: .color(AppColors.accent))
        }
    }

    private func drawBrushCursor(_ context: inout GraphicsContext, cursor: CGPoint, picture: CGRect) {
        let tint: Color = model.backgroundBrush == .remove ? .red : AppColors.accent
        let diameter = CGFloat(model.backgroundBrushSize) * min(picture.width, picture.height) * 2
        if !displayStroke.isEmpty {
            var path = Path()
            path.move(to: displayStroke[0])
            for point in displayStroke.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(tint.opacity(0.28)),
                           style: .init(lineWidth: diameter, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(tint.opacity(0.95)),
                           style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        let rect = CGRect(x: cursor.x - diameter / 2, y: cursor.y - diameter / 2,
                          width: diameter, height: diameter)
        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.16)))
        context.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(0.95)), lineWidth: 2)
        context.stroke(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)),
                       with: .color(.black.opacity(0.7)), lineWidth: 1)
    }

    // MARK: - Interaction

    private func interaction(in picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isZooming else { discardStroke(); return }
                guard picture.contains(value.location) else { return }
                if cursor == nil { loupeImage = model.renderer.currentInteractionImage() }
                cursor = value.location
                let point = sourcePoint(value.location, picture)
                guard model.backgroundBrush != nil || isDrawingLasso else { return }
                // A lasso is traced far more finely than a brush stroke, so it
                // samples at a quarter of the distance before thinning.
                let minimumStep = isDrawingLasso ? 0.0008 : 0.002
                if let last = stroke.last,
                   hypot(point.x - last.x, point.y - last.y) <= minimumStep { return }
                stroke.append(point)
                displayStroke.append(value.location)
            }
            .onEnded { value in
                defer { discardStroke() }
                guard !isZooming else { return }
                let point = sourcePoint(value.location, picture)
                if model.backgroundBrush != nil {
                    model.addBackgroundStroke(stroke.isEmpty ? [point] : stroke)
                } else if isDrawingLasso {
                    model.commitBackgroundLasso(stroke)
                } else if model.isPickingBackgroundColor {
                    model.pickBackgroundColor(atSourcePoint: CGPoint(x: point.x, y: point.y))
                }
            }
    }

    private func discardStroke() {
        stroke.removeAll()
        displayStroke.removeAll()
        cursor = nil
        loupeImage = nil
    }

    /// The loupe.
    ///
    /// Picture and overlay are drawn into ONE canvas, in one coordinate space,
    /// rather than stacked as separate views that each get laid out their own
    /// way. That is what keeps the line registered to the pixels underneath
    /// it: anything drawn here is positioned by the same rule as the picture.
    private func magnifier(image: CGImage, cursor: CGPoint, picture: CGRect, canvas: CGSize) -> some View {
        // The lasso gets a wider, less magnified loupe. At 2.35x a 106pt
        // circle only covers ±22pt of picture, which is too small to show the
        // shape of the line you are tracing — the whole reason to look at it.
        let diameter: CGFloat = isDrawingLasso ? 136 : 106
        let zoom: CGFloat = isDrawingLasso ? 1.9 : 2.35
        let brushDiameter = model.backgroundBrush == nil ? 14
            : CGFloat(model.backgroundBrushSize) * min(picture.width, picture.height) * 2
        let local = CGPoint(x: min(max(cursor.x - picture.minX, 0), picture.width),
                            y: min(max(cursor.y - picture.minY, 0), picture.height))
        // Always above the finger, clamped rather than flipped. A loupe that
        // jumps to the other side mid-stroke moves exactly when the user is
        // concentrating on an edge, so it is allowed to ride up over the top
        // of the picture instead of changing sides.
        let center = CGPoint(
            x: min(max(cursor.x, diameter / 2 + 8), canvas.width - diameter / 2 - 8),
            y: max(diameter / 2 + 8, cursor.y - diameter / 2 - 28))
        let tint: Color = model.backgroundBrush == .remove ? .red : AppColors.accent
        let snapshot = Image(decorative: image, scale: 1, orientation: .up)
        return Canvas { context, size in
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            // Every point in this canvas is placed by this one rule: the
            // picture-local point under the finger sits in the middle, and
            // everything else is that offset times the zoom.
            func place(_ point: CGPoint) -> CGPoint {
                CGPoint(x: middle.x + (point.x - picture.minX - local.x) * zoom,
                        y: middle.y + (point.y - picture.minY - local.y) * zoom)
            }
            context.draw(snapshot, in: CGRect(origin: place(picture.origin),
                                                size: CGSize(width: picture.width * zoom,
                                                             height: picture.height * zoom)))
            context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)),
                         with: .color(tint.opacity(0.10)))
            drawStrokeInLoupe(&context, place: place, brushWidth: brushDiameter * zoom, tint: tint)
            if isDrawingLasso {
                // Ticks with a gap in the middle: a full crosshair would sit
                // on top of the one pixel the user is aiming at.
                var ticks = Path()
                for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    ticks.move(to: CGPoint(x: middle.x + dx * 7, y: middle.y + dy * 7))
                    ticks.addLine(to: CGPoint(x: middle.x + dx * 15, y: middle.y + dy * 15))
                }
                context.stroke(ticks, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            } else {
                let reticle = min(size.width - 12, max(8, brushDiameter))
                context.stroke(Path(ellipseIn: CGRect(
                    x: middle.x - reticle / 2, y: middle.y - reticle / 2,
                    width: reticle, height: reticle)), with: .color(.white.opacity(0.9)), lineWidth: 1)
                let arm = min(reticle / 2, 24)
                var cross = Path()
                cross.move(to: CGPoint(x: middle.x - arm, y: middle.y))
                cross.addLine(to: CGPoint(x: middle.x + arm, y: middle.y))
                cross.move(to: CGPoint(x: middle.x, y: middle.y - arm))
                cross.addLine(to: CGPoint(x: middle.x, y: middle.y + arm))
                context.stroke(cross, with: .color(.white.opacity(0.85)), lineWidth: 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(tint, lineWidth: 3))
        .shadow(color: .black.opacity(0.55), radius: 8, y: 4)
        .position(center)
    }

    /// The live stroke, placed by the loupe's own rule so it lands exactly on
    /// the pixels it was drawn over. The loupe is a snapshot of the rendered
    /// frame and never contains the line, so without this the one thing the
    /// user is looking at is the one thing the loupe does not show.
    private func drawStrokeInLoupe(_ context: inout GraphicsContext,
                                   place: (CGPoint) -> CGPoint,
                                   brushWidth: CGFloat, tint: Color) {
        guard displayStroke.count > 1 else { return }
        var path = Path()
        path.move(to: place(displayStroke[0]))
        for point in displayStroke.dropFirst() { path.addLine(to: place(point)) }
        if isDrawingLasso {
            context.stroke(path, with: .color(.black.opacity(0.6)),
                           style: .init(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(tint),
                           style: .init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            guard let first = displayStroke.first, let last = displayStroke.last else { return }
            var closing = Path()
            closing.move(to: place(last)); closing.addLine(to: place(first))
            context.stroke(closing, with: .color(.white.opacity(0.8)),
                           style: .init(lineWidth: 1.5, dash: [5, 5]))
            let start = place(first)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)),
                         with: .color(tint))
        } else {
            context.stroke(path, with: .color(tint.opacity(0.30)),
                           style: .init(lineWidth: max(2, brushWidth), lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(tint.opacity(0.95)),
                           style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Coordinates

    private func pictureRect(_ size: CGSize) -> CGRect {
        guard let rect = displayedRect() else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                      width: rect.width * size.width, height: rect.height * size.height)
    }

    /// The one conversion between what the user touches and what the document
    /// stores. `displayPoint` is its exact inverse, so an outline drawn on a
    /// rotated or transformed clip redraws on top of itself.
    private func sourcePoint(_ point: CGPoint, _ picture: CGRect) -> MaskPoint {
        var normalized = CGPoint(x: (point.x - picture.minX) / max(picture.width, 1),
                                 y: (point.y - picture.minY) / max(picture.height, 1))
        guard let coordinates = sourceCoordinates() else {
            return .init(x: normalized.x, y: normalized.y)
        }
        if let transform = canvasTransform(coordinates) {
            normalized = normalized.applying(transform.inverted())
        } else {
            normalized = coordinates.displayToSource(normalized)
        }
        return .init(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
    }

    private func displayPoint(_ source: CGPoint, _ picture: CGRect) -> CGPoint {
        var normalized = source
        if let coordinates = sourceCoordinates() {
            if let transform = canvasTransform(coordinates) {
                normalized = normalized.applying(transform)
            } else {
                normalized = coordinates.sourceToDisplay(normalized)
            }
        }
        return CGPoint(x: picture.minX + normalized.x * picture.width,
                       y: picture.minY + normalized.y * picture.height)
    }

    private func sourceCoordinates() -> MaskTrackingCoordinates? {
        guard let clip = model.evaluatedSelectedClip,
              let asset = model.project.assets.first(where: { $0.id == clip.assetID }) else { return nil }
        let encoded = asset.videoMetadata?.encodedSize
            ?? CGSize(width: asset.stillImage?.width ?? 1, height: asset.stillImage?.height ?? 1)
        let preferred = asset.videoMetadata?.preferredTransform.cgTransform ?? .identity
        return try? MaskTrackingCoordinates(encodedSize: encoded, preferredTransform: preferred)
    }

    private func canvasTransform(_ coordinates: MaskTrackingCoordinates) -> CGAffineTransform? {
        guard model.maskOverlayUsesCanvas, let clip = model.evaluatedSelectedClip else { return nil }
        let canvas = CGSize(width: model.project.canvas.width, height: model.project.canvas.height)
        return coordinates.sourceToCanvasTransform(clip.transform, canvas: canvas)
    }
}
