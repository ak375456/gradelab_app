import MetalKit
import SwiftUI

/// The scope's density, drawn by Metal straight from the analyzer's buffers.
struct MetalScopeView: UIViewRepresentable {
    let renderer: ScopeRenderer
    let analyzer: ScopeAnalyzer
    let type: ScopeType
    let intensity: Double

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        renderer.configure(view)
        renderer.update(type: type, intensity: intensity)
        // The analyzer wakes the view when a pass lands, so nothing redraws on a
        // display link showing numbers that have not changed.
        analyzer.onUpdate = { [weak view] in
            Task { @MainActor in view?.setNeedsDisplay() }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        renderer.update(type: type, intensity: intensity)
        uiView.setNeedsDisplay()
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Void) {
        uiView.delegate = nil
    }
}
