@preconcurrency import Metal
import CoreVideo
import Foundation
import simd

/// Uniforms shared by the analysis kernels and the visualisation shaders.
/// Laid out to match `ScopeUniforms` in ScopeShaders.metal.
struct ScopeUniforms: Sendable {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var bins: UInt32 = 0
    var cells: UInt32 = 0
    var intensity: Float = 1
    var kR: Float = 0
    var kG: Float = 0
    var kB: Float = 0
    var chromaScale: Float = 1
}

/// Runs one scope's analysis pass against the frame the preview is showing.
///
/// It does **not** decode anything of its own: `MetalVideoRenderer` already has
/// the decoded frame, the grade uniforms and the LUT for the frame it is about
/// to draw, and hands them straight here. The analysis is a small compute pass
/// on the same device and queue, so its ordering against the scope's own drawing
/// is guaranteed without a fence or a readback.
///
/// Nothing is ever copied to the CPU. The density buffers are read directly by
/// the visualisation fragment shaders.
final class ScopeAnalyzer: @unchecked Sendable {
    /// Long edge of the analysis texture. 512 samples across is far more than a
    /// scope drawn a few hundred points wide can show, and it is ~0.9% of the
    /// pixels of a 4K frame.
    static let analysisLongEdge = 512
    static let binCount = 256
    static let vectorCells = 256

    private let context: MetalContext
    private let colorSpace: ScopeColorSpace
    private let lock = NSLock()

    private var samplePipelines: [String: MTLComputePipelineState] = [:]
    private var analysisPipelines: [ScopeType: MTLComputePipelineState] = [:]
    private var maximumPipeline: MTLComputePipelineState?

    private var analysisTexture: MTLTexture?
    private var analysisSize = (width: 0, height: 0)
    private var binBuffers: [ScopeType: MTLBuffer] = [:]
    private let peakBuffer: MTLBuffer

    /// Bumped whenever a pass completes, so the scope view knows to redraw.
    private(set) var generation: UInt64 = 0
    private var inFlight = false
    var onUpdate: (@Sendable () -> Void)?

