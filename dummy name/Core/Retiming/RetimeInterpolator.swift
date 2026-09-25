@preconcurrency import CoreVideo
@preconcurrency import Metal
import CoreMedia
import Foundation
import simd

/// Makes the frame between two source frames.
///
/// ## Where this sits
///
/// The compositor is handed a clip's frame and, for a retimed clip, the one
/// after it — that pair already exists, because frame blending needs exactly
/// the same two pictures and the composition has been scheduling a second,
/// one-frame-later copy of the source for as long as blending has existed.
/// Optical flow is not a different input, it is a better answer from the same
/// one.
///
/// ## Why the result is a pixel buffer in the source's own format
///
/// It would be cheaper to blend inside the grading kernels — that is what frame
/// blending does, and it is why there are four `blendAmount` parameters
/// scattered across the SDR, HDR and two Apple Log paths. Doing the same for
/// flow would mean four more kernel variants, four more sets of texture
/// bindings, and four places for the warp to be subtly different.
///
/// Instead the interpolated frame is written back into a buffer of exactly the
/// format it came from — 4:2:0 or 4:2:2, 8-bit or 10-bit — and handed on as if
/// it had been decoded. Grading, masks, background removal, the Log transforms
/// and the HDR working space are all untouched and none of them learns that
/// this frame was made rather than read. Colour accuracy is therefore not a
/// question: the frame goes through the identical path.
///
/// ## Where the motion estimate comes from
///
/// `nrFlowSearch` and `nrFlowSmooth`, in NoiseReductionShaders.metal. They are
/// a coarse-to-fine block match with a vector median between levels, written
/// for temporal denoising and validated by `Scripts/validate-noise-reduction.sh`.
/// They are general-purpose motion estimation and both engines use them; this
/// one keeps its own surfaces and pipelines so neither can disturb the other's
/// state.
final class RetimeInterpolator {
    /// Identifies a pair of source frames, so the same flow is estimated once
    /// however many output frames it serves.
    ///
    /// This is the reason flow is affordable at all. At 25% speed one pair of
    /// source frames covers four output frames; at 10%, ten. The estimate is
    /// keyed by the frames themselves — the asset and the two presentation
    /// times — and **not** by the speed curve or the trim, because the motion
    /// between two given pictures does not depend on the edit that asked for
    /// it. Keying it by the edit would recompute identical answers on every
    /// drag of a speed point.
    struct PairKey: Hashable {
        let assetID: UUID
        let first: CMTime
        let second: CMTime
        let divisor: Int
    }

    private let context: MetalContext
    private let prepareLuma: MTLComputePipelineState
    private let downsample: MTLComputePipelineState
    private let flowSearch: MTLComputePipelineState
    private let flowSmooth: MTLComputePipelineState
    private let interpolate: MTLComputePipelineState

    /// Levels in the matching pyramid, as the denoiser uses. Four takes a
    /// quarter-resolution grid down to a thirty-second of the frame, which is
    /// coarse enough to catch a whip pan.
    private static let flowLevels = 4

    /// How much the frame is divided down before motion is estimated.
    ///
    /// Preview and High differ here and only here. A motion field does not need
    /// the picture's resolution — it needs enough of it to find the edges — so
    /// halving the grid quarters the search and is most of what makes the
    /// timeline usable while still showing real flow rather than a dissolve.
    static func divisor(for quality: OpticalFlowQuality) -> Int {
        switch quality {
        case .preview: 8
        case .high: 4
        }
    }

