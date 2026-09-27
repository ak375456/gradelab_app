import SwiftUI
import UIKit

/// The screen geometry of one selectable drawn layer.
///
/// Titles and shapes are dragged, pinched and rotated with identical rules, and
/// they magnet onto each other's edges, so the handles are written once against
/// this description instead of twice against two clip types. Everything here is
/// in AUTHORED canvas units — the reduced preview surface text point sizes and
/// shape dimensions are both stored in — never screen points.
struct CanvasOverlay: Identifiable {
    let id: UUID
    var transform: VisualTransform
    let range: TimelineRange
    /// The bounds the anchor and placement are measured against: a title's
    /// fitted line box, a shape's own box.
    let anchorBounds: CGRect
    /// The frame drawn around the selection, padded clear of the ink or outline.
    let frame: CGRect
    /// What the layer is. Titles, shapes and pictures are dragged, pinched and
    /// rotated by identical rules; only the wording and the double tap differ.
    enum Kind { case text, shape, media }
    let kind: Kind
    /// Whether a double tap opens a content editor. Only a title has content.
    var editsContent: Bool { kind == .text }

    init(_ clip: TextClip, canvas: CGSize) {
        let layout = TextRenderer.layout(clip, canvas: canvas)
        id = clip.id
        transform = clip.transform
        range = clip.placement.range
        anchorBounds = layout.fittedBounds
        // Frame the glyphs, not the full wrapping width.
        frame = layout.fittedBounds.insetBy(dx: -max(6, clip.strokeWidth), dy: -6)
        kind = .text
    }

    init(_ clip: ShapeClip, canvas: CGSize) {
        let bounds = ShapeRenderer.bounds(clip)
        id = clip.id
        transform = clip.transform
        range = clip.placement.range
        anchorBounds = bounds
        // A centred stroke hangs half its width outside the figure.
        let pad = max(6, clip.strokeWidth/2)
        frame = bounds.insetBy(dx: -pad, dy: -pad)
        kind = .shape
    }

    /// A picture layer — an image or video overlay.
    ///
    /// Its bounds are the source fitted to the canvas, which is the size the
    /// compositor draws it at before the clip's own transform. Handing those
    /// already-fitted bounds to `VisualTransform.placement` reproduces the
    /// compositor's `fit * scale` exactly, so the outline sits on the picture
    /// rather than near it.
    init(_ clip: VideoClip, displaySize: CGSize, canvas: CGSize) {
        id = clip.id
        transform = clip.transform
        range = clip.placement.range
        let fit = min(canvas.width/displaySize.width, canvas.height/displaySize.height)
        let fitted = CGRect(origin: .zero, size: CGSize(width: displaySize.width*fit,
                                                        height: displaySize.height*fit))
        anchorBounds = fitted
        // A picture has no ink to clear: its edge IS the frame.
        frame = fitted
        kind = .media
    }

    func placement(canvas: CGSize) -> CGAffineTransform {
        transform.placement(bounds: anchorBounds, canvas: canvas)
    }

    /// The same overlay proposed at another position, for the magnet to measure
    /// before anything is written to the project.
    func moved(x: Double, y: Double) -> CanvasOverlay {
        var copy = self
        copy.transform.positionX = x
        copy.transform.positionY = y
        return copy
    }

    var selectionAccessibilityLabel: String {
        switch kind {
        case .text: String(localized: "Selected text. Drag to move, pinch to resize, rotate with two fingers.")
        case .shape: String(localized: "Selected shape. Drag to move, pinch to resize, rotate with two fingers.")
        case .media: String(localized: "Selected picture. Drag to move, pinch to resize, rotate with two fingers.")
        }
    }

    var resizeAccessibilityLabel: String {
        switch kind {
        case .text: String(localized: "Resize and rotate text")
        case .shape: String(localized: "Resize and rotate shape")
        case .media: String(localized: "Resize and rotate picture")
        }
    }

    var deleteAccessibilityLabel: String {
        switch kind {
        case .text: String(localized: "Delete text clip")
        case .shape: String(localized: "Delete shape clip")
        case .media: String(localized: "Delete picture clip")
        }
    }

