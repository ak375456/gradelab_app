@preconcurrency import MetalKit
import Foundation

/// Draws a scope's density straight from the analyzer's buffers.
///
/// There is no GPU→CPU→SwiftUI round trip: the fragment shader reads the same
/// buffer the compute pass wrote. Both run on one command queue, so a draw
/// submitted after a pass sees that pass' results without a fence.
final class ScopeRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let context: MetalContext
    private let analyzer: ScopeAnalyzer
    private var pipelines: [ScopeType: MTLRenderPipelineState] = [:]
    private let lock = NSLock()
    private var type: ScopeType
    private var intensity: Double

    init?(context: MetalContext, analyzer: ScopeAnalyzer, type: ScopeType, intensity: Double) {
        self.context = context
        self.analyzer = analyzer
        self.type = type
        self.intensity = intensity
        super.init()
        let fragments: [ScopeType: String] = [
            .histogram: "scopeHistogramFragment", .waveform: "scopeWaveformFragment",
            .rgbParade: "scopeParadeFragment", .vectorscope: "scopeVectorscopeFragment"
        ]
        guard let vertex = context.library.makeFunction(name: "scopeVertex") else { return nil }
        for (scope, name) in fragments {
            guard let fragment = context.library.makeFunction(name: name) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "GradeLab \(name)"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let state = try? context.device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            pipelines[scope] = state
        }
    }

    func update(type: ScopeType, intensity: Double) {
        lock.lock(); self.type = type; self.intensity = intensity; lock.unlock()
    }

    func configure(_ view: MTKView) {
        view.device = context.device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        // Redraw only when a new analysis lands, rather than on a display link:
        // a scope showing the same numbers again costs nothing to skip.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.layer.isOpaque = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock(); let type = self.type; let intensity = self.intensity; lock.unlock()
        guard let pipeline = pipelines[type],
              let buffers = analyzer.visualisationBuffers(for: type),
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var uniforms = analyzer.uniforms(for: type, intensity: intensity)
        guard uniforms.width > 0 else { encoder.endEncoding(); return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(buffers.bins, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffers.peak, offset: 0, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScopeUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
