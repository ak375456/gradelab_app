import SwiftUI

// ---------------------------------------------------------------------------
// Direct manipulation of a power window on the preview
//
// The geometry drawn here is the SAME geometry the shader evaluates, expressed
// as its inverse: the shader maps a pixel into the mask's aspect-corrected local
// space, and this maps that local space back out to the view. There is no second
// idea of where the window is, so the outline cannot drift from the grade.
//
// Nothing here is ever rendered into a frame. It is editor furniture, drawn over
// the Metal preview and gone the moment the tool is closed.
// ---------------------------------------------------------------------------

struct MaskOverlay: View {
    @ObservedObject var model: EditorViewModel
    @Environment(\.previewMagnification) private var magnification
    /// The renderer returns the aspect-fitted picture as a rectangle in
    /// normalised view space, so the guide letterboxes exactly as Metal does.
    let displayedRect: () -> CGRect?
    var isZooming = false

    private enum Handle: Equatable {
        case move
        case resizeWidth(Double)   // sign along the local x axis
        case resizeHeight(Double)
        case rotate
        case feather
        case vertex(Int)
        case tangent(Int, incoming: Bool)
    }

    @State private var active: Handle?
    @State private var start: MaskGeometry?
    @State private var startPoint: CGPoint?
    /// Pending input lives in the overlay until release. Native pinch/pan
    /// cancellation can discard it without changing the document or Undo.
    @State private var lastDrawLocation: CGPoint?
    @State private var stroke: [MaskPoint] = []
    @State private var draft: MaskGeometry?
    @GestureState private var isInteracting = false

    /// How close a finger has to be to grab a handle. A comfortable target
    /// without making the whole shape un-draggable on a small preview.
    private var grabRadius: CGFloat { 26 / max(magnification, 0.5) }

    var body: some View {
        GeometryReader { proxy in
            let picture = pictureRect(in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    // Every other mask, faintly: placing one window while the
                    // others are invisible is how two masks end up on the same
                    // face without anyone noticing.
                    for mask in model.maskedGrades where mask.id != model.selectedMaskID {
                        guard mask.isEnabled, mask.geometry.isRenderable else { continue }
                        draw(model.displayedMask(mask.id) ?? mask, in: picture, context: &context, selected: false)
                    }
                    if let mask = model.displayedSelectedMask {
                        var displayed = mask
                        if let draft { displayed.geometry = draft }
                        if !stroke.isEmpty { displayed.geometry.points += stroke }
                        draw(displayed, in: picture, context: &context, selected: true)
                    }
                }
                .allowsHitTesting(false)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .allowsHitTesting(model.selectedMaskID.map { !model.isTrackingMask($0) } ?? true)
                    .gesture(dragGesture(in: picture))
            }
        }
        .onChange(of: isZooming) { _, zooming in if zooming { discardInteraction() } }
        .onChange(of: isInteracting) { _, interacting in if !interacting { discardInteraction() } }
        .onChange(of: model.selectedMaskID) { _, _ in discardInteraction() }
        .onChange(of: model.playheadTime) { _, _ in discardInteraction() }
        .onDisappear { discardInteraction() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Drag the shape to move it, or its handles to resize, rotate and soften it.")
    }

    private var accessibilityLabel: String {
        guard let mask = model.displayedSelectedMask else { return String(localized: "Mask editing") }
        return String(localized: "\(mask.name), \(mask.geometry.shape.title) mask")
    }

    // MARK: - Geometry

