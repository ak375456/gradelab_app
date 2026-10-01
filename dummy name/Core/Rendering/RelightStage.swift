@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
@preconcurrency import Metal
import os
import simd

// ---------------------------------------------------------------------------
// The Relight render stage
//
// One stage serves every path that draws a picture — the preview, the
// exporter and the layer compositor — for the reason noise reduction and the
// finishing effects are shared: a light that rendered one way on screen and
// another in the file would be a preview of a picture nobody gets. The paths
// differ only in how many pixels they spend on geometry; the arithmetic is the
// same, so the light behaves identically at every quality.
//
// It runs where noise reduction runs — after the input transform, before the
// look and the grade — and hands back a frame in the same representation, so
// the existing grade-from-texture kernels pick it up unchanged.
//
// It never runs the depth analysis. Depth arrives from `RelightDepthStore`,
// already estimated, fused and cached; a frame with no depth yet is drawn
// without relight rather than waiting for one, and repainted when it lands.
// ---------------------------------------------------------------------------

/// How the stage converts a decoded frame into the grade's representation.
enum RelightPrepareMode: Sendable {
    /// Rec.709-encoded SDR, kept encoded: the direct and composited SDR paths.
    case encodedSDR
    /// An HLG signal (the HDR decoder's half-float surface), into working space.
    case hlgSignal
    /// Encoded SDR into working space: an SDR clip in an HDR or Log project.
    case sdrToWorking
    /// Apple Log camera values, through the Log input transform.
    case appleLog

    var code: Float {
        switch self {
        case .encodedSDR: 0
        case .hlgSignal: 1
        case .sdrToWorking: 2
        case .appleLog: 3
        }
    }
}

/// What the stage starts from.
enum RelightStageInput {
    /// A decoded frame. `partner` and `blend` carry a clip retimed with frame
    /// blending: the two frames are mixed before the light is applied, so the
    /// light lands once on the picture the clip actually shows.
    case pixelBuffer(CVPixelBuffer, partner: CVPixelBuffer?, blend: Float, mode: RelightPrepareMode)
    /// A packed RGB frame the compositor already holds as a texture — the HDR
    /// path's half-float sources, or a frame interpolated by optical flow.
    case texture(MTLTexture, partner: MTLTexture?, blend: Float, mode: RelightPrepareMode)
    /// A frame already in the grade's representation — noise reduction's output.
    case working(MTLTexture)
}

/// Whether a light is being dragged right now, for the one path that cannot be
/// told directly: AVFoundation rebuilds the layer compositor on every
/// composition refresh, so it has no line back to the editor. Read per frame,
/// written by the editor at the start and end of a gesture.
enum RelightInteraction {
    private static let state = OSAllocatedUnfairLock(initialState: false)

    static var isActive: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Everything one relit frame needs, resolved once by whichever path is drawing.
struct RelightFrame {
    /// Evaluated at this moment: keyframes already applied.
    let settings: RelightSettings
    let source: RelightSourceInfo
    let depth: RelightDepthSample
    /// The clip's masked grades, evaluated at this moment, for Affect.
    let masks: [MaskedGradeLayer]
    let maskAspect: Double
    /// True for the linear BT.2020 working space (HLG, Apple Log); false for
    /// Rec.709-encoded SDR.
    let extendedRange: Bool
    /// What added light is rolled toward: SDR white, the HLG peak, or a few
    /// stops of Log latitude.
    let ceiling: Float
    let geometryLongEdge: Int
    let isLog2: Bool
}

/// How much this device spends on Relight. Derived from the machine rather
/// than from a device list, for the reason `NoiseReductionCapability` is.
enum RelightCapability {
    enum Tier: Sendable { case standard, high }

    static var tier: Tier {
        #if targetEnvironment(macCatalyst)
        let isMac = true
        #else
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        #endif
        // A Mac, or an iPad or phone with the memory of an M-series iPad.
        return isMac || ProcessInfo.processInfo.physicalMemory >= 7_500_000_000 ? .high : .standard
    }

