@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
@preconcurrency import Metal

// ---------------------------------------------------------------------------
// The GPU half of a depth analysis
//
// Three jobs per decoded frame, all small:
//
//   1. The frame, reduced to the analysis grid as a display-referred picture
//      (read back for the CPU) and as luminance (kept for the motion search).
//   2. On keyframes only, the frame at the estimator's size, written straight
//      into a pixel buffer Vision and Core ML can read without a copy.
//   3. Motion between this frame and the last, both ways, with the pyramid
//      search noise reduction already uses — the same kernels, not a second
//      motion estimator — read back so the CPU can carry depth along it.
//
// Every frame is committed and waited on. That is right for a background
// analysis that has to hand its results to the CPU anyway, and it is why this
// never runs on a render path.
// ---------------------------------------------------------------------------

struct RelightAnalysisFrame {
    /// The analysis picture, RGBA8, encoded orientation.
    let picture: [UInt8]
    /// Its luminance, 0…1, for the estimators' confidence.
    let luma: [Float]
    /// Current → previous and previous → current, on the finest flow grid.
    let forward: RelightFlowField?
    let backward: RelightFlowField?
    /// The frame at the estimator's size, when asked for.
    let estimatorImage: CVPixelBuffer?
}

final class RelightAnalysisGPU {
    private static let flowLevels = 4

    private let context: MetalContext
    private let colorMode: ProjectColorMode
    let analysisWidth: Int
    let analysisHeight: Int
    let estimatorWidth: Int
    let estimatorHeight: Int

    private let prepareYUV: MTLComputePipelineState
    private let prepareRGB: MTLComputePipelineState
    private let prepareAppleLog: MTLComputePipelineState?
    private let downsample: MTLComputePipelineState
    private let flowSearch: MTLComputePipelineState
    private let flowSmooth: MTLComputePipelineState

    private let picture: MTLTexture
    private let luma: MTLTexture
    private let estimatorLuma: MTLTexture
    /// Two halving chains of the analysis luminance, swapped every frame so
    /// the previous frame's is still there to search against.
    private var pyramids: [[MTLTexture]]
    private var current = 0
    private var hasPrevious = false
    private let scratchA: [MTLTexture]
    private let scratchB: [MTLTexture]
    private let forwardField: MTLTexture
    private let backwardField: MTLTexture
    private var estimatorPool: CVPixelBufferPool?

    init?(context: MetalContext, colorMode: ProjectColorMode,
          analysisSize: (width: Int, height: Int), estimatorSize: (width: Int, height: Int)) {
        self.context = context
        self.colorMode = colorMode
        analysisWidth = analysisSize.width
        analysisHeight = analysisSize.height
        estimatorWidth = estimatorSize.width
        estimatorHeight = estimatorSize.height
        let device = context.device
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = context.library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }
        guard let prepareYUV = pipeline("relightAnalysisPrepareYUV"),
              let prepareRGB = pipeline("relightAnalysisPrepareRGB"),
              let downsample = pipeline("nrDownsampleLuma"),
              let flowSearch = pipeline("nrFlowSearch"),
              let flowSmooth = pipeline("nrFlowSmooth") else { return nil }
        self.prepareYUV = prepareYUV
        self.prepareRGB = prepareRGB
        self.downsample = downsample
        self.flowSearch = flowSearch
        self.flowSmooth = flowSmooth
        let logPipeline = colorMode.isAppleLog
            ? AppleLogSpecialization.computePipeline(
                "relightAnalysisPrepareAppleLog", isLog2: colorMode == .appleLog2,
                library: context.library, device: device)
            : nil
        if colorMode.isAppleLog, logPipeline == nil { return nil }
        prepareAppleLog = logPipeline

        func make(_ format: MTLPixelFormat, _ width: Int, _ height: Int, shared: Bool = false) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let picture = make(.rgba8Unorm, analysisSize.width, analysisSize.height, shared: true),
              let luma = make(.r16Float, analysisSize.width, analysisSize.height),
              let estimatorLuma = make(.r16Float, estimatorSize.width, estimatorSize.height) else { return nil }
        self.picture = picture
        self.luma = luma
        self.estimatorLuma = estimatorLuma