    /// The selection frame's four corners in VIEW coordinates: the canvas fitted
    /// into the preview and centred in it. Top-left, top-right, bottom-right,
    /// bottom-left, which is the order the handles are placed by.
    func corners(canvas: CGSize, fit: CGFloat, offset: CGPoint) -> [CGPoint] {
        let placement = placement(canvas: canvas)
        return [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)].map { point in
            let placed = point.applying(placement)
            return CGPoint(x: offset.x+placed.x*fit, y: offset.y+(canvas.height-placed.y)*fit)
        }
    }

    /// Whether this layer is on screen at a timeline position, in seconds.
    func isVisible(at seconds: Double) -> Bool {
        seconds >= range.start.seconds && seconds < ((try? range.end.seconds) ?? 0)
    }

    /// Axis-aligned screen-space bounds in canvas units, origin at top-left.
    func screenBounds(canvas: CGSize) -> CGRect {
        let transform = placement(canvas: canvas)
        let points = [
            CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)
        ].map { point -> CGPoint in
            let placed = point.applying(transform)
            return CGPoint(x: placed.x, y: canvas.height-placed.y)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0)-(xs.min() ?? 0),
                      height: (ys.max() ?? 0)-(ys.min() ?? 0))
    }
}

/// Where a block of drawn layers is placed against the canvas edges.
enum CanvasAlignment: String, CaseIterable, Identifiable {
    case left, centerHorizontally, right, top, centerVertically, bottom
    var id: String { rawValue }
    var isHorizontal: Bool { self == .left || self == .centerHorizontally || self == .right }
    var symbol: String {
        switch self {
        case .left: "align.horizontal.left"
        case .centerHorizontally: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .centerVertically: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }
    var title: String {
        switch self {
        case .left: String(localized: "Align left")
        case .centerHorizontally: String(localized: "Center horizontally")
        case .right: String(localized: "Align right")
        case .top: String(localized: "Align top")
        case .centerVertically: String(localized: "Center vertically")
        case .bottom: String(localized: "Align bottom")
        }
    }
}

/// The six canvas placements, for the Transform section of a drawn layer's panel.
struct CanvasAlignmentRow: View {
    @ObservedObject var model: EditorViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // German runs a third longer here; the label shrinks rather than
                // wrapping the row onto two lines.
                Text("Align to canvas").font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                if model.selectedClipIDs.count > 1 {
                    Text("As one block").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 4) {
                ForEach(CanvasAlignment.allCases) { alignment in
                    Button { model.alignSelection(alignment) } label: {
                        Image(systemName: alignment.symbol)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(alignment.title)
                }
            }.font(.system(size: 14, weight: .medium)).disabled(!model.canAlignSelection)
        }
    }
}

/// The magnet that lines drawn layers up with each other and with the canvas.
///
/// Pure geometry, deliberately not a method on the view: a lone layer and a
/// whole selection both magnet through it, and it is tested directly rather
/// than through a gesture.
enum CanvasMagnet {
    /// Freeform placement with a magnet: edges, thirds and centre.
    static let positionStops: [Double] = [0, 1.0/3, 0.5, 2.0/3, 1]
    static let positionTolerance = 0.012

