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
    /// Whether a double tap opens a content editor. Only a title has content.
    let editsContent: Bool

    init(_ clip: TextClip, canvas: CGSize) {
        let layout = TextRenderer.layout(clip, canvas: canvas)
        id = clip.id
        transform = clip.transform
        range = clip.placement.range
        anchorBounds = layout.fittedBounds
        // Frame the glyphs, not the full wrapping width.
        frame = layout.fittedBounds.insetBy(dx: -max(6, clip.strokeWidth), dy: -6)
        editsContent = true
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
        editsContent = false
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

/// Canvas-space hit geometry follows the same layout/transform as export.
struct OverlayCanvasControls: View {
    @ObservedObject var model: EditorViewModel
    let editContent: () -> Void
    @State private var origin: VisualTransform?
    @State private var initialScale: Double?
    @State private var initialRotation: Double?
    /// Normalized guide positions currently held by the magnet, drawn while dragging.
    @State private var guides: (x: Double?, y: Double?) = (nil, nil)
    @State private var rotationGuide: Double?

    // Freeform placement with a magnet: edges, thirds and centre.
    private static let positionStops: [Double] = [0, 1.0/3, 0.5, 2.0/3, 1]
    private static let positionTolerance = 0.012
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
            if let overlay = selection(canvas: canvas), model.canEditSelection,
               model.selectedClipIDs.count == 1,
               model.timelineTime >= overlay.range.start.seconds,
               model.timelineTime < ((try? overlay.range.end.seconds) ?? 0) {
                let fit = min(view.size.width/canvas.width, view.size.height/canvas.height)
                let offset = CGPoint(x: (view.size.width-canvas.width*fit)/2,
                                     y: (view.size.height-canvas.height*fit)/2)
                let placement = overlay.placement(canvas: canvas)
                let frame = overlay.frame
                let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                               CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)].map { point in
                    let p = point.applying(placement)
                    return CGPoint(x: offset.x+p.x*fit, y: offset.y+(canvas.height-p.y)*fit)
                }
                let outline = Path { path in path.addLines(corners); path.closeSubpath() }
                if let x = guides.x {
                    Path { $0.move(to: CGPoint(x: offset.x+x*canvas.width*fit, y: offset.y)); $0.addLine(to: CGPoint(x: offset.x+x*canvas.width*fit, y: offset.y+canvas.height*fit)) }
                        .stroke(.yellow.opacity(0.9), lineWidth: 1).allowsHitTesting(false)
                }
                if let y = guides.y {
                    Path { $0.move(to: CGPoint(x: offset.x, y: offset.y+y*canvas.height*fit)); $0.addLine(to: CGPoint(x: offset.x+canvas.width*fit, y: offset.y+y*canvas.height*fit)) }
                        .stroke(.yellow.opacity(0.9), lineWidth: 1).allowsHitTesting(false)
                }
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
                                            screenScale: fit, others: peers(canvas: canvas, excluding: overlay.id))
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
                    .accessibilityLabel(overlay.editsContent
                        ? "Selected text. Drag to move, pinch to resize, rotate with two fingers."
                        : "Selected shape. Drag to move, pinch to resize, rotate with two fingers.")
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
                    .accessibilityLabel(overlay.editsContent ? "Resize and rotate text" : "Resize and rotate shape")
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

    /// Whichever drawn layer is selected, evaluated at the playhead.
    private func selection(canvas: CGSize) -> CanvasOverlay? {
        if let clip = model.evaluatedText { return CanvasOverlay(clip, canvas: canvas) }
        if let clip = model.evaluatedShape { return CanvasOverlay(clip, canvas: canvas) }
        return nil
    }

    /// Every other drawn layer visible at this frame. A title lines up on a
    /// shape's edge and a shape on a title's, which is the whole point of
    /// measuring both against one description.
    private func peers(canvas: CGSize, excluding id: UUID) -> [CanvasOverlay] {
        model.visibleEvaluatedTexts.filter { $0.id != id }.map { CanvasOverlay($0, canvas: canvas) }
            + model.visibleEvaluatedShapes.filter { $0.id != id }.map { CanvasOverlay($0, canvas: canvas) }
    }

    /// Returns the magnetised value and, when held, the stop it locked onto.
    private func snap(_ value: Double, to stops: [Double], tolerance: Double) -> (value: Double, stop: Double?) {
        guard let nearest = stops.min(by: { abs($0-value) < abs($1-value) }), abs(nearest-value) <= tolerance else { return (value, nil) }
        return (nearest, nearest)
    }

    /// Aligns the moving layer's left/centre/right and top/centre/bottom to the
    /// same anchors on every other drawn layer visible at this frame. Bounds
    /// include scale and rotation, matching the selection outlines users line up
    /// by eye.
    private func align(overlay: CanvasOverlay, x: Double, y: Double, canvas: CGSize,
                       screenScale: CGFloat, others: [CanvasOverlay])
        -> (x: Double, y: Double, xGuide: Double?, yGuide: Double?) {
        let moving = overlay.moved(x: x, y: y).screenBounds(canvas: canvas)
        let xAnchors = [moving.minX, moving.midX, moving.maxX]
        let yAnchors = [moving.minY, moving.midY, moving.maxY]
        let tolerance = 12 / max(screenScale, 0.001)
        var bestX: (distance: CGFloat, delta: CGFloat, guide: CGFloat)?
        var bestY: (distance: CGFloat, delta: CGFloat, guide: CGFloat)?
        for other in others {
            let bounds = other.screenBounds(canvas: canvas)
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
        return (
            x + Double(bestX?.delta ?? 0) / Double(canvas.width),
            y + Double(bestY?.delta ?? 0) / Double(canvas.height),
            bestX.map { Double($0.guide / canvas.width) },
            bestY.map { Double($0.guide / canvas.height) }
        )
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