    /// The long edge geometry is reconstructed at for the preview.
    static func previewGeometryLongEdge(quality: RelightQuality, interactive: Bool) -> Int {
        if interactive { return tier == .high ? 640 : 480 }
        switch (quality, tier) {
        case (.fast, .standard): return 720
        case (.fast, .high): return 960
        case (.high, .standard): return 1024
        case (.high, .high): return 1440
        }
    }

    /// Export spends what the frame needs: geometry beyond about 2K adds
    /// nothing a light can show, because the depth beneath it is far coarser.
    static let exportGeometryLongEdge = 2048

    /// The analysis grid's long edge.
    static func analysisLongEdge(quality: RelightQuality) -> Int {
        switch (quality, tier) {
        case (.fast, .standard): return 224
        case (.fast, .high): return 256
        case (.high, .standard): return 320
        case (.high, .high): return 384
        }
    }

    /// Frames between depth estimates; motion carries depth across the rest.
    static func keyframeInterval(quality: RelightQuality) -> Int {
        switch (quality, tier) {
        case (.fast, .standard): return 10
        case (.fast, .high): return 8
        case (.high, .standard): return 5
        case (.high, .high): return 4
        }
    }

    /// What added light rolls toward in each representation.
    static func ceiling(for colorMode: ProjectColorMode) -> Float {
        if colorMode.isHDR { return Float(HDRColorSpace.peakInWorkingSpace) }
        if colorMode.isAppleLog { return 8 }
        return 1
    }
}

/// Builds a `RelightFrame` for one clip at one moment, the same way for every
/// path, so the preview, the compositor and the exporter cannot disagree about
/// which depth, which lights or which mask a frame gets.
enum RelightFrameResolver {
    static func resolve(
        clip: VideoClip,
        at composition: TimelineTime,
        sources: [UUID: RelightSourceInfo],
        preferredQuality: RelightQuality,
        colorMode: ProjectColorMode,
        extendedRange: Bool,
        masks: [MaskedGradeLayer],
        maskAspect: Double,
        geometryLongEdge: Int,
        prefetches: Bool
    ) -> RelightFrame? {
        guard let settings = clip.evaluatedRelight(at: composition),
              let source = sources[clip.assetID],
              let sourceTime = try? clip.sourceTime(at: composition) else { return nil }
        // Depth follows the SOURCE frame, through the clip's time map — so a
        // ramp, a freeze and a reversed clip all read the depth of the picture
        // they are actually showing.
        let position = source.framePosition(sourceTime: sourceTime)
        guard let depth = RelightDepthStore.shared.sample(
            identifier: source.cacheIdentifier, preferring: preferredQuality, position: position) else { return nil }
        if prefetches {
            RelightDepthStore.shared.prefetch(identifier: source.cacheIdentifier,
                                              quality: depth.quality, after: position)
        }
        return RelightFrame(
            settings: settings, source: source, depth: depth, masks: masks, maskAspect: maskAspect,
            extendedRange: extendedRange, ceiling: RelightCapability.ceiling(for: colorMode),
            geometryLongEdge: geometryLongEdge, isLog2: colorMode == .appleLog2)
    }
}

final class RelightStage: @unchecked Sendable {
    /// How deep the scene is, in frame heights, for nearness 0…1. A relative
    /// figure: it sets how far a point light at "Near" sits in front of the
    /// nearest surface and how steep the estimated forms read.
    static let depthRange: Float = 0.6

    private let context: MetalContext
    private let prepareYUV: MTLComputePipelineState
    private let prepareRGB: MTLComputePipelineState
    private let guide: MTLComputePipelineState
    private let upsample: MTLComputePipelineState
    private let normals: MTLComputePipelineState
    private let smooth: MTLComputePipelineState
    private let apply: MTLComputePipelineState
    private var prepareAppleLog: [Bool: MTLComputePipelineState] = [:]
    private let lock = NSLock()
    private var surfaces: Surfaces?
    /// Uploaded depth frames, keyed by source, quality and frame. Each is
    /// written once, before any GPU work reads it, and only ever read after —
    /// so a frame still in flight can never see one change under it.
    private var depthTextures: [String: MTLTexture] = [:]
    private var depthOrder: [String] = []
    private let depthCapacity = 10

