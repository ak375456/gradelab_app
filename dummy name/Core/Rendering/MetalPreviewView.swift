import MetalKit
import SwiftUI

struct MetalPreviewView: UIViewRepresentable {
    let renderer: MetalVideoRenderer
    let settings: GradeSettings
    let showsOriginal: Bool
    let isPlaying: Bool
    let redrawTime: Double
    let frameUpdateID: UInt
    var isActive: Bool = true

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        renderer.configure(view)
        renderer.update(settings: settings, bypass: showsOriginal)
        view.isPaused = !isActive
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        renderer.update(settings: settings, bypass: showsOriginal)
        // A display tick retries unavailable drawables and late decoded 4K frames.
        // The renderer skips unchanged frames before allocating GPU work.
        uiView.isPaused = !isActive
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Void) {
        uiView.isPaused = true
        uiView.delegate = nil
    }
}