        func chain() -> [MTLTexture]? {
            var levels: [MTLTexture] = []
            var width = analysisSize.width, height = analysisSize.height
            for _ in 0..<Self.flowLevels {
                width = max(1, width / 2); height = max(1, height / 2)
                guard let level = make(.r16Float, width, height) else { return nil }
                levels.append(level)
            }
            return levels
        }
        guard let first = chain(), let second = chain() else { return nil }
        pyramids = [first, second]
        var a: [MTLTexture] = [], b: [MTLTexture] = []
        for level in first {
            guard let x = make(.rgba16Float, level.width, level.height),
                  let y = make(.rgba16Float, level.width, level.height) else { return nil }
            a.append(x); b.append(y)
        }
        scratchA = a
        scratchB = b
        guard let forward = make(.rgba32Float, first[0].width, first[0].height, shared: true),
              let backward = make(.rgba32Float, first[0].width, first[0].height, shared: true) else { return nil }
        forwardField = forward
        backwardField = backward
    }

    /// Forgets the previous frame, so the next one starts a new motion chain.
    func resetMotion() { hasPrevious = false }

    func process(_ pixelBuffer: CVPixelBuffer, wantsEstimatorImage: Bool, wantsMotion: Bool) throws -> RelightAnalysisFrame {
        guard let textures = PixelBufferTextures(pixelBuffer: pixelBuffer, context: context),
              let command = context.commandQueue.makeCommandBuffer() else {
            throw RelightError.message(String(localized: "A frame could not be prepared for scene analysis."))
        }
        command.label = "GradeLab Relight Analysis"

        guard encodePrepare(textures, buffer: pixelBuffer, picture: picture, luma: luma, into: command) else {
            throw RelightError.message(String(localized: "This frame's format cannot be analysed."))
        }
        var estimatorImage: CVPixelBuffer?
        var estimatorTexture: (reference: CVMetalTexture, texture: MTLTexture)?
        if wantsEstimatorImage, let buffer = makeEstimatorBuffer(),
           let target = context.packedTexture(from: buffer, pixelFormat: .bgra8Unorm),
           encodePrepare(textures, buffer: pixelBuffer, picture: target.texture, luma: estimatorLuma, into: command) {
            estimatorImage = buffer
            estimatorTexture = target
        }

        // The halving chain for this frame, then motion against the last one.
        let pyramid = pyramids[current]
        var input = luma
        for level in pyramid {
            guard let encoder = command.makeComputeCommandEncoder() else { break }
            encoder.setComputePipelineState(downsample)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(level, index: 1)
            Self.dispatch(encoder, downsample, level.width, level.height)
            encoder.endEncoding()
            input = level
        }
        let computesMotion = wantsMotion && hasPrevious
        if computesMotion {
            let previous = pyramids[1 - current]
            encodeFlow(from: pyramid, to: previous, destination: forwardField, into: command)
            encodeFlow(from: previous, to: pyramid, destination: backwardField, into: command)
        }

        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        withExtendedLifetime(estimatorTexture) {}
        guard command.status == .completed else {
            throw RelightError.message(command.error?.localizedDescription
                ?? String(localized: "Scene analysis stopped on the GPU."))
        }

        current = 1 - current
        hasPrevious = true

        let pixels = analysisWidth * analysisHeight
        var bytes = [UInt8](repeating: 0, count: pixels * 4)
        bytes.withUnsafeMutableBytes { raw in
            picture.getBytes(raw.baseAddress!, bytesPerRow: analysisWidth * 4,
                             from: MTLRegionMake2D(0, 0, analysisWidth, analysisHeight), mipmapLevel: 0)
        }
        var lumaValues = [Float](repeating: 0, count: pixels)
        for index in 0..<pixels {
            let r = Float(bytes[index * 4]), g = Float(bytes[index * 4 + 1]), b = Float(bytes[index * 4 + 2])
            lumaValues[index] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return RelightAnalysisFrame(
            picture: bytes, luma: lumaValues,
            forward: computesMotion ? Self.readField(forwardField) : nil,
            backward: computesMotion ? Self.readField(backwardField) : nil,
            estimatorImage: estimatorImage)
    }

    // MARK: - Encoding

    private func encodePrepare(_ textures: PixelBufferTextures, buffer: CVPixelBuffer,
                               picture: MTLTexture, luma: MTLTexture,
                               into command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        let pipeline: MTLComputePipelineState
        var yuv = YUVUniforms.make(for: buffer, fallbackMatrix: "BT.709")
        var hdr = HDRDisplayUniforms()
        switch textures.storage {
        case .biPlanar(_, let lumaPlane, _, let chromaPlane):
            if colorMode.isAppleLog, let log = prepareAppleLog {
                pipeline = log
                encoder.setComputePipelineState(pipeline)
            } else {
                pipeline = prepareYUV
                encoder.setComputePipelineState(pipeline)
                encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
            }
            encoder.setTexture(lumaPlane, index: 0)
            encoder.setTexture(chromaPlane, index: 1)
        case .bgra(_, let texture):
            pipeline = prepareRGB
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            var mode = SIMD4<Float>(0, 0, 0, 0)
            encoder.setBytes(&mode, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        case .linearHalf(_, let texture):
            pipeline = prepareRGB
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            var mode = SIMD4<Float>(1, 0, 0, 0)
            encoder.setBytes(&mode, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        }
        encoder.setTexture(picture, index: 2)
        encoder.setTexture(luma, index: 3)
        Self.dispatch(encoder, pipeline, picture.width, picture.height)
        encoder.endEncoding()
        return true
    }

    /// Coarse to fine, exactly as `NoiseReductionStage.encodeFlow` searches:
    /// an exhaustive search at the top, one-pixel refinements below it, and a
    /// vector median after each so an outlier cannot be refined into a
    /// confident mistake.
    private func encodeFlow(from source: [MTLTexture], to target: [MTLTexture],
                            destination: MTLTexture, into command: MTLCommandBuffer) {
        var seed: MTLTexture?
        for level in stride(from: Self.flowLevels - 1, through: 0, by: -1) {
            let isCoarsest = level == Self.flowLevels - 1
            var params = SIMD4<Float>(isCoarsest ? 4 : 1, isCoarsest ? 1 : 2, 0.0025, 0)
            guard let search = command.makeComputeCommandEncoder() else { return }
            search.setComputePipelineState(flowSearch)
            search.setTexture(source[level], index: 0)
            search.setTexture(target[level], index: 1)
            search.setTexture(seed, index: 2)
            search.setTexture(scratchA[level], index: 3)
            search.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            Self.dispatch(search, flowSearch, scratchA[level].width, scratchA[level].height)
            search.endEncoding()

            let smoothed = level == 0 ? destination : scratchB[level]
            guard let median = command.makeComputeCommandEncoder() else { return }
            median.setComputePipelineState(flowSmooth)
            median.setTexture(scratchA[level], index: 0)
            median.setTexture(smoothed, index: 1)
            Self.dispatch(median, flowSmooth, smoothed.width, smoothed.height)
            median.endEncoding()
            seed = smoothed
        }
    }

    private func makeEstimatorBuffer() -> CVPixelBuffer? {
        if estimatorPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: estimatorWidth,
                kCVPixelBufferHeightKey as String: estimatorHeight,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
                return nil
            }
            estimatorPool = pool
        }
        guard let estimatorPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, estimatorPool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private static func readField(_ texture: MTLTexture) -> RelightFlowField {
        var vectors = [SIMD4<Float>](repeating: .zero, count: texture.width * texture.height)
        vectors.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: texture.width * MemoryLayout<SIMD4<Float>>.stride,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return RelightFlowField(width: texture.width, height: texture.height, vectors: vectors)
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                                 _ width: Int, _ height: Int) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchThreads(
            MTLSize(width: max(width, 1), height: max(height, 1), depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }
}