    init?(context: MetalContext) {
        self.context = context
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = context.library.makeFunction(name: name) else { return nil }
            return try? context.device.makeComputePipelineState(function: function)
        }
        guard let prepareYUV = pipeline("relightPrepareYUV"),
              let prepareRGB = pipeline("relightPrepareRGB"),
              let guide = pipeline("relightGuide"),
              let upsample = pipeline("relightUpsample"),
              let normals = pipeline("relightNormals"),
              let smooth = pipeline("relightSmoothNormals"),
              let apply = pipeline("relightApply") else { return nil }
        self.prepareYUV = prepareYUV
        self.prepareRGB = prepareRGB
        self.guide = guide
        self.upsample = upsample
        self.normals = normals
        self.smooth = smooth
        self.apply = apply
    }

    func releaseResources() {
        lock.lock()
        surfaces = nil
        depthTextures.removeAll()
        depthOrder.removeAll()
        lock.unlock()
    }

    /// Encodes the stage into `command` and returns the relit frame, or nil
    /// when it could not — in which case the caller draws the frame the way it
    /// would have without Relight.
    ///
    /// Nothing is committed or waited on: the caller owns the command buffer,
    /// so relight, grade and present can share one submission.
    func encode(
        _ input: RelightStageInput,
        frame: RelightFrame,
        fallbackMatrix: String?,
        into command: MTLCommandBuffer
    ) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        let full: (width: Int, height: Int)
        switch input {
        case .pixelBuffer(let buffer, _, _, _):
            full = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        case .texture(let texture, _, _, _), .working(let texture):
            full = (texture.width, texture.height)
        }
        guard full.width > 1, full.height > 1 else { return nil }
        let geometrySize = Self.fitted(full, longEdge: frame.geometryLongEdge)
        let lowSize = (width: frame.depth.first.plane.width, height: frame.depth.first.plane.height)
        let needsWorking: Bool
        if case .working = input { needsWorking = false } else { needsWorking = true }
        guard let s = resolvedSurfaces(full: full, geometry: geometrySize, low: lowSize,
                                       needsWorking: needsWorking),
              let depthA = depthTexture(frame.depth.first) else { return nil }
        let depthB = frame.depth.second.flatMap { depthTexture($0) } ?? depthA
        let phase: Float = frame.depth.second == nil ? 0 : frame.depth.phase

        // 1. Into the grade's representation.
        let working: MTLTexture
        switch input {
        case .working(let texture):
            working = texture
        case .pixelBuffer(let buffer, let partner, let blend, let mode):
            guard let destination = s.working,
                  encodePrepare(buffer, partner: partner, blend: blend, mode: mode, isLog2: frame.isLog2,
                                fallbackMatrix: fallbackMatrix, destination: destination,
                                into: command) else { return nil }
            working = destination
        case .texture(let texture, let partner, let blend, let mode):
            guard let destination = s.working,
                  encodePrepare(texture, partner: partner, blend: blend, mode: mode,
                                destination: destination, into: command) else { return nil }
            working = destination
        }

