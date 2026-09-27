@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import Metal
import Foundation
import os

/// Preview owns mutable grade state; export builds its own immutable snapshot.
final class LayerRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var project: VideoProject
    private var bypass = false
    /// The layer whose matte the editor is inspecting, or nil for the ordinary
    /// picture. Editor-only: export builds its own state and never sets it, so
    /// a debug view cannot reach a written file.
    ///
    /// The TARGET, not the source: the same source cuts one layer and its
    /// inverse cuts another, so only the target says which of the two the view
    /// should be showing.
    private var matteInspectionTargetID: UUID?
    private var backgroundInspectionTargetID: UUID?
    private var transparencyGrid = false
    let context: MetalContext?
    init(_ project: VideoProject, context: MetalContext? = nil) { self.project = project; self.context = context }
    func update(_ project: VideoProject, bypass: Bool, inspectingMatteOn target: UUID? = nil,
                inspectingBackgroundOn background: UUID? = nil,
                showsTransparencyGrid grid: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.project = project; self.bypass = bypass; self.matteInspectionTargetID = target
        self.backgroundInspectionTargetID = background
        self.transparencyGrid = grid
    }
    func snapshot() -> (VideoProject, Bool) {
        lock.lock(); defer { lock.unlock() }; return (project, bypass)
    }
    var inspectedMatteTargetID: UUID? {
        lock.lock(); defer { lock.unlock() }; return matteInspectionTargetID
    }
    var inspectedBackgroundTargetID: UUID? {
        lock.lock(); defer { lock.unlock() }; return backgroundInspectionTargetID
    }
    var showsTransparencyGrid: Bool {
        lock.lock(); defer { lock.unlock() }; return transparencyGrid
    }
}

final class LayerInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let trackIDs: [UUID: CMPersistentTrackID]
    /// The same source shifted one frame later, for clips that cross-dissolve
    /// between source frames instead of stepping.
    let blendTrackIDs: [UUID: CMPersistentTrackID]
    let state: LayerRenderState
    init(range: CMTimeRange, tracks: [UUID: CMPersistentTrackID],
         blendTracks: [UUID: CMPersistentTrackID] = [:], state: LayerRenderState) {
        timeRange = range; trackIDs = tracks; blendTrackIDs = blendTracks; self.state = state
        requiredSourceTrackIDs = (Array(tracks.values) + Array(blendTracks.values)).map { NSNumber(value: $0) }
    }
}

