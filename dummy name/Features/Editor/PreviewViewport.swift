import SwiftUI

/// What the preview lets the user do with the picture itself.
enum PreviewInteraction: Equatable {
    /// Pinch to zoom, one finger to pan once zoomed, double tap to reset.
    case full
    /// Two fingers zoom and pan; one finger is left entirely alone.
    ///
    /// For the tools that draw directly on the picture — the cutout lasso and
    /// its refinement brushes. Tracing an edge at fit-to-screen size is the
    /// difference between a usable cutout and an approximate one, so the
    /// viewport has to zoom *while* the tool is armed rather than only before
    /// it is. The one-finger pan is given up to buy that: it is the same touch
    /// the tool needs.
    case pinchOnly
    /// Held at 1x, with every gesture belonging to the content.
    case off
}

/// Inspection only: this transform never changes the project or exported frame.
struct PreviewViewport<Content: View>: View {
    var interaction: PreviewInteraction = .full
    /// Called when a two-finger zoom starts and again when it ends — twice per
    /// gesture, not once per event, because the owner of this flag redraws on
    /// it. It lets a tool drawing on the picture throw away the stroke the
    /// pinch's first finger was leaving behind.
    var onPinchChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let content: () -> Content
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var translation: CGSize = .zero
    /// Where the in-flight two-finger gesture started. Every frame of that
    /// gesture is computed from this rather than accumulated, so it cannot
    /// drift, and the drag baseline means a pinch begun mid-stroke does not
    /// jump the picture by however far the stroke had already travelled.
    @State private var pinchStart: PinchStart?

    private struct PinchStart {
        let scale: CGFloat
        let offset: CGSize
        let drag: CGSize
        let anchor: UnitPoint
    }

    private static var maximumZoom: CGFloat { 6 }

    var body: some View {
        GeometryReader { geometry in
            let zoom = min(Self.maximumZoom, max(1, scale * magnification))
            let position = bounded(CGSize(width: offset.width + translation.width,
                                          height: offset.height + translation.height), zoom: zoom, size: geometry.size)
            content()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(zoom).offset(position)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped().contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .updating($magnification) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        scale = min(Self.maximumZoom, max(1, scale * value.magnification))
                        offset = bounded(offset, zoom: scale, size: geometry.size)
                    }, including: interaction == .full ? .all : .subviews)
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .updating($translation) { value, state, _ in if scale > 1 { state = value.translation } }
                    .onEnded { value in
                        guard scale > 1 else { return }
                        offset = bounded(CGSize(width: offset.width + value.translation.width,
                                                height: offset.height + value.translation.height), zoom: scale, size: geometry.size)
                    }, including: interaction == .full ? .all : .subviews)
                .simultaneousGesture(precisionZoom(in: geometry.size),
                                     including: interaction == .pinchOnly ? .all : .subviews)
                // Only where a double tap cannot also be two strokes of a
                // brush. A pinch back down to 1x resets the other mode, since
                // `bounded` allows no offset at all at that zoom.
                .onTapGesture(count: 2) { if interaction == .full { reset() } }
                .onChange(of: interaction) { _, mode in
                    endPinch()
                    if mode == .off { reset() }
                }
                .accessibilityAction(named: "Reset preview zoom") { reset() }
        }
    }

    /// Two-finger zoom and pan that leaves one finger to the content.
    ///
    /// The drag is bundled with the pinch rather than attached separately so
    /// there is one recogniser pair to reason about, and it is consulted only
    /// once the pinch itself has recognised. A `DragGesture` fires for a single
    /// finger too, and acting on that is exactly what would steal the stroke
    /// the lasso is drawing.
    private func precisionZoom(in size: CGSize) -> some Gesture {
        SimultaneousGesture(MagnifyGesture(), DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard let magnify = value.first else { return }
                let drag = value.second?.translation ?? .zero
                let start: PinchStart
                if let pinchStart {
                    start = pinchStart
                } else {
                    start = PinchStart(scale: scale, offset: offset, drag: drag, anchor: magnify.startAnchor)
                    pinchStart = start
                    onPinchChanged(true)
                }
                let zoom = min(Self.maximumZoom, max(1, start.scale * magnify.magnification))
                // Zoom about the point the fingers landed on, so pinching an
                // edge brings that edge in rather than magnifying the middle of
                // the frame and leaving the edge off screen. Derived rather
                // than applied as a `scaleEffect` anchor because the offset is
                // what the pan and the bounds clamp both work in.
                let ratio = zoom / max(start.scale, 0.0001)
                let dx = (start.anchor.x - 0.5) * size.width
                let dy = (start.anchor.y - 0.5) * size.height
                let panned = CGSize(
                    width: dx * (1 - ratio) + start.offset.width * ratio + (drag.width - start.drag.width),
                    height: dy * (1 - ratio) + start.offset.height * ratio + (drag.height - start.drag.height))
                scale = zoom
                offset = bounded(panned, zoom: zoom, size: size)
            }
            .onEnded { _ in endPinch() }
    }

    private func endPinch() {
        guard pinchStart != nil else { return }
        pinchStart = nil
        onPinchChanged(false)
    }

    private func reset() {
        scale = 1
        offset = .zero
        endPinch()
    }

    private func bounded(_ value: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        let x = size.width * (zoom-1)/2, y = size.height * (zoom-1)/2
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }
}