    private func pictureRect(in size: CGSize) -> CGRect {
        guard let rect = displayedRect() else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                      width: rect.width * size.width, height: rect.height * size.height)
    }

    private var coordinates: MaskTrackingCoordinates? {
        guard let clip = model.selectedClip,
              let metadata = model.project.assets.first(where: { $0.id == clip.assetID })?.videoMetadata else { return nil }
        return try? MaskTrackingCoordinates(encodedSize: metadata.encodedSize,
                                            preferredTransform: metadata.preferredTransform.cgTransform)
    }

    private func aspect(_ picture: CGRect) -> Double {
        coordinates?.aspect ?? Double(picture.width / max(1, picture.height))
    }

    private var canvasTransform: CGAffineTransform? {
        guard model.maskOverlayUsesCanvas, let coordinates, let clip = model.evaluatedSelectedClip else { return nil }
        return coordinates.sourceToCanvasTransform(clip.transform,
            canvas: CGSize(width: model.project.canvas.width, height: model.project.canvas.height))
    }

    private func sourceToView(_ point: CGPoint, _ picture: CGRect) -> CGPoint {
        let p: CGPoint
        if let canvasTransform { p = point.applying(canvasTransform) }
        else { p = coordinates?.sourceToDisplay(point) ?? point }
        return CGPoint(x: picture.minX + p.x * picture.width, y: picture.minY + p.y * picture.height)
    }

    private func vertexToView(_ point: MaskPoint, _ g: MaskGeometry, _ picture: CGRect) -> CGPoint {
        sourceToView(MaskTrackingCoordinates.placedVertex(point, geometry: g, aspect: aspect(picture)), picture)
    }

    /// Mask-local (aspect-corrected, centred, unrotated) → view point.
    private func toView(_ local: CGPoint, _ geometry: MaskGeometry, _ picture: CGRect) -> CGPoint {
        let a = aspect(picture)
        let theta = geometry.rotationDegrees * .pi / 180
        let x = cos(theta) * local.x - sin(theta) * local.y
        let y = sin(theta) * local.x + cos(theta) * local.y
        let u = geometry.centerX + Double(x) / a
        let v = geometry.centerY + Double(y)
        return sourceToView(CGPoint(x: u, y: v), picture)
    }

    /// View point → mask-local. The exact inverse of `toView`, and the same
    /// transform `localMaskWeight` applies per pixel.
    private func toLocal(_ point: CGPoint, _ geometry: MaskGeometry, _ picture: CGRect) -> CGPoint {
        let a = aspect(picture)
        let source = normalized(point, picture)
        let u = source.x - geometry.centerX
        let v = source.y - geometry.centerY
        let vx = u * a, vy = v
        let theta = geometry.rotationDegrees * .pi / 180
        return CGPoint(x: cos(theta) * vx + sin(theta) * vy,
                       y: -sin(theta) * vx + cos(theta) * vy)
    }

    /// A frame-normalised coordinate for a view point.
    private func normalized(_ point: CGPoint, _ picture: CGRect) -> MaskPoint {
        let p = CGPoint(x: (point.x - picture.minX) / max(picture.width, 1),
                        y: (point.y - picture.minY) / max(picture.height, 1))
        let source: CGPoint
        if let canvasTransform { source = p.applying(canvasTransform.inverted()) }
        else { source = coordinates?.displayToSource(p) ?? p }
        return MaskPoint(x: source.x, y: source.y)
    }

    /// Half width and height in the aspect-corrected local space.
    private func halfSize(_ geometry: MaskGeometry, _ picture: CGRect) -> CGSize {
        let a = aspect(picture)
        return CGSize(width: max(geometry.width, 0.001) * 0.5 * a,
                      height: max(geometry.height, 0.001) * 0.5)
    }

    /// The feather band's width, in the same units the shader uses for it.
    private func softness(_ geometry: MaskGeometry, _ picture: CGRect) -> Double {
        let half = halfSize(geometry, picture)
        switch geometry.shape {
        case .ellipse, .rectangle:
            return geometry.feather * Double(min(half.width, half.height))
        case .linear:
            return geometry.feather * 0.5
        case .freehand:
            return geometry.feather * 0.15
        }
    }

    // MARK: - Drawing

    private func draw(_ mask: MaskedGradeLayer, in picture: CGRect,
                      context: inout GraphicsContext, selected: Bool) {
        let unclipped = context
        defer { context = unclipped }
        context.clip(to: Path(picture))
        let geometry = mask.geometry.clamped
        let tint = selected ? AppColors.accent : AppColors.textSecondary
        let opacity = selected ? 1.0 : 0.35
        let outline = path(for: geometry, inset: 0, picture: picture)

        // The coverage tint: a professional matte colour that cannot be mistaken
        // for picture. Drawn over the preview and never into it.
        if selected, model.showsMaskOverlay {
            var fill = outline
            if geometry.isInverted {
                var inverted = Path(picture)
                inverted.addPath(outline)
                fill = inverted
            }
            context.fill(fill, with: .color(Color(red: 1, green: 0.18, blue: 0.55).opacity(0.28)),
                         style: FillStyle(eoFill: true))
        }

        context.stroke(outline, with: .color(.black.opacity(0.75)), lineWidth: 4 / magnification)
        context.stroke(outline, with: .color(tint.opacity(opacity)),
                       style: StrokeStyle(lineWidth: 1.75 / magnification, dash: geometry.isInverted ? [6, 4] : []))

        guard selected else { return }

        // The feather band, so softness is something you can see rather than a
        // number you have to guess at.
        let soft = softness(geometry, picture)
        if soft > 0.0005 {
            for sign in [-1.0, 1.0] where geometry.shape != .linear || sign > 0 {
                let band = path(for: geometry, inset: sign * soft, picture: picture)
                context.stroke(band, with: .color(tint.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1 / magnification, dash: [3, 4]))
            }
            if geometry.shape == .linear {
                let band = path(for: geometry, inset: -soft, picture: picture)
                context.stroke(band, with: .color(tint.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1 / magnification, dash: [3, 4]))
            }
        }

        // Handles at a sky/frame boundary can extend into the letterbox.
        context = unclipped
        for handle in handlePositions(geometry, picture) {
            dot(at: handle.point, filled: handle.filled, tint: tint, context: &context)
        }

        if geometry.shape == .freehand {
            if !model.isDrawingMask, let index = model.selectedMaskPointIndex,
               geometry.points.indices.contains(index) {
                let anchor = geometry.points[index]
                let origin = vertexToView(anchor, geometry, picture)
                for incoming in [true, false] {
                    let tangent = geometry.suggestedTangent(at: index, incoming: incoming)
                    let endpoint = vertexToView(MaskPoint(x: anchor.x + tangent.x, y: anchor.y + tangent.y), geometry, picture)
                    var line = Path(); line.move(to: origin); line.addLine(to: endpoint)
                    context.stroke(line, with: .color(.black.opacity(0.7)), lineWidth: 3 / magnification)
                    context.stroke(line, with: .color(tint), lineWidth: 1 / magnification)
                    dot(at: endpoint, filled: false, tint: tint, context: &context, radius: 6)
                }
            }
            for (index, point) in geometry.points.enumerated() {
                let view = vertexToView(point, geometry, picture)
                let selected = model.selectedMaskPointIndex == index
                dot(at: view, filled: selected, tint: tint, context: &context, radius: selected ? 7 : 5)
            }
        }
    }

    private func dot(at point: CGPoint, filled: Bool, tint: Color,
                     context: inout GraphicsContext, radius: CGFloat = 6) {
        let radius = radius / max(magnification, 0.5)
        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect.insetBy(dx: -1.5 / magnification, dy: -1.5 / magnification)),
                     with: .color(.black.opacity(0.7)))
        context.fill(Path(ellipseIn: rect), with: .color(filled ? tint : Color.white.opacity(0.9)))
    }

    /// The outline, optionally grown by `inset` in local units to draw a feather
    /// band. Built from the same local space the shader measures in, so what is
    /// drawn is what is graded.
    private func path(for geometry: MaskGeometry, inset: Double, picture: CGRect) -> Path {
        var path = Path()
        let half = halfSize(geometry, picture)
        switch geometry.shape {
        case .ellipse:
            let rx = Double(half.width) + inset, ry = Double(half.height) + inset
            guard rx > 0, ry > 0 else { return path }
            let steps = 72
            for step in 0...steps {
                let angle = Double(step) / Double(steps) * 2 * .pi
                let point = CGPoint(x: rx * cos(angle), y: ry * sin(angle))
                let view = toView(point, geometry, picture)
                if step == 0 { path.move(to: view) } else { path.addLine(to: view) }
            }
            path.closeSubpath()
        case .rectangle:
            let hx = Double(half.width) + inset, hy = Double(half.height) + inset
            guard hx > 0, hy > 0 else { return path }
            let radius = min(geometry.cornerRadius, 1) * min(hx, hy)
            // Traced rather than drawn as a rounded rect, because the shape has
            // to pass through the same rotation the shader applies.
            var samples: [CGPoint] = []
            let corners: [(Double, Double, Double)] = [
                (hx - radius, hy - radius, 0), (-(hx - radius), hy - radius, .pi / 2),
                (-(hx - radius), -(hy - radius), .pi), (hx - radius, -(hy - radius), 3 * .pi / 2)
            ]
            for (cx, cy, base) in corners {
                let steps = radius > 0 ? 10 : 1
                for step in 0...steps {
                    let angle = base + Double(step) / Double(steps) * (.pi / 2)
                    samples.append(CGPoint(x: cx + radius * cos(angle), y: cy + radius * sin(angle)))
                }
            }
            for (index, point) in samples.enumerated() {
                let view = toView(point, geometry, picture)
                if index == 0 { path.move(to: view) } else { path.addLine(to: view) }
            }
            path.closeSubpath()
        case .linear:
            // The transition line itself. `inset` offsets it along the local y
            // axis to show where the gradient starts and ends.
            let reach = 4.0
            path.move(to: toView(CGPoint(x: -reach, y: inset), geometry, picture))
            path.addLine(to: toView(CGPoint(x: reach, y: inset), geometry, picture))
        case .freehand:
            guard geometry.points.count >= 2 else { return path }
            let a = aspect(picture)
            let theta = geometry.rotationDegrees * .pi / 180
            // Vertices live about the pivot; the mask is positioned by its
            // centre, so the two together are the translation.
            func place(_ point: MaskPoint) -> CGPoint {
                var lx = (point.x - geometry.pivotX) * a * max(geometry.width, 0.01)
                var ly = (point.y - geometry.pivotY) * max(geometry.height, 0.01)
                if inset != 0 {
                    let length = max(sqrt(lx * lx + ly * ly), 0.0001)
                    lx += lx / length * inset
                    ly += ly / length * inset
                }
                let rx = cos(theta) * lx - sin(theta) * ly
                let ry = sin(theta) * lx + cos(theta) * ly
                return sourceToView(CGPoint(x: geometry.centerX + rx / a, y: geometry.centerY + ry), picture)
            }
            for (index, point) in geometry.renderPoints.enumerated() {
                let view = place(point)
                if index == 0 { path.move(to: view) } else { path.addLine(to: view) }
            }
            path.closeSubpath()
        }
        return path
    }

    private func handlePositions(_ geometry: MaskGeometry, _ picture: CGRect) -> [(handle: Handle, point: CGPoint, filled: Bool)] {
        // An empty freehand mask used to show a blue centre handle. It looked
        // actionable, but there was no polygon for that handle to move. During
        // drawing the vertices are the interaction, so keep the misleading
        // handle out of the way until the path is finished.
        if geometry.shape == .freehand, model.isDrawingMask { return [] }
        var handles: [(Handle, CGPoint, Bool)] = [(.move, toView(.zero, geometry, picture), true)]
        let half = halfSize(geometry, picture)
        let soft = softness(geometry, picture)
        switch geometry.shape {
        case .ellipse, .rectangle:
            handles.append((.resizeWidth(1), toView(CGPoint(x: half.width, y: 0), geometry, picture), false))
            handles.append((.resizeWidth(-1), toView(CGPoint(x: -half.width, y: 0), geometry, picture), false))
            handles.append((.resizeHeight(1), toView(CGPoint(x: 0, y: half.height), geometry, picture), false))
            handles.append((.resizeHeight(-1), toView(CGPoint(x: 0, y: -half.height), geometry, picture), false))
            handles.append((.rotate, toView(CGPoint(x: 0, y: -Double(half.height) - 0.09), geometry, picture), true))
            handles.append((.feather, toView(CGPoint(x: Double(half.width) + soft, y: 0), geometry, picture), true))
        case .linear:
            handles.append((.rotate, toView(CGPoint(x: 0.3, y: 0), geometry, picture), true))
            handles.append((.feather, toView(CGPoint(x: 0, y: soft), geometry, picture), true))
        case .freehand:
            guard !geometry.points.isEmpty else { break }
            handles.append((.rotate, toView(CGPoint(x: 0, y: -0.3), geometry, picture), true))
        }
        return handles.map { (handle: $0.0, point: $0.1, filled: $0.2) }
    }

    // MARK: - Gestures

    private func dragGesture(in picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isInteracting) { _, state, _ in state = true }
            .onChanged { value in
                guard !isZooming, let mask = model.displayedSelectedMask else { return }
                if model.playback.isPlaying { model.playback.pause() }
                if model.isDrawingMask, mask.geometry.shape == .freehand {
                    appendDrawPointIfNeeded(value.location, to: mask, in: picture)
                    return
                }
                if active == nil {
                    active = hitTest(value.startLocation, mask.geometry, picture)
                    start = mask.geometry
                    startPoint = value.startLocation
                    if case .vertex(let index) = active { model.selectedMaskPointIndex = index }
                }
                guard let active, let start,
                      hypot(value.translation.width, value.translation.height) >= 3 / magnification else { return }
                apply(active, from: start, at: value.location, picture: picture, mask: mask, committing: false)
            }
            .onEnded { value in
                defer { discardInteraction() }
                guard !isZooming else { return }
                if let mask = model.displayedSelectedMask,
                   model.isDrawingMask, mask.geometry.shape == .freehand {
                    // Tap the first anchor to close without adding a duplicate.
                    if stroke.count <= 1, mask.geometry.points.count >= 3,
                       let first = mask.geometry.points.first {
                        let view = vertexToView(first, mask.geometry, picture)
                        if hypot(view.x - value.location.x, view.y - value.location.y) < 18 / magnification {
                            model.finishDrawingMask(mask.id)
                            return
                        }
                    }
                    appendDrawPointIfNeeded(value.location, to: mask, in: picture, force: true)
                    for point in stroke { model.appendMaskPoint(mask.id, point, immediate: false) }
                    model.flushGradeHistory()
                    return
                }
                if hypot(value.translation.width, value.translation.height) < 3 / magnification {
                    if case .vertex(let index) = hitTest(value.location, model.displayedSelectedMask?.geometry ?? .default, picture) {
                        model.selectedMaskPointIndex = index
                    } else if case .tangent = active {
                        // Keep the selected anchor while touching its handles.
                    } else { model.selectedMaskPointIndex = nil }
                } else if let active, let start, let mask = model.displayedSelectedMask {
                    apply(active, from: start, at: value.location, picture: picture, mask: mask, committing: true)
                    model.flushGradeHistory()
                }
            }
    }

    private func discardInteraction() {
        active = nil; start = nil; startPoint = nil
        lastDrawLocation = nil; stroke = []; draft = nil
        model.setMaskGeometryPreview(nil)
    }

    private func unplacedVertex(_ location: CGPoint, geometry: MaskGeometry, picture: CGRect) -> MaskPoint {
        let local = toLocal(location, geometry, picture)
        return MaskPoint(x: geometry.pivotX + local.x / (aspect(picture) * geometry.width),
                         y: geometry.pivotY + local.y / geometry.height)
    }

    private func appendDrawPointIfNeeded(_ location: CGPoint, to mask: MaskedGradeLayer,
                                        in picture: CGRect, force: Bool = false) {
        guard picture.contains(location),
              mask.geometry.points.count + stroke.count < MaskGeometry.maximumPoints else { return }
        if let lastDrawLocation {
            let distance = hypot(location.x - lastDrawLocation.x, location.y - lastDrawLocation.y)
            let spacing = max(8 / magnification, min(picture.width, picture.height) / 55)
            guard force || distance >= spacing else { return }
            if force, distance < 2 / magnification { return }
        }
        stroke.append(unplacedVertex(location, geometry: mask.geometry, picture: picture).clamped)
        lastDrawLocation = location
        var preview = mask.geometry
        preview.points += stroke
        model.setMaskGeometryPreview(preview)
    }

    /// The nearest handle within reach, or the whole shape. Returns nil when the
    /// touch is nowhere near this mask, which leaves the drag inert rather than
    /// yanking the window across the picture.
    private func hitTest(_ point: CGPoint, _ geometry: MaskGeometry, _ picture: CGRect) -> Handle? {
        if geometry.shape == .freehand {
            // Nearest wins: dense traced paths used to grab the first point
            // within 26pt, even when a different point was directly under you.
            var candidates: [(Handle, CGFloat)] = geometry.points.enumerated().map { index, vertex in
                let view = vertexToView(vertex, geometry, picture)
                return (.vertex(index), hypot(view.x - point.x, view.y - point.y))
            }
            if let index = model.selectedMaskPointIndex, geometry.points.indices.contains(index) {
                let vertex = geometry.points[index]
                for incoming in [true, false] {
                    let tangent = geometry.suggestedTangent(at: index, incoming: incoming)
                    let view = vertexToView(MaskPoint(x: vertex.x + tangent.x, y: vertex.y + tangent.y), geometry, picture)
                    candidates.append((.tangent(index, incoming: incoming), hypot(view.x - point.x, view.y - point.y)))
                }
            }
            if let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= grabRadius { return nearest.0 }
        }
        var best: (Handle, CGFloat)?
        for handle in handlePositions(geometry, picture) where handle.handle != .move {
            let distance = hypot(handle.point.x - point.x, handle.point.y - point.y)
            guard distance <= grabRadius else { continue }
            if best == nil || distance < best!.1 { best = (handle.handle, distance) }
        }
        if let best { return best.0 }
        // Inside the shape, or anywhere on the picture for a gradient, which has
        // no inside to speak of.
        if geometry.shape == .linear { return .move }
        return path(for: geometry, inset: 0, picture: picture).contains(point) ? .move : nil
    }

    private func apply(_ handle: Handle, from start: MaskGeometry, at point: CGPoint,
                       picture: CGRect, mask: MaskedGradeLayer, committing: Bool) {
        let id = mask.id
        var edited = start
        switch handle {
        case .move:
            guard let startPoint else { return }
            let current = normalized(point, picture), initial = normalized(startPoint, picture)
            edited.centerX += current.x - initial.x
            edited.centerY += current.y - initial.y
        case .resizeWidth(let sign):
            edited.width = max(abs(Double(toLocal(point, start, picture).x) * sign) * 2 / aspect(picture), 0.01)
        case .resizeHeight(let sign):
            edited.height = max(abs(Double(toLocal(point, start, picture).y) * sign) * 2, 0.01)
        case .rotate:
            var unrotated = start; unrotated.rotationDegrees = 0
            let local = toLocal(point, unrotated, picture)
            edited.rotationDegrees = atan2(Double(local.x), -Double(local.y)) * 180 / .pi
        case .feather:
            let local = toLocal(point, start, picture)
            let half = halfSize(start, picture)
            let distance = start.shape == .linear ? abs(Double(local.y))
                : max(abs(Double(local.x)) - Double(half.width), 0)
            let span = start.shape == .linear ? 0.5 : max(Double(min(half.width, half.height)), 0.001)
            edited.feather = min(distance / span, 1)
        case .vertex(let index):
            guard edited.points.indices.contains(index) else { return }
            let vertex = unplacedVertex(point, geometry: start, picture: picture).clamped
            edited.points[index].x = vertex.x; edited.points[index].y = vertex.y
            if committing { model.moveMaskPoint(id, index: index, to: vertex, committing: false); return }
        case .tangent(let index, let incoming):
            guard edited.points.indices.contains(index) else { return }
            let location = unplacedVertex(point, geometry: start, picture: picture)
            let vertex = start.points[index]
            let tangent = MaskTangent(x: location.x - vertex.x, y: location.y - vertex.y).clamped
            if incoming { edited.points[index].incoming = tangent }
            else { edited.points[index].outgoing = tangent }
            if committing {
                model.setMaskTangent(id, index: index, incoming: incoming, to: tangent, committing: false)
                return
            }
        }
        if committing {
            for property in MaskedGradeLayer.geometryProperties {
                let updated = MaskedGradeLayer(name: "", geometry: edited)
                let original = MaskedGradeLayer(name: "", geometry: start)
                if let value = updated.baseValue(of: property), value != original.baseValue(of: property) {
                    model.setMaskValue(id, property, value, immediate: false)
                }
            }
        } else {
            draft = edited.clamped
            model.setMaskGeometryPreview(draft)
        }
    }
}