    /// Lines the moving rect's left/centre/right and top/centre/bottom up with
    /// the same anchors on every other rect, and reports the nudge that lands it
    /// on the nearest one. Bounds include scale and rotation, matching the
    /// outlines users line up by eye. Normalized, ready to add to a position.
    static func pull(bounds moving: CGRect, canvas: CGSize,
                     screenScale: CGFloat, others: [CGRect])
        -> (dx: Double, dy: Double, xGuide: Double?, yGuide: Double?) {
        let xAnchors = [moving.minX, moving.midX, moving.maxX]
        let yAnchors = [moving.minY, moving.midY, moving.maxY]
        let tolerance = 12 / max(screenScale, 0.001)
        var bestX: (distance: CGFloat, delta: CGFloat, guide: CGFloat)?
        var bestY: (distance: CGFloat, delta: CGFloat, guide: CGFloat)?
        for bounds in others {
            for source in xAnchors {
                for target in [bounds.minX, bounds.midX, bounds.maxX] {
                    let delta = target-source, distance = abs(delta)
                    if distance <= tolerance && (bestX == nil || distance < bestX!.distance) {
                        bestX = (distance, delta, target)
                    }
                }
            }
            for source in yAnchors {
                for target in [bounds.minY, bounds.midY, bounds.maxY] {
                    let delta = target-source, distance = abs(delta)
                    if distance <= tolerance && (bestY == nil || distance < bestY!.distance) {
                        bestY = (distance, delta, target)
                    }
                }
            }
        }
        guard canvas.width > 0, canvas.height > 0 else { return (0, 0, nil, nil) }
        return (
            Double(bestX?.delta ?? 0) / Double(canvas.width),
            Double(bestY?.delta ?? 0) / Double(canvas.height),
            bestX.map { Double($0.guide / canvas.width) },
            bestY.map { Double($0.guide / canvas.height) }
        )
    }

    /// Returns the magnetised value and, when held, the stop it locked onto.
    static func snap(_ value: Double, to stops: [Double], tolerance: Double) -> (value: Double, stop: Double?) {
        guard let nearest = stops.min(by: { abs($0-value) < abs($1-value) }),
              abs(nearest-value) <= tolerance else { return (value, nil) }
        return (nearest, nearest)
    }
}

/// Canvas-space hit geometry follows the same layout/transform as export.
struct OverlayCanvasControls: View {
    @ObservedObject var model: EditorViewModel
    let editContent: () -> Void
    @State private var origin: VisualTransform?
    /// How far a group drag has already been applied, normalized. The gesture
    /// writes the DIFFERENCE each time, because a group has no single transform
    /// to measure an absolute translation against.
    @State private var groupOrigin: CGPoint?
    /// The selection's outer bounds in canvas units when a group drag began -
    /// the rect the magnet measures, held still so it cannot drift as the
    /// layers move under it.
    @State private var groupBounds: CGRect?
    @State private var initialScale: Double?
    @State private var initialRotation: Double?
    /// Normalized guide positions currently held by the magnet, drawn while dragging.
    @State private var guides: (x: Double?, y: Double?) = (nil, nil)
    @State private var rotationGuide: Double?

    private static let positionStops = CanvasMagnet.positionStops
    private static let positionTolerance = CanvasMagnet.positionTolerance
    /// Multiples of 45 near the current value, so snapping works past a full turn too.
    private func stops(around value: Double) -> [Double] {
        let base = (value/45).rounded()
        return (-2...2).map { (base + Double($0)) * 45 }
    }
    private static let rotationTolerance = 4.0