    init?(context: MetalContext, colorSpace: ScopeColorSpace) {
        self.context = context
        self.colorSpace = colorSpace
        guard let peak = context.device.makeBuffer(length: MemoryLayout<UInt32>.stride,
                                                   options: .storageModePrivate) else { return nil }
        peakBuffer = peak
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = context.library.makeFunction(name: name) else { return nil }
            return try? context.device.makeComputePipelineState(function: function)
        }
        for name in ["scopeSampleYUV", "scopeSampleBGRA", "scopeSampleHDR"] {
            guard let state = pipeline(name) else { return nil }
            samplePipelines[name] = state
        }
        let kernels: [ScopeType: String] = [
            .histogram: "scopeHistogram", .waveform: "scopeWaveform",
            .rgbParade: "scopeParade", .vectorscope: "scopeVectorscope"
        ]
        for (type, name) in kernels {
            guard let state = pipeline(name) else { return nil }
            analysisPipelines[type] = state
        }
        guard let maximum = pipeline("scopeMaximum") else { return nil }
        maximumPipeline = maximum
    }

    // MARK: - Resources

    /// Analysis size for a frame, preserving aspect ratio so nothing is
    /// stretched. Portrait footage gets a portrait analysis texture.
    static func analysisSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let longest = max(width, height)
        guard longest > analysisLongEdge else { return (width, height) }
        let scale = Double(analysisLongEdge) / Double(longest)
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return (even(width), even(height))
    }

    /// Elements in the density buffer for a scope at a given analysis width.
    static func binCapacity(_ type: ScopeType, width: Int) -> Int {
        switch type {
        case .histogram: binCount * 3
        case .waveform: width * binCount
        case .rgbParade: width * binCount * 3
        case .vectorscope: vectorCells * vectorCells
        }
    }

    private func texture(width: Int, height: Int) -> MTLTexture? {
        if let existing = analysisTexture, analysisSize == (width, height) { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let made = context.device.makeTexture(descriptor: descriptor) else { return nil }
        analysisTexture = made
        analysisSize = (width, height)
        // A different frame size invalidates every density buffer that is sized
        // by analysis width.
        binBuffers.removeAll()
        return made
    }

    private func bins(for type: ScopeType, width: Int) -> MTLBuffer? {
        if let existing = binBuffers[type] { return existing }
        let length = Self.binCapacity(type, width: width) * MemoryLayout<UInt32>.stride
        guard let made = context.device.makeBuffer(length: length, options: .storageModePrivate) else { return nil }
        binBuffers[type] = made
        return made
    }

    /// The buffers the visualisation reads. Both live on the same queue as the
    /// analysis, so a draw submitted after a pass sees that pass' results.
    func visualisationBuffers(for type: ScopeType) -> (bins: MTLBuffer, peak: MTLBuffer)? {
        lock.lock(); defer { lock.unlock() }
        guard let bins = binBuffers[type] else { return nil }
        return (bins, peakBuffer)
    }

    func uniforms(for type: ScopeType, intensity: Double) -> ScopeUniforms {
        lock.lock(); defer { lock.unlock() }
        return makeUniforms(type: type, intensity: intensity)
    }

    private func makeUniforms(type: ScopeType, intensity: Double) -> ScopeUniforms {
        let k = colorSpace.lumaCoefficients
        return ScopeUniforms(
            width: UInt32(analysisSize.width), height: UInt32(analysisSize.height),
            bins: UInt32(Self.binCount), cells: UInt32(Self.vectorCells),
            intensity: Float(intensity), kR: k.r, kG: k.g, kB: k.b,
            chromaScale: Float(1 / colorSpace.fullSaturationRadius))
    }

    /// Frees everything the analyzer holds. Called when scopes are switched off,
    /// so nothing is kept alive for a panel nobody is looking at.
    func release() {
        lock.lock()
        analysisTexture = nil
        analysisSize = (0, 0)
        binBuffers.removeAll()
        inFlight = false
        lock.unlock()
    }

    // MARK: - Analysis

    /// One analysis pass for the frame the preview is drawing.
    ///
    /// Encoded into its own command buffer and committed without waiting, so the
    /// preview's own submission is never blocked. A pass is skipped while one is
    /// still in flight rather than queued, which is what keeps scrubbing
    /// responsive: the scope simply shows the most recent frame it managed.
    ///
    /// - Returns: whether a pass was actually encoded. Video can ignore this —
    ///   the next decoded frame comes along and asks again — but a still has no
    ///   next frame, so its caller has to know to try again rather than leave
    ///   the scope reading a grade that is no longer on screen.
    @discardableResult
    func analyze(
        textures: PixelBufferTextures,
        pixelBuffer: CVPixelBuffer,
        type: ScopeType,
        grade: GradeUniforms,
        /// The clip's masked local grades. Scopes measure the FINISHED frame, so
        /// they grade through exactly the same stack the picture does rather
        /// than analysing anything of their own.
        locals: LocalGradeStack = .empty,
        yuv: YUVUniforms,
        hdr: HDRDisplayUniforms,
        intensity: Double,
        lut: MTLTexture,
        curveLUT: MTLTexture,
        warpField: MTLTexture
    ) -> Bool {
        lock.lock()
        if inFlight { lock.unlock(); return false }
        let size = Self.analysisSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer))
        guard size.width > 0, size.height > 0,
              let analysis = texture(width: size.width, height: size.height),
              let binBuffer = bins(for: type, width: size.width),
              let analysisPipeline = analysisPipelines[type],
              let maximumPipeline,
              let command = context.commandQueue.makeCommandBuffer() else {
            lock.unlock(); return false
        }
        var uniforms = makeUniforms(type: type, intensity: intensity)
        inFlight = true
        lock.unlock()

        command.label = "GradeLab scope \(type.rawValue)"

        // Zeroing with a blit is one command for the whole buffer; a clear
        // kernel would be a dispatch per element for no benefit.
        if let blit = command.makeBlitCommandEncoder() {
            blit.fill(buffer: binBuffer, range: 0..<binBuffer.length, value: 0)
            blit.fill(buffer: peakBuffer, range: 0..<peakBuffer.length, value: 0)
            blit.endEncoding()
        }

        var grade = grade, yuv = yuv, hdr = hdr
        if let encoder = command.makeComputeCommandEncoder() {
            let name: String
            switch textures.storage {
            case .biPlanar(_, let luma, _, let chroma):
                name = "scopeSampleYUV"
                encoder.setTexture(luma, index: 0)
                encoder.setTexture(chroma, index: 1)
                encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
            case .bgra(_, let texture):
                name = "scopeSampleBGRA"
                encoder.setTexture(texture, index: 0)
            case .linearHalf(_, let texture):
                name = "scopeSampleHDR"
                encoder.setTexture(texture, index: 0)
                encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
            }
            guard let pipeline = samplePipelines[name] else {
                encoder.endEncoding(); finish(command, retaining: textures, skipped: true); return false
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(analysis, index: 2)
            encoder.setTexture(lut, index: 3)
            encoder.setTexture(curveLUT, index: 6)
            encoder.setTexture(warpField, index: 12)
            encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            locals.bind(encoder)
            Self.dispatch(encoder, pipeline: pipeline, width: size.width, height: size.height)
            encoder.endEncoding()
        }

        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(analysisPipeline)
            encoder.setTexture(analysis, index: 0)
            encoder.setBuffer(binBuffer, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<ScopeUniforms>.stride, index: 1)
            Self.dispatch(encoder, pipeline: analysisPipeline, width: size.width, height: size.height)
            encoder.endEncoding()
        }

        var count = UInt32(Self.binCapacity(type, width: size.width))
        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(maximumPipeline)
            encoder.setBuffer(binBuffer, offset: 0, index: 0)
            encoder.setBuffer(peakBuffer, offset: 0, index: 1)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
            Self.dispatch(encoder, pipeline: maximumPipeline, width: Int(count), height: 1)
            encoder.endEncoding()
        }

        finish(command, retaining: textures, skipped: false)
        return true
    }

    /// `retaining` keeps the source's `CVMetalTexture` bindings alive until the
    /// GPU is finished with them; releasing them earlier would pull the IOSurface
    /// out from under a pass that is still reading it.
    private func finish(_ command: MTLCommandBuffer, retaining textures: PixelBufferTextures, skipped: Bool) {
        command.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(textures) {}
            guard let self else { return }
            self.lock.lock()
            self.inFlight = false
            if !skipped { self.generation &+= 1 }
            let notify = self.onUpdate
            self.lock.unlock()
            if !skipped { notify?() }
        }
        command.commit()
    }

    private static func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchThreads(
            MTLSize(width: max(1, width), height: max(1, height), depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }
}