        // 2. Luminance guides at both scales, from the frame being drawn.
        var guideParameters = SIMD4<Float>(frame.extendedRange ? 1 : 0, 0, 0, 0)
        for target in [s.guideLow, s.guideHigh] {
            guard let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(guide)
            encoder.setTexture(working, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&guideParameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            Self.dispatch(encoder, guide, target.width, target.height)
            encoder.endEncoding()
        }

        // 3. Depth up to geometry resolution, edge-aware, between the two
        //    stored frames this moment falls between.
        let orientation = frame.source.orientation
        let relief = frame.depth.relief * Float(frame.settings.resolvedForm)
        let geometryUniforms: [SIMD4<Float>] = [
            SIMD4(orientation.row0.x, orientation.row0.y, orientation.row0.z, 0),
            SIMD4(orientation.row1.x, orientation.row1.y, orientation.row1.z, 0),
            SIMD4(Float(frame.source.displayAspect), relief, Self.depthRange, 0),
            SIMD4(phase, 0.08, 0, 0)
        ]
        guard let upsampleEncoder = command.makeComputeCommandEncoder() else { return nil }
        upsampleEncoder.setComputePipelineState(upsample)
        upsampleEncoder.setTexture(depthA, index: 0)
        upsampleEncoder.setTexture(depthB, index: 1)
        upsampleEncoder.setTexture(s.guideLow, index: 2)
        upsampleEncoder.setTexture(s.guideHigh, index: 3)
        upsampleEncoder.setTexture(s.geometry, index: 4)
        geometryUniforms.withUnsafeBytes {
            upsampleEncoder.setBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        Self.dispatch(upsampleEncoder, upsample, s.geometry.width, s.geometry.height)
        upsampleEncoder.endEncoding()

        // 4. Orientation, and its two smoothed sets.
        guard let normalEncoder = command.makeComputeCommandEncoder() else { return nil }
        normalEncoder.setComputePipelineState(normals)
        normalEncoder.setTexture(s.geometry, index: 0)
        normalEncoder.setTexture(s.rawNormals, index: 1)
        geometryUniforms.withUnsafeBytes {
            normalEncoder.setBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        Self.dispatch(normalEncoder, normals, s.geometry.width, s.geometry.height)
        normalEncoder.endEncoding()

        guard let smoothEncoder = command.makeComputeCommandEncoder() else { return nil }
        smoothEncoder.setComputePipelineState(smooth)
        smoothEncoder.setTexture(s.rawNormals, index: 0)
        smoothEncoder.setTexture(s.geometry, index: 1)
        smoothEncoder.setTexture(s.sharpNormals, index: 2)
        smoothEncoder.setTexture(s.softNormals, index: 3)
        Self.dispatch(smoothEncoder, smooth, s.geometry.width, s.geometry.height)
        smoothEncoder.endEncoding()

        // 5. The light.
        let uniforms = Self.uniformWords(frame)
        let locals = LocalGradeStack(layers: frame.masks, aspect: frame.maskAspect)
        guard let applyEncoder = command.makeComputeCommandEncoder() else { return nil }
        applyEncoder.setComputePipelineState(apply)
        applyEncoder.setTexture(working, index: 0)
        applyEncoder.setTexture(s.geometry, index: 1)
        applyEncoder.setTexture(s.sharpNormals, index: 2)
        applyEncoder.setTexture(s.softNormals, index: 3)
        applyEncoder.setTexture(s.output, index: 4)
        uniforms.withUnsafeBytes {
            applyEncoder.setBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        locals.bind(applyEncoder)
        Self.dispatch(applyEncoder, apply, s.output.width, s.output.height)
        applyEncoder.endEncoding()
        return s.output
    }

    // MARK: - Preparation

    private func encodePrepare(
        _ buffer: CVPixelBuffer,
        partner: CVPixelBuffer?,
        blend: Float,
        mode: RelightPrepareMode,
        isLog2: Bool,
        fallbackMatrix: String?,
        destination: MTLTexture,
        into command: MTLCommandBuffer
    ) -> Bool {
        guard let textures = PixelBufferTextures(pixelBuffer: buffer, context: context) else { return false }
        let partnerTextures = partner.flatMap { PixelBufferTextures(pixelBuffer: $0, context: context) }
        var prepare = SIMD4<Float>(mode.code, partnerTextures == nil ? 0 : min(max(blend, 0), 1), 0, 0)
        var hdr = HDRDisplayUniforms()
        var yuv = YUVUniforms.make(for: buffer, fallbackMatrix: fallbackMatrix)
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        // The pipeline actually bound, so the dispatch below is sized for its
        // own thread limits: the Log variant carries more registers than the
        // others and can allow fewer threads per group.
        let pipeline: MTLComputePipelineState
        switch textures.storage {
        case .biPlanar(_, let luma, _, let chroma):
            if mode == .appleLog {
                guard let log = appleLogPipeline(isLog2: isLog2) else { encoder.endEncoding(); return false }
                pipeline = log
            } else {
                pipeline = prepareYUV
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            // Bound explicitly either way: the kernel tests for a null partner,
            // and an explicit nil is what that test is written against.
            if let partnerTextures, case .biPlanar(_, let partnerLuma, _, let partnerChroma) = partnerTextures.storage {
                encoder.setTexture(partnerLuma, index: 2)
                encoder.setTexture(partnerChroma, index: 3)
            } else {
                encoder.setTexture(nil, index: 2)
                encoder.setTexture(nil, index: 3)
            }
            encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        case .bgra(_, let texture), .linearHalf(_, let texture):
            pipeline = prepareRGB
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setTexture(nil, index: 1)
            if let partnerTextures {
                switch partnerTextures.storage {
                case .bgra(_, let other), .linearHalf(_, let other): encoder.setTexture(other, index: 1)
                case .biPlanar: break
                }
            }
        }
        encoder.setTexture(destination, index: 4)
        encoder.setBytes(&prepare, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        Self.dispatch(encoder, pipeline, destination.width, destination.height)
        encoder.endEncoding()
        // The textures are views onto the decoder's buffers, which have to
        // outlive the GPU work rather than this function.
        command.addCompletedHandler { _ in
            withExtendedLifetime(textures) {}
            withExtendedLifetime(partnerTextures) {}
        }
        return true
    }

    /// The packed-RGB preparation, for a frame that is already a texture.
    private func encodePrepare(
        _ texture: MTLTexture,
        partner: MTLTexture?,
        blend: Float,
        mode: RelightPrepareMode,
        destination: MTLTexture,
        into command: MTLCommandBuffer
    ) -> Bool {
        guard mode != .appleLog, let encoder = command.makeComputeCommandEncoder() else { return false }
        var prepare = SIMD4<Float>(mode.code, partner == nil ? 0 : min(max(blend, 0), 1), 0, 0)
        var hdr = HDRDisplayUniforms()
        encoder.setComputePipelineState(prepareRGB)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(partner, index: 1)
        encoder.setTexture(destination, index: 4)
        encoder.setBytes(&prepare, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        Self.dispatch(encoder, prepareRGB, destination.width, destination.height)
        encoder.endEncoding()
        return true
    }

    private func appleLogPipeline(isLog2: Bool) -> MTLComputePipelineState? {
        if let built = prepareAppleLog[isLog2] { return built }
        let built = AppleLogSpecialization.computePipeline(
            "relightPrepareAppleLog", isLog2: isLog2, library: context.library, device: context.device)
        prepareAppleLog[isLog2] = built
        return built
    }

    // MARK: - Uniforms

    /// The signed stops a light at `intensity` percent adds at full response.
    ///
    /// Perceptual rather than linear, so the bottom of the slider has the
    /// precision: 50% is about 0.4 of the light, 100% is the light, and 200%
    /// is a little over two and a half times it.
    static func intensityResponse(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        let magnitude = pow(min(abs(percent), 200) / 100, 1.35)
        return percent < 0 ? -magnitude : magnitude
    }

    /// The `RelightUniforms` block as flat float4 words, laid out exactly as
    /// the shader declares it: five frame words, then six per light.
    static func uniformWords(_ frame: RelightFrame) -> [SIMD4<Float>] {
        let maximum = RelightSettings.maximumLights
        var words = [SIMD4<Float>](repeating: .zero, count: 5 + 6 * maximum)
        let settings = frame.settings
        let lights = settings.renderableLights
        let aspect = Float(frame.source.displayAspect)
        let orientation = frame.source.orientation
        words[0] = SIMD4(frame.extendedRange ? 1 : 0, Float(settings.resolvedStrength),
                         Float(settings.resolvedPreserveHighlights), Float(settings.resolvedProtectBlacks))
        words[1] = SIMD4(aspect, depthRange, Float(lights.count), frame.ceiling)
        words[2] = SIMD4(orientation.row0.x, orientation.row0.y, orientation.row0.z, 0)
        words[3] = SIMD4(orientation.row1.x, orientation.row1.y, orientation.row1.z, 0)
        words[4] = maskWord(settings: settings, masks: frame.masks)
        for (index, light) in lights.enumerated() {
            let block = lightWords(light, aspect: aspect, extendedRange: frame.extendedRange)
            for (offset, word) in block.enumerated() { words[5 + index * 6 + offset] = word }
        }
        return words
    }

    /// Which mask, if any, limits the relight. A mask that is on the clip but
    /// switched off limits it to nothing; one that is not on the clip at all
    /// (the grade was pasted from elsewhere) is the whole frame.
    static func maskWord(settings: RelightSettings, masks: [MaskedGradeLayer]) -> SIMD4<Float> {
        guard let id = settings.maskID, masks.contains(where: { $0.id == id }) else { return .zero }
        let live = LocalGradeStack.admitted(masks)
        if let index = live.firstIndex(where: { $0.id == id }) {
            return SIMD4(Float(index + 1), 0, 0, 0)
        }
        return SIMD4(0, 1, 0, 0)
    }

    /// One light in relight space — x right and y down across the upright
    /// picture in frame heights, z toward the viewer — as six words.
    static func lightWords(_ light: RelightLight, aspect: Float, extendedRange: Bool) -> [SIMD4<Float>] {
        let type = light.type.shaderCode
        let depth = depthRange
        // Distance 0 is in front of the nearest surface, 1 behind the farthest.
        let z = Float(1.35 + (-0.35 - 1.35) * light.distance) * depth
        let position = SIMD3<Float>(Float(light.positionX - 0.5) * aspect, Float(light.positionY - 0.5), z)

        var direction = SIMD3<Float>(0, 0, 1)
        switch light.type {
        case .directional:
            let azimuth = Float(light.azimuth * .pi / 180), elevation = Float(light.elevation * .pi / 180)
            direction = simd_normalize(SIMD3(cos(elevation) * cos(azimuth),
                                             -cos(elevation) * sin(azimuth),
                                             sin(elevation)))
        case .spot:
            let target = SIMD3<Float>(Float(light.targetX - 0.5) * aspect, Float(light.targetY - 0.5), 0.5 * depth)
            let axis = target - position
            direction = simd_length(axis) > 1e-4 ? simd_normalize(axis) : SIMD3(0, 0, -1)
        case .point:
            break
        }

        let linear = RelightColorScience.lightColor(light)
        let color = extendedRange ? RelightColorScience.rec709ToBT2020(linear) : linear
        let stops = Float(light.exposure * intensityResponse(light.intensity))

        let outer = Float(light.coneAngle * .pi / 180)
        let inner = outer * Float(1 - min(max(light.feather, 0), 1) * 0.95)
        let cosOuter = cos(outer)
        let cosInner = max(cos(inner), cosOuter + 1e-3)
        let softness = Float(min(max(light.softness, 0), 1))

        return [
            SIMD4(position.x, position.y, position.z, type),
            SIMD4(direction.x, direction.y, direction.z, 0),
            SIMD4(Float(color.x), Float(color.y), Float(color.z), stops),
            SIMD4(softness, Float(0.6 + 1.6 * min(max(light.falloff, 0), 1)),
                  Float(light.radius) * (1 + 0.5 * softness), cosOuter),
            SIMD4(cosInner, Float(min(max(light.shadowResponse, 0), 1)),
                  Float(light.specular), Float(light.roughness)),
            SIMD4(Float(light.lightWrap), 0, 0, 0)
        ]
    }

    // MARK: - Surfaces

    private final class Surfaces {
        let key: String
        let working: MTLTexture?
        let output: MTLTexture
        let guideLow: MTLTexture
        let guideHigh: MTLTexture
        let geometry: MTLTexture
        let rawNormals: MTLTexture
        let sharpNormals: MTLTexture
        let softNormals: MTLTexture

        init?(device: MTLDevice, key: String, full: (width: Int, height: Int),
              geometry size: (width: Int, height: Int), low: (width: Int, height: Int), needsWorking: Bool) {
            func make(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                return device.makeTexture(descriptor: descriptor)
            }
            guard let output = make(.rgba16Float, full.width, full.height),
                  let guideLow = make(.r16Float, low.width, low.height),
                  let guideHigh = make(.r16Float, size.width, size.height),
                  let geometry = make(.rg16Float, size.width, size.height),
                  let rawNormals = make(.rgba16Float, size.width, size.height),
                  let sharpNormals = make(.rgba16Float, size.width, size.height),
                  let softNormals = make(.rgba16Float, size.width, size.height) else { return nil }
            let working = needsWorking ? make(.rgba16Float, full.width, full.height) : nil
            if needsWorking, working == nil { return nil }
            self.key = key
            self.working = working
            self.output = output
            self.guideLow = guideLow
            self.guideHigh = guideHigh
            self.geometry = geometry
            self.rawNormals = rawNormals
            self.sharpNormals = sharpNormals
            self.softNormals = softNormals
        }
    }

    /// Must be called with the lock held.
    private func resolvedSurfaces(full: (width: Int, height: Int), geometry: (width: Int, height: Int),
                                  low: (width: Int, height: Int), needsWorking: Bool) -> Surfaces? {
        let key = "\(full.width)x\(full.height)|\(geometry.width)x\(geometry.height)|\(low.width)x\(low.height)|\(needsWorking)"
        if let existing = surfaces, existing.key == key { return existing }
        // Dropped first, so a size change never briefly holds two sets.
        surfaces = nil
        surfaces = Surfaces(device: context.device, key: key, full: full, geometry: geometry,
                            low: low, needsWorking: needsWorking)
        return surfaces
    }

    /// Must be called with the lock held.
    private func depthTexture(_ frame: RelightDepthSample.Frame) -> MTLTexture? {
        if let cached = depthTextures[frame.cacheKey] {
            depthOrder.removeAll { $0 == frame.cacheKey }
            depthOrder.append(frame.cacheKey)
            return cached
        }
        let plane = frame.plane
        guard plane.isValid else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Unorm, width: plane.width, height: plane.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        var words = [UInt16](repeating: 0, count: plane.width * plane.height * 2)
        for index in 0..<(plane.width * plane.height) {
            words[index * 2] = plane.depth[index]
            words[index * 2 + 1] = UInt16(plane.confidence[index]) * 257
        }
        words.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, plane.width, plane.height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: plane.width * 4)
        }
        depthTextures[frame.cacheKey] = texture
        depthOrder.append(frame.cacheKey)
        while depthOrder.count > depthCapacity {
            depthTextures.removeValue(forKey: depthOrder.removeFirst())
        }
        return texture
    }

    static func fitted(_ size: (width: Int, height: Int), longEdge: Int) -> (width: Int, height: Int) {
        let long = max(size.width, size.height)
        guard long > longEdge, longEdge > 0 else { return size }
        let scale = Double(longEdge) / Double(long)
        return (max(1, Int((Double(size.width) * scale).rounded())),
                max(1, Int((Double(size.height) * scale).rounded())))
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

/// The stage the layer compositor uses, one per Metal context for the whole
/// process.
///
/// AVFoundation builds a new compositor object on every composition refresh,
/// so a stage per compositor would rebuild its pipelines on every slider tick.
/// One shared stage is reached through `gate`, which a caller holds from the
/// first relight encode until its command buffer has completed, so two
/// compositors rendering at once can never share surfaces mid-frame.
final class RelightSharedStage: @unchecked Sendable {
    let stage: RelightStage
    let gate = NSLock()
    private let context: MetalContext
    private let pipelineLock = NSLock()
    private var gradeFromTexture: MTLComputePipelineState?

    private init(stage: RelightStage, context: MetalContext) {
        self.stage = stage
        self.context = context
    }

    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: RelightSharedStage] = [:]

    static func shared(for context: MetalContext) -> RelightSharedStage? {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = ObjectIdentifier(context)
        if let existing = registry[key] { return existing }
        guard let stage = RelightStage(context: context) else { return nil }
        let shared = RelightSharedStage(stage: stage, context: context)
        registry[key] = shared
        return shared
    }

    /// The SDR grade from a texture, which the compositor otherwise never
    /// needs. Compiled the first time a relit SDR layer is composited, rather
    /// than with the compositor's own pipelines, so a project without Relight
    /// adds nothing to the longest wait in the app.
    var sdrGradePipeline: MTLComputePipelineState? {
        pipelineLock.lock(); defer { pipelineLock.unlock() }
        if let gradeFromTexture { return gradeFromTexture }
        guard let function = context.library.makeFunction(name: "gradeToTextureBGRA"),
              let state = try? context.device.makeComputePipelineState(function: function) else { return nil }
        gradeFromTexture = state
        return state
    }
}