/// Grades with the existing Metal kernel, then transforms/blends on the GPU.
/// A serial request queue bounds working surfaces to one composition frame.
class LayerCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }
    private let queue = DispatchQueue(label: "GradeLab.layers", qos: .userInitiated)
    /// Sheds every cache the moment the system says memory is tight.
    ///
    /// The app had no answer to memory pressure at all: the system warned, the
    /// app held on to everything, and jetsam killed it — which is the crash
    /// this whole path was reported for. A dropped cache costs a re-decode or a
    /// re-render, and a slower frame is always better than being terminated.
    private lazy var memoryPressure: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.stillFrames.removeAll()
            self.stillOrder.removeAll()
            self.pools.removeAll()
            self.opaqueFrames.removeAll()
            self.interpolator?.purge()
            self.supplies.removeAll()
            TextRenderer.purge()
            ShapeRenderer.purge()
        }
        source.resume()
        return source
    }()
    private let cancellationLock = NSLock()
    private var generation: UInt = 0
    private func currentGeneration() -> UInt {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; return generation
    }
    private var metal: MetalContext?
    private var pipeline: MTLComputePipelineState?
    private var stillPipeline: MTLComputePipelineState?
    private var blendPipeline: MTLComputePipelineState?
    private var maskPipeline: MTLComputePipelineState?
    /// One cached pipeline serves every transition type. It is built with the
    /// compositor, never during frame playback.
    private var transitionPipeline: MTLComputePipelineState?
    /// A decoded still, and how big it was decoded, so a later request that
    /// needs more pixels can tell that this one will not do.
    private struct CachedStill {
        let buffer: CVPixelBuffer
        let longEdge: Int
        var bytes: Int { CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer) }
    }
    private var stillFrames: [URL: CachedStill] = [:]
    /// Least-recently-used first.
    private var stillOrder: [URL] = []
    /// The ceiling a still is ever decoded at, whatever the canvas asks for.
    static let maximumStillLongEdge = 4096
    /// What the decoded stills are collectively allowed to occupy.
    ///
    /// A count was the wrong unit. Four entries is 195 MB of 12-megapixel
    /// photographs and 2 MB of icons, and a timeline with nine image overlays
    /// blew through a four-entry cache on every single frame — each miss
    /// re-decoding a 12-megapixel file and allocating another 48 MB surface.
    static let stillCacheBudget = 128 * 1024 * 1024
    /// Fully opaque source-sized surfaces, one per distinct size. A video's
    /// coverage is "everything inside its transformed rectangle", so a white
    /// frame run through the layer mask kernel produces its matte alpha without
    /// decoding or grading a single frame of the source.
    private var opaqueFrames: [String: CVPixelBuffer] = [:]
    /// A 1x1 opaque texture, bound wherever a layer has no track matte. Metal
    /// kernels cannot have an unbound texture argument, and a constant white
    /// sample costs nothing and needs no uniform flag.
    private var neutralMatteTexture: MTLTexture?
    /// The opposite constant: coverage zero, for a transition side whose matte
    /// source is not present at this moment.
    private var emptyMatteTexture: MTLTexture?
    private var ci: CIContext?
    private var pools: [String: CVPixelBufferPool] = [:]
    /// Built on first use and thrown away under memory pressure, like every
    /// other cache here. A project that never asks for optical flow never
    /// builds its pipelines.
    private var interpolator: RetimeInterpolator?
    /// One per reversed clip source. Built on demand and thrown away with every
    /// other cache; a project with no reversed clip never makes one.
    private var supplies: [RetimeFrameSupply.Key: RetimeFrameSupply] = [:]
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    /// Built only when the device has them; an HDR project without them refuses
    /// with a reason rather than rendering something wrong.
    private var hdrVideoPipeline: MTLComputePipelineState?
    private var hdrImagePipeline: MTLComputePipelineState?
    private var hdrResolvePipeline: MTLComputePipelineState?
    private var hdrTransitionPipeline: MTLComputePipelineState?
    private var editorCheckerboardPipeline: MTLComputePipelineState?
    /// Two working-space canvases, ping-ponged as layers are composited.
    private var hdrCanvasPair: (MTLTexture, MTLTexture)?
    /// Spatial finishing effects, the same object preview and export use.
    private var effects: FilmEffectsStage?
    private var appleLogRenderer: AppleLogLayerRenderer?
    private var backgroundRemovalGPU: BackgroundRemovalGPU?
    private var resources: CompositorResources.Bundle?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.async {
            _ = self.memoryPressure
            self.pools.removeAll(); self.hdrCanvasPair = nil; self.appleLogRenderer = nil
            self.interpolator = nil; self.supplies.removeAll()
        }
    }
    func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.lock(); generation &+= 1; cancellationLock.unlock()
    }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let token = currentGeneration()
        queue.async {
            autoreleasepool {
                guard token == self.currentGeneration() else { request.finishCancelledRequest(); return }
                do { try self.render(request) }
                catch { request.finish(with: error) }
            }
        }
    }
    /// Logged once per process, not per instance: AVFoundation builds a new
    /// compositor on every `videoComposition` assignment, so an instance-scoped
    /// flag would log on every refresh and become a cost of its own.
    private static let firstFrameLogged = OSAllocatedUnfairLock(initialState: false)

    private func prepare(context supplied: MetalContext?) throws {
        guard metal == nil else { return }
        // Everything below is device-only state, so it is built once per process
        // and shared. AVFoundation makes a new compositor every time the preview
        // reassigns `videoComposition` — which is once per transform tick — and
        // rebuilding a shader library, twelve pipelines and a CIContext at that
        // rate is what froze the picture while a slider moved.
        let bundle = try CompositorResources.shared(supplied: supplied, colorSpace: colorSpace)
        pipeline = bundle.pipeline("gradeExportBGRA")
        stillPipeline = bundle.pipeline("gradeStillBGRA")
        blendPipeline = bundle.pipeline("gradeBlendedBGRA")
        maskPipeline = bundle.pipeline("applyLayerMaskBGRA")
        transitionPipeline = bundle.pipeline("transitionBGRA")
        hdrVideoPipeline = bundle.pipeline("compositeVideoHDR")
        hdrImagePipeline = bundle.pipeline("compositeImageHDR")
        hdrResolvePipeline = bundle.pipeline("resolveHDRCanvas")
        hdrTransitionPipeline = bundle.pipeline("compositeTransitionHDR")
        editorCheckerboardPipeline = bundle.pipeline("fillEditorCheckerboard")
        ci = bundle.ci
        effects = bundle.effects
        resources = bundle
        metal = bundle.context
        backgroundRemovalGPU = try BackgroundRemovalGPU(context: bundle.context, resources: bundle)
    }
    /// Cross-dissolves two source frames and grades the result in one pass.
    ///
    /// Blending before grading is what keeps the grade applied once: grading
    /// both sides and mixing afterwards would put the tone curves through the
    /// image twice. At the extremes there is nothing to mix, and skipping the
    /// blend keeps exact source frames exact.
    private func gradedBlend(
        _ first: CVPixelBuffer,
        _ second: CVPixelBuffer,
        amount: Double,
        settings: GradeSettings,
        masks: [MaskedGradeLayer] = [],
        bypass: Bool
    ) throws -> CVPixelBuffer {
        if amount <= 0.001 { return try graded(first, settings: settings, masks: masks, bypass: bypass) }
        if amount >= 0.999 { return try graded(second, settings: settings, masks: masks, bypass: bypass) }
        guard let metal, let blendPipeline,
              let firstTextures = PixelBufferTextures(pixelBuffer: first, context: metal),
              let secondTextures = PixelBufferTextures(pixelBuffer: second, context: metal),
              case .biPlanar(_, let luma, _, let chroma) = firstTextures.storage,
              case .biPlanar(_, let partnerLuma, _, let partnerChroma) = secondTextures.storage else {
            // Anything but a pair of NV12 frames falls back to the plain grade
            // rather than blending something it cannot decode the same way.
            return try graded(first, settings: settings, masks: masks, bypass: bypass)
        }
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        let output = try pooledBGRA(width: width, height: height)
        guard let destination = metal.packedTexture(from: output, pixelFormat: .bgra8Unorm),
              let command = metal.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        let program = GradeProgram(settings: settings, masks: masks, bypass: bypass,
                                   aspect: CGSize(width: width, height: height).maskAspect)
        var grade = program.uniforms
        var yuv = YUVUniforms.make(for: first, fallbackMatrix: "BT.709")
        var mix = Float(amount)
        encoder.setComputePipelineState(blendPipeline)
        encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
        encoder.setTexture(destination.texture, index: 2)
        encoder.setTexture(metal.luts.texture(for: program.lookIdentifier), index: 3)
        encoder.setTexture(metal.curves.texture(for: program.curveRows), index: 6)
        encoder.setTexture(metal.warps.texture(for: program.warp), index: 12)
        encoder.setTexture(partnerLuma, index: 4); encoder.setTexture(partnerChroma, index: 5)
        encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        encoder.setBytes(&mix, length: MemoryLayout<Float>.stride, index: 2)
        program.locals.bind(encoder)
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(firstTextures) {}; withExtendedLifetime(secondTextures) {}
        withExtendedLifetime(destination) {}
        guard command.status == .completed else { throw GradeLabError.rendererInitializationFailed }
        return output
    }

    /// A pooled BGRA surface. Shared by frame blending, grading and the HDR
    /// path's SDR artwork so there is one place that decides pool attributes.
    private func pooledBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        let key = "\(width)x\(height)"
        if pools[key] == nil {
            if pools.count >= 8 { pools.removeAll() }
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
                throw GradeLabError.rendererInitializationFailed
            }
            pools[key] = pool
        }
        var buffer: CVPixelBuffer?
        guard let pool = pools[key],
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw GradeLabError.rendererInitializationFailed
        }
        return buffer
    }

    /// A pooled surface in an arbitrary format.
    ///
    /// `pooledBGRA` is the special case everything composited goes through.
    /// This exists for the interpolated frame, which has to come back in the
    /// SOURCE's own layout — 4:2:0 or 4:2:2, 8-bit or 10-bit, or the HDR path's
    /// half-float — so that nothing downstream can tell it was made rather than
    /// decoded.
    private func pooledBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        let key = "\(width)x\(height)x\(format)"
        if pools[key] == nil {
            if pools.count >= 8 { pools.removeAll() }
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
                throw GradeLabError.rendererInitializationFailed
            }
            pools[key] = pool
        }
        var buffer: CVPixelBuffer?
        guard let pool = pools[key],
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw GradeLabError.rendererInitializationFailed
        }
        return buffer
    }

    /// The frame between two source frames, when a clip asks for optical flow.
    ///
    /// Returns nil for every reason there might be not to do it — the clip is
    /// not asking, there is no partner frame, the pair sits exactly on a source
    /// frame, the layout is one the interpolator does not take, or the estimate
    /// failed. In all of those the caller carries on with the blend it would
    /// have done, which is a real picture rather than a missing one.
    ///
    /// Called with the SAME pair frame blending uses. Optical flow is not a
    /// different input, it is a better answer from the same one.
    private func flowFrame(clip: VideoClip, asset: ProjectMediaAsset,
                           source: CVPixelBuffer, partner: CVPixelBuffer,
                           phase: Double, sourceTime: TimelineTime) -> CVPixelBuffer? {
        guard clip.frameInterpolation == .opticalFlow, let metal,
              let frameDuration = asset.frameDuration, frameDuration > .zero else { return nil }
        if interpolator == nil { interpolator = RetimeInterpolator(context: metal) }
        guard let interpolator else { return nil }
        // The pair is identified by the two source frames themselves, snapped to
        // the media's own frame grid, so every output frame that falls between
        // the same two pictures asks the same question and is answered from the
        // cache.
        let elapsed = sourceTime.seconds - clip.sourceRange.start.seconds
        let index = (elapsed / frameDuration.seconds).rounded(.down)
        guard index.isFinite else { return nil }
        let first = CMTimeAdd(clip.sourceRange.start.cmTime,
                              CMTimeMultiplyByFloat64(frameDuration.cmTime, multiplier: index))
        let key = RetimeInterpolator.PairKey(
            assetID: asset.id, first: first,
            second: CMTimeAdd(first, frameDuration.cmTime),
            divisor: RetimeInterpolator.divisor(for: clip.resolvedRemap.opticalFlowQuality))
        return try? interpolator.interpolated(
            source, partner, phase: phase,
            quality: clip.resolvedRemap.opticalFlowQuality, key: key,
            allocate: { [weak self] width, height, format in
                guard let self else { throw GradeLabError.rendererInitializationFailed }
                return try self.pooledBuffer(width: width, height: height, format: format)
            })
    }

    /// The pictures a reversed clip should be showing.
    ///
    /// A reversed clip's frames cannot come from the composition: an edit list
    /// has no way to say "backwards", so what AVFoundation delivers is the shot
    /// playing forwards. The composition is still what schedules the clip and
    /// fixes its length — the time map's durations are unaffected by direction
    /// — but the picture is replaced here.
    ///
    /// Returns the pair in source order along with the phase between them, so a
    /// reversed clip can still be blended or interpolated exactly as a forward
    /// one is. Nil when the clip is not reversed, or when the supply could not
    /// produce the frame; the caller then keeps what it had, which is the last
    /// good picture rather than a jump to the wrong one.
    private func reversedFrames(clip: VideoClip, asset: ProjectMediaAsset,
                                delivered: CVPixelBuffer, sourceTime: TimelineTime)
        -> (frame: CVPixelBuffer, partner: CVPixelBuffer?, phase: Double)? {
        guard clip.isReversed, let frameDuration = asset.frameDuration, frameDuration > .zero else { return nil }
        let key = RetimeFrameSupply.Key(
            assetID: asset.id,
            start: clip.sourceRange.start.cmTime,
            duration: clip.sourceRange.duration.cmTime,
            format: CVPixelBufferGetPixelFormatType(delivered),
            width: CVPixelBufferGetWidth(delivered),
            height: CVPixelBufferGetHeight(delivered))
        let supply: RetimeFrameSupply
        if let existing = supplies[key] { supply = existing }
        else {
            // A handful at most — one per reversed clip on screen. Dropping the
            // lot when that is exceeded is right: the ones being read are
            // immediately rebuilt and the ones that are not were finished with.
            if supplies.count >= 4 { supplies.removeAll() }
            guard let made = RetimeFrameSupply(
                url: asset.url, range: clip.sourceRange.cmTimeRange,
                frameDuration: frameDuration.cmTime,
                pixelFormat: key.format, width: key.width, height: key.height) else { return nil }
            supplies[key] = made
            supply = made
        }
        // The partner is only fetched when something will use it. On a reversed
        // clip it sits one frame in the direction already travelled, so asking
        // for it while merely sampling drags the decode window back and forth
        // across its own edge once per frame.
        guard let pair = supply.pair(at: sourceTime.cmTime,
                                     needsPartner: clip.smoothsMotion) else { return nil }
        return (pair.first, pair.second, pair.phase)
    }

    /// The frame a retimed clip should show, and its partner, whichever
    /// direction it is playing.
    ///
    /// One answer for both cases, so no caller has to ask "is this reversed"
    /// before it asks "what is the picture". A forward clip takes the frame the
    /// composition delivered and the partner track that has always accompanied
    /// it; a reversed one takes both from its own supply. The phase is measured
    /// the same way either way, because it is a property of where the moment
    /// falls between two source frames and not of the direction of travel.
    private func retimedPair(clip: VideoClip, asset: ProjectMediaAsset,
                             delivered: CVPixelBuffer, sourceTime: TimelineTime,
                             request: AVAsynchronousVideoCompositionRequest,
                             instruction: LayerInstruction)
        -> (frame: CVPixelBuffer, partner: CVPixelBuffer?, phase: Double) {
        if let reversed = reversedFrames(clip: clip, asset: asset,
                                         delivered: delivered, sourceTime: sourceTime) {
            return reversed
        }
        guard clip.smoothsMotion,
              let partnerID = instruction.blendTrackIDs[clip.id],
              let partner = request.sourceFrame(byTrackID: partnerID),
              let frameDuration = asset.frameDuration else {
            return (delivered, nil, 0)
        }
        return (delivered, partner, ClipSpeed.framePhase(
            sourceTime: sourceTime, sourceStart: clip.sourceRange.start,
            frameDuration: frameDuration))
    }

    /// Cuts structural alpha only after the clip's grade and spatial effects
    /// are complete. The resulting premultiplied surface can then be placed and
    /// blended normally by Core Image.
    private func masked(_ source: CVPixelBuffer, with authored: LayerMask) throws -> CVPixelBuffer {
        let mask = authored.clamped
        guard mask.isEnabled else { return source }
        guard let metal, let maskPipeline else { throw GradeLabError.rendererInitializationFailed }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let output = try pooledBGRA(width: width, height: height)
        guard let sourceTexture = metal.packedTexture(from: source, pixelFormat: .bgra8Unorm),
              let destination = metal.packedTexture(from: output, pixelFormat: .bgra8Unorm),
              let command = metal.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        var uniforms = LayerMaskUniforms(mask)
        encoder.setComputePipelineState(maskPipeline)
        encoder.setTexture(sourceTexture.texture, index: 0)
        encoder.setTexture(destination.texture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<LayerMaskUniforms>.stride, index: 0)
        encoder.dispatchThreads(
            .init(width: width, height: height, depth: 1),
            threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(sourceTexture) {}; withExtendedLifetime(destination) {}
        guard command.status == .completed else { throw GradeLabError.rendererInitializationFailed }
        return output
    }

    /// Applies source-local cutout coverage after the source has been processed
    /// and before the existing structural mask. Vision reads `original`; alpha
    /// is multiplied into `processed`, so creative grading never changes which
    /// subject was found.
    private func backgroundRemoved(
        _ processed: CVPixelBuffer,
        original: CVPixelBuffer,
        clip: VideoClip,
        asset: ProjectMediaAsset,
        projectID: UUID,
        compositionTime: CMTime
    ) throws -> CVPixelBuffer {
        guard let settings = clip.resolvedBackgroundRemoval,
              let backgroundRemovalGPU else { return processed }
        guard let matte = try backgroundMatteTexture(original: original, clip: clip, asset: asset,
            projectID: projectID, compositionTime: compositionTime) else { return processed }
        let output = try pooledBGRA(width: CVPixelBufferGetWidth(processed),
                                    height: CVPixelBufferGetHeight(processed))
        try backgroundRemovalGPU.apply(processed: processed, matte: matte,
                                       settings: settings, output: output)
        return output
    }

    private func backgroundMatteTexture(
        original: CVPixelBuffer,
        clip: VideoClip,
        asset: ProjectMediaAsset,
        projectID: UUID,
        compositionTime: CMTime
    ) throws -> MTLTexture? {
        guard let settings = clip.resolvedBackgroundRemoval,
              let backgroundRemovalGPU else { return nil }
        let composition = try TimelineTime(compositionTime)
        let sourceTime = asset.stillImage != nil ? .zero : try clip.sourceTime(at: composition)
        let local = clip.localTime(for: composition)
        let plane: BackgroundMaskPlane?
        switch settings.mode {
        case .colorKey:
            plane = nil
        case .lasso:
            // Rasterized here rather than read from the cache: the outline is
            // authored data, and evaluating it against this frame is what lets
            // a tracked cutout follow the object without a generated matte per
            // frame sitting on disk.
            plane = settings.lasso.flatMap {
                BackgroundLassoMatte.plane(for: $0, atLocal: local,
                                           aspectWidth: CVPixelBufferGetWidth(original),
                                           aspectHeight: CVPixelBufferGetHeight(original))
            }
        case .automatic:
            let frame = BackgroundMaskFrameIndex.make(sourceTime: sourceTime,
                assetStart: asset.sourceRange.start, frameDuration: asset.frameDuration)
            plane = BackgroundRemovalMaskStore.shared.nearest(
                projectID: projectID, clipID: clip.id,
                analysisID: settings.analysisID, frame: frame)
        }
        return try backgroundRemovalGPU.makeMatte(
            source: original, settings: settings, automatic: plane,
            localTime: local, frameDuration: asset.frameDuration)
    }

    private func graded(_ source: CVPixelBuffer, settings: GradeSettings,
                        masks: [MaskedGradeLayer] = [], bypass: Bool,
                        seconds: Double = 0) throws -> CVPixelBuffer {
        guard let metal, let pipeline else { throw GradeLabError.rendererInitializationFailed }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let output = try pooledBGRA(width: width, height: height)
        guard let textures = PixelBufferTextures(pixelBuffer: source, context: metal),
              let destination = metal.packedTexture(from: output, pixelFormat: .bgra8Unorm),
              let command = metal.commandQueue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        // The mask is normalised to the SOURCE frame, which is what this pass
        // grades — the layer transform that places it on the canvas happens
        // afterwards, so the window travels with the picture it was drawn on.
        var program = GradeProgram(settings: settings, masks: masks, bypass: bypass,
                                   aspect: CGSize(width: width, height: height).maskAspect)
        program.setGrainSeed(seconds)
        var grade = program.uniforms
        var yuv = YUVUniforms.make(for: source, fallbackMatrix: "BT.709")
        switch textures.storage {
        case .biPlanar(_, let y, _, let uv):
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(y, index: 0); encoder.setTexture(uv, index: 1)
        case .bgra(_, let texture):
            guard let stillPipeline else { throw GradeLabError.rendererInitializationFailed }
            encoder.setComputePipelineState(stillPipeline); encoder.setTexture(texture, index: 0)
        case .linearHalf:
            // Unreachable: an HDR project takes `renderHDR`, which never calls
            // this. Kept as a backstop because this function writes 8-bit BGRA,
            // and an extended-range frame arriving here would have every
            // highlight above diffuse white silently crushed.
            encoder.endEncoding()
            throw GradeLabError.unsupportedExport(
                String(localized: "An HDR frame reached the SDR compositing path. This is a bug; the frame was refused rather than clipped.")
            )
        }
        encoder.setTexture(destination.texture, index: 2)
        encoder.setTexture(metal.luts.texture(for: program.lookIdentifier), index: 3)
        encoder.setTexture(metal.curves.texture(for: program.curveRows), index: 6)
        encoder.setTexture(metal.warps.texture(for: program.warp), index: 12)
        encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        program.locals.bind(encoder)
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        // Finishing effects run on the layer's own graded frame, before it is
        // composited, because they belong to that clip's grade.
        var finished = output
        if let effects, FilmEffectsStage.isActive(grade) {
            let effected = try pooledBGRA(width: width, height: height)
            if let effectedTexture = metal.packedTexture(from: effected, pixelFormat: .bgra8Unorm),
               effects.encode(source: destination.texture, destination: effectedTexture.texture,
                              grade: grade, workingSpace: false, into: command) {
                withExtendedLifetime(effectedTexture) {}
                finished = effected
            }
        }
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(textures) {}; withExtendedLifetime(destination) {}
        guard command.status == .completed else { throw GradeLabError.rendererInitializationFailed }
        return finished
    }
    // MARK: - Track matte

    /// One frame's rendered mattes, keyed by matte-source item id.
    ///
    /// A source is drawn once per frame however many targets read it, and a
    /// stored nil records "this source supplies no coverage here" so a second
    /// target does not retry it. The buffers stay alive as long as the frame
    /// does, which is also what keeps them checked out of the pool.
    ///
    /// A reference type so the per-frame helpers can share it without passing
    /// `inout` through a nested function that also captures it.
    final class MatteCache {
        var buffers: [UUID: CVPixelBuffer?] = [:]
    }

    /// One layer's track matte, resolved for this frame, as the Metal paths
    /// need it: the coverage texture plus which side of it keeps the layer.
    ///
    /// The flag rides alongside the texture rather than inside it, so two
    /// targets reading the SAME source — one alpha, one inverted — share the
    /// one rendered matte and differ by a single float in their uniforms.
    struct LayerMatte {
        let texture: MTLTexture
        let inverted: Bool
    }

    /// The matte source's coverage, in FINAL CANVAS coordinates.
    ///
    /// Canvas space is the whole point. The target and the source have their own
    /// resolutions, aspect ratios, rotations and positions, so there is no
    /// meaningful shared source-local coordinate to compare — the only place the
    /// two pictures agree is the frame they both land on.
    ///
    /// The source contributes ALPHA. Its colour never reaches the result, which
    /// is why nothing here grades it: black text and white text with the same
    /// coverage cut identically, and changing a matte layer's exposure or LUT
    /// leaves the matte untouched. Its transform, its opacity and its own
    /// structural layer mask DO change coverage, so those are all applied.
    ///
    /// Returns nil when the source contributes nothing at this moment — it is
    /// disabled, its track is hidden, or the playhead is outside it. For an
    /// alpha matte that is coverage zero, so the caller must drop the target
    /// entirely rather than draw it unmatted.
    private func matte(
        source id: UUID,
        project: VideoProject,
        at compositionTime: CMTime,
        canvas: CGSize,
        authoredCanvas: CGSize,
        cache: MatteCache,
        request: AVAsynchronousVideoCompositionRequest,
        instruction: LayerInstruction
    ) throws -> CVPixelBuffer? {
        if let cached = cache.buffers[id] { return cached }
        let rendered = try renderMatte(source: id, project: project, at: compositionTime,
                                       canvas: canvas, authoredCanvas: authoredCanvas,
                                       request: request, instruction: instruction)
        cache.buffers[id] = rendered
        return rendered
    }

    private func renderMatte(
        source id: UUID,
        project: VideoProject,
        at compositionTime: CMTime,
        canvas: CGSize,
        authoredCanvas: CGSize,
        request: AVAsynchronousVideoCompositionRequest,
        instruction: LayerInstruction
    ) throws -> CVPixelBuffer? {
        guard let ci, let item = project.timeline.item(id: id), item.placement.isEnabled,
              let track = project.timeline.tracks.first(where: { $0.id == item.placement.trackID }),
              track.isEnabled else { return nil }
        let relative = CMTimeSubtract(compositionTime, item.placement.timelineStart.cmTime)
        guard relative >= .zero, relative < item.placement.duration.cmTime else { return nil }
        let time = try? TimelineTime(compositionTime)
        let bounds = CGRect(origin: .zero, size: canvas)
        let clear = CIImage(color: .clear).cropped(to: bounds)
        let placed: CIImage
        switch item {
        case .text(let authored):
            // Resolved, so an animated title animates the MATTE too: a
            // typewriter reveals the layer below it letter by letter, with no
            // matte-specific animation code anywhere.
            let resolved = authored.resolved(at: time)
            // The real rendered title: glyph anti-aliasing, stroke, background,
            // shadow and glow all carry their own alpha, and all of it is
            // coverage. Nothing is thresholded into a hard mask.
            guard let image = TextRenderer.image(resolved, canvas: canvas, authoredCanvas: authoredCanvas) else { return nil }
            placed = image
        case .shape(let authored):
            let clip = time.map { authored.evaluated(at: $0) } ?? authored
            guard let image = ShapeRenderer.image(clip, canvas: canvas, authoredCanvas: authoredCanvas) else { return nil }
            placed = image
        case .video(let authored):
            let clip = time.map { authored.evaluated(at: $0) } ?? authored
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return nil }
            let sourceSize: CGSize
            let transform: CGAffineTransform
            var coverage: CIImage
            if asset.stillImage != nil {
                // A still carries real transparency — a PNG logo cuts its own
                // shape — so its own alpha is the coverage.
                let still = try stillFrame(asset.url, canvas: canvas,
                                           magnification: Self.magnification(clip.transform))
                sourceSize = CGSize(width: CVPixelBufferGetWidth(still), height: CVPixelBufferGetHeight(still))
                transform = Self.transform(clip.transform, encoded: sourceSize, preferred: .identity, canvas: canvas)
                let cutout = try backgroundRemoved(still, original: still, clip: clip,
                    asset: asset, projectID: project.id, compositionTime: compositionTime)
                let masked = try self.masked(cutout, with: clip.resolvedLayerMask)
                coverage = CIImage(cvPixelBuffer: masked, options: [.colorSpace: colorSpace])
            } else {
                guard let metadata = asset.videoMetadata else { return nil }
                sourceSize = metadata.encodedSize
                transform = Self.transform(clip.transform, metadata: metadata, canvas: canvas)
                let rect = CGRect(origin: .zero, size: sourceSize)
                if clip.resolvedBackgroundRemoval?.isEnabled == true {
                    guard let trackID = instruction.trackIDs[clip.id],
                          let original = request.sourceFrame(byTrackID: trackID) else { return nil }
                    let opaque = try opaqueCoverage(width: Int(sourceSize.width), height: Int(sourceSize.height))
                    let cutout = try backgroundRemoved(opaque, original: original, clip: clip,
                        asset: asset, projectID: project.id, compositionTime: compositionTime)
                    let masked = try self.masked(cutout, with: clip.resolvedLayerMask)
                    coverage = CIImage(cvPixelBuffer: masked, options: [.colorSpace: colorSpace])
                } else if clip.resolvedLayerMask.isEnabled {
                    // Run the SAME kernel the picture uses, so a feathered edge
                    // on the matte is the feather the mask draws, not a second
                    // implementation of it that happens to look similar.
                    let opaque = try opaqueCoverage(width: Int(sourceSize.width), height: Int(sourceSize.height))
                    let masked = try self.masked(opaque, with: clip.resolvedLayerMask)
                    coverage = CIImage(cvPixelBuffer: masked, options: [.colorSpace: colorSpace])
                } else {
                    // No mask: coverage is simply the clip's rectangle, and a
                    // decoded frame would tell us nothing a flat one does not.
                    coverage = CIImage(color: .white).cropped(to: rect)
                }
            }
            coverage = coverage.transformed(by: transform)
            placed = coverage.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)
            ])
        case .audio:
            return nil
        }
        return try renderedSDRLayer(placed.composited(over: clear), size: canvas, ci: ci)
    }

    /// Multiplies a canvas-space layer's coverage by the matte.
    ///
    /// Both sides are premultiplied here — a `CVPixelBuffer` CIImage is, and
    /// `applyLayerMaskBGRA` writes premultiplied — and blending toward a clear
    /// background is exactly `rgb *= a, alpha *= a`. No unpremultiply/
    /// repremultiply round trip, so anti-aliased glyph edges keep their
    /// fractional coverage with no dark or bright fringe.
    ///
    /// Inverting is the SAME blend with its two sides exchanged, not a second
    /// kind of blend and not a second pass: `mix(clear, image, m)` keeps the
    /// layer where the source is opaque, `mix(image, clear, m)` keeps it where
    /// the source is not. That is `1 - m` exactly, over the whole continuous
    /// range, without an inversion filter that would round separately.
    private func matted(
        _ image: CIImage,
        with buffer: CVPixelBuffer,
        mode: TrackMatteMode,
        bounds: CGRect
    ) -> CIImage {
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
        let clear = CIImage(color: .clear).cropped(to: bounds)
        let foreground = mode.isInverted ? clear : image
        let background = mode.isInverted ? image : clear
        return foreground.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: bounds)
    }

    /// The matte shown as a picture: white where the target is kept, black
    /// where it is cut, grey in between — in BOTH modes, so the view answers
    /// "what survives" rather than "what the source happens to look like".
    /// Editor-only; nothing calls this on the export path.
    private func matteInspectionImage(_ buffer: CVPixelBuffer, mode: TrackMatteMode) -> CIImage {
        // Alpha to an opaque grey, and the inverted mode simply negates that
        // one channel: -a + 1 rather than a + 0.
        let scale: CGFloat = mode.isInverted ? -1 : 1
        let bias: CGFloat = mode.isInverted ? 1 : 0
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: scale),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: scale),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: scale),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
            ])
    }

    /// What the matte view shows when the source supplies nothing at all at
    /// this moment: black for an alpha matte (the target is cut everywhere),
    /// white for an inverted one (the target is kept everywhere).
    private func emptyMatteInspectionImage(mode: TrackMatteMode, bounds: CGRect) -> CIImage {
        CIImage(color: mode.isInverted ? .white : .black).cropped(to: bounds)
    }

    /// A fully opaque source-sized surface, cached per size.
    private func opaqueCoverage(width: Int, height: Int) throws -> CVPixelBuffer {
        let key = "\(width)x\(height)"
        if let existing = opaqueFrames[key] { return existing }
        guard let ci else { throw GradeLabError.rendererInitializationFailed }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(nil, max(1, width), max(1, height), kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw GradeLabError.rendererInitializationFailed }
        let bounds = CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height))
        ci.render(CIImage(color: .white).cropped(to: bounds), to: buffer, bounds: bounds, colorSpace: colorSpace)
        if opaqueFrames.count >= 4 { opaqueFrames.removeAll() }
        opaqueFrames[key] = buffer
        return buffer
    }

    /// The texture the Metal compositing kernels multiply their coverage by.
    /// Without a matte this is the 1x1 opaque texture, which leaves alpha alone.
    private func matteTexture(_ buffer: CVPixelBuffer?, retaining retained: inout [Any]) throws -> MTLTexture {
        guard let metal else { throw GradeLabError.rendererInitializationFailed }
        guard let buffer else { return try neutralMatte(device: metal.device) }
        guard let texture = metal.packedTexture(from: buffer, pixelFormat: .bgra8Unorm) else {
            throw GradeLabError.rendererInitializationFailed
        }
        retained.append(texture)
        return texture.texture
    }

    private func neutralMatte(device: MTLDevice) throws -> MTLTexture {
        if let neutralMatteTexture { return neutralMatteTexture }
        neutralMatteTexture = try constantMatte(device: device, alpha: 255)
        return neutralMatteTexture!
    }

    /// A 1x1 fully transparent texture: coverage zero everywhere. Used where a
    /// layer HAS a matte but the source supplies nothing at this moment, in the
    /// one place the layer cannot simply be skipped — a transition, which needs
    /// both of its inputs.
    private func transparentMatteTexture() throws -> MTLTexture {
        guard let metal else { throw GradeLabError.rendererInitializationFailed }
        if let emptyMatteTexture { return emptyMatteTexture }
        emptyMatteTexture = try constantMatte(device: metal.device, alpha: 0)
        return emptyMatteTexture!
    }

    private func constantMatte(device: MTLDevice, alpha: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GradeLabError.rendererInitializationFailed
        }
        // Premultiplied, so the colour channels carry the same value the alpha
        // does. Only the alpha is ever read.
        var pixel: [UInt8] = [alpha, alpha, alpha, alpha]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return texture
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws {
        guard let instruction = request.videoCompositionInstruction as? LayerInstruction else { throw GradeLabError.rendererInitializationFailed }
        let began = Date()
        defer {
            let shouldLog = Self.firstFrameLogged.withLock { logged -> Bool in
                guard !logged else { return false }
                logged = true
                return true
            }
            if shouldLog {
                CompositorWarmup.log.notice(
                    "first composited frame: \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s")
            }
        }
        try prepare(context: instruction.state.context)
        let (project, bypass) = instruction.state.snapshot()
        if let inspected = instruction.state.inspectedBackgroundTargetID {
            try renderBackgroundInspection(inspected, request: request,
                                           instruction: instruction, project: project)
            return
        }
        if project.colorMode.isAppleLog {
            try renderAppleLog(request, instruction: instruction, project: project, bypass: bypass)
            return
        }
        if project.colorMode.isHDR {
            try renderHDR(request, instruction: instruction, project: project, bypass: bypass)
            return
        }
        guard let output = request.renderContext.newPixelBuffer(), let ci else { throw GradeLabError.rendererInitializationFailed }
        // The render context's size, not the project canvas: preview renders at a
        // reduced size and everything here is normalised to the canvas it is
        // given, so both paths scale without a second set of geometry.
        let bounds = CGRect(origin: .zero, size: request.renderContext.size)
        // The coordinate system drawn overlays are authored in. Constant for the
        // whole frame, so it is read once rather than per track.
        let authoredCanvas = SequenceComposition.previewRenderSize(
            width: project.canvas.width, height: project.canvas.height)
        var result = instruction.state.showsTransparencyGrid
            ? transparencyGridImage(bounds: bounds)
            : CIImage(color: CIColor(cgColor: project.canvas.background.cgColor)).cropped(to: bounds)
        var retained: [CVPixelBuffer] = []
        // Layers consumed as a matte are not ALSO drawn in their own right —
        // a title used to cut a video is the hole, not a caption over it.
        let consumed = project.timeline.trackMatteConsumedSourceIDs
        // Rendered mattes for this frame. One entry per source however many
        // targets read it, retained until the frame is finished.
        let mattes = MatteCache()
        if let inspected = instruction.state.inspectedMatteTargetID,
           let configuration = project.timeline.item(id: inspected)?.trackMatte {
            // Editor-only matte view. Everything else about the frame is
            // skipped: what is being asked is what the coverage looks like.
            let buffer = try matte(source: configuration.sourceItemID, project: project,
                                   at: request.compositionTime,
                                   canvas: bounds.size, authoredCanvas: authoredCanvas, cache: mattes,
                                   request: request, instruction: instruction)
            let view = buffer.map { matteInspectionImage($0, mode: configuration.mode) }
                ?? emptyMatteInspectionImage(mode: configuration.mode, bounds: bounds)
            ci.render(view.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
            withExtendedLifetime(mattes) {}
            request.finish(withComposedVideoFrame: output)
            return
        }
        /// The target's coverage after its track matte, or nil when the matte
        /// supplies none here and the target must not be drawn at all.
        func applyMatte(_ image: CIImage, of item: TimelineItem) throws -> CIImage? {
            guard let configuration = item.trackMatte else { return image }
            guard let buffer = try matte(source: configuration.sourceItemID, project: project,
                                         at: request.compositionTime, canvas: bounds.size,
                                         authoredCanvas: authoredCanvas, cache: mattes,
                                         request: request, instruction: instruction) else {
                // No source here means coverage zero, which an alpha matte cuts
                // away entirely and an inverted one keeps entirely. Both fall
                // out of `1 - 0 = 1`; neither is the matte quietly switching
                // itself off.
                return configuration.mode.isInverted ? image : nil
            }
            return matted(image, with: buffer, mode: configuration.mode, bounds: bounds)
        }
        for track in project.timeline.tracks.reversed() where track.isEnabled {
            for item in track.items where item.placement.isEnabled && item.isDrawnOverlay {
                guard !consumed.contains(item.id) else { continue }
                let relative = CMTimeSubtract(request.compositionTime, item.placement.timelineStart.cmTime)
                guard relative >= .zero, relative < item.placement.duration.cmTime else { continue }
                // Single conversion from composition time to clip-local animation time.
                // Preview and export reach this same line, so they cannot disagree.
                let time = try? TimelineTime(request.compositionTime)
                let drawn: (image: CIImage, blend: VisualBlendMode)?
                switch item {
                case .text(let authored):
                    let resolved = authored.resolved(at: time)
                    drawn = TextRenderer.image(resolved, canvas: bounds.size, authoredCanvas: authoredCanvas)
                        .map { ($0, resolved.clip.blendMode) }
                case .shape(let authored):
                    let clip = time.map { authored.evaluated(at: $0) } ?? authored
                    drawn = ShapeRenderer.image(clip, canvas: bounds.size, authoredCanvas: authoredCanvas)
                        .map { ($0, clip.blendMode) }
                default: drawn = nil
                }
                if let drawn, let matted = try applyMatte(drawn.image, of: item) {
                    let filters: [VisualBlendMode: String] = [.normal: "CISourceOverCompositing", .multiply: "CIMultiplyBlendMode", .screen: "CIScreenBlendMode", .overlay: "CIOverlayBlendMode", .softLight: "CISoftLightBlendMode", .hardLight: "CIHardLightBlendMode", .darken: "CIDarkenBlendMode", .lighten: "CILightenBlendMode"]
                    result = matted.applyingFilter(filters[drawn.blend]!, parameters: [kCIInputBackgroundImageKey: result]).cropped(to: bounds)
                }
            }
            let activeTransition = project.timeline.transitions.first { transition in
                guard transition.enabled,
                      let outgoing = project.timeline.videoClip(id: transition.outgoingClipID),
                      outgoing.placement.trackID == track.id else { return false }
                return transition.progress(at: request.compositionTime) != nil
            }
            var transitionedClipIDs = Set<UUID>()
            if let transition = activeTransition,
               let progress = transition.progress(at: request.compositionTime),
               let outgoing = project.timeline.videoClip(id: transition.outgoingClipID),
               let incoming = project.timeline.videoClip(id: transition.incomingClipID),
               // A clip being consumed as somebody's matte is not in the
               // picture, so there is nothing for it to transition into. The
               // other side of the cut still draws normally below.
               !consumed.contains(outgoing.id), !consumed.contains(incoming.id) {
                let first = try renderedSDRClip(outgoing, request: request, instruction: instruction,
                                                project: project, bypass: bypass, bounds: bounds,
                                                mattes: mattes, authoredCanvas: authoredCanvas)
                let second = try renderedSDRClip(incoming, request: request, instruction: instruction,
                                                 project: project, bypass: bypass, bounds: bounds,
                                                 mattes: mattes, authoredCanvas: authoredCanvas)
                retained.append(contentsOf: first.retained + second.retained)
                let clear = CIImage(color: .clear).cropped(to: bounds)
                let firstCanvas = try renderedSDRLayer(first.image.composited(over: clear), size: bounds.size, ci: ci)
                let secondCanvas = try renderedSDRLayer(second.image.composited(over: clear), size: bounds.size, ci: ci)
                let transitioned = try transitionBGRA(firstCanvas, secondCanvas, transition: transition,
                                                      progress: progress, size: bounds.size)
                retained.append(contentsOf: [firstCanvas, secondCanvas, transitioned])
                let image = CIImage(cvPixelBuffer: transitioned, options: [.colorSpace: colorSpace])
                result = image.applyingFilter("CISourceOverCompositing",
                    parameters: [kCIInputBackgroundImageKey: result]).cropped(to: bounds)
                transitionedClipIDs = [outgoing.id, incoming.id]
            }
            for case .video(let authored) in track.items where authored.placement.isEnabled {
                guard !transitionedClipIDs.contains(authored.id), !consumed.contains(authored.id) else { continue }
                guard TimelineEditing.activeClip(in: [authored], at: request.compositionTime) != nil else { continue }
                let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
                guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                    throw TimelineError.invalid(String(localized: "A layer frame is unavailable."))
                }
                let source: CVPixelBuffer
                let transform: CGAffineTransform
                var blendPartner: CVPixelBuffer?
                var blendAmount = 0.0
                if asset.stillImage != nil {
                    source = try stillFrame(asset.url, canvas: bounds.size,
                                            magnification: Self.magnification(clip.transform))
                    transform = Self.transform(clip.transform, encoded: CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)), preferred: .identity, canvas: bounds.size)
                } else {
                    guard let id = instruction.trackIDs[clip.id], let frame = request.sourceFrame(byTrackID: id), let metadata = asset.videoMetadata else { throw TimelineError.invalid(String(localized: "A video layer frame is unavailable.")) }
                    // Smooth retiming: cross-dissolve toward the next source
                    // frame by however far between the two this moment falls.
                    // Without it each source frame is simply held, which is the
                    // stepping that makes slow motion judder on footage that was
                    // not shot at a high frame rate.
                    var decoded = frame
                    if let compositionTime = try? TimelineTime(request.compositionTime),
                       let sourceTime = try? clip.sourceTime(at: compositionTime) {
                        let pair = retimedPair(clip: clip, asset: asset, delivered: frame,
                                               sourceTime: sourceTime, request: request,
                                               instruction: instruction)
                        decoded = pair.frame
                        if clip.smoothsMotion, let partner = pair.partner {
                            // Optical flow replaces the pair with a single made
                            // frame, so everything after this — grading, masks,
                            // the cutout — sees an ordinary decoded picture.
                            if let interpolated = flowFrame(clip: clip, asset: asset,
                                                            source: pair.frame, partner: partner,
                                                            phase: pair.phase, sourceTime: sourceTime) {
                                decoded = interpolated
                            } else {
                                blendPartner = partner
                                blendAmount = pair.phase
                            }
                        }
                    }
                    source = decoded
                    transform = Self.transform(clip.transform, metadata: metadata, canvas: bounds.size)
                }
                let masks = (try? TimelineTime(request.compositionTime))
                    .map { clip.evaluatedMaskedGrades(at: $0) } ?? clip.resolvedMaskedGrades
                let gradedFrame: CVPixelBuffer
                if let blendPartner {
                    gradedFrame = try gradedBlend(source, blendPartner, amount: blendAmount,
                                                  settings: clip.gradeSettings, masks: masks, bypass: bypass)
                } else {
                    gradedFrame = try graded(source, settings: clip.gradeSettings, masks: masks, bypass: bypass,
                                             seconds: request.compositionTime.seconds)
                }
                let cutoutFrame = try backgroundRemoved(gradedFrame, original: source, clip: clip,
                    asset: asset, projectID: project.id, compositionTime: request.compositionTime)
                let frame = try masked(cutoutFrame, with: clip.resolvedLayerMask)
                retained.append(cutoutFrame)
                retained.append(frame)
                var image = CIImage(cvPixelBuffer: frame, options: [.colorSpace: colorSpace]).transformed(by: transform)
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)])
                // Last thing before the blend: the clip is fully graded, its
                // power windows are applied, it is placed, its own layer mask
                // has cut it and its opacity is in. The matte then decides how
                // much of that finished layer covers the canvas.
                guard let matted = try applyMatte(image, of: .video(authored)) else { continue }
                image = matted
                let filter: String
                switch clip.blendMode {
                case .normal: filter = "CISourceOverCompositing"
                case .multiply: filter = "CIMultiplyBlendMode"
                case .screen: filter = "CIScreenBlendMode"
                case .overlay: filter = "CIOverlayBlendMode"
                case .softLight: filter = "CISoftLightBlendMode"
                case .hardLight: filter = "CIHardLightBlendMode"
                case .darken: filter = "CIDarkenBlendMode"
                case .lighten: filter = "CILightenBlendMode"
                }
                result = image.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: result]).cropped(to: bounds)
            }
        }
        ci.render(result, to: output, bounds: bounds, colorSpace: colorSpace)
        withExtendedLifetime(retained) {}
        withExtendedLifetime(mattes) {}
        request.finish(withComposedVideoFrame: output)
    }

    /// Editor-only transparency indication. It lives at the bottom of the
    /// composition, so a real lower timeline layer naturally covers it and the
    /// grid is visible only where the stack remains transparent.
    private func transparencyGridImage(bounds: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CICheckerboardGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0.13, green: 0.13, blue: 0.14),
            "inputColor1": CIColor(red: 0.20, green: 0.20, blue: 0.21),
            kCIInputWidthKey: 14,
            kCIInputSharpnessKey: 1
        ]), let image = filter.outputImage else {
            return CIImage(color: CIColor(red: 0.16, green: 0.16, blue: 0.17)).cropped(to: bounds)
        }
        return image.cropped(to: bounds)
    }

    /// Editor-only white/black view of the final cutout matte. It uses the same
    /// GPU stage ordinary composition uses and returns before any color mode's
    /// picture renderer, so it can never leak into export state.
    private func renderBackgroundInspection(
        _ clipID: UUID,
        request: AVAsynchronousVideoCompositionRequest,
        instruction: LayerInstruction,
        project: VideoProject
    ) throws {
        guard let output = request.renderContext.newPixelBuffer(), let ci,
              let clip = project.timeline.videoClip(id: clipID),
              let settings = clip.resolvedBackgroundRemoval,
              let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
            throw GradeLabError.rendererInitializationFailed
        }
        let source: CVPixelBuffer
        let transform: CGAffineTransform
        if asset.stillImage != nil {
            source = try stillFrame(asset.url, canvas: request.renderContext.size,
                                    magnification: Self.magnification(clip.transform))
            transform = Self.transform(clip.transform,
                encoded: CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)),
                preferred: .identity, canvas: request.renderContext.size)
        } else {
            guard let id = instruction.trackIDs[clip.id],
                  let frame = request.sourceFrame(byTrackID: id),
                  let metadata = asset.videoMetadata else {
                throw TimelineError.invalid(String(localized: "The source frame for matte preview is unavailable."))
            }
            source = frame
            transform = Self.transform(clip.transform, metadata: metadata, canvas: request.renderContext.size)
        }
        let opaque = try opaqueCoverage(width: CVPixelBufferGetWidth(source),
                                        height: CVPixelBufferGetHeight(source))
        let matteFrame = try backgroundRemoved(opaque, original: source, clip: clip,
            asset: asset, projectID: project.id, compositionTime: request.compositionTime)
        let bounds = CGRect(origin: .zero, size: request.renderContext.size)
        let black = CIImage(color: .black).cropped(to: bounds)
        let white = CIImage(cvPixelBuffer: matteFrame, options: [.colorSpace: colorSpace])
            .transformed(by: transform)
        ci.render(white.composited(over: black).cropped(to: bounds), to: output,
                  bounds: bounds, colorSpace: colorSpace)
        withExtendedLifetime(settings) {}
        request.finish(withComposedVideoFrame: output)
    }

    /// Produces one fully graded, effected, masked and placed clip layer. This
    /// is the exact preparation ordinary layer composition uses, reused for
    /// both transition inputs so unlike grades are never blended raw.
    private func renderedSDRClip(
        _ authored: VideoClip,
        request: AVAsynchronousVideoCompositionRequest,
        instruction: LayerInstruction,
        project: VideoProject,
        bypass: Bool,
        bounds: CGRect,
        mattes: MatteCache,
        authoredCanvas: CGSize
    ) throws -> (image: CIImage, retained: [CVPixelBuffer]) {
        guard let asset = project.assets.first(where: { $0.id == authored.assetID }) else {
            throw TimelineError.invalid(String(localized: "A transition source is unavailable."))
        }
        let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
        let source: CVPixelBuffer
        let transform: CGAffineTransform
        var blendPartner: CVPixelBuffer?
        var blendAmount = 0.0
        if asset.stillImage != nil {
            source = try stillFrame(asset.url, canvas: bounds.size,
                                    magnification: Self.magnification(clip.transform))
            transform = Self.transform(clip.transform,
                encoded: CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)),
                preferred: .identity, canvas: bounds.size)
        } else {
            guard let id = instruction.trackIDs[clip.id],
                  let frame = request.sourceFrame(byTrackID: id),
                  let metadata = asset.videoMetadata else {
                throw TimelineError.invalid(String(localized: "A transition source frame is unavailable."))
            }
            var decoded = frame
            if let compositionTime = try? TimelineTime(request.compositionTime),
               let sourceTime = try? clip.sourceTime(at: compositionTime) {
                let pair = retimedPair(clip: clip, asset: asset, delivered: frame,
                                       sourceTime: sourceTime, request: request,
                                       instruction: instruction)
                decoded = pair.frame
                if clip.smoothsMotion, let partner = pair.partner {
                    if let interpolated = flowFrame(clip: clip, asset: asset, source: pair.frame,
                                                    partner: partner, phase: pair.phase,
                                                    sourceTime: sourceTime) {
                        decoded = interpolated
                    } else {
                        blendPartner = partner
                        blendAmount = pair.phase
                    }
                }
            }
            source = decoded
            transform = Self.transform(clip.transform, metadata: metadata, canvas: bounds.size)
        }
        let masks = (try? TimelineTime(request.compositionTime))
            .map { clip.evaluatedMaskedGrades(at: $0) } ?? clip.resolvedMaskedGrades
        let gradedFrame = try blendPartner.map {
            try gradedBlend(source, $0, amount: blendAmount, settings: clip.gradeSettings,
                            masks: masks, bypass: bypass)
        } ?? graded(source, settings: clip.gradeSettings, masks: masks, bypass: bypass,
                    seconds: request.compositionTime.seconds)
        let cutoutFrame = try backgroundRemoved(gradedFrame, original: source, clip: clip,
            asset: asset, projectID: project.id, compositionTime: request.compositionTime)
        let frame = try masked(cutoutFrame, with: clip.resolvedLayerMask)
        var image = CIImage(cvPixelBuffer: frame, options: [.colorSpace: colorSpace]).transformed(by: transform)
        image = image.applyingFilter("CIColorMatrix",
            parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)])
        // The transition receives the MATTED layer, alpha and all. Cutting the
        // coverage afterwards would mean the dissolve mixed picture the matte
        // had already removed.
        if let configuration = authored.trackMatte {
            if let buffer = try matte(source: configuration.sourceItemID, project: project,
                                      at: request.compositionTime, canvas: bounds.size,
                                      authoredCanvas: authoredCanvas, cache: mattes,
                                      request: request, instruction: instruction) {
                image = matted(image, with: buffer, mode: configuration.mode, bounds: bounds)
            } else if !configuration.mode.isInverted {
                // Coverage zero. An inverted matte reads that as full coverage
                // and leaves the transition input exactly as it was.
                return (CIImage(color: .clear).cropped(to: bounds), [gradedFrame, cutoutFrame, frame])
            }
        }
        return (image, [gradedFrame, cutoutFrame, frame])
    }

    private func transitionBGRA(_ outgoing: CVPixelBuffer, _ incoming: CVPixelBuffer,
                                transition: TimelineTransition, progress: Float,
                                size: CGSize) throws -> CVPixelBuffer {
        guard let metal, let transitionPipeline else { throw GradeLabError.rendererInitializationFailed }
        let output = try pooledBGRA(width: Int(size.width), height: Int(size.height))
        guard let first = metal.packedTexture(from: outgoing, pixelFormat: .bgra8Unorm),
              let second = metal.packedTexture(from: incoming, pixelFormat: .bgra8Unorm),
              let destination = metal.packedTexture(from: output, pixelFormat: .bgra8Unorm),
              let command = metal.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        var uniforms = TransitionUniforms(transition, progress: progress, size: size)
        encoder.setComputePipelineState(transitionPipeline)
        encoder.setTexture(first.texture, index: 0)
        encoder.setTexture(second.texture, index: 1)
        encoder.setTexture(destination.texture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        Self.dispatch(encoder, pipeline: transitionPipeline, width: Int(size.width), height: Int(size.height))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(first) {}; withExtendedLifetime(second) {}; withExtendedLifetime(destination) {}
        guard command.status == .completed else { throw GradeLabError.rendererInitializationFailed }
        return output
    }
    // MARK: - HDR layer compositing

    /// Composites an HDR project's layers in the working space the rest of the
    /// HDR pipeline uses: linear light, BT.2020 primaries, diffuse white at 1.0.
    ///
    /// This exists as a separate path rather than a widened version of the SDR
    /// one because the SDR path's two load-bearing stages cannot carry an HDR
    /// image at all: `graded` writes 8-bit BGRA, and the Core Image composite
    /// runs in Rec.709. Both would clip every highlight above diffuse white.
    ///
    /// Layers are composited into a half-float canvas and converted to the HLG
    /// signal once, at the end, by the same `workingToSignal` the direct preview
    /// and the HDR encoder use — so a composited frame and a plain one reach the
    /// display through identical maths.
    private func renderHDR(
        _ request: AVAsynchronousVideoCompositionRequest,
        instruction: LayerInstruction,
        project: VideoProject,
        bypass: Bool
    ) throws {
        guard let metal, let ci,
              let videoPipeline = hdrVideoPipeline,
              let imagePipeline = hdrImagePipeline,
              let resolvePipeline = hdrResolvePipeline else {
            throw GradeLabError.unsupportedExport(String(localized: "This device could not build the HDR compositing pipeline."))
        }
        guard let output = request.renderContext.newPixelBuffer(),
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_64RGBAHalf,
              let destination = metal.packedTexture(from: output, pixelFormat: .rgba16Float) else {
            throw GradeLabError.unsupportedExport(String(localized: "The HDR compositor needs half-float render surfaces."))
        }
        let canvasSize = request.renderContext.size
        let canvases = try hdrCanvases(size: canvasSize, device: metal.device)
        guard let command = metal.commandQueue.makeCommandBuffer() else {
            throw GradeLabError.rendererInitializationFailed
        }
        command.label = "GradeLab HDR layers"

        if instruction.state.showsTransparencyGrid, let editorCheckerboardPipeline,
           let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(editorCheckerboardPipeline)
            encoder.setTexture(canvases.0, index: 0)
            Self.dispatch(encoder, pipeline: editorCheckerboardPipeline,
                          width: Int(canvasSize.width), height: Int(canvasSize.height))
            encoder.endEncoding()
        } else {
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = canvases.0
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].storeAction = .store
            clear.colorAttachments[0].clearColor = project.canvas.background.linearBT2020ClearColor
            command.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        }

        var hdrUniforms = HDRDisplayUniforms()
        var readsFirst = true
        var retained: [Any] = [destination]
        /// The grade whose finishing effects apply to the composed HDR frame.
        /// Unlike the SDR path there is no per-layer texture to run the stage on
        /// — layers are composited straight into the canvas — so the topmost
        /// video layer's settings decide. With one video layer, which is what an
        /// HDR project with effects is, that is exactly per-clip.
        var topmostVideoGrade: GradeUniforms?
        let width = Int(canvasSize.width), height = Int(canvasSize.height)

        func compose(
            _ pipeline: MTLComputePipelineState,
            _ configure: (MTLComputeCommandEncoder) -> Void
        ) throws {
            guard let encoder = command.makeComputeCommandEncoder() else {
                throw GradeLabError.rendererInitializationFailed
            }
            encoder.setComputePipelineState(pipeline)
            configure(encoder)
            encoder.setTexture(readsFirst ? canvases.0 : canvases.1, index: 2)
            encoder.setTexture(readsFirst ? canvases.1 : canvases.0, index: 3)
            Self.dispatch(encoder, pipeline: pipeline, width: width, height: height)
            encoder.endEncoding()
            readsFirst.toggle()
        }

        // The coordinate system drawn overlays are authored in. Constant for the
        // whole frame, so it is read once rather than per track.
        let authoredCanvas = SequenceComposition.previewRenderSize(
            width: project.canvas.width, height: project.canvas.height)
        // Track matte, exactly as the SDR path resolves it: a canvas-space
        // coverage buffer per source, built once and read by every target.
        let consumed = project.timeline.trackMatteConsumedSourceIDs
        let mattes = MatteCache()
        let inspectedMatte = instruction.state.inspectedMatteTargetID
        func matteFor(_ item: TimelineItem, retaining store: inout [Any]) throws -> LayerMatte? {
            guard let configuration = item.trackMatte else {
                return LayerMatte(texture: try matteTexture(nil, retaining: &store), inverted: false)
            }
            guard let buffer = try matte(source: configuration.sourceItemID, project: project,
                                         at: request.compositionTime, canvas: canvasSize,
                                         authoredCanvas: authoredCanvas, cache: mattes,
                                         request: request, instruction: instruction) else {
                // Coverage zero. An alpha matte cuts the layer away entirely,
                // so it is skipped; an inverted one keeps all of it, which is
                // the neutral opaque texture read the ordinary way.
                guard configuration.mode.isInverted else { return nil }
                return LayerMatte(texture: try matteTexture(nil, retaining: &store), inverted: false)
            }
            return LayerMatte(texture: try matteTexture(buffer, retaining: &store),
                              inverted: configuration.mode.isInverted)
        }
        // The same traversal order the SDR path uses, so the two cannot disagree
        // about which layer sits on top.
        for track in project.timeline.tracks.reversed() where track.isEnabled && inspectedMatte == nil {
            for item in track.items where item.placement.isEnabled && item.isDrawnOverlay {
                guard !consumed.contains(item.id) else { continue }
                let relative = CMTimeSubtract(request.compositionTime, item.placement.timelineStart.cmTime)
                guard relative >= .zero, relative < item.placement.duration.cmTime else { continue }
                let time = try? TimelineTime(request.compositionTime)
                let drawn: CIImage?
                switch item {
                case .text(let authored):
                    let resolved = authored.resolved(at: time)
                    try Self.requireNormalBlend(resolved.clip.blendMode)
                    drawn = TextRenderer.image(resolved, canvas: canvasSize, authoredCanvas: authoredCanvas)
                case .shape(let authored):
                    let clip = time.map { authored.evaluated(at: $0) } ?? authored
                    try Self.requireNormalBlend(clip.blendMode)
                    drawn = ShapeRenderer.image(clip, canvas: canvasSize, authoredCanvas: authoredCanvas)
                default: drawn = nil
                }
                guard let image = drawn else { continue }
                let buffer = try renderedSDRLayer(image, size: canvasSize, ci: ci)
                guard let texture = metal.packedTexture(from: buffer, pixelFormat: .bgra8Unorm) else {
                    throw GradeLabError.rendererInitializationFailed
                }
                retained.append(buffer); retained.append(texture)
                // A drawn overlay is authored into canvas coordinates already, so
                // it needs no placement of its own — only the SDR→working
                // conversion and its own alpha.
                guard let layerMatte = try matteFor(item, retaining: &retained) else { continue }
                var layer = HDRLayerUniforms(
                    transform: .identity, sourceSize: canvasSize, canvasSize: canvasSize,
                    opacity: 1, sourceIsSDR: true, premultiplied: true,
                    matteInverted: layerMatte.inverted)
                var mask = LayerMaskUniforms(nil)
                var backgroundRemoval = BackgroundRemovalUniforms(.automatic)
                try compose(imagePipeline) { encoder in
                    encoder.setTexture(texture.texture, index: 0)
                    encoder.setTexture(layerMatte.texture, index: 8)
                    encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                    encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                    encoder.setBytes(&backgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 4)
                }
            }
            let activeTransition = project.timeline.transitions.first { transition in
                guard transition.enabled,
                      let outgoing = project.timeline.videoClip(id: transition.outgoingClipID),
                      outgoing.placement.trackID == track.id else { return false }
                return transition.progress(at: request.compositionTime) != nil
            }
            var transitionedClipIDs = Set<UUID>()
            if let transition = activeTransition,
               let transitionPipeline = hdrTransitionPipeline,
               let progress = transition.progress(at: request.compositionTime),
               let outgoing = project.timeline.videoClip(id: transition.outgoingClipID),
               let incoming = project.timeline.videoClip(id: transition.incomingClipID),
               !consumed.contains(outgoing.id), !consumed.contains(incoming.id),
               let outgoingAsset = project.assets.first(where: { $0.id == outgoing.assetID }),
               let incomingAsset = project.assets.first(where: { $0.id == incoming.assetID }),
               let outgoingMetadata = outgoingAsset.videoMetadata,
               let incomingMetadata = incomingAsset.videoMetadata,
               let outgoingID = instruction.trackIDs[outgoing.id],
               let incomingID = instruction.trackIDs[incoming.id],
               let outgoingFrame = request.sourceFrame(byTrackID: outgoingID),
               let incomingFrame = request.sourceFrame(byTrackID: incomingID),
               let outgoingTexture = metal.packedTexture(from: outgoingFrame, pixelFormat: .rgba16Float),
               let incomingTexture = metal.packedTexture(from: incomingFrame, pixelFormat: .rgba16Float) {
                retained.append(outgoingTexture); retained.append(incomingTexture)
                let timelineTime = (try? TimelineTime(request.compositionTime)) ?? .zero
                let outgoingClip = outgoing.evaluated(at: timelineTime)
                let incomingClip = incoming.evaluated(at: timelineTime)
                let compositionTime = try? TimelineTime(request.compositionTime)
                var outgoingProgram = GradeProgram(
                    settings: outgoingClip.gradeSettings,
                    masks: compositionTime.map { outgoingClip.evaluatedMaskedGrades(at: $0) }
                        ?? outgoingClip.resolvedMaskedGrades,
                    bypass: bypass, aspect: outgoingMetadata.encodedSize.maskAspect)
                var incomingProgram = GradeProgram(
                    settings: incomingClip.gradeSettings,
                    masks: compositionTime.map { incomingClip.evaluatedMaskedGrades(at: $0) }
                        ?? incomingClip.resolvedMaskedGrades,
                    bypass: bypass, aspect: incomingMetadata.encodedSize.maskAspect)
                outgoingProgram.setGrainSeed(request.compositionTime.seconds)
                incomingProgram.setGrainSeed(request.compositionTime.seconds)
                var outgoingGrade = outgoingProgram.uniforms
                var incomingGrade = incomingProgram.uniforms
                let outgoingLocals = outgoingProgram.locals
                let incomingLocals = incomingProgram.locals
                topmostVideoGrade = incomingGrade
                let outgoingMatte = try matteFor(.video(outgoing), retaining: &retained)
                let incomingMatte = try matteFor(.video(incoming), retaining: &retained)
                let outgoingBackground = try backgroundMatteTexture(
                    original: outgoingFrame, clip: outgoingClip, asset: outgoingAsset,
                    projectID: project.id, compositionTime: request.compositionTime)
                let incomingBackground = try backgroundMatteTexture(
                    original: incomingFrame, clip: incomingClip, asset: incomingAsset,
                    projectID: project.id, compositionTime: request.compositionTime)
                if let outgoingBackground { retained.append(outgoingBackground) }
                if let incomingBackground { retained.append(incomingBackground) }
                var outgoingLayer = HDRLayerUniforms(
                    transform: Self.transform(outgoingClip.transform, metadata: outgoingMetadata, canvas: canvasSize),
                    sourceSize: outgoingMetadata.encodedSize, canvasSize: canvasSize,
                    opacity: outgoingClip.opacity, sourceIsSDR: outgoingMetadata.transferFunction != "HLG",
                    matteInverted: outgoingMatte?.inverted ?? false)
                var incomingLayer = HDRLayerUniforms(
                    transform: Self.transform(incomingClip.transform, metadata: incomingMetadata, canvas: canvasSize),
                    sourceSize: incomingMetadata.encodedSize, canvasSize: canvasSize,
                    opacity: incomingClip.opacity, sourceIsSDR: incomingMetadata.transferFunction != "HLG",
                    matteInverted: incomingMatte?.inverted ?? false)
                var outgoingMask = LayerMaskUniforms(outgoingClip.layerMask)
                var incomingMask = LayerMaskUniforms(incomingClip.layerMask)
                var outgoingBackgroundRemoval = BackgroundRemovalUniforms(outgoingClip.resolvedBackgroundRemoval ?? .automatic)
                var incomingBackgroundRemoval = BackgroundRemovalUniforms(incomingClip.resolvedBackgroundRemoval ?? .automatic)
                var uniforms = TransitionUniforms(transition, progress: progress, size: canvasSize)
                // A side whose alpha matte supplies no coverage here contributes
                // nothing, which is a fully transparent input rather than a
                // skipped transition. An inverted matte never lands here: no
                // coverage means it keeps everything.
                let blankMatte = try transparentMatteTexture()
                try compose(transitionPipeline) { encoder in
                    encoder.setTexture(outgoingTexture.texture, index: 0)
                    encoder.setTexture(incomingTexture.texture, index: 1)
                    encoder.setTexture(outgoingMatte?.texture ?? blankMatte, index: 8)
                    encoder.setTexture(incomingMatte?.texture ?? blankMatte, index: 9)
                    encoder.setTexture(outgoingBackground, index: 10)
                    encoder.setTexture(incomingBackground, index: 11)
                    encoder.setTexture(metal.luts.texture(for: outgoingProgram.lookIdentifier), index: 4)
                    encoder.setTexture(metal.luts.texture(for: incomingProgram.lookIdentifier), index: 5)
                    encoder.setTexture(metal.curves.texture(for: outgoingProgram.curveRows), index: 6)
                    encoder.setTexture(metal.curves.texture(for: incomingProgram.curveRows), index: 7)
                    encoder.setTexture(metal.warps.texture(for: outgoingProgram.warp), index: 12)
                    encoder.setTexture(metal.warps.texture(for: incomingProgram.warp), index: 13)
                    encoder.setBytes(&outgoingGrade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                    encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
                    encoder.setBytes(&outgoingLayer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                    encoder.setBytes(&outgoingMask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                    encoder.setBytes(&incomingGrade, length: MemoryLayout<GradeUniforms>.stride, index: 4)
                    encoder.setBytes(&incomingLayer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 5)
                    encoder.setBytes(&incomingMask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 6)
                    encoder.setBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 7)
                    encoder.setBytes(&outgoingBackgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 10)
                    encoder.setBytes(&incomingBackgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 11)
                    outgoingLocals.bind(encoder, index: LocalGradeStack.bufferIndex)
                    incomingLocals.bind(encoder, index: LocalGradeStack.incomingBufferIndex)
                }
                transitionedClipIDs = [outgoing.id, incoming.id]
            }
            for case .video(let authored) in track.items where authored.placement.isEnabled {
                guard !transitionedClipIDs.contains(authored.id), !consumed.contains(authored.id) else { continue }
                guard TimelineEditing.activeClip(in: [authored], at: request.compositionTime) != nil else { continue }
                let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
                try Self.requireNormalBlend(clip.blendMode)
                guard let layerMatte = try matteFor(.video(authored), retaining: &retained) else { continue }
                guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                    throw TimelineError.invalid(String(localized: "A layer frame is unavailable."))
                }
                if asset.stillImage != nil {
                    let still = try stillFrame(asset.url, canvas: canvasSize,
                                               magnification: Self.magnification(clip.transform))
                    let size = CGSize(width: CVPixelBufferGetWidth(still), height: CVPixelBufferGetHeight(still))
                    guard let texture = metal.packedTexture(from: still, pixelFormat: .bgra8Unorm) else {
                        throw GradeLabError.rendererInitializationFailed
                    }
                    retained.append(texture)
                    let background = try backgroundMatteTexture(
                        original: still, clip: clip, asset: asset,
                        projectID: project.id, compositionTime: request.compositionTime)
                    if let background { retained.append(background) }
                    var layer = HDRLayerUniforms(
                        transform: Self.transform(clip.transform, encoded: size, preferred: .identity, canvas: canvasSize),
                        sourceSize: size, canvasSize: canvasSize,
                        opacity: clip.opacity, sourceIsSDR: true, premultiplied: false,
                        matteInverted: layerMatte.inverted)
                    var mask = LayerMaskUniforms(clip.layerMask)
                    var backgroundRemoval = BackgroundRemovalUniforms(clip.resolvedBackgroundRemoval ?? .automatic)
                    try compose(imagePipeline) { encoder in
                        encoder.setTexture(texture.texture, index: 0)
                        encoder.setTexture(layerMatte.texture, index: 8)
                        encoder.setTexture(background, index: 9)
                        encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                        encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                        encoder.setBytes(&backgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 4)
                    }
                    continue
                }
                guard let id = instruction.trackIDs[clip.id],
                      let frame = request.sourceFrame(byTrackID: id),
                      let metadata = asset.videoMetadata else {
                    throw TimelineError.invalid(String(localized: "A video layer frame is unavailable."))
                }
                guard let texture = metal.packedTexture(from: frame, pixelFormat: .rgba16Float) else {
                    throw GradeLabError.unsupportedExport(String(localized: "An HDR source frame did not arrive as half-float."))
                }
                retained.append(texture)
                let background = try backgroundMatteTexture(
                    original: frame, clip: clip, asset: asset,
                    projectID: project.id, compositionTime: request.compositionTime)
                if let background { retained.append(background) }
                // Measured: a custom compositor is handed each source in its OWN
                // encoding, relabelled but not converted — an HLG file arrives as
                // the HLG signal, a Rec.709 file as Rec.709. The direct preview
                // path gets AVFoundation's conversion for free; this one has to
                // do it, which is what `sourceIsSDR` selects in the kernel.
                let sourceIsSDR = metadata.transferFunction != "HLG"
                var sourceTexture = texture.texture
                var partnerTexture = texture.texture
                var blendAmount = 0.0
                if let compositionTime = try? TimelineTime(request.compositionTime),
                   let sourceTime = try? clip.sourceTime(at: compositionTime) {
                    let pair = retimedPair(clip: clip, asset: asset, delivered: frame,
                                           sourceTime: sourceTime, request: request,
                                           instruction: instruction)
                    // A reversed clip's picture comes from its own supply, so
                    // the texture the composition produced is replaced before
                    // anything is blended into it.
                    if pair.frame !== frame,
                       let made = metal.packedTexture(from: pair.frame, pixelFormat: .rgba16Float) {
                        retained.append(made)
                        sourceTexture = made.texture
                        partnerTexture = made.texture
                    }
                    let partnerFrame = pair.partner
                    let phase = pair.phase
                    if clip.smoothsMotion, let partnerFrame {
                    // The interpolated frame comes back as another half-float
                    // surface in the same working space, so the kernel below is
                    // handed one frame and no blend rather than two and a mix.
                    // Nothing about the HDR transfer or the reference white
                    // changes: this is the same picture, at a different moment.
                    if let interpolated = flowFrame(clip: clip, asset: asset, source: pair.frame,
                                                    partner: partnerFrame, phase: phase,
                                                    sourceTime: sourceTime),
                       let made = metal.packedTexture(from: interpolated, pixelFormat: .rgba16Float) {
                        retained.append(made)
                        sourceTexture = made.texture
                        partnerTexture = made.texture
                    } else if let partner = metal.packedTexture(from: partnerFrame, pixelFormat: .rgba16Float) {
                        retained.append(partner)
                        partnerTexture = partner.texture
                        blendAmount = phase
                    }
                    }
                }
                var program = GradeProgram(
                    settings: clip.gradeSettings,
                    masks: (try? TimelineTime(request.compositionTime))
                        .map { clip.evaluatedMaskedGrades(at: $0) } ?? clip.resolvedMaskedGrades,
                    bypass: bypass, aspect: metadata.encodedSize.maskAspect)
                program.setGrainSeed(request.compositionTime.seconds)
                var grade = program.uniforms
                topmostVideoGrade = grade
                var layer = HDRLayerUniforms(
                    transform: Self.transform(clip.transform, metadata: metadata, canvas: canvasSize),
                    sourceSize: metadata.encodedSize, canvasSize: canvasSize,
                    opacity: clip.opacity, blendAmount: blendAmount, sourceIsSDR: sourceIsSDR,
                    matteInverted: layerMatte.inverted)
                var mask = LayerMaskUniforms(clip.layerMask)
                var backgroundRemoval = BackgroundRemovalUniforms(clip.resolvedBackgroundRemoval ?? .automatic)
                let lut = metal.luts.texture(for: program.lookIdentifier)
                let curveLUT = metal.curves.texture(for: program.curveRows)
                let warpField = metal.warps.texture(for: program.warp)
                let locals = program.locals
                try compose(videoPipeline) { encoder in
                    encoder.setTexture(sourceTexture, index: 0)
                    encoder.setTexture(partnerTexture, index: 1)
                    encoder.setTexture(lut, index: 4)
                    encoder.setTexture(curveLUT, index: 6)
                    encoder.setTexture(warpField, index: 12)
                    encoder.setTexture(layerMatte.texture, index: 8)
                    encoder.setTexture(background, index: 9)
                    encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                    encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
                    encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                    encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                    encoder.setBytes(&backgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 4)
                    locals.bind(encoder)
                }
            }
        }

        // Editor-only matte view: the coverage itself, as a picture, instead of
        // the composition. Nothing on the export path can reach this.
        if let inspected = inspectedMatte,
           let configuration = project.timeline.item(id: inspected)?.trackMatte {
            let buffer = try matte(source: configuration.sourceItemID, project: project,
                                   at: request.compositionTime,
                                   canvas: canvasSize, authoredCanvas: authoredCanvas, cache: mattes,
                                   request: request, instruction: instruction)
            let bounds = CGRect(origin: .zero, size: canvasSize)
            let view = buffer.map { matteInspectionImage($0, mode: configuration.mode) }
                ?? emptyMatteInspectionImage(mode: configuration.mode, bounds: bounds)
            let rendered = try renderedSDRLayer(view, size: canvasSize, ci: ci)
            if let texture = metal.packedTexture(from: rendered, pixelFormat: .bgra8Unorm) {
                retained.append(rendered); retained.append(texture)
                var layer = HDRLayerUniforms(
                    transform: .identity, sourceSize: canvasSize, canvasSize: canvasSize,
                    opacity: 1, sourceIsSDR: true, premultiplied: true)
                var mask = LayerMaskUniforms(nil)
                var backgroundRemoval = BackgroundRemovalUniforms(.automatic)
                let neutral = try matteTexture(nil, retaining: &retained)
                try compose(imagePipeline) { encoder in
                    encoder.setTexture(texture.texture, index: 0)
                    encoder.setTexture(neutral, index: 8)
                    encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                    encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                    encoder.setBytes(&backgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 4)
                }
            }
        }

        // Finishing effects, in working space, before the signal conversion: a
        // glow is light adding to light, and adding it after the transfer curve
        // would weight it by a non-linear function of brightness.
        if let effects, let effectGrade = topmostVideoGrade, inspectedMatte == nil,
           FilmEffectsStage.isActive(effectGrade) {
            let source = readsFirst ? canvases.0 : canvases.1
            let destination = readsFirst ? canvases.1 : canvases.0
            if effects.encode(source: source, destination: destination,
                              grade: effectGrade, workingSpace: true, into: command) {
                readsFirst.toggle()
            }
        }
        guard let resolve = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        resolve.setComputePipelineState(resolvePipeline)
        resolve.setTexture(readsFirst ? canvases.0 : canvases.1, index: 0)
        resolve.setTexture(destination.texture, index: 1)
        resolve.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
        Self.dispatch(resolve, pipeline: resolvePipeline, width: width, height: height)
        resolve.endEncoding()

        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        withExtendedLifetime(mattes) {}
        guard command.status == .completed else {
            throw GradeLabError.exportFailed(
                command.error.map { "HDR compositing failed: \($0.localizedDescription)" } ?? "HDR compositing failed."
            )
        }
        request.finish(withComposedVideoFrame: output)
    }

    private static func requireNormalBlend(_ mode: VisualBlendMode) throws {
        guard mode != .normal else { return }
        throw GradeLabError.unsupportedExport(
            String(localized: "Blend modes other than Normal are not available in HDR projects yet. They are defined on 0-1 values, and an HDR image is not.")
        )
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
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    private func hdrCanvases(size: CGSize, device: MTLDevice) throws -> (MTLTexture, MTLTexture) {
        if let existing = hdrCanvasPair,
           existing.0.width == Int(size.width), existing.0.height == Int(size.height) {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let first = device.makeTexture(descriptor: descriptor),
              let second = device.makeTexture(descriptor: descriptor) else {
            throw GradeLabError.rendererInitializationFailed
        }
        hdrCanvasPair = (first, second)
        return (first, second)
    }

    /// Renders authored SDR artwork — text, a still — into a Rec.709 buffer the
    /// HDR kernel can convert into working space.
    private func renderedSDRLayer(_ image: CIImage, size: CGSize, ci: CIContext) throws -> CVPixelBuffer {
        let buffer = try pooledBGRA(width: Int(size.width), height: Int(size.height))
        ci.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        return buffer
    }

    static func transform(_ t: VisualTransform, metadata: VideoMetadata, canvas: CGSize) -> CGAffineTransform {
        transform(t, encoded: metadata.encodedSize, preferred: metadata.preferredTransform.cgTransform, canvas: canvas)
    }
    static func transform(_ t: VisualTransform, encoded: CGSize, preferred: CGAffineTransform, canvas: CGSize) -> CGAffineTransform {
        let display = CGRect(origin: .zero, size: encoded).applying(preferred).standardized
        let fit = min(canvas.width/display.width, canvas.height/display.height)
        // Convert CI bottom-left coordinates to AV top-left, transform there,
        // then return to CI coordinates. Placement is normalized to the canvas.
        return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: encoded.height)
            .concatenating(preferred)
            .concatenating(.init(translationX: -display.minX - display.width*t.anchorX, y: -display.minY - display.height*t.anchorY))
            .concatenating(.init(scaleX: fit*t.scale*t.widthScale, y: fit*t.scale*t.heightScale))
            .concatenating(.init(rotationAngle: t.rotationDegrees * .pi/180))
            .concatenating(.init(translationX: canvas.width*t.positionX, y: canvas.height*t.positionY))
            .concatenating(.init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height))
    }

    /// How much of the canvas a clip's picture actually covers, as a multiple of
    /// being fitted to it. 1 is fitted to the canvas, 2 is blown up to twice
    /// that and genuinely wants twice the source pixels, and a half-size
    /// overlay needs only half.
    ///
    /// Quantized UP the power-of-two ladder, for two reasons. Rounding up can
    /// never ask for fewer pixels than the frame draws, so it cannot soften
    /// anything. And a scale that is being animated by keyframes would
    /// otherwise land on a slightly different number every frame and re-decode
    /// the image every frame; on the ladder it re-decodes a handful of times.
    static func magnification(_ t: VisualTransform) -> CGFloat {
        let scale = max(abs(t.scale * t.widthScale), abs(t.scale * t.heightScale))
        guard scale.isFinite, scale > 0 else { return 1 }
        return pow(2, ceil(log2(max(0.25, min(4, CGFloat(scale))))))
    }

    /// The long edge a still is worth decoding at for this canvas.
    ///
    /// Sampling a picture denser than the canvas can draw it is invisible by
    /// definition, so the canvas — enlarged by however far the clip blows the
    /// picture up — is the honest answer.
    static func stillDecodeLongEdge(canvas: CGSize, magnification: CGFloat) -> Int {
        let longEdge = max(canvas.width, canvas.height)
        guard longEdge.isFinite, longEdge > 0 else { return maximumStillLongEdge }
        let wanted = longEdge * max(0.25, magnification)
        guard wanted.isFinite else { return maximumStillLongEdge }
        return max(16, min(maximumStillLongEdge, Int(wanted.rounded(.up))))
    }

    /// A decoded still, sized to what the canvas can actually show.
    ///
    /// This used to decode every image at up to 4096 on the long edge whatever
    /// the canvas was, so a 12-megapixel photograph became a 4032x3024 BGRA
    /// surface — 48 MB — even when the preview was compositing at 1920. Nine
    /// image overlays asked for nine of those at once against a cache that held
    /// four and emptied itself whenever a fifth arrived, so every frame
    /// re-decoded most of them. That is what the system was killing the app for.
    ///
    /// **Nothing moves on screen.** Every caller builds its transform from the
    /// size of the buffer this returns and then fits that to the canvas, so the
    /// picture lands in the same place at the same size whatever resolution it
    /// was decoded at. Only sampling density changes.
    private func stillFrame(_ url: URL, canvas: CGSize, magnification: CGFloat = 1) throws -> CVPixelBuffer {
        let wanted = Self.stillDecodeLongEdge(canvas: canvas, magnification: magnification)
        if let cached = stillFrames[url], cached.longEdge >= wanted {
            stillOrder.removeAll { $0 == url }
            stillOrder.append(url)
            return cached.buffer
        }
        guard let ci, var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .colorSpace: colorSpace]) else {
            throw TimelineError.invalid(String(localized: "The image could not be decoded."))
        }
        let factor = min(1, CGFloat(wanted)/max(image.extent.width, image.extent.height))
        image = image.transformed(by: .init(scaleX: factor, y: factor))
        image = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw GradeLabError.rendererInitializationFailed }
        ci.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
        remember(CachedStill(buffer: buffer,
                             longEdge: Int(max(image.extent.width, image.extent.height))), for: url)
        return buffer
    }

    /// Files the decoded still and evicts by age until the cache is inside its
    /// budget. The entry just decoded is never evicted — the frame being
    /// rendered is holding it.
    private func remember(_ entry: CachedStill, for url: URL) {
        stillFrames[url] = entry
        stillOrder.removeAll { $0 == url }
        stillOrder.append(url)
        var total = stillFrames.values.reduce(0) { $0 + $1.bytes }
        while total > Self.stillCacheBudget, stillOrder.count > 1, let oldest = stillOrder.first {
            total -= stillFrames[oldest]?.bytes ?? 0
            stillFrames.removeValue(forKey: oldest)
            stillOrder.removeFirst()
        }
    }
}


