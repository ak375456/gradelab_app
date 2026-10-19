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
struct PreviewViewport<Content: View, Controls: View>: View {
    var interaction: PreviewInteraction = .full
    var onPinchChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let content: () -> Content
    @ViewBuilder let controls: () -> Controls
    @State private var zoom: CGFloat = 1
    @State private var command = PreviewZoomCommand(scale: 1, reset: true)

    var body: some View {
        VStack(spacing: 0) {
            NativePreviewViewport(content: content().environment(\.previewMagnification, zoom), interaction: interaction,
                                  command: command, zoom: $zoom, onNavigationChanged: onPinchChanged)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityAction(named: "Reset preview zoom") { reset() }
            HStack(spacing: AppSpacing.small) {
                zoomControls
                Spacer(minLength: 0)
                controls()
            }
            .padding(.horizontal, AppSpacing.small)
            .frame(height: PreviewToolbarMetrics.height)
            .background(AppColors.editorBackground)
            .overlay(alignment: .top) { AppDivider() }
        }
    }

    private var zoomControls: some View {
        Menu {
            Button("Fit · 100%", systemImage: "arrow.counterclockwise", action: reset)
            Divider()
            Button("Zoom in", systemImage: "plus.magnifyingglass") { setZoom(zoom * 1.25) }
                .disabled(zoom >= PreviewZoom.maximum)
            Button("Zoom out", systemImage: "minus.magnifyingglass") { setZoom(zoom / 1.25) }
                .disabled(zoom <= PreviewZoom.minimum)
            Divider()
            ForEach([50, 200, 400, 800], id: \.self) { percent in
                Button("\(percent)%") { setZoom(CGFloat(percent) / 100) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "viewfinder")
                Text("\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(AppTypography.caption.weight(.medium))
            .foregroundStyle(AppColors.textSecondary)
            .frame(minWidth: 88, minHeight: PreviewToolbarMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview zoom, \(Int((zoom * 100).rounded())) percent")
        .help("Zoom relative to Fit. Pinch anywhere to zoom; use two fingers to pan.")
    }

    private func setZoom(_ value: CGFloat) {
        command = PreviewZoomCommand(scale: PreviewZoom.clamped(value), reset: false)
    }

    private func reset() { command = PreviewZoomCommand(scale: 1, reset: true) }
}

extension PreviewViewport where Controls == EmptyView {
    init(interaction: PreviewInteraction = .full,
         onPinchChanged: @escaping (Bool) -> Void = { _ in },
         @ViewBuilder content: @escaping () -> Content) {
        self.interaction = interaction
        self.onPinchChanged = onPinchChanged
        self.content = content
        self.controls = { EmptyView() }
    }
}

enum PreviewToolbarMetrics {
    static let height: CGFloat = 44
}

/// Preview furniture lives below the image, outside its zoom and hit regions.
struct PreviewToolbarLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var isSelected = false

    var body: some View {
        Label(title, systemImage: symbol)
            .font(AppTypography.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.small)
            .frame(minWidth: 44, minHeight: PreviewToolbarMetrics.height)
            .foregroundStyle(isSelected ? AppColors.accent : AppColors.textSecondary)
            .background(isSelected ? AppColors.accentMuted : .clear,
                        in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
            .contentShape(Rectangle())
    }
}

/// Tap to pin the original, or hold for a momentary comparison. The hold owns
/// its gesture only after recognition, leaving ordinary Button taps intact.
struct PreviewCompareButton: View {
    @Binding var isPinned: Bool
    var showsOriginal: Bool
    var onHoldChanged: (Bool) -> Void
    @GestureState private var isHolding = false

    var body: some View {
        Button { isPinned.toggle() } label: {
            PreviewToolbarLabel(title: showsOriginal ? "Original" : "Compare",
                                symbol: "square.on.square", isSelected: showsOriginal)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($isHolding) { value, held, _ in
                    if case .second(true, _) = value { held = true }
                }
        )
        .onChange(of: isHolding) { _, held in onHoldChanged(held) }
        .onDisappear { onHoldChanged(false) }
        .accessibilityLabel(isPinned ? "Show edited" : "Compare with original")
        .accessibilityValue(showsOriginal ? "Original" : "Edited")
        .accessibilityHint("Tap to toggle, or hold to compare temporarily")
        .help("Tap to toggle, or hold to compare temporarily")
    }
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
