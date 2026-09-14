import SwiftUI

/// Inspection only: this transform never changes the project or exported frame.
struct PreviewViewport<Content: View>: View {
    var inspectionEnabled = true
    @ViewBuilder let content: () -> Content
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let zoom = min(6, max(1, scale * magnification))
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
                        scale = min(6, max(1, scale * value.magnification))
                        offset = bounded(offset, zoom: scale, size: geometry.size)
                    }, including: inspectionEnabled ? .all : .subviews)
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .updating($translation) { value, state, _ in if scale > 1 { state = value.translation } }
                    .onEnded { value in
                        guard scale > 1 else { return }
                        offset = bounded(CGSize(width: offset.width + value.translation.width,
                                                height: offset.height + value.translation.height), zoom: scale, size: geometry.size)
                    }, including: inspectionEnabled ? .all : .subviews)
                .onTapGesture(count: 2) { if inspectionEnabled { scale = 1; offset = .zero } }
                .onChange(of: inspectionEnabled) { _, enabled in if !enabled { scale = 1; offset = .zero } }
                .accessibilityAction(named: "Reset preview zoom") { scale = 1; offset = .zero }
        }
    }

    private func bounded(_ value: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        let x = size.width * (zoom-1)/2, y = size.height * (zoom-1)/2
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }
}
