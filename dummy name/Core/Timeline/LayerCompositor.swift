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
    let context: MetalContext?
    init(_ project: VideoProject, context: MetalContext? = nil) { self.project = project; self.context = context }
    func update(_ project: VideoProject, bypass: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.project = project; self.bypass = bypass
    }
    func snapshot() -> (VideoProject, Bool) {
        lock.lock(); defer { lock.unlock() }; return (project, bypass)
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
    private var stillFrames: [URL: CVPixelBuffer] = [:]
    private var ci: CIContext?
    private var pools: [String: CVPixelBufferPool] = [:]
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    /// Built only when the device has them; an HDR project without them refuses
    /// with a reason rather than rendering something wrong.
    private var hdrVideoPipeline: MTLComputePipelineState?
    private var hdrImagePipeline: MTLComputePipelineState?
    private var hdrResolvePipeline: MTLComputePipelineState?
    private var hdrTransitionPipeline: MTLComputePipelineState?
    /// Two working-space canvases, ping-ponged as layers are composited.
    private var hdrCanvasPair: (MTLTexture, MTLTexture)?
    /// Spatial finishing effects, the same object preview and export use.
    private var effects: FilmEffectsStage?
    private var appleLogRenderer: AppleLogLayerRenderer?
    private var resources: CompositorResources.Bundle?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.async { self.pools.removeAll(); self.hdrCanvasPair = nil; self.appleLogRenderer = nil }
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
        ci = bundle.ci
        effects = bundle.effects
        resources = bundle
        metal = bundle.context
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
                "An HDR frame reached the SDR compositing path. This is a bug; the frame was refused rather than clipped."
            )
        }
        encoder.setTexture(destination.texture, index: 2)
        encoder.setTexture(metal.luts.texture(for: program.lookIdentifier), index: 3)
        encoder.setTexture(metal.curves.texture(for: program.curveRows), index: 6)
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
        if project.colorMode == .appleLog {
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
        var result = CIImage(color: .black).cropped(to: bounds)
        var retained: [CVPixelBuffer] = []
        for track in project.timeline.tracks.reversed() where track.isEnabled {
            for case .text(let authored) in track.items where authored.placement.isEnabled {
                let relative = CMTimeSubtract(request.compositionTime, authored.placement.timelineStart.cmTime)
                guard relative >= .zero, relative < authored.placement.duration.cmTime else { continue }
                // Single conversion from composition time to clip-local animation time.
                // Preview and export reach this same line, so they cannot disagree.
                let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
                if let text = TextRenderer.image(
                    clip,
                    canvas: bounds.size,
                    authoredCanvas: SequenceComposition.previewRenderSize(
                        width: project.canvas.width,
                        height: project.canvas.height
                    )
                ) {
                    let filters: [VisualBlendMode: String] = [.normal: "CISourceOverCompositing", .multiply: "CIMultiplyBlendMode", .screen: "CIScreenBlendMode", .overlay: "CIOverlayBlendMode", .softLight: "CISoftLightBlendMode", .hardLight: "CIHardLightBlendMode", .darken: "CIDarkenBlendMode", .lighten: "CILightenBlendMode"]
                    result = text.applyingFilter(filters[clip.blendMode]!, parameters: [kCIInputBackgroundImageKey: result]).cropped(to: bounds)
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
               let incoming = project.timeline.videoClip(id: transition.incomingClipID) {
                let first = try renderedSDRClip(outgoing, request: request, instruction: instruction,
                                                project: project, bypass: bypass, bounds: bounds)
                let second = try renderedSDRClip(incoming, request: request, instruction: instruction,
                                                 project: project, bypass: bypass, bounds: bounds)
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
                guard !transitionedClipIDs.contains(authored.id) else { continue }
                guard TimelineEditing.activeClip(in: [authored], at: request.compositionTime) != nil else { continue }
                let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
                guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                    throw TimelineError.invalid("A layer frame is unavailable.")
                }
                let source: CVPixelBuffer
                let transform: CGAffineTransform
                var blendPartner: CVPixelBuffer?
                var blendAmount = 0.0
                if asset.stillImage != nil {
                    source = try stillFrame(asset.url)
                    transform = Self.transform(clip.transform, encoded: CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)), preferred: .identity, canvas: bounds.size)
                } else {
                    guard let id = instruction.trackIDs[clip.id], let frame = request.sourceFrame(byTrackID: id), let metadata = asset.videoMetadata else { throw TimelineError.invalid("A video layer frame is unavailable.") }
                    // Smooth retiming: cross-dissolve toward the next source
                    // frame by however far between the two this moment falls.
                    // Without it each source frame is simply held, which is the
                    // stepping that makes slow motion judder on footage that was
                    // not shot at a high frame rate.
                    source = frame
                    if clip.smoothsMotion,
                       let partnerID = instruction.blendTrackIDs[clip.id],
                       let partner = request.sourceFrame(byTrackID: partnerID),
                       let frameDuration = asset.frameDuration,
                       let compositionTime = try? TimelineTime(request.compositionTime),
                       let sourceTime = try? clip.sourceTime(at: compositionTime) {
                        blendPartner = partner
                        blendAmount = ClipSpeed.framePhase(
                            sourceTime: sourceTime,
                            sourceStart: clip.sourceRange.start,
                            frameDuration: frameDuration
                        )
                    }
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
                let frame = try masked(gradedFrame, with: clip.resolvedLayerMask)
                retained.append(frame)
                var image = CIImage(cvPixelBuffer: frame, options: [.colorSpace: colorSpace]).transformed(by: transform)
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)])
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
        bounds: CGRect
    ) throws -> (image: CIImage, retained: [CVPixelBuffer]) {
        guard let asset = project.assets.first(where: { $0.id == authored.assetID }) else {
            throw TimelineError.invalid("A transition source is unavailable.")
        }
        let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
        let source: CVPixelBuffer
        let transform: CGAffineTransform
        var blendPartner: CVPixelBuffer?
        var blendAmount = 0.0
        if asset.stillImage != nil {
            source = try stillFrame(asset.url)
            transform = Self.transform(clip.transform,
                encoded: CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)),
                preferred: .identity, canvas: bounds.size)
        } else {
            guard let id = instruction.trackIDs[clip.id],
                  let frame = request.sourceFrame(byTrackID: id),
                  let metadata = asset.videoMetadata else {
                throw TimelineError.invalid("A transition source frame is unavailable.")
            }
            source = frame
            if clip.smoothsMotion,
               let partnerID = instruction.blendTrackIDs[clip.id],
               let partner = request.sourceFrame(byTrackID: partnerID),
               let frameDuration = asset.frameDuration,
               let compositionTime = try? TimelineTime(request.compositionTime),
               let sourceTime = try? clip.sourceTime(at: compositionTime) {
                blendPartner = partner
                blendAmount = ClipSpeed.framePhase(sourceTime: sourceTime,
                    sourceStart: clip.sourceRange.start, frameDuration: frameDuration)
            }
            transform = Self.transform(clip.transform, metadata: metadata, canvas: bounds.size)
        }
        let masks = (try? TimelineTime(request.compositionTime))
            .map { clip.evaluatedMaskedGrades(at: $0) } ?? clip.resolvedMaskedGrades
        let gradedFrame = try blendPartner.map {
            try gradedBlend(source, $0, amount: blendAmount, settings: clip.gradeSettings,
                            masks: masks, bypass: bypass)
        } ?? graded(source, settings: clip.gradeSettings, masks: masks, bypass: bypass,
                    seconds: request.compositionTime.seconds)
        let frame = try masked(gradedFrame, with: clip.resolvedLayerMask)
        var image = CIImage(cvPixelBuffer: frame, options: [.colorSpace: colorSpace]).transformed(by: transform)
        image = image.applyingFilter("CIColorMatrix",
            parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)])
        return (image, [gradedFrame, frame])
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
            throw GradeLabError.unsupportedExport("This device could not build the HDR compositing pipeline.")
        }
        guard let output = request.renderContext.newPixelBuffer(),
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_64RGBAHalf,
              let destination = metal.packedTexture(from: output, pixelFormat: .rgba16Float) else {
            throw GradeLabError.unsupportedExport("The HDR compositor needs half-float render surfaces.")
        }
        let canvasSize = request.renderContext.size
        let canvases = try hdrCanvases(size: canvasSize, device: metal.device)
        guard let command = metal.commandQueue.makeCommandBuffer() else {
            throw GradeLabError.rendererInitializationFailed
        }
        command.label = "GradeLab HDR layers"

        // Start from opaque black in working space. A clear render pass is the
        // cheapest way to do that without a kernel that exists only to zero it.
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = canvases.0
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        command.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()

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

        // The same traversal order the SDR path uses, so the two cannot disagree
        // about which layer sits on top.
        for track in project.timeline.tracks.reversed() where track.isEnabled {
            for case .text(let authored) in track.items where authored.placement.isEnabled {
                let relative = CMTimeSubtract(request.compositionTime, authored.placement.timelineStart.cmTime)
                guard relative >= .zero, relative < authored.placement.duration.cmTime else { continue }
                let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
                try Self.requireNormalBlend(clip.blendMode)
                guard let image = TextRenderer.image(
                    clip,
                    canvas: canvasSize,
                    authoredCanvas: SequenceComposition.previewRenderSize(
                        width: project.canvas.width,
                        height: project.canvas.height
                    )
                ) else { continue }
                let buffer = try renderedSDRLayer(image, size: canvasSize, ci: ci)
                guard let texture = metal.packedTexture(from: buffer, pixelFormat: .bgra8Unorm) else {
                    throw GradeLabError.rendererInitializationFailed
                }
                retained.append(buffer); retained.append(texture)
                // Text is authored into canvas coordinates already, so it needs
                // no placement of its own — only the SDR→working conversion and
                // its own alpha.
                var layer = HDRLayerUniforms(
                    transform: .identity, sourceSize: canvasSize, canvasSize: canvasSize,
                    opacity: 1, sourceIsSDR: true, premultiplied: true)
                var mask = LayerMaskUniforms(nil)
                try compose(imagePipeline) { encoder in
                    encoder.setTexture(texture.texture, index: 0)
                    encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                    encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
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
                var outgoingLayer = HDRLayerUniforms(
                    transform: Self.transform(outgoingClip.transform, metadata: outgoingMetadata, canvas: canvasSize),
                    sourceSize: outgoingMetadata.encodedSize, canvasSize: canvasSize,
                    opacity: outgoingClip.opacity, sourceIsSDR: outgoingMetadata.transferFunction != "HLG")
                var incomingLayer = HDRLayerUniforms(
                    transform: Self.transform(incomingClip.transform, metadata: incomingMetadata, canvas: canvasSize),
                    sourceSize: incomingMetadata.encodedSize, canvasSize: canvasSize,
                    opacity: incomingClip.opacity, sourceIsSDR: incomingMetadata.transferFunction != "HLG")
                var outgoingMask = LayerMaskUniforms(outgoingClip.layerMask)
                var incomingMask = LayerMaskUniforms(incomingClip.layerMask)
                var uniforms = TransitionUniforms(transition, progress: progress, size: canvasSize)
                try compose(transitionPipeline) { encoder in
                    encoder.setTexture(outgoingTexture.texture, index: 0)
                    encoder.setTexture(incomingTexture.texture, index: 1)
                    encoder.setTexture(metal.luts.texture(for: outgoingProgram.lookIdentifier), index: 4)
                    encoder.setTexture(metal.luts.texture(for: incomingProgram.lookIdentifier), index: 5)
                    encoder.setTexture(metal.curves.texture(for: outgoingProgram.curveRows), index: 6)
                    encoder.setTexture(metal.curves.texture(for: incomingProgram.curveRows), index: 7)
                    encoder.setBytes(&outgoingGrade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                    encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
                    encoder.setBytes(&outgoingLayer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                    encoder.setBytes(&outgoingMask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                    encoder.setBytes(&incomingGrade, length: MemoryLayout<GradeUniforms>.stride, index: 4)
                    encoder.setBytes(&incomingLayer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 5)
                    encoder.setBytes(&incomingMask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 6)
                    encoder.setBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 7)
                    outgoingLocals.bind(encoder, index: LocalGradeStack.bufferIndex)
                    incomingLocals.bind(encoder, index: LocalGradeStack.incomingBufferIndex)
                }
                transitionedClipIDs = [outgoing.id, incoming.id]
            }
            for case .video(let authored) in track.items where authored.placement.isEnabled {
                guard !transitionedClipIDs.contains(authored.id) else { continue }
                guard TimelineEditing.activeClip(in: [authored], at: request.compositionTime) != nil else { continue }
                let clip = (try? TimelineTime(request.compositionTime)).map { authored.evaluated(at: $0) } ?? authored
                try Self.requireNormalBlend(clip.blendMode)
                guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                    throw TimelineError.invalid("A layer frame is unavailable.")
                }
                if asset.stillImage != nil {
                    let still = try stillFrame(asset.url)
                    let size = CGSize(width: CVPixelBufferGetWidth(still), height: CVPixelBufferGetHeight(still))
                    guard let texture = metal.packedTexture(from: still, pixelFormat: .bgra8Unorm) else {
                        throw GradeLabError.rendererInitializationFailed
                    }
                    retained.append(texture)
                    var layer = HDRLayerUniforms(
                        transform: Self.transform(clip.transform, encoded: size, preferred: .identity, canvas: canvasSize),
                        sourceSize: size, canvasSize: canvasSize,
                        opacity: clip.opacity, sourceIsSDR: true, premultiplied: false)
                    var mask = LayerMaskUniforms(clip.layerMask)
                    try compose(imagePipeline) { encoder in
                        encoder.setTexture(texture.texture, index: 0)
                        encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                        encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                    }
                    continue
                }
                guard let id = instruction.trackIDs[clip.id],
                      let frame = request.sourceFrame(byTrackID: id),
                      let metadata = asset.videoMetadata else {
                    throw TimelineError.invalid("A video layer frame is unavailable.")
                }
                guard let texture = metal.packedTexture(from: frame, pixelFormat: .rgba16Float) else {
                    throw GradeLabError.unsupportedExport("An HDR source frame did not arrive as half-float.")
                }
                retained.append(texture)
                // Measured: a custom compositor is handed each source in its OWN
                // encoding, relabelled but not converted — an HLG file arrives as
                // the HLG signal, a Rec.709 file as Rec.709. The direct preview
                // path gets AVFoundation's conversion for free; this one has to
                // do it, which is what `sourceIsSDR` selects in the kernel.
                let sourceIsSDR = metadata.transferFunction != "HLG"
                var partnerTexture = texture
                var blendAmount = 0.0
                if clip.smoothsMotion,
                   let partnerID = instruction.blendTrackIDs[clip.id],
                   let partnerFrame = request.sourceFrame(byTrackID: partnerID),
                   let partner = metal.packedTexture(from: partnerFrame, pixelFormat: .rgba16Float),
                   let frameDuration = asset.frameDuration,
                   let compositionTime = try? TimelineTime(request.compositionTime),
                   let sourceTime = try? clip.sourceTime(at: compositionTime) {
                    retained.append(partner)
                    partnerTexture = partner
                    blendAmount = ClipSpeed.framePhase(
                        sourceTime: sourceTime,
                        sourceStart: clip.sourceRange.start,
                        frameDuration: frameDuration
                    )
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
                    opacity: clip.opacity, blendAmount: blendAmount, sourceIsSDR: sourceIsSDR)
                var mask = LayerMaskUniforms(clip.layerMask)
                let lut = metal.luts.texture(for: program.lookIdentifier)
                let curveLUT = metal.curves.texture(for: program.curveRows)
                let locals = program.locals
                try compose(videoPipeline) { encoder in
                    encoder.setTexture(texture.texture, index: 0)
                    encoder.setTexture(partnerTexture.texture, index: 1)
                    encoder.setTexture(lut, index: 4)
                    encoder.setTexture(curveLUT, index: 6)
                    encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                    encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
                    encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                    encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                    locals.bind(encoder)
                }
            }
        }

        // Finishing effects, in working space, before the signal conversion: a
        // glow is light adding to light, and adding it after the transfer curve
        // would weight it by a non-linear function of brightness.
        if let effects, let effectGrade = topmostVideoGrade,
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
            "Blend modes other than Normal are not available in HDR projects yet. They are defined on 0-1 values, and an HDR image is not."
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

    private func stillFrame(_ url: URL) throws -> CVPixelBuffer {
        if let cached = stillFrames[url] { return cached }
        guard let ci, var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .colorSpace: colorSpace]) else {
            throw TimelineError.invalid("The image could not be decoded.")
        }
        let factor = min(1, 4096/max(image.extent.width, image.extent.height))
        image = image.transformed(by: .init(scaleX: factor, y: factor))
        image = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw GradeLabError.rendererInitializationFailed }
        ci.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
        if stillFrames.count >= 4 { stillFrames.removeAll() }
        stillFrames[url] = buffer
        return buffer
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
        if appleLogRenderer == nil { appleLogRenderer = try AppleLogLayerRenderer(context: metal, prebuilt: resources?.pipelines) }
        guard let renderer = appleLogRenderer, let command = metal.commandQueue.makeCommandBuffer() else {
            throw GradeLabError.rendererInitializationFailed
        }
        command.label = "GradeLab Apple Log layers"
        let size = request.renderContext.size
        let width = Int(size.width), height = Int(size.height)
        let surfaces = try renderer.canvases(width: width, height: height)
        var readIndex = 0
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = surfaces[0]
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let clearEncoder = command.makeRenderCommandEncoder(descriptor: clear) else {
            throw GradeLabError.rendererInitializationFailed
        }
        clearEncoder.endEncoding()
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
                   mask authoredMask: LayerMask?, program: GradeProgram, to destination: MTLTexture) throws {
            guard let texture = metal.packedTexture(from: buffer, pixelFormat: .bgra8Unorm) else {
                throw GradeLabError.rendererInitializationFailed
            }
            retained.append(buffer); retained.append(texture)
            var layer = HDRLayerUniforms(transform: transform,
                sourceSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                canvasSize: size, opacity: opacity, sourceIsSDR: true, premultiplied: true)
            var mask = LayerMaskUniforms(authoredMask)
            var grade = program.uniforms
            try renderer.encode("compositeImageAppleLog", into: command, width: width, height: height) { encoder in
                encoder.setTexture(texture.texture, index: 0)
                encoder.setTexture(destination, index: 2)
                encoder.setTexture(metal.luts.texture(for: program.lookIdentifier), index: 3)
                encoder.setTexture(metal.curves.texture(for: program.curveRows), index: 6)
                encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                program.locals.bind(encoder)
            }
        }

        func video(_ authored: VideoClip, to destination: MTLTexture) throws {
            let clip = authored.evaluated(at: time)
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
                throw TimelineError.invalid("A layer source is unavailable.")
            }
            let sourceSize: CGSize
            let still: CVPixelBuffer?
            if asset.stillImage != nil {
                let frame = try stillFrame(asset.url)
                still = frame
                sourceSize = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
            } else {
                still = nil
                guard let metadata = asset.videoMetadata else { throw TimelineError.invalid("Missing video metadata.") }
                sourceSize = metadata.encodedSize
            }
            var program = GradeProgram(settings: clip.gradeSettings, masks: clip.evaluatedMaskedGrades(at: time),
                                       bypass: bypass, aspect: sourceSize.maskAspect)
            program.setGrainSeed(request.compositionTime.seconds)
            topmostGrade = program.uniforms
            if let still {
                try image(still, transform: Self.transform(clip.transform, encoded: sourceSize,
                          preferred: .identity, canvas: size), opacity: clip.opacity,
                          mask: clip.layerMask, program: program, to: destination)
                return
            }
            guard let metadata = asset.videoMetadata, let id = instruction.trackIDs[clip.id],
                  let frame = request.sourceFrame(byTrackID: id),
                  CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                  let textures = PixelBufferTextures(pixelBuffer: frame, context: metal),
                  case .biPlanar(_, let luma, _, let chroma) = textures.storage else {
                throw GradeLabError.unsupportedExport("Apple Log layers require untouched full-range 10-bit 4:2:2 source frames.")
            }
            retained.append(textures)
            let profile = metadata.logProfileIdentifier.map(SourceColorProfile.fromLogIdentifier)
            if let profile, profile != .appleLog {
                throw GradeLabError.unsupportedExport("This Log profile is not supported in Apple Log layers.")
            }
            if profile == nil, metadata.transferFunction == "HLG" {
                throw GradeLabError.unsupportedExport("HLG video cannot be interpreted as Rec.709 in an Apple Log timeline.")
            }
            var partnerLuma = luma, partnerChroma = chroma
            var amount = 0.0
            if clip.smoothsMotion, let partnerID = instruction.blendTrackIDs[clip.id],
               let partnerFrame = request.sourceFrame(byTrackID: partnerID),
               let partner = PixelBufferTextures(pixelBuffer: partnerFrame, context: metal),
               case .biPlanar(_, let y, _, let c) = partner.storage,
               let frameDuration = asset.frameDuration {
                retained.append(partner)
                partnerLuma = y; partnerChroma = c
                amount = ClipSpeed.framePhase(sourceTime: try clip.sourceTime(at: time),
                    sourceStart: clip.sourceRange.start, frameDuration: frameDuration)
            }
            var layer = HDRLayerUniforms(transform: Self.transform(clip.transform, metadata: metadata, canvas: size),
                sourceSize: sourceSize, canvasSize: size, opacity: clip.opacity,
                blendAmount: amount, sourceIsSDR: profile != .appleLog)
            var mask = LayerMaskUniforms(clip.layerMask)
            var grade = program.uniforms
            var yuv = YUVUniforms.make(for: frame, fallbackMatrix: metadata.yCbCrMatrix)
            try renderer.encode("compositeVideoAppleLog", into: command, width: width, height: height) { encoder in
                encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
                encoder.setTexture(destination, index: 2)
                encoder.setTexture(metal.luts.texture(for: program.lookIdentifier), index: 3)
                encoder.setTexture(partnerLuma, index: 4); encoder.setTexture(partnerChroma, index: 5)
                encoder.setTexture(metal.curves.texture(for: program.curveRows), index: 6)
                encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
                encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
                encoder.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
                program.locals.bind(encoder)
            }
        }

        for track in project.timeline.tracks.reversed() where track.isEnabled {
            for case .text(let authored) in track.items where authored.placement.isEnabled {
                let relative = CMTimeSubtract(request.compositionTime, authored.placement.timelineStart.cmTime)
                guard relative >= .zero, relative < authored.placement.duration.cmTime else { continue }
                let clip = authored.evaluated(at: time)
                guard let text = TextRenderer.image(
                    clip,
                    canvas: size,
                    authoredCanvas: SequenceComposition.previewRenderSize(
                        width: project.canvas.width,
                        height: project.canvas.height
                    )
                ) else { continue }
                let buffer = try renderedSDRLayer(text, size: size, ci: ci)
                try image(buffer, transform: .identity, opacity: 1, mask: nil,
                    program: GradeProgram(settings: .neutral, bypass: true, aspect: size.maskAspect), to: surfaces[2])
                try blend(surfaces[2], mode: clip.blendMode)
            }
            var transitioned = Set<UUID>()
            if let transition = project.timeline.transitions.first(where: {
                $0.enabled && $0.progress(at: request.compositionTime) != nil &&
                project.timeline.videoClip(id: $0.outgoingClipID)?.placement.trackID == track.id
            }), let outgoing = project.timeline.videoClip(id: transition.outgoingClipID),
               let incoming = project.timeline.videoClip(id: transition.incomingClipID),
               let progress = transition.progress(at: request.compositionTime) {
                try video(outgoing, to: surfaces[2])
                try video(incoming, to: surfaces[3])
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
                guard !transitioned.contains(clip.id),
                      TimelineEditing.activeClip(in: [clip], at: request.compositionTime) != nil else { continue }
                try video(clip, to: surfaces[2])
                try blend(surfaces[2], mode: clip.blendMode)
            }
        }
        if let grade = topmostGrade, FilmEffectsStage.isActive(grade) {
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
            throw GradeLabError.unsupportedExport("Apple Log layers need BGRA preview or 10-bit 4:2:2 export surfaces.")
        }
        // Composition-wide tags can relabel decoder inputs. Output tags belong
        // here, after the one and only Apple display transform has run.
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferRemoveAttachment(output, kCVImageBufferLogTransferFunctionKey)
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        guard command.status == .completed else {
            throw GradeLabError.exportFailed(command.error?.localizedDescription ?? "Apple Log compositing failed.")
        }
        request.finish(withComposedVideoFrame: output)
    }
}