    init?(context: MetalContext) {
        self.context = context
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = context.library.makeFunction(name: name) else { return nil }
            return try? context.device.makeComputePipelineState(function: function)
        }
        guard let prepareLuma = pipeline("retimePrepareLuma"),
              let downsample = pipeline("nrDownsampleLuma"),
              let flowSearch = pipeline("nrFlowSearch"),
              let flowSmooth = pipeline("nrFlowSmooth"),
              let interpolate = pipeline("retimeInterpolatePlane") else { return nil }
        self.prepareLuma = prepareLuma
        self.downsample = downsample
        self.flowSearch = flowSearch
        self.flowSmooth = flowSmooth
        self.interpolate = interpolate
    }

    // MARK: - Surfaces

    /// A finished pair of motion fields, and the grid they were measured on.
    private struct Flow {
        let forward: MTLTexture
        let backward: MTLTexture
        let width: Int
        let height: Int
    }

    private var flowCache: [PairKey: Flow] = [:]
    private var flowOrder: [PairKey] = []
    /// Enough to cover a slow section without holding the whole clip. Each
    /// entry is two small float fields — at a 1/8 grid of 1080p that is about
    /// 130KB the pair — so this is well under ten megabytes.
    private static let flowCacheLimit = 24

    private var scratch: Scratch?

    /// Everything the estimate needs at one frame size, kept between frames.
    ///
    /// Rebuilt only when the frame size changes, which in practice means once.
    /// Allocating a pyramid per frame would dominate the cost of the estimate
    /// it was allocated for.
    private struct Scratch {
        let width: Int
        let height: Int
        let divisor: Int
        let lumaA: MTLTexture
        let lumaB: MTLTexture
        let pyramidA: [MTLTexture]
        let pyramidB: [MTLTexture]
        let searchScratch: [MTLTexture]
        let medianScratch: [MTLTexture]
        var base: Int { RetimeInterpolator.baseLevel(for: divisor) }
        var flowSize: (width: Int, height: Int) {
            (pyramidA[base].width, pyramidA[base].height)
        }
    }

    /// Which halving of the frame the motion grid is.
    ///
    /// Counted rather than taken from `log2`, for the reason the denoiser gives:
    /// a floating-point logarithm that lands on 1.9999 puts the whole pyramid
    /// one level out.
    static func baseLevel(for divisor: Int) -> Int {
        var level = 0, value = max(divisor, 2)
        while value > 2 { value /= 2; level += 1 }
        return level
    }

    func purge() {
        flowCache.removeAll()
        flowOrder.removeAll()
        scratch = nil
    }

    private func float(_ width: Int, _ height: Int, channels: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: channels == 1 ? .r16Float : .rgba16Float,
            width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return context.device.makeTexture(descriptor: descriptor)
    }

    private func makeScratch(width: Int, height: Int, divisor: Int) -> Scratch? {
        let depth = Self.baseLevel(for: divisor) + Self.flowLevels
        func chain(from: MTLTexture) -> [MTLTexture]? {
            var levels: [MTLTexture] = []
            var w = from.width, h = from.height
            for _ in 0..<depth {
                w = max(1, w / 2); h = max(1, h / 2)
                guard let level = float(w, h, channels: 1) else { return nil }
                levels.append(level)
            }
            return levels
        }
        guard let lumaA = float(width, height, channels: 1),
              let lumaB = float(width, height, channels: 1),
              let pyramidA = chain(from: lumaA), let pyramidB = chain(from: lumaB) else { return nil }
        var search: [MTLTexture] = [], median: [MTLTexture] = []
        let base = Self.baseLevel(for: divisor)
        for step in 0..<Self.flowLevels {
            let level = pyramidA[min(pyramidA.count - 1, base + step)]
            guard let a = float(level.width, level.height, channels: 4),
                  let b = float(level.width, level.height, channels: 4) else { return nil }
            search.append(a); median.append(b)
        }
        return Scratch(width: width, height: height, divisor: divisor,
                       lumaA: lumaA, lumaB: lumaB, pyramidA: pyramidA, pyramidB: pyramidB,
                       searchScratch: search, medianScratch: median)
    }

    // MARK: - The estimate

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                          width: Int, height: Int) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchThreads(
            MTLSize(width: max(width, 1), height: max(height, 1), depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }

    private func buildPyramid(from source: MTLTexture, into levels: [MTLTexture],
                              command: MTLCommandBuffer) {
        var input = source
        for level in levels {
            guard let encoder = command.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(downsample)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(level, index: 1)
            dispatch(encoder, downsample, width: level.width, height: level.height)
            encoder.endEncoding()
            input = level
        }
    }

    /// Coarse to fine, exactly as the denoiser runs it: an exhaustive search at
    /// the top, one-pixel refinements below seeded from the level above, and a
    /// vector median between each pair so an outlier cannot be carried down and
    /// refined into a confident mistake.
    private func estimate(from source: [MTLTexture], to target: [MTLTexture],
                          scratch: Scratch, into destination: MTLTexture,
                          command: MTLCommandBuffer) {
        var seed: MTLTexture?
        for step in stride(from: Self.flowLevels - 1, through: 0, by: -1) {
            let level = min(source.count - 1, scratch.base + step)
            let isCoarsest = step == Self.flowLevels - 1
            let isFinest = step == 0
            var params = SIMD4<Float>(
                isCoarsest ? 4 : 1,
                isCoarsest ? 1 : 2,
                // The bias toward the seed. It decides what happens where the
                // picture gives the search nothing to hold on to — a sky, a
                // wall — and there the right answer is "it did not move".
                0.0025,
                0)
            guard let searchEncoder = command.makeComputeCommandEncoder() else { return }
            searchEncoder.setComputePipelineState(flowSearch)
            searchEncoder.setTexture(source[level], index: 0)
            searchEncoder.setTexture(target[level], index: 1)
            searchEncoder.setTexture(seed, index: 2)
            searchEncoder.setTexture(scratch.searchScratch[step], index: 3)
            searchEncoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch(searchEncoder, flowSearch,
                     width: scratch.searchScratch[step].width,
                     height: scratch.searchScratch[step].height)
            searchEncoder.endEncoding()

            let smoothed = isFinest ? destination : scratch.medianScratch[step]
            guard let smoothEncoder = command.makeComputeCommandEncoder() else { return }
            smoothEncoder.setComputePipelineState(flowSmooth)
            smoothEncoder.setTexture(scratch.searchScratch[step], index: 0)
            smoothEncoder.setTexture(smoothed, index: 1)
            dispatch(smoothEncoder, flowSmooth, width: smoothed.width, height: smoothed.height)
            smoothEncoder.endEncoding()
            seed = smoothed
        }
    }

    // MARK: - The frame

    /// Produces the frame `phase` of the way from `first` to `second`.
    ///
    /// - Returns: a new buffer in the same pixel format, or nil when this pair
    ///   cannot be interpolated — an unsupported layout, mismatched sizes, a
    ///   pool that could not allocate. Nil is not an error: the caller falls
    ///   back to blending, which is what the clip would have done anyway.
    func interpolated(
        _ first: CVPixelBuffer,
        _ second: CVPixelBuffer,
        phase: Double,
        quality: OpticalFlowQuality,
        key: PairKey,
        allocate: (Int, Int, OSType) throws -> CVPixelBuffer
    ) throws -> CVPixelBuffer? {
        guard phase > 0.001, phase < 0.999 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(first)
        guard CVPixelBufferGetPixelFormatType(second) == format,
              CVPixelBufferGetWidth(first) == CVPixelBufferGetWidth(second),
              CVPixelBufferGetHeight(first) == CVPixelBufferGetHeight(second),
              let a = PixelBufferTextures(pixelBuffer: first, context: context),
              let b = PixelBufferTextures(pixelBuffer: second, context: context) else { return nil }

        // Two layouts reach this: the planar YUV every SDR and Log clip is
        // decoded into, and the packed half-float surface an HDR timeline
        // carries. They differ only in how many textures a frame is, which is
        // what this reduces them to.
        let planes: [(first: MTLTexture, second: MTLTexture)]
        let matchesRGB: Bool
        switch (a.storage, b.storage) {
        case (.biPlanar(_, let lumaA, _, let chromaA), .biPlanar(_, let lumaB, _, let chromaB)):
            planes = [(lumaA, lumaB), (chromaA, chromaB)]
            matchesRGB = false
        case (.linearHalf(_, let textureA), .linearHalf(_, let textureB)):
            planes = [(textureA, textureB)]
            matchesRGB = true
        default:
            // A still image or a BGRA surface. Neither is ever retimed — a
            // still has no motion to estimate and nothing decodes to BGRA on
            // this path — so refusing is correct rather than a gap.
            return nil
        }
        let lumaA = planes[0].first, lumaB = planes[0].second

        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        let divisor = Self.divisor(for: quality)
        if scratch?.width != width || scratch?.height != height || scratch?.divisor != divisor {
            scratch = makeScratch(width: width, height: height, divisor: divisor)
        }
        guard let scratch else { return nil }

        let output = try allocate(width, height, format)
        let is10Bit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        var destinations: [MTLTexture] = []
        var retainedDestinations: [Any] = []
        if matchesRGB {
            guard let packed = writablePacked(output, pixelFormat: .rgba16Float) else { return nil }
            destinations = [packed.texture]; retainedDestinations = [packed.reference]
        } else {
            guard let luma = context.writableTexture(
                    from: output, pixelFormat: is10Bit ? .r16Unorm : .r8Unorm, plane: 0),
                  let chroma = context.writableTexture(
                    from: output, pixelFormat: is10Bit ? .rg16Unorm : .rg8Unorm, plane: 1) else { return nil }
            destinations = [luma.texture, chroma.texture]
            retainedDestinations = [luma.reference, chroma.reference]
        }
        guard let command = context.commandQueue.makeCommandBuffer() else { return nil }

        let flow = cachedFlow(key: key, lumaA: lumaA, lumaB: lumaB, matchesRGB: matchesRGB,
                              scratch: scratch, command: command)

        var uniforms = RetimeUniforms(
            params: SIMD4<Float>(
                Float(phase),
                // How far apart the two estimates may be, in grid pixels,
                // before the match stops being believed. Measured rather than
                // chosen: real motion agrees to well under a pixel, and 1.5 is
                // where genuine occlusion starts to be excluded.
                1.5,
                // A patch cost above this means the search found nothing worth
                // having even if it was self-consistent.
                0.06,
                flow == nil ? 0 : 1),
            geometry: SIMD4<Float>(Float(flow?.width ?? 1), Float(flow?.height ?? 1), 0, 0))

        for (index, plane) in planes.enumerated() {
            let destination = destinations[min(index, destinations.count - 1)]
            guard let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(interpolate)
            encoder.setTexture(plane.first, index: 0)
            encoder.setTexture(plane.second, index: 1)
            encoder.setTexture(flow?.forward, index: 2)
            encoder.setTexture(flow?.backward, index: 3)
            encoder.setTexture(destination, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<RetimeUniforms>.stride, index: 0)
            dispatch(encoder, interpolate, width: destination.width, height: destination.height)
            encoder.endEncoding()
        }

        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(a) {}; withExtendedLifetime(b) {}
        withExtendedLifetime(retainedDestinations) {}
        guard command.status == .completed else { return nil }
        return output
    }

    /// The motion for this pair, estimated once.
    private func writablePacked(_ buffer: CVPixelBuffer,
                                pixelFormat: MTLPixelFormat) -> (reference: CVMetalTexture, texture: MTLTexture)? {
        var reference: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue] as CFDictionary
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, context.textureCache, buffer, attributes, pixelFormat,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &reference)
        guard status == kCVReturnSuccess, let reference,
              let texture = CVMetalTextureGetTexture(reference) else { return nil }
        return (reference, texture)
    }

    private func cachedFlow(key: PairKey, lumaA: MTLTexture, lumaB: MTLTexture,
                            matchesRGB: Bool,
                            scratch: Scratch, command: MTLCommandBuffer) -> Flow? {
        if let existing = flowCache[key] { return existing }
        let size = scratch.flowSize
        guard let forward = float(size.width, size.height, channels: 4),
              let backward = float(size.width, size.height, channels: 4) else { return nil }

        // Both frames into a single consistent float representation first, so
        // the match-cost limit means the same thing at 8 and 10 bits.
        // Rec.709 luma weights, and `w` telling the kernel whether it has RGB
        // to reduce or a luma plane that already is one.
        var weights = SIMD4<Float>(0.2126, 0.7152, 0.0722, matchesRGB ? 1 : 0)
        for (source, destination) in [(lumaA, scratch.lumaA), (lumaB, scratch.lumaB)] {
            guard let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(prepareLuma)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setBytes(&weights, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch(encoder, prepareLuma, width: destination.width, height: destination.height)
            encoder.endEncoding()
        }
        buildPyramid(from: scratch.lumaA, into: scratch.pyramidA, command: command)
        buildPyramid(from: scratch.lumaB, into: scratch.pyramidB, command: command)
        // Both directions. The backward field is not an optional refinement —
        // it is the only way to find out where the forward one is lying.
        estimate(from: scratch.pyramidA, to: scratch.pyramidB, scratch: scratch,
                 into: forward, command: command)
        estimate(from: scratch.pyramidB, to: scratch.pyramidA, scratch: scratch,
                 into: backward, command: command)

        let flow = Flow(forward: forward, backward: backward,
                        width: size.width, height: size.height)
        flowCache[key] = flow
        flowOrder.append(key)
        while flowOrder.count > Self.flowCacheLimit {
            flowCache.removeValue(forKey: flowOrder.removeFirst())
        }
        return flow
    }
}

/// Matches `RetimeUniforms` in RetimeShaders.metal.
///
/// Packed into `float4`s, as every other uniform block in this app is: it is
/// what Metal's constant buffers align to, and a scalar field would silently
/// pad. Keep the two declarations in step — a mismatch compiles cleanly on both
/// sides and aborts at the first dispatch.
struct RetimeUniforms {
    var params: SIMD4<Float>
    var geometry: SIMD4<Float>
}
