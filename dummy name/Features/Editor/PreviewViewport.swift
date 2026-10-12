import SwiftUI
import UIKit

private struct PreviewMagnificationKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var previewMagnification: CGFloat {
        get { self[PreviewMagnificationKey.self] }
        set { self[PreviewMagnificationKey.self] = newValue }
    }
}

/// Tools retain one-finger input; the viewport always accepts two fingers.
enum PreviewInteraction: Equatable {
    case full
    case pinchOnly
}

/// Inspection only: picture and tool overlays share one native zoom surface.
/// UIScrollView owns pinch and two-finger pan, so drawing recognizers cannot
/// steal zoom, and panning does not depend on changing the pinch distance.
struct PreviewViewport<Content: View>: View {
    var interaction: PreviewInteraction = .full
    var onPinchChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let content: () -> Content
    @State private var zoom: CGFloat = 1
    @State private var command = PreviewZoomCommand(scale: 1, reset: true)

    var body: some View {
        NativePreviewViewport(content: content().environment(\.previewMagnification, zoom), interaction: interaction,
                              command: command, zoom: $zoom, onNavigationChanged: onPinchChanged)
            .overlay(alignment: .bottomLeading) { zoomControls.padding(10) }
            .accessibilityAction(named: "Reset preview zoom") { reset() }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { setZoom(zoom / 1.25) } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
            }
            .disabled(zoom <= PreviewZoom.minimum)
            .accessibilityLabel("Zoom out")
            Menu {
                Button("Fit · 100%") { reset() }
                ForEach([50, 200, 400, 800], id: \.self) { percent in
                    Button("\(percent)%") { setZoom(CGFloat(percent) / 100) }
                }
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit().frame(minWidth: 56, minHeight: 44)
            }
            .accessibilityLabel("Preview zoom, \(Int((zoom * 100).rounded())) percent")
            .help("Zoom relative to Fit. Pinch anywhere to zoom; use two fingers to pan.")
            Button { setZoom(zoom * 1.25) } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .disabled(zoom >= PreviewZoom.maximum)
            .accessibilityLabel("Zoom in")
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 16)
            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Reset preview to Fit, 100 percent")
            .help("Reset preview zoom and position")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func setZoom(_ value: CGFloat) {
        command = PreviewZoomCommand(scale: PreviewZoom.clamped(value), reset: false)
    }

    private func reset() { command = PreviewZoomCommand(scale: 1, reset: true) }
}

/// Fit is the stable 100% reference on every device, including while a tool is
/// active. Snap only on release, so a pinch can pass smoothly through 100%.
enum PreviewZoom {
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 8
    static func clamped(_ scale: CGFloat) -> CGFloat { min(maximum, max(minimum, scale)) }
    static func snapped(_ scale: CGFloat) -> CGFloat { abs(scale - 1) <= 0.06 ? 1 : clamped(scale) }
}

private struct PreviewZoomCommand: Equatable {
    let id = UUID()
    let scale: CGFloat
    let reset: Bool
}

private final class PreviewScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    // Direct manipulation should immediately receive a finger, but yield when
    // the native two-finger navigation recognizer begins.
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

private struct NativePreviewViewport<Content: View>: UIViewRepresentable {
    var content: Content
    var interaction: PreviewInteraction
    var command: PreviewZoomCommand
    @Binding var zoom: CGFloat
    var onNavigationChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = PreviewScrollView()
        let coordinator = context.coordinator
        scroll.backgroundColor = .clear
        scroll.minimumZoomScale = PreviewZoom.minimum
        scroll.maximumZoomScale = PreviewZoom.maximum
        scroll.bouncesZoom = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delaysContentTouches = false
        scroll.delegate = coordinator
        scroll.panGestureRecognizer.minimumNumberOfTouches = interaction == .full ? 1 : 2
        scroll.addSubview(coordinator.host.view)
        scroll.onLayout = { [weak coordinator, weak scroll] in
            guard let scroll else { return }
            coordinator?.layout(scroll)
        }
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.gradeLabResetPreviewZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.host.rootView = content
        scroll.panGestureRecognizer.minimumNumberOfTouches = interaction == .full ? 1 : 2
        coordinator.layout(scroll)
        if coordinator.lastCommand != command.id {
            coordinator.lastCommand = command.id
            coordinator.apply(command, to: scroll)
        }
    }

    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) {
        coordinator.setNavigating(false)
        scroll.delegate = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: NativePreviewViewport
        let host: UIHostingController<Content>
        var lastCommand: UUID?
        private var lastSize: CGSize = .zero
        private var navigating = false

        init(_ parent: NativePreviewViewport) {
            self.parent = parent
            host = UIHostingController(rootView: parent.content)
            super.init()
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
        }

        func layout(_ scroll: UIScrollView) {
            let size = scroll.bounds.size
            guard size.width > 0, size.height > 0, size != lastSize else { return }
            let oldSize = lastSize
            let scale = scroll.zoomScale
            let center = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: host.view)
            lastSize = size
            scroll.setZoomScale(1, animated: false)
            host.view.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            scroll.setZoomScale(scale, animated: false)
            if oldSize.width > 0, oldSize.height > 0, scale > 1 {
                scroll.contentOffset = CGPoint(x: center.x / oldSize.width * size.width * scale - size.width / 2,
                                               y: center.y / oldSize.height * size.height * scale - size.height / 2)
            }
            centerContent(scroll)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(scrollView)
            reportZoom(scrollView.zoomScale)
        }

        private func centerContent(_ scroll: UIScrollView) {
            host.view.center = CGPoint(x: max(scroll.bounds.width, scroll.contentSize.width) / 2,
                                       y: max(scroll.bounds.height, scroll.contentSize.height) / 2)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { setNavigating(true) }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            let snapped = PreviewZoom.snapped(scale)
            if snapped != scale { apply(.init(scale: snapped, reset: false), to: scrollView) }
            if !scrollView.isDragging { setNavigating(false) }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { setNavigating(true) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !scrollView.isZooming { setNavigating(false) }
        }

        func setNavigating(_ value: Bool) {
            guard navigating != value else { return }
            navigating = value
            parent.onNavigationChanged(value)
        }

        private func reportZoom(_ value: CGFloat) {
            // Delegate callbacks also occur during representable layout.
            // Publish on the next run loop, coalescing unchanged values.
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.zoom - value) > 0.001 else { return }
                self.parent.zoom = value
            }
        }

        func apply(_ command: PreviewZoomCommand, to scroll: UIScrollView) {
            guard lastSize != .zero else { return }
            if command.reset {
                scroll.setZoomScale(1, animated: false)
                scroll.setContentOffset(.zero, animated: false)
            } else {
                let scale = PreviewZoom.clamped(command.scale)
                let center = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: host.view)
                scroll.zoom(to: CGRect(x: center.x - scroll.bounds.width / scale / 2,
                                       y: center.y - scroll.bounds.height / scale / 2,
                                       width: scroll.bounds.width / scale, height: scroll.bounds.height / scale), animated: false)
            }
            reportZoom(scroll.zoomScale)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent.interaction == .full
        }

        // Keep our action distinct from UIKit's private selector names: App
        // Store validation also checks Objective-C selectors on app classes.
        @objc func gradeLabResetPreviewZoom(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            apply(.init(scale: 1, reset: true), to: scroll)
        }
    }
}