/// The compositor AVFoundation instantiates for an HDR project.
///
/// Identical behaviour to `LayerCompositor` — it is the same `render` — but it
/// asks for and returns half-float surfaces. Measured: with these attributes a
/// custom compositor is handed each source in its own encoding, an HLG file
/// arriving as the HLG signal, which is exactly what the working-space
/// conversion expects.
final class HDRLayerCompositor: LayerCompositor, @unchecked Sendable {
    override var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }
    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }
}

/// Source identity is carried by this type before AVFoundation reads the first
/// instruction. Asking for RGB would let the decoder choose a transfer curve
/// that cannot describe Apple Log.
class AppleLogLayerCompositor: LayerCompositor, @unchecked Sendable {
    // AVFoundation otherwise conforms wide/HDR sources to Rec.709 before our
    // kernel can see their code values (AVVideoCompositing's source contract).
    @objc var supportsWideColorSourceFrames: Bool { true }
    @objc var supportsHDRSourceFrames: Bool { true }
    @objc var canConformColorOfSourceFrames: Bool { true }
    override var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
}

/// Export never passes through the preview's 8-bit surface. These are finished
/// Rec.709 samples, matching the wide-SDR reader and its 10-bit delivery path.
final class AppleLogExportLayerCompositor: AppleLogLayerCompositor, @unchecked Sendable {
    override var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
}