    var body: some View {
        GeometryReader { view in
            // Drawn layers are authored in the base preview's coordinate system.
            // Using the full 4K canvas here made the selection frame half the
            // size of the visible layer even though the layer itself looked
            // right in the editor.
            let canvas = SequenceComposition.previewRenderSize(
                width: model.project.canvas.width,
                height: model.project.canvas.height
            )
            // Geometry uses the EVALUATED layer so the selection frame sits on what
            // you can actually see while animation is driving it.
            if model.selectedClipIDs.count > 1 {
                groupSelection(canvas: canvas, view: view.size)
            } else if let overlay = selection(canvas: canvas), model.canEditSelection,
               overlay.isVisible(at: model.timelineTime) {
                let fit = min(view.size.width/canvas.width, view.size.height/canvas.height)
                let offset = CGPoint(x: (view.size.width-canvas.width*fit)/2,
                                     y: (view.size.height-canvas.height*fit)/2)
                let corners = overlay.corners(canvas: canvas, fit: fit, offset: offset)
                let outline = Path { path in path.addLines(corners); path.closeSubpath() }
                if let x = guides.x { guide(x: x, canvas: canvas, fit: fit, offset: offset) }
                if let y = guides.y { guide(y: y, canvas: canvas, fit: fit, offset: offset) }
                outline.fill(.white.opacity(0.001)).contentShape(outline)
                    .overlay(outline.stroke(rotationGuide != nil ? .yellow : .cyan, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        // The baseline is the EVALUATED transform at gesture start, so a
                        // keyframe inserted between existing ones starts from what was on
                        // screen rather than an outdated base value.
                        if origin == nil { origin = overlay.transform; model.playback.pause() }
                        guard let origin else { return }
                        let rawX = origin.positionX+value.translation.width/(canvas.width*fit)
                        let rawY = origin.positionY+value.translation.height/(canvas.height*fit)
                        let aligned = align(overlay: overlay, x: rawX, y: rawY, canvas: canvas,
                                            screenScale: fit, others: peers(canvas: canvas, excluding: [overlay.id]))
                        let x = aligned.xGuide == nil
                            ? snap(rawX, to: Self.positionStops, tolerance: Self.positionTolerance)
                            : (aligned.x, aligned.xGuide)
                        let y = aligned.yGuide == nil
                            ? snap(rawY, to: Self.positionStops, tolerance: Self.positionTolerance)
                            : (aligned.y, aligned.yGuide)
                        report(x: x.1, y: y.1)
                        model.setAnimatableValue(.positionX, .number(x.0))
                        model.setAnimatableValue(.positionY, .number(y.0))
                    }.onEnded { _ in origin = nil; guides = (nil, nil); model.flushGradeHistory() })
                    .simultaneousGesture(MagnifyGesture().onChanged { value in
                        if initialScale == nil { initialScale = overlay.transform.scale; model.playback.pause() }
                        model.setAnimatableValue(.scale, .number(min(6, max(0.05, initialScale! * value.magnification))))
                    }.onEnded { _ in initialScale = nil; model.flushGradeHistory() })
                    .simultaneousGesture(RotateGesture().onChanged { value in
                        if initialRotation == nil { initialRotation = overlay.transform.rotationDegrees; model.playback.pause() }
                        // Accumulated, never wrapped into +/-180: a deliberate multi-turn
                        // rotation must survive as real motion.
                        let raw = initialRotation!+value.rotation.degrees
                        let snapped = snap(raw, to: stops(around: raw), tolerance: Self.rotationTolerance)
                        reportRotation(snapped.stop)
                        model.setAnimatableValue(.rotation, .number(snapped.value))
                    }.onEnded { _ in initialRotation = nil; rotationGuide = nil; model.flushGradeHistory() })
                    .onTapGesture(count: 2) { if overlay.editsContent { editContent() } }
                    .accessibilityLabel(overlay.selectionAccessibilityLabel)
                let center = CGPoint(x: offset.x+overlay.transform.positionX*canvas.width*fit,
                                     y: offset.y+overlay.transform.positionY*canvas.height*fit)
                Circle().fill(.cyan).frame(width: 12, height: 12).frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(corners[1])
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("overlayCanvas")).onChanged { value in
                        if origin == nil { origin = overlay.transform }
                        let start = CGVector(dx: value.startLocation.x-center.x, dy: value.startLocation.y-center.y)
                        let current = CGVector(dx: value.location.x-center.x, dy: value.location.y-center.y)
                        let ratio = hypot(current.dx, current.dy)/max(1, hypot(start.dx, start.dy))
                        let angle = (atan2(current.dy, current.dx)-atan2(start.dy, start.dx))*180 / .pi
                        let raw = origin!.rotationDegrees+angle
                        let snapped = snap(raw, to: stops(around: raw), tolerance: Self.rotationTolerance)
                        reportRotation(snapped.stop)
                        model.setAnimatableValue(.scale, .number(min(6, max(0.05, origin!.scale*ratio))))
                        model.setAnimatableValue(.rotation, .number(snapped.value))
                    }.onEnded { _ in origin = nil; rotationGuide = nil; model.flushGradeHistory() })
                    .accessibilityLabel(overlay.resizeAccessibilityLabel)
                Button { model.deleteClip() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 22, height: 22).background(Circle().fill(.cyan))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .position(corners[3])
                .accessibilityLabel(overlay.editsContent ? "Delete text clip" : "Delete shape clip")
            }
        }.coordinateSpace(name: "overlayCanvas")
    }

    /// Outlines for a multiple selection, and one drag that moves them together.
    ///
    /// No corner handles: scaling or rotating a group needs a shared pivot the
    /// document has no place to keep, and the panel's own controls already reach
    /// every selected layer. Moving is the thing that was missing - before this,
    /// selecting four titles showed nothing at all on the canvas.
    @ViewBuilder private func groupSelection(canvas: CGSize, view: CGSize) -> some View {
        let fit = min(view.width/canvas.width, view.height/canvas.height)
        let offset = CGPoint(x: (view.width-canvas.width*fit)/2, y: (view.height-canvas.height*fit)/2)
        let overlays = model.selectedOverlays(canvas: canvas).filter { $0.isVisible(at: model.timelineTime) }
        if !overlays.isEmpty {
            let outlines = Path { path in
                for overlay in overlays {
                    path.addLines(overlay.corners(canvas: canvas, fit: fit, offset: offset))
                    path.closeSubpath()
                }
            }
            if let x = guides.x { guide(x: x, canvas: canvas, fit: fit, offset: offset) }
            if let y = guides.y { guide(y: y, canvas: canvas, fit: fit, offset: offset) }
            let drawn = outlines.fill(.white.opacity(0.001))
                .overlay(outlines.stroke(.cyan, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            // A mixed selection - titles and shapes together - has no shared edit
            // path, so it is shown but not draggable rather than silently ignoring
            // the drag.
            if model.selectionMovesAsAGroup, model.canEditSelection {
                drawn.contentShape(outlines)
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        if groupOrigin == nil {
                            groupOrigin = .zero
                            groupBounds = overlays.dropFirst().reduce(overlays[0].screenBounds(canvas: canvas)) {
                                $0.union($1.screenBounds(canvas: canvas))
                            }
                            model.playback.pause()
                        }
                        guard let applied = groupOrigin, let base = groupBounds else { return }
                        let rawX = value.translation.width/(canvas.width*fit)
                        let rawY = value.translation.height/(canvas.height*fit)
                        // The block magnets by its own outer edges and centre,
                        // exactly as a lone layer does by its frame: onto the
                        // layers it is NOT dragging first, and onto the canvas
                        // thirds and centre when none of those is near.
                        let proposed = base.offsetBy(dx: rawX*canvas.width, dy: rawY*canvas.height)
                        let pull = magnet(bounds: proposed, canvas: canvas, screenScale: fit,
                                          others: peers(canvas: canvas, excluding: model.selectedClipIDs))
                        var x = rawX + pull.dx, y = rawY + pull.dy
                        var xGuide = pull.xGuide, yGuide = pull.yGuide
                        if xGuide == nil {
                            // A lone layer snaps its anchor to the stops; a block
                            // has no single anchor, so its centre stands in.
                            let centre = Double(proposed.midX)/Double(canvas.width)
                            let stop = snap(centre, to: Self.positionStops, tolerance: Self.positionTolerance)
                            x += stop.value-centre; xGuide = stop.stop
                        }
                        if yGuide == nil {
                            let centre = Double(proposed.midY)/Double(canvas.height)
                            let stop = snap(centre, to: Self.positionStops, tolerance: Self.positionTolerance)
                            y += stop.value-centre; yGuide = stop.stop
                        }
                        report(x: xGuide, y: yGuide)
                        model.offsetSelection(.positionX, by: x-applied.x,
                                              label: AnimatableProperty.positionX.title)
                        model.offsetSelection(.positionY, by: y-applied.y,
                                              label: AnimatableProperty.positionY.title)
                        groupOrigin = CGPoint(x: x, y: y)
                    }.onEnded { _ in
                        groupOrigin = nil; groupBounds = nil; guides = (nil, nil)
                        model.flushGradeHistory()
                    })
                    .accessibilityLabel("Selected layers. Drag to move them together.")
            } else {
                drawn.allowsHitTesting(false)
            }
        }
    }

    /// A magnet guide across the canvas, at a normalized position.
    private func guide(x: Double, canvas: CGSize, fit: CGFloat, offset: CGPoint) -> some View {
        Path {
            $0.move(to: CGPoint(x: offset.x+x*canvas.width*fit, y: offset.y))
            $0.addLine(to: CGPoint(x: offset.x+x*canvas.width*fit, y: offset.y+canvas.height*fit))
        }.stroke(.yellow.opacity(0.9), lineWidth: 1).allowsHitTesting(false)
    }
    private func guide(y: Double, canvas: CGSize, fit: CGFloat, offset: CGPoint) -> some View {
        Path {
            $0.move(to: CGPoint(x: offset.x, y: offset.y+y*canvas.height*fit))
            $0.addLine(to: CGPoint(x: offset.x+canvas.width*fit, y: offset.y+y*canvas.height*fit))
        }.stroke(.yellow.opacity(0.9), lineWidth: 1).allowsHitTesting(false)
    }

    /// Whichever drawn layer is selected, evaluated at the playhead.
    private func selection(canvas: CGSize) -> CanvasOverlay? {
        if let clip = model.evaluatedText { return CanvasOverlay(clip, canvas: canvas) }
        if let clip = model.evaluatedShape { return CanvasOverlay(clip, canvas: canvas) }
        if let clip = model.evaluatedMediaOverlay, let size = model.displaySize(of: clip) {
            return CanvasOverlay(clip, displaySize: size, canvas: canvas)
        }
        return nil
    }

    /// Every other drawn layer visible at this frame. A title lines up on a
    /// shape's edge and a shape on a title's, which is the whole point of
    /// measuring both against one description.
    private func peers(canvas: CGSize, excluding ids: Set<UUID>) -> [CanvasOverlay] {
        model.visibleEvaluatedTexts.filter { !ids.contains($0.id) }.map { CanvasOverlay($0, canvas: canvas) }
            + model.visibleEvaluatedShapes.filter { !ids.contains($0.id) }.map { CanvasOverlay($0, canvas: canvas) }
            + model.visibleEvaluatedMediaOverlays.filter { !ids.contains($0.id) }.compactMap { clip in
                model.displaySize(of: clip).map { CanvasOverlay(clip, displaySize: $0, canvas: canvas) }
            }
    }

    private func snap(_ value: Double, to stops: [Double], tolerance: Double) -> (value: Double, stop: Double?) {
        CanvasMagnet.snap(value, to: stops, tolerance: tolerance)
    }

    /// One layer's magnet: its own frame measured against the others.
    private func align(overlay: CanvasOverlay, x: Double, y: Double, canvas: CGSize,
                       screenScale: CGFloat, others: [CanvasOverlay])
        -> (x: Double, y: Double, xGuide: Double?, yGuide: Double?) {
        let pull = magnet(bounds: overlay.moved(x: x, y: y).screenBounds(canvas: canvas),
                          canvas: canvas, screenScale: screenScale, others: others)
        return (x + pull.dx, y + pull.dy, pull.xGuide, pull.yGuide)
    }

    private func magnet(bounds moving: CGRect, canvas: CGSize,
                        screenScale: CGFloat, others: [CanvasOverlay])
        -> (dx: Double, dy: Double, xGuide: Double?, yGuide: Double?) {
        CanvasMagnet.pull(bounds: moving, canvas: canvas, screenScale: screenScale,
                          others: others.map { $0.screenBounds(canvas: canvas) })
    }

    private func report(x: Double?, y: Double?) {
        if x != guides.x || y != guides.y {
            if (x != nil && x != guides.x) || (y != nil && y != guides.y) { UISelectionFeedbackGenerator().selectionChanged() }
            guides = (x, y)
        }
    }
    private func reportRotation(_ stop: Double?) {
        if stop != rotationGuide {
            if stop != nil { UISelectionFeedbackGenerator().selectionChanged() }
            rotationGuide = stop
        }
    }
}