extension LayerCompositor {
    private func renderAppleLog(_ request: AVAsynchronousVideoCompositionRequest,
                                instruction: LayerInstruction, project: VideoProject,
                                bypass: Bool) throws {
        guard let metal, let ci, let output = request.renderContext.newPixelBuffer() else {
            throw GradeLabError.rendererInitializationFailed
        }
        // The Log format the timeline is being composited in. The kernel is
        // specialised for one input transform, so this is fixed for the whole
        // timeline and every clip is checked against it below.
        let isLog2 = project.colorMode == .appleLog2
        let expectedProfile: SourceColorProfile = isLog2 ? .appleLog2 : .appleLog
        if appleLogRenderer == nil {
            appleLogRenderer = try AppleLogLayerRenderer(
                context: metal, prebuilt: resources?.pipelines, isLog2: isLog2)
        }
        guard let renderer = appleLogRenderer, let command = metal.commandQueue.makeCommandBuffer() else {
            throw GradeLabError.rendererInitializationFailed
        }
        command.label = "GradeLab Apple Log layers"
        let size = request.renderContext.size
        let width = Int(size.width), height = Int(size.height)
        let surfaces = try renderer.canvases(width: width, height: height)
        var readIndex = 0
        if instruction.state.showsTransparencyGrid, let editorCheckerboardPipeline,
           let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(editorCheckerboardPipeline)
            encoder.setTexture(surfaces[0], index: 0)
            Self.dispatch(encoder, pipeline: editorCheckerboardPipeline, width: width, height: height)
            encoder.endEncoding()
        } else {
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = surfaces[0]
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].storeAction = .store
            clear.colorAttachments[0].clearColor = project.canvas.background.linearBT2020ClearColor
            guard let clearEncoder = command.makeRenderCommandEncoder(descriptor: clear) else {
                throw GradeLabError.rendererInitializationFailed
            }
            clearEncoder.endEncoding()
        }
        let time = try TimelineTime(request.compositionTime)
        var retained: [Any] = [output]
        var topmostGrade: GradeUniforms?

        func blend(_ texture: MTLTexture, mode: VisualBlendMode) throws {
            var index = AppleLogLayerRenderer.blendIndex(mode)
            try renderer.encode("blendAppleLogLayer", into: command, width: width, height: height) { encoder in
                encoder.setTexture(texture, index: 0)
                encoder.setTexture(surfaces[readIndex], index: 1)
                encoder.setTexture(surfaces[1 - readIndex], index: 2)
                encoder.setBytes(&index, length: MemoryLayout<UInt32>.stride, index: 0)
            }
            readIndex = 1 - readIndex
        }

        func image(_ buffer: CVPixelBuffer, transform: CGAffineTransform, opacity: Double,
                   mask authoredMask: LayerMask?, program: GradeProgram, to destination: MTLTexture,
                   matte layerMatte: LayerMatte, background: MTLTexture? = nil,
                   removal: BackgroundRemovalSettings? = nil) throws {
            guard let texture = metal.packedTexture(from: buffer, pixelFormat: .bgra8Unorm) else {
                throw GradeLabError.rendererInitializationFailed
            }
            retained.append(buffer); retained.append(texture)
            var layer = HDRLayerUniforms(transform: transform,
                sourceSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                canvasSize: size, opacity: opacity, sourceIsSDR: true, premultiplied: true,
                matteInverted: layerMatte.inverted)
            var mask = LayerMaskUniforms(authoredMask)
            var grade = program.uniforms
            var backgroundRemoval = BackgroundRemovalUniforms(removal ?? .automatic)
            try renderer.encode("compositeImageAppleLog", into: command, width: width, height: height) { encoder in
                encoder.setTexture(texture.texture, index: 0)
                encoder.setTexture(destination, index: 2)
                encoder.setTexture(metal.luts.texture(for: program.lookIdentifier), index: 3)
                encoder.setTexture(metal.curves.texture(for: program.curveRows), index: 6)
                encoder.setTexture(metal.warps.texture(for: program.warp), index: 12)
                encoder.setTexture(layerMatte.texture, index: 8)
                encoder.setTexture(background, index: 9)
                encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                encoder.setBytes(&backgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 4)
                program.locals.bind(encoder)
            }
        }

        func video(_ authored: VideoClip, to destination: MTLTexture, matte layerMatte: LayerMatte) throws {
            let clip = authored.evaluated(at: time)
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                throw TimelineError.invalid(String(localized: "A layer source is unavailable."))
            }
            let sourceSize: CGSize
            let still: CVPixelBuffer?
            if asset.stillImage != nil {
                let frame = try stillFrame(asset.url, canvas: size,
                                           magnification: Self.magnification(clip.transform))
                still = frame
                sourceSize = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
            } else {
                still = nil
                guard let metadata = asset.videoMetadata else { throw TimelineError.invalid(String(localized: "Missing video metadata.")) }
                sourceSize = metadata.encodedSize
            }
            var program = GradeProgram(settings: clip.gradeSettings, masks: clip.evaluatedMaskedGrades(at: time),
                                       bypass: bypass, aspect: sourceSize.maskAspect)
            program.setGrainSeed(request.compositionTime.seconds)
            topmostGrade = program.uniforms
            if let still {
                let background = try backgroundMatteTexture(
                    original: still, clip: clip, asset: asset,
                    projectID: project.id, compositionTime: request.compositionTime)
                if let background { retained.append(background) }
                try image(still, transform: Self.transform(clip.transform, encoded: sourceSize,
                          preferred: .identity, canvas: size), opacity: clip.opacity,
                          mask: clip.layerMask, program: program, to: destination,
                          matte: layerMatte, background: background,
                          removal: clip.resolvedBackgroundRemoval)
                return
            }
            guard let metadata = asset.videoMetadata, let id = instruction.trackIDs[clip.id],
                  let frame = request.sourceFrame(byTrackID: id),
                  CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                  let textures = PixelBufferTextures(pixelBuffer: frame, context: metal),
                  case .biPlanar(_, let luma, _, let chroma) = textures.storage else {
                throw GradeLabError.unsupportedExport(String(localized: "Apple Log layers require untouched full-range 10-bit 4:2:2 source frames."))
            }
            retained.append(textures)
            let background = try backgroundMatteTexture(
                original: frame, clip: clip, asset: asset,
                projectID: project.id, compositionTime: request.compositionTime)
            if let background { retained.append(background) }
            let profile = metadata.logProfileIdentifier.map(SourceColorProfile.fromLogIdentifier)
            if let profile, profile != expectedProfile {
                // Including the *other* Apple Log. The compositing kernel is
                // compiled for one set of primaries, so a Log clip of the other
                // kind would be decoded through the wrong gamut and come out
                // subtly, plausibly wrong — which is worse than a refusal.
                throw GradeLabError.unsupportedExport(
                    String(localized: "This timeline is \(expectedProfile.displayName), but this clip is \(profile.displayName). A timeline cannot mix the two Log formats."))
            }
            if profile == nil, metadata.transferFunction == "HLG" {
                throw GradeLabError.unsupportedExport(String(localized: "HLG video cannot be interpreted as Rec.709 in an Apple Log timeline."))
            }
            var sourceLuma = luma, sourceChroma = chroma
            var partnerLuma = luma, partnerChroma = chroma
            var amount = 0.0
            do {
                let sourceTime = try clip.sourceTime(at: time)
                let pair = retimedPair(clip: clip, asset: asset, delivered: frame,
                                       sourceTime: sourceTime, request: request,
                                       instruction: instruction)
                // A reversed Log clip is held to the same layout rule as a
                // decoded one: full-range 10-bit 4:2:2 or nothing. The supply
                // is asked for exactly the format the composition delivered, so
                // this only refuses a frame that genuinely came back wrong.
                if pair.frame !== frame,
                   CVPixelBufferGetPixelFormatType(pair.frame) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                   let made = PixelBufferTextures(pixelBuffer: pair.frame, context: metal),
                   case .biPlanar(_, let y, _, let c) = made.storage {
                    retained.append(made)
                    sourceLuma = y; sourceChroma = c
                    partnerLuma = y; partnerChroma = c
                }
                let phase = pair.phase
                if clip.smoothsMotion, let partnerFrame = pair.partner {
                // The interpolated frame is written back as full-range 10-bit
                // 4:2:2 — the one layout this path accepts — so the Log
                // transform below it is unchanged and untouched. A frame that
                // came back in any other shape is refused rather than decoded
                // through the wrong transform, which is the same rule the
                // decoded frame above is held to.
                if let interpolated = flowFrame(clip: clip, asset: asset, source: pair.frame,
                                                partner: partnerFrame, phase: phase,
                                                sourceTime: sourceTime),
                   CVPixelBufferGetPixelFormatType(interpolated) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                   let made = PixelBufferTextures(pixelBuffer: interpolated, context: metal),
                   case .biPlanar(_, let y, _, let c) = made.storage {
                    retained.append(made)
                    sourceLuma = y; sourceChroma = c
                    partnerLuma = y; partnerChroma = c
                } else if let partner = PixelBufferTextures(pixelBuffer: partnerFrame, context: metal),
                          case .biPlanar(_, let y, _, let c) = partner.storage {
                    retained.append(partner)
                    partnerLuma = y; partnerChroma = c
                    amount = phase
                }
                }
            }
            var layer = HDRLayerUniforms(transform: Self.transform(clip.transform, metadata: metadata, canvas: size),
                sourceSize: sourceSize, canvasSize: size, opacity: clip.opacity,
                blendAmount: amount, sourceIsSDR: profile != expectedProfile,
                matteInverted: layerMatte.inverted)
            var mask = LayerMaskUniforms(clip.layerMask)
            var grade = program.uniforms
            var backgroundRemoval = BackgroundRemovalUniforms(clip.resolvedBackgroundRemoval ?? .automatic)
            var yuv = YUVUniforms.make(for: frame, fallbackMatrix: metadata.yCbCrMatrix)
            try renderer.encode(AppleLogSpecialization.key("compositeVideoAppleLog", isLog2: isLog2),
                                into: command, width: width, height: height) { encoder in
                encoder.setTexture(sourceLuma, index: 0); encoder.setTexture(sourceChroma, index: 1)
                encoder.setTexture(destination, index: 2)
                encoder.setTexture(metal.luts.texture(for: program.lookIdentifier), index: 3)
                encoder.setTexture(partnerLuma, index: 4); encoder.setTexture(partnerChroma, index: 5)
                encoder.setTexture(metal.curves.texture(for: program.curveRows), index: 6)
                encoder.setTexture(metal.warps.texture(for: program.warp), index: 12)
                encoder.setTexture(layerMatte.texture, index: 8)
                encoder.setTexture(background, index: 9)
                encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
                encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                encoder.setBytes(&backgroundRemoval, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 4)
                program.locals.bind(encoder)
            }
        }

        // The coordinate system drawn overlays are authored in. Constant for the
        // whole frame, so it is read once rather than per track.
        let authoredCanvas = SequenceComposition.previewRenderSize(
            width: project.canvas.width, height: project.canvas.height)
        // Track matte, resolved exactly as the other two paths resolve it.
        let consumed = project.timeline.trackMatteConsumedSourceIDs
        let mattes = MatteCache()
        let inspectedMatte = instruction.state.inspectedMatteTargetID
        func matteFor(_ item: TimelineItem, retaining store: inout [Any]) throws -> LayerMatte? {
            guard let configuration = item.trackMatte else {
                return LayerMatte(texture: try matteTexture(nil, retaining: &store), inverted: false)
            }
            guard let buffer = try matte(source: configuration.sourceItemID, project: project,
                                         at: request.compositionTime, canvas: size,
                                         authoredCanvas: authoredCanvas, cache: mattes,
                                         request: request, instruction: instruction) else {
                guard configuration.mode.isInverted else { return nil }
                return LayerMatte(texture: try matteTexture(nil, retaining: &store), inverted: false)
            }
            return LayerMatte(texture: try matteTexture(buffer, retaining: &store),
                              inverted: configuration.mode.isInverted)
        }
        for track in project.timeline.tracks.reversed() where track.isEnabled && inspectedMatte == nil {
            for item in track.items where item.placement.isEnabled && item.isDrawnOverlay {
                guard !consumed.contains(item.id) else { continue }
                let relative = CMTimeSubtract(request.compositionTime, item.placement.timelineStart.cmTime)
                guard relative >= .zero, relative < item.placement.duration.cmTime else { continue }
                let drawn: (image: CIImage, blend: VisualBlendMode)?
                switch item {
                case .text(let authored):
                    let resolved = authored.resolved(at: time)
                    drawn = TextRenderer.image(resolved, canvas: size, authoredCanvas: authoredCanvas)
                        .map { ($0, resolved.clip.blendMode) }
                case .shape(let authored):
                    let clip = authored.evaluated(at: time)
                    drawn = ShapeRenderer.image(clip, canvas: size, authoredCanvas: authoredCanvas)
                        .map { ($0, clip.blendMode) }
                default: drawn = nil
                }
                guard let drawn else { continue }
                guard let overlayMatte = try matteFor(item, retaining: &retained) else { continue }
                let buffer = try renderedSDRLayer(drawn.image, size: size, ci: ci)
                try image(buffer, transform: .identity, opacity: 1, mask: nil,
                    program: GradeProgram(settings: .neutral, bypass: true, aspect: size.maskAspect),
                    to: surfaces[2], matte: overlayMatte)
                try blend(surfaces[2], mode: drawn.blend)
            }
            var transitioned = Set<UUID>()
            if let transition = project.timeline.transitions.first(where: {
                $0.enabled && $0.progress(at: request.compositionTime) != nil &&
                project.timeline.videoClip(id: $0.outgoingClipID)?.placement.trackID == track.id
            }), let outgoing = project.timeline.videoClip(id: transition.outgoingClipID),
               let incoming = project.timeline.videoClip(id: transition.incomingClipID),
               !consumed.contains(outgoing.id), !consumed.contains(incoming.id),
               let progress = transition.progress(at: request.compositionTime) {
                // An alpha matte with no coverage here makes its side of the
                // transition empty; an inverted one never reaches this fallback
                // because no coverage means it keeps everything.
                let blank = LayerMatte(texture: try transparentMatteTexture(), inverted: false)
                let outgoingMatte = try matteFor(.video(outgoing), retaining: &retained) ?? blank
                let incomingMatte = try matteFor(.video(incoming), retaining: &retained) ?? blank
                try video(outgoing, to: surfaces[2], matte: outgoingMatte)
                try video(incoming, to: surfaces[3], matte: incomingMatte)
                var u = TransitionUniforms(transition, progress: progress, size: size)
                try renderer.encode("compositeTransitionAppleLog", into: command, width: width, height: height) { encoder in
                    encoder.setTexture(surfaces[2], index: 0); encoder.setTexture(surfaces[3], index: 1)
                    encoder.setTexture(surfaces[4], index: 2)
                    encoder.setBytes(&u, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
                }
                try blend(surfaces[4], mode: incoming.blendMode)
                transitioned = [outgoing.id, incoming.id]
            }
            for case .video(let clip) in track.items where clip.placement.isEnabled {
                guard !transitioned.contains(clip.id), !consumed.contains(clip.id),
                      TimelineEditing.activeClip(in: [clip], at: request.compositionTime) != nil else { continue }
                guard let layerMatte = try matteFor(.video(clip), retaining: &retained) else { continue }
                try video(clip, to: surfaces[2], matte: layerMatte)
                try blend(surfaces[2], mode: clip.blendMode)
            }
        }
        // Editor-only matte view. Replaces the picture with the coverage; never
        // reachable from export, which never sets an inspection id.
        if let inspected = inspectedMatte,
           let configuration = project.timeline.item(id: inspected)?.trackMatte {
            let buffer = try matte(source: configuration.sourceItemID, project: project,
                                   at: request.compositionTime,
                                   canvas: size, authoredCanvas: authoredCanvas, cache: mattes,
                                   request: request, instruction: instruction)
            let bounds = CGRect(origin: .zero, size: size)
            let view = buffer.map { matteInspectionImage($0, mode: configuration.mode) }
                ?? emptyMatteInspectionImage(mode: configuration.mode, bounds: bounds)
            let rendered = try renderedSDRLayer(view, size: size, ci: ci)
            let neutral = LayerMatte(texture: try matteTexture(nil, retaining: &retained), inverted: false)
            try image(rendered, transform: .identity, opacity: 1, mask: nil,
                      program: GradeProgram(settings: .neutral, bypass: true, aspect: size.maskAspect),
                      to: surfaces[2], matte: neutral)
            try blend(surfaces[2], mode: .normal)
        }
        if let grade = topmostGrade, inspectedMatte == nil, FilmEffectsStage.isActive(grade) {
            guard let effects, effects.encode(source: surfaces[readIndex], destination: surfaces[1 - readIndex],
                                              grade: grade, workingSpace: true, into: command) else {
                throw GradeLabError.rendererInitializationFailed
            }
            readIndex = 1 - readIndex
        }
        if CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA,
           let destination = metal.packedTexture(from: output, pixelFormat: .bgra8Unorm) {
            retained.append(destination)
            try renderer.encode("resolveAppleLogCanvas", into: command, width: width, height: height) { encoder in
                encoder.setTexture(surfaces[readIndex], index: 0); encoder.setTexture(destination.texture, index: 1)
                encoder.setTexture(renderer.renderingLUT, index: 4)
            }
        } else if CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                  let y = metal.writableTexture(from: output, pixelFormat: .r16Unorm, plane: 0),
                  let c = metal.writableTexture(from: output, pixelFormat: .rg16Unorm, plane: 1) {
            retained.append(y); retained.append(c)
            try renderer.encode("resolveAppleLogCanvas422", into: command, width: c.texture.width, height: c.texture.height) { encoder in
                encoder.setTexture(surfaces[readIndex], index: 0)
                encoder.setTexture(y.texture, index: 1); encoder.setTexture(c.texture, index: 2)
                encoder.setTexture(renderer.renderingLUT, index: 4)
            }
        } else {
            throw GradeLabError.unsupportedExport(String(localized: "Apple Log layers need BGRA preview or 10-bit 4:2:2 export surfaces."))
        }
        // Composition-wide tags can relabel decoder inputs. Output tags belong
        // here, after the one and only Apple display transform has run.
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferRemoveAttachment(output, kCVImageBufferLogTransferFunctionKey)
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        withExtendedLifetime(mattes) {}
        guard command.status == .completed else {
            throw GradeLabError.exportFailed(command.error?.localizedDescription ?? "Apple Log compositing failed.")
        }
        request.finish(withComposedVideoFrame: output)
    }
}
