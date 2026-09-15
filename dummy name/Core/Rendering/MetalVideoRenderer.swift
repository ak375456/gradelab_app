@preconcurrency import CoreMedia
@preconcurrency import MetalKit
import UIKit
@preconcurrency import CoreVideo
import QuartzCore
import simd

final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private struct Vertex {
        var position: SIMD2<Float>
        var textureCoordinate: SIMD2<Float>
    }

    private let context: MetalContext
    /// Shared with look-preview rendering so both use one device and LUT cache.
    var metalContext: MetalContext { context }
    private let frameProvider: any PreviewFrameSource
    private let yuvPipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState
    /// Only built for HDR projects; nil keeps SDR projects on exactly the
    /// pipelines they used before this work.
    private let hdrPipeline: MTLRenderPipelineState?
    /// Downsamples a decoded frame for the look strip. Built once, lazily, and
    /// only if the device can make it; nil simply means the strip falls back to
    /// reading a frame from the file.
    private lazy var downsamplePipeline: MTLComputePipelineState? = {
        guard let function = context.library.makeFunction(name: "gradeExportBGRA") else { return nil }
        return try? context.device.makeComputePipelineState(function: function)
    }()
    /// Spatial finishing effects. Built on first use and released when nothing
    /// needs them, so a project with no effects pays nothing for them.
    private lazy var effectsStage: FilmEffectsStage? = FilmEffectsStage(context: context)
    private lazy var gradeToTexture: [String: MTLComputePipelineState] = {
        var built: [String: MTLComputePipelineState] = [:]
        for name in ["gradeToTextureYUV", "gradeToTextureBGRA", "gradeToTextureHDR", "gradeToTextureAppleLog"] {
            // Through the specialisation helper even for Apple Log: the Apple
            // Log kernel references the Log 2 function constant, and Metal
            // refuses to build a pipeline from a function that carries one
            // unless constant values are supplied.
            if let state = AppleLogSpecialization.computePipeline(
                name, isLog2: false, library: context.library, device: context.device) {
                built[name] = state
            }
        }
        // The Apple Log 2 variant of the same kernel, specialised by function
        // constant. Built only for a Log 2 project, so an Apple Log or SDR
        // project pays nothing for a format it will never open.
        if colorMode == .appleLog2,
           let state = AppleLogSpecialization.computePipeline(
               "gradeToTextureAppleLog", isLog2: true,
               library: context.library, device: context.device) {
            built[AppleLogSpecialization.key("gradeToTextureAppleLog", isLog2: true)] = state
        }
        return built
    }()
    private lazy var presentPipelines: [Bool: MTLRenderPipelineState] = {
        var built: [Bool: MTLRenderPipelineState] = [:]
        guard let vertex = context.library.makeFunction(name: "videoVertex") else { return built }
        for hdr in [false, true] {
            let name = hdr ? "presentFragmentHDR" : "presentFragmentSDR"
            guard let fragment = context.library.makeFunction(name: name) else { continue }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "GradeLab \(name)"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = hdr ? Self.hdrDrawableFormat : .bgra8Unorm
            if let state = try? context.device.makeRenderPipelineState(descriptor: descriptor) {
                built[hdr] = state
            }
        }
        return built
    }()
    private lazy var appleLogPresentPipeline: MTLRenderPipelineState? = {
        guard let vertex = context.library.makeFunction(name: "videoVertex"),
              let fragment = context.library.makeFunction(name: "presentFragmentAppleLog") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? context.device.makeRenderPipelineState(descriptor: descriptor)
    }()
    private var effectTextures: (MTLTexture, MTLTexture)?
    /// Set for still-image projects: the geometry the spatial finishing effects
    /// are rendered in.
    ///
    /// Video renders them at the drawable's size, which is right for video: the
    /// picture on screen is the only thing that exists, and it is re-made every
    /// frame. A photograph is different. The same grade has to produce the same
    /// glow in a preview a few hundred points wide and in a 48 MP export, so for
    /// stills the effects run in the picture's own geometry, at a fixed
    /// reference size, and the blur is built at a fixed long edge. Its radius is
    /// then a constant fraction of the photograph rather than a fraction of
    /// whatever surface happened to be handy — which is also what lets the
    /// export composite whole-image glows onto individual tiles.
    private var stillEffectSize: CGSize?

    /// Marks this renderer as showing a still of `imageSize`, or nil for video.
    func setStillGeometry(imageSize: CGSize?) {
        stateLock.lock()
        let resolved = imageSize.map { StillEffectGeometry.referenceSize(for: $0) }
        if stillEffectSize != resolved {
            stillEffectSize = resolved
            effectTextures = nil
            revision &+= 1
        }
        stateLock.unlock()
    }

    /// Two frame-sized surfaces for the effects stage: the graded frame and the
    /// finished one. Sized to the DRAWABLE, not to the video — the preview only
    /// ever shows drawable-sized pixels, and every effect radius is a fraction
    /// of the frame rather than a pixel count, so a 4K export and a phone-sized
    /// preview get the same look from the same numbers.
    private func effectSurfaces(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let existing = effectTextures, existing.0.width == width, existing.0.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let first = context.device.makeTexture(descriptor: descriptor),
              let second = context.device.makeTexture(descriptor: descriptor) else { return nil }
        effectTextures = (first, second)
        return (first, second)
    }

    /// Grades the frame into a texture and runs the spatial stage over it.
    /// Returns the finished frame, or nil to fall back to the direct path.
    private func effectedFrame(
        textures: PixelBufferTextures,
        size: (width: Int, height: Int),
        grade: inout GradeUniforms,
        locals: LocalGradeStack,
        yuv: inout YUVUniforms,
        hdr: inout HDRDisplayUniforms,
        lut: MTLTexture?,
        curveLUT: MTLTexture?,
        command: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let stage = effectsStage,
              let surfaces = effectSurfaces(width: size.width, height: size.height) else { return nil }
        let name: String
        switch textures.storage {
        case .biPlanar: name = colorMode.isAppleLog && !composited
            ? AppleLogSpecialization.key("gradeToTextureAppleLog", isLog2: colorMode == .appleLog2)
            : "gradeToTextureYUV"
        case .bgra: name = "gradeToTextureBGRA"
        case .linearHalf: name = "gradeToTextureHDR"
        }
        guard let pipeline = gradeToTexture[name],
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        switch textures.storage {
        case .biPlanar(_, let luma, _, let chroma):
            encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
            encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        case .bgra(_, let texture):
            encoder.setTexture(texture, index: 0)
        case .linearHalf(_, let texture):
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        }
        encoder.setTexture(surfaces.0, index: 2)
        encoder.setTexture(lut, index: 3)
        encoder.setTexture(curveLUT, index: 6)
        encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        locals.bind(encoder)
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, size.width))
        encoder.dispatchThreads(
            MTLSize(width: size.width, height: size.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, size.height)),
                depth: 1))
        encoder.endEncoding()
        stateLock.lock(); let isStill = stillEffectSize != nil; stateLock.unlock()
        guard stage.encode(source: surfaces.0, destination: surfaces.1, grade: grade,
                           workingSpace: colorMode.isHDR || (colorMode.isAppleLog && !composited),
                           blurLongEdge: isStill ? StillEffectGeometry.blurLongEdge : nil,
                           into: command) else { return nil }
        return surfaces.1
    }
    let colorMode: ProjectColorMode
    /// Last headroom seen during draw. iOS posts no notification when headroom
    /// changes, so it is re-read every frame rather than cached across frames.
    /// 10-bit packed, the format Apple documents for an HLG-tagged layer.
    static let hdrDrawableFormat: MTLPixelFormat = .bgr10a2Unorm
    private var displayHeadroom: Double = 1
    private var usesSDRFallback = true
    /// Called when the display's EDR state actually changes, so the preview
    /// badge reflects reality instead of going stale while playback is paused.
    var onDisplayStateChanged: (@Sendable () -> Void)?
    private let stateLock = NSLock()
    private var settings = GradeSettings.neutral
    /// Masked local grades for the single-clip path. The sequence path reads
    /// them off the active clip instead, exactly as it reads its grade.
    private var maskedGrades: [MaskedGradeLayer] = []
    /// Show Mask. Editor-only state: no export path can reach it, because the
    /// exporters build their own stack and never name a matte layer.
    private var maskMatte: MaskMatte = .none
    private var sequenceClips: [VideoClip]?

    func updateSequence(_ clips: [VideoClip]) {
        stateLock.lock(); defer { stateLock.unlock() }
        if sequenceClips != clips { sequenceClips = clips; revision &+= 1 }
    }

    /// Which mask, if any, the preview shows as a matte instead of a picture.
    func setMaskMatte(_ matte: MaskMatte) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard maskMatte != matte else { return }
        maskMatte = matte
        revision &+= 1
    }
    private var bypassGrade = false
    /// True while a workspace divider is under a finger.
    ///
    /// The spatial finishing effects render through two drawable-sized
    /// rgba16Float surfaces. A divider drag changes the drawable every frame,
    /// which would reallocate both of them sixty times a second - tens of
    /// megabytes per frame on an iPad. The preview drops to the single-pass
    /// path for the length of the drag and comes back the moment it ends, the
    /// same trade an NLE makes when it lowers preview quality while scrubbing.
    private var interactiveResize = false
    private var sourceSize: CGSize
    private let originalSize: CGSize
    /// Grading evaluates encoded UVs, even when presentation rotates the video.
    private let encodedMaskAspect: Double
    private var textureCoordinates: [SIMD2<Float>]
    private var originalCoordinates: [SIMD2<Float>] = []
    private var composited = false
    /// Apple Log preview pipeline, built only for Apple Log projects.
    private let appleLogPipeline: MTLRenderPipelineState?
    /// Apple's published Log-to-Rec.709 rendering LUT. Read from the cache on
    /// the render thread; loaded by `preloadLooks`.
    private var appleLogRenderingLUT: MTLTexture? {
        context.luts.renderingTexture(named: AppleLogRendering.rec709LUTResourceName)
    }

    /// Brackets a workspace resize. Cheap and idempotent; safe from the main
    /// thread while the render thread is drawing.
    func setInteractiveResize(_ active: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard interactiveResize != active else { return }
        interactiveResize = active
        // Ending one has to force a repaint, or the frame that finally brings
        // the effects back is skipped as unchanged.
        if !active { revision &+= 1 }
    }

    func setComposited(_ value: Bool, canvas: CGSize? = nil) {
        stateLock.lock(); defer { stateLock.unlock() }
        let size = value ? (canvas ?? sourceSize) : originalSize
        guard composited != value || sourceSize != size else { return }
        composited = value
        sourceSize = size
        textureCoordinates = value ? VideoTextureGeometry.textureCoordinates(encodedSize: sourceSize, preferredTransform: .identity) : originalCoordinates
        revision &+= 1
    }
    private let fallbackMatrix: String?
    private var droppedFrameCount = 0
    private var revision: UInt = 0
    /// Scopes analyse the frame this renderer is about to draw. They are owned
    /// here because this is the one place that already holds the decoded frame,
    /// the grade uniforms and the LUT for it — a second decoder or a second copy
    /// of the grading maths is exactly what would let a scope drift from the
    /// picture. Nothing here is reachable from the export path.
    private var scopeAnalyzerStorage: ScopeAnalyzer?
    private var scopeSettings = ScopeSettings()
    private var lastScopeTime: CFTimeInterval = 0
    private var scopedRevision: UInt = .max
    /// While playing, scopes update at about this rate rather than every frame.
    /// A grading change bumps `revision` and refreshes them immediately, so a
    /// paused adjustment is never waiting on this.
    private let scopeInterval: CFTimeInterval = 1.0 / 20.0
    private var renderedRevision: UInt = .max
    private var renderedBuffer: CVPixelBuffer?
    private var renderedSize: CGSize = .zero
    /// Last drawable size seen, so the eyedropper can work out where the
    /// letterbox is without a reference to the view.
    private var lastDrawableSize: CGSize = .zero
    private let inFlight = DispatchSemaphore(value: 2)

    convenience init(
        context: MetalContext,
        frameProvider: VideoFrameProvider,
        metadata: VideoMetadata,
        colorMode: ProjectColorMode = .sdr
    ) throws {
        try self.init(
            context: context,
            frameProvider: frameProvider,
            displaySize: metadata.displaySize,
            encodedSize: metadata.encodedSize,
            preferredTransform: metadata.preferredTransform.cgTransform,
            fallbackMatrix: metadata.yCbCrMatrix,
            colorMode: colorMode
        )
    }

    /// The geometry a source is presented with, without asking for a
    /// `VideoMetadata` to carry it.
    ///
    /// A still has no duration, no frame rate and no YCbCr matrix, so
    /// synthesising a `VideoMetadata` for it would mean inventing values the
    /// renderer would then read back. It needs four things — the displayed size,
    /// the encoded size, the transform between them, and a fallback matrix for
    /// untagged video — so it asks for those.
    init(
        context: MetalContext,
        frameProvider: any PreviewFrameSource,
        displaySize: CGSize,
        encodedSize: CGSize,
        preferredTransform: CGAffineTransform,
        fallbackMatrix: String?,
        colorMode: ProjectColorMode = .sdr
    ) throws {
        self.context = context
        self.colorMode = colorMode
        self.frameProvider = frameProvider
        sourceSize = displaySize
        originalSize = displaySize
        encodedMaskAspect = encodedSize.maskAspect
        self.fallbackMatrix = fallbackMatrix
        textureCoordinates = VideoTextureGeometry.textureCoordinates(
            encodedSize: encodedSize,
            preferredTransform: preferredTransform
        )

        guard let vertexFunction = context.library.makeFunction(name: "videoVertex"),
              let yuvFunction = context.library.makeFunction(name: "gradeFragmentYUV"),
              let bgraFunction = context.library.makeFunction(name: "gradeFragmentBGRA") else {
            throw GradeLabError.rendererInitializationFailed
        }

        func makePipeline(fragment: MTLFunction) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "GradeLab Preview"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try context.device.makeRenderPipelineState(descriptor: descriptor)
        }

        do {
            yuvPipeline = try makePipeline(fragment: yuvFunction)
            bgraPipeline = try makePipeline(fragment: bgraFunction)
            if colorMode.isHDR, let hdrFunction = context.library.makeFunction(name: "previewFragmentHDR") {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = "GradeLab HDR Preview"
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = hdrFunction
                descriptor.colorAttachments[0].pixelFormat = Self.hdrDrawableFormat
                hdrPipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
            } else {
                hdrPipeline = nil
            }
            // Apple Log renders to an ordinary Rec.709 drawable: the log
            // encoding is an input format, never something presented.
            if colorMode.isAppleLog,
               let logFunction = AppleLogSpecialization.makeFunction(
                   "previewFragmentAppleLog", isLog2: colorMode == .appleLog2,
                   library: context.library) {
                appleLogPipeline = try makePipeline(fragment: logFunction)
            } else {
                appleLogPipeline = nil
            }
        } catch {
            #if DEBUG
            print("Metal preview pipeline failed: \(error)")
            #endif
            throw GradeLabError.rendererInitializationFailed
        }
        super.init()
        originalCoordinates = textureCoordinates
    }

    /// Turns scope analysis on or off, and switches which scope is computed.
    ///
    /// Switching off releases the analyzer's textures and buffers outright: no
    /// pass is encoded and nothing is held for a panel nobody is looking at.
    func setScopes(_ settings: ScopeSettings) {
        stateLock.lock()
        let changed = scopeSettings != settings
        scopeSettings = settings
        if settings.isEnabled {
            if scopeAnalyzerStorage == nil {
                scopeAnalyzerStorage = ScopeAnalyzer(context: context, colorSpace: ScopeColorSpace(colorMode))
            }
        } else {
            scopeAnalyzerStorage?.release()
            scopeAnalyzerStorage = nil
        }
        if changed {
            // Repaint once so a scope that was just opened or switched fills in
            // straight away rather than at the next frame or slider move.
            revision &+= 1
            scopedRevision = .max
        }
        stateLock.unlock()
    }

    /// The live analyzer, for the scope view to read its density buffers from.
    var scopeAnalyzer: ScopeAnalyzer? {
        stateLock.lock(); defer { stateLock.unlock() }; return scopeAnalyzerStorage
    }

    /// Encodes one scope pass for the frame being drawn, subject to the throttle.
    private func analyzeScopes(
        pixelBuffer: CVPixelBuffer,
        grade: GradeUniforms,
        locals: LocalGradeStack,
        lut: MTLTexture?,
        curveLUT: MTLTexture?,
        revision: UInt
    ) {
        stateLock.lock()
        guard let analyzer = scopeAnalyzerStorage, scopeSettings.isEnabled else {
            stateLock.unlock(); return
        }
        // A still has one frame, so a pass that does not happen never gets
        // another chance on its own. `scopedRevision` is therefore only advanced
        // once a pass has actually been encoded, and a refused pass asks for
        // another draw. Video reaches the same place by simply decoding the next
        // frame.
        let now = CACurrentMediaTime()
        // A changed revision is a grading change, a look landing or the scope
        // itself being switched: those refresh at once. A changed frame during
        // playback goes through the throttle.
        guard revision != scopedRevision || now - lastScopeTime >= scopeInterval else {
            stateLock.unlock(); return
        }
        lastScopeTime = now
        let type = scopeSettings.type
        let intensity = scopeSettings.intensity
        stateLock.unlock()

        var attempted = false
        var analyzed = false
        if let lut, let curveLUT,
           let textures = PixelBufferTextures(pixelBuffer: pixelBuffer, context: context) {
            attempted = true
            analyzed = analyzer.analyze(
                textures: textures, pixelBuffer: pixelBuffer, type: type, grade: grade,
                locals: locals,
                yuv: YUVUniforms.make(for: pixelBuffer, fallbackMatrix: fallbackMatrix),
                hdr: HDRDisplayUniforms(), intensity: intensity, lut: lut, curveLUT: curveLUT)
        }
        stateLock.lock()
        if analyzed || !attempted {
            // Either it worked, or there was nothing to analyse from. The second
            // case must not ask for a retry: a frame this analyzer can never
            // read would spin the display link forever.
            scopedRevision = revision
        } else {
            // The analyzer was busy with the previous pass. Ask for one more
            // draw, so the scope catches up rather than sitting on a reading the
            // picture has moved past — a still has no next frame to correct it.
            self.revision &+= 1
        }
        stateLock.unlock()
    }

    /// A thumbnail-sized copy of the frame already on screen, for the look strip.
    ///
    /// Opening the look picker used to run `AVAssetImageGenerator` over the file
    /// again, which on heavy 4K footage means decoding a whole GOP for a picture
    /// the app has already decoded and is displaying. This reuses that frame
    /// instead: one downsampling pass, no second decode.
    ///
    /// Returns nil — and the caller falls back to the generator — when the frame
    /// on screen is not the plain SDR source the strip expects: a composited
    /// timeline has the clip's own grade already baked into it, and an HDR frame
    /// carries an HLG signal that would need a display transform to make a
    /// thumbnail of.
    func lookPreviewSource(maximumEdge: Int = 240) -> MTLTexture? {
        stateLock.lock()
        let isComposited = composited
        stateLock.unlock()
        guard !isComposited, !colorMode.isHDR,
              let buffer = frameProvider.latestFrame,
              let textures = PixelBufferTextures(pixelBuffer: buffer, context: context) else { return nil }
        // Video decodes to bi-planar YCbCr, a still to packed BGRA. Both are
        // downsampled by the shared grading kernels, bypassed, so the strip
        // compares looks against the decoded picture rather than against the
        // clip's current adjustments.
        let kernelName: String
        switch textures.storage {
        case .biPlanar: kernelName = "gradeExportBGRA"
        case .bgra: kernelName = "gradeToTextureBGRA"
        case .linearHalf: return nil
        }
        guard let pipeline = kernelName == "gradeExportBGRA"
                ? downsamplePipeline : gradeToTexture[kernelName] else { return nil }

        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let scale = min(1, Double(maximumEdge) / Double(max(width, height, 1)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded())),
            mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let output = context.device.makeTexture(descriptor: descriptor),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        // Bypassed: the strip compares looks against each other on an otherwise
        // neutral grade, so this is the decoded frame and nothing else.
        var grade = GradeUniforms(settings: .neutral, bypass: true)
        var yuv = YUVUniforms.make(for: buffer, fallbackMatrix: fallbackMatrix)
        encoder.setComputePipelineState(pipeline)
        switch textures.storage {
        case .biPlanar(_, let luma, _, let chroma):
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        case .bgra(_, let texture):
            encoder.setTexture(texture, index: 0)
        case .linearHalf:
            encoder.endEncoding(); return nil
        }
        encoder.setTexture(output, index: 2)
        encoder.setTexture(context.luts.texture(for: nil), index: 3)
        encoder.setTexture(context.curves.texture(for: nil), index: 6)
        encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        LocalGradeStack.empty.bind(encoder)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        return command.status == .completed ? output : nil
    }

    /// Frees the effect surfaces. They are frame-sized, so holding them for a
    /// project with no effects would be tens of megabytes for nothing.
    private func releaseEffectSurfacesIfIdle(_ active: Bool) {
        guard !active, effectTextures != nil else { return }
        effectTextures = nil
        effectsStage?.releaseResources()
    }

    /// Forces the next draw to repaint, used when a look finishes loading.
    func invalidate() {
        stateLock.lock(); revision &+= 1; stateLock.unlock()
    }

    /// Loads one look off the render thread, then asks for a repaint. Until it
    /// lands, `draw` binds the identity texture and the frame is simply ungraded
    /// by the LUT rather than wrong.
    func prepareLook(_ identifier: String) {
        guard !context.luts.isReady(identifier) else { return }
        Task.detached(priority: .userInitiated) { [context, weak self] in
            context.luts.prepare(identifier)
            self?.invalidate()
        }
    }

    /// Drops a look from the texture cache after it is removed or replaced.
    func forgetLook(_ identifier: String) {
        context.luts.forget(identifier)
        invalidate()
    }

    /// Warms every bundled look shortly after the editor opens, so selecting one
    /// is instant.
    func preloadLooks() {
        let needsAppleLogRendering = colorMode.isAppleLog
        Task.detached(priority: .utility) { [context, weak self] in
            // Apple's rendering LUT first when it is needed: until it lands the
            // preview falls back to a plain Rec.709 transfer, which is a
            // different picture, so the sooner it is ready the better.
            if needsAppleLogRendering {
                context.luts.prepareRenderingLUT(named: AppleLogRendering.rec709LUTResourceName)
                self?.invalidate()
            }
            context.luts.preloadBundledLooks()
            self?.invalidate()
        }
    }

    func update(settings: GradeSettings, masks: [MaskedGradeLayer] = [], bypass: Bool) {
        stateLock.lock()
        if self.settings != settings || maskedGrades != masks || bypassGrade != bypass {
            revision &+= 1
        }
        self.settings = settings
        maskedGrades = masks
        bypassGrade = bypass
        let active = settings.advanced?.resolvedEffects.needsStage ?? false
        stateLock.unlock()
        releaseEffectSurfacesIfIdle(active)
    }

    func configure(_ view: MTKView) {
        view.device = context.device
        view.delegate = self
        // EDR needs a half-float drawable and an *extended* linear colorspace.
        // A non-extended colorspace clips to SDR no matter what the pixel format
        // is, which is the usual way this goes silently wrong.
        // (WWDC22 - Explore EDR on iOS.)
        view.colorPixelFormat = colorMode.isHDR && hdrPipeline != nil ? Self.hdrDrawableFormat : .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.018, 0.02, 0.024, 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.isOpaque = true
        if let layer = view.layer as? CAMetalLayer {
            if colorMode.isHDR, hdrPipeline != nil {
                // Present the HLG signal itself and let the system apply the
                // OOTF and the display's tone mapping - the same path Photos
                // uses. Doing the OOTF here as well double-counted it, which is
                // what made the preview first too flat and then too dark.
                layer.wantsExtendedDynamicRangeContent = true
                layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                if CAEDRMetadata.isAvailable {
                    layer.edrMetadata = .hlg
                }
            } else {
                layer.wantsExtendedDynamicRangeContent = false
                layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            }
        }
        stateLock.lock(); let isStill = stillEffectSize != nil; stateLock.unlock()
        view.accessibilityLabel = isStill
            ? "Image preview"
            : (colorMode.isHDR ? "HDR video preview" : "Video preview")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // A resized layer hands back fresh, empty drawables. Without this the skip test
        // ("same buffer, same revision, same size") can match again after the size returns
        // to its previous value — for example when a keyboard opens and closes — and the
        // preview would stay black until playback or a grade change forced a repaint.
        stateLock.lock(); revision &+= 1; stateLock.unlock()
    }

    func draw(in view: MTKView) {
        autoreleasepool {
            // Before the frame guard: with no decoded frame yet there is still a
            // display, and leaving headroom unread would pin the preview badge
            // to its pessimistic initial value.
            if colorMode.isHDR { updateHeadroom(for: view) }
            guard let pixelBuffer = frameProvider.pixelBuffer(forHostTime: CACurrentMediaTime()) else { return }
            stateLock.lock()
            lastDrawableSize = view.drawableSize
            let resizing = interactiveResize
            let currentRevision = revision
            let activeClip = sequenceClips.flatMap {
                TimelineEditing.activeClip(in: $0, at: frameProvider.presentationTime)
            }
            // Grading keyframes are evaluated here, at the presentation time of
            // the frame about to be drawn, so playback, a paused seek and a
            // timeline scrub all show the grade that moment actually has. The
            // authored clip is never touched: evaluation returns a copy.
            let frameTime = try? TimelineTime(frameProvider.presentationTime)
            let frameGrade = sequenceClips == nil
                ? settings
                : (activeClip.map { clip in
                    frameTime.map { clip.effectiveGrade(at: $0) } ?? clip.gradeSettings
                } ?? .neutral)
            // Masked local grades follow the grade they belong to: off the active
            // clip on a sequence, off the single graded clip otherwise. Evaluated
            // here so geometry keyframes land on the same frame the grade does.
            let frameMasks: [MaskedGradeLayer] = sequenceClips == nil
                ? maskedGrades
                : (activeClip.map { clip in
                    frameTime.map { clip.evaluatedMaskedGrades(at: $0) } ?? clip.resolvedMaskedGrades
                } ?? [])
            var program = GradeProgram(
                settings: frameGrade, masks: frameMasks,
                bypass: bypassGrade || composited,
                aspect: encodedMaskAspect, matte: maskMatte)
            program.setGrainSeed(frameProvider.presentationTime.seconds)
            var grade = program.uniforms
            let locals = program.locals
            stateLock.unlock()
            // Cache read only: never parses on the render thread. Falls back to
            // the identity texture, which cannot change a pixel.
            let lutTexture = context.luts.texture(for: program.lookIdentifier)
            // Cache read on the render thread, like the look above: only the
            // curve under the finger is ever re-sampled, and an unchanged grade
            // is one comparison. The stack holds the clip's own curves followed
            // by one block per masked layer.
            let curveTexture = context.curves.texture(for: program.curveRows)
            if renderedBuffer === pixelBuffer, renderedRevision == currentRevision,
               renderedSize == view.drawableSize { return }
            // Same frame, same grade, same LUT the picture is about to be drawn
            // with. Placed after the skip test so an unchanged paused frame
            // costs nothing, and before the preview's in-flight gate so a busy
            // preview does not starve the scope of the frame it already has.
            analyzeScopes(pixelBuffer: pixelBuffer, grade: grade, locals: locals,
                          lut: lutTexture, curveLUT: curveTexture, revision: currentRevision)
            guard inFlight.wait(timeout: .now()) == .success else { return }
            var submitted = false
            defer { if !submitted { inFlight.signal() } }
            if colorMode.isAppleLog, !composited, appleLogRenderingLUT == nil { return }
            guard let drawable = view.currentDrawable,
                  let renderPass = view.currentRenderPassDescriptor,
                  let textures = PixelBufferTextures(pixelBuffer: pixelBuffer, context: context),
                  let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                return
            }

            var yuv = YUVUniforms.make(for: pixelBuffer, fallbackMatrix: fallbackMatrix)
            var vertices = makeVertices(drawableSize: view.drawableSize)

            var hdrUniforms = HDRDisplayUniforms()
            var isHDRDraw = false

            let wantsEffects = FilmEffectsStage.isActive(grade) && !resizing
            stateLock.lock(); let stillSize = stillEffectSize; stateLock.unlock()
            // A still renders its effects in the picture's own geometry; video
            // keeps rendering them at the drawable, exactly as it always has.
            let effectSize = stillSize ?? view.drawableSize
            let effected: MTLTexture? = wantsEffects
                ? effectedFrame(
                    textures: textures,
                    size: (max(1, Int(effectSize.width)), max(1, Int(effectSize.height))),
                    grade: &grade, locals: locals, yuv: &yuv, hdr: &hdrUniforms,
                    lut: lutTexture, curveLUT: curveTexture, command: commandBuffer)
                : nil
            if wantsEffects, effected == nil { return }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

            // A spatial effect needs the graded frame as something it can read
            // neighbours from, so grading and presenting split into two passes.
            // With no spatial effect switched on, none of this runs and the
            // single-pass route below is exactly what it always was.
            if effected == nil, colorMode.isAppleLog, !composited, let appleLogPipeline,
               case .biPlanar(_, let luma, _, let chroma) = textures.storage {
                // Apple Log: its own input transform, then the same extended
                // range grading path HLG uses, then Apple's rendering LUT.
                encoder.setRenderPipelineState(appleLogPipeline)
                encoder.setFragmentTexture(luma, index: 0)
                encoder.setFragmentTexture(chroma, index: 1)
                encoder.setFragmentTexture(lutTexture, index: 3)
                encoder.setFragmentTexture(appleLogRenderingLUT, index: 4)
                encoder.setFragmentTexture(curveTexture, index: 6)
                encoder.setFragmentBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 1)
                locals.bindFragment(encoder)
            } else if effected == nil {
                switch textures.storage {
                case .biPlanar(_, let luma, _, let chroma):
                    encoder.setRenderPipelineState(yuvPipeline)
                    encoder.setFragmentTexture(luma, index: 0)
                    encoder.setFragmentTexture(chroma, index: 1)
                    encoder.setFragmentBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
                case .bgra(_, let texture):
                    encoder.setRenderPipelineState(bgraPipeline)
                    encoder.setFragmentTexture(texture, index: 0)
                case .linearHalf(_, let texture):
                    // Extended-range linear HDR: working-space conversion, the
                    // grading stage, then the display transform.
                    guard let hdrPipeline else { return }
                    isHDRDraw = true
                    encoder.setRenderPipelineState(hdrPipeline)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 1)
                    encoder.setFragmentTexture(lutTexture, index: 3)
                    encoder.setFragmentTexture(curveTexture, index: 6)
                    locals.bindFragment(encoder)
                }
            } else if let effected, colorMode.isAppleLog, !composited, let present = appleLogPresentPipeline {
                encoder.setRenderPipelineState(present)
                encoder.setFragmentTexture(effected, index: 0)
                encoder.setFragmentTexture(appleLogRenderingLUT, index: 4)
            } else if let effected, let present = presentPipelines[colorMode.isHDR] {
                isHDRDraw = colorMode.isHDR
                encoder.setRenderPipelineState(present)
                encoder.setFragmentTexture(effected, index: 0)
                if isHDRDraw {
                    encoder.setFragmentBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 0)
                }
            } else {
                encoder.endEncoding(); return
            }

            encoder.setVertexBytes(&vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
            if !isHDRDraw {
                encoder.setFragmentTexture(lutTexture, index: 3)
                encoder.setFragmentTexture(curveTexture, index: 6)
                encoder.setFragmentBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
                // `presentFragmentSDR` reads no stack, but the YUV and BGRA
                // grading fragments above do and this is their one shared bind.
                if effected == nil { locals.bindFragment(encoder) }
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [textures, inFlight, weak self] buffer in
                _ = textures
                if buffer.status == .error, let self {
                    self.stateLock.lock()
                    self.revision &+= 1
                    self.stateLock.unlock()
                }
                inFlight.signal()
            }
            renderedBuffer = pixelBuffer
            renderedRevision = currentRevision
            renderedSize = view.drawableSize
            submitted = true
            commandBuffer.commit()
        }
    }

    /// Re-reads the display's EDR headroom. iOS sends no notification when it
    /// changes - it moves with display brightness - so it is sampled per frame.
    /// A repaint is forced only when it moves enough to matter, to avoid
    /// invalidating every frame over sensor noise.
    private func updateHeadroom(for view: MTKView) {
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        let current = Double(screen.currentEDRHeadroom)
        let potential = Double(screen.potentialEDRHeadroom)
        // Apple's guidance: below ~1.5 there is no useful headroom, so render
        // the deliberately labelled SDR path rather than pretending otherwise.
        let fallback = potential < HDRColorSpace.minimumUsefulHeadroom
        guard abs(current - displayHeadroom) > 0.01 || fallback != usesSDRFallback else { return }
        stateLock.lock()
        displayHeadroom = current
        usesSDRFallback = fallback
        revision &+= 1
        let notify = onDisplayStateChanged
        stateLock.unlock()
        notify?()
    }

    /// What the preview is actually doing right now, for the editor to label.
    /// Reported rather than assumed: an SDR fallback must never be presented as
    /// showing HDR brightness.
    var previewState: (isHDR: Bool, headroom: Double) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (colorMode.isHDR && !usesSDRFallback, displayHeadroom)
    }

    // -----------------------------------------------------------------------
    // Eyedropper
    //
    // Samples the frame the preview is showing, graded, rather than reading
    // pixels back out of a screenshot of the view. A screenshot would carry the
    // compare overlay, the text canvas, the letterbox and whatever the display
    // did to the colour on the way to the screen; this is the picture itself.
    // -----------------------------------------------------------------------

    /// One graded colour from the current frame.
    ///
    /// - Parameter point: where the tap landed inside the preview view, as
    ///   0...1 from its top-left corner.
    /// - Returns: the colour in the same space the curve stage works in, or nil
    ///   if the tap was on the letterbox or no frame has been decoded yet.
    func sampleGradedColor(atViewPoint point: CGPoint) -> SIMD3<Float>? {
        stateLock.lock()
        let videoSize = sourceSize
        let coordinates = textureCoordinates
        stateLock.unlock()
        guard coordinates.count == 4, videoSize.width > 0, videoSize.height > 0 else { return nil }

        // The preview is aspect-fitted inside the view, so a tap on the
        // letterbox is not a tap on the picture.
        guard let rect = displayedVideoRect() else { return nil }
        guard rect.contains(point) else { return nil }
        let s = Float((point.x - rect.minX) / rect.width)
        let t = Float((point.y - rect.minY) / rect.height)
        // Texture coordinates are stored bottom-left, bottom-right, top-left,
        // top-right, and already carry the source's rotation and reflection, so
        // interpolating them is all the mapping a rotated clip needs.
        let top = coordinates[2] + (coordinates[3] - coordinates[2]) * s
        let bottom = coordinates[0] + (coordinates[1] - coordinates[0]) * s
        let uv = top + (bottom - top) * t

        guard let pixelBuffer = frameProvider.latestFrame,
              let textures = PixelBufferTextures(pixelBuffer: pixelBuffer, context: context) else { return nil }

        stateLock.lock()
        let activeClip = sequenceClips.flatMap {
            TimelineEditing.activeClip(in: $0, at: frameProvider.presentationTime)
        }
        let sampleTime = try? TimelineTime(frameProvider.presentationTime)
        let frameGrade = sequenceClips == nil
            ? settings
            : (activeClip.map { clip in
                sampleTime.map { clip.effectiveGrade(at: $0) } ?? clip.gradeSettings
            } ?? .neutral)
        let frameMasks: [MaskedGradeLayer] = sequenceClips == nil
            ? maskedGrades
            : (activeClip.map { clip in
                sampleTime.map { clip.evaluatedMaskedGrades(at: $0) } ?? clip.resolvedMaskedGrades
            } ?? [])
        let aspect = encodedMaskAspect
        stateLock.unlock()
        // The eyedropper has to sample the picture on screen, so it grades
        // through the masks too. It never asks for a matte: a matte has no hue
        // to pick.
        let program = GradeProgram(settings: frameGrade, masks: frameMasks,
                                   bypass: false, aspect: aspect)
        var grade = program.uniforms

        // Grading the whole frame at a fraction of its size costs a fraction of
        // a millisecond and reuses the pipelines the preview already built, so
        // the sampled colour is the same maths the picture went through.
        let long = 512
        let width = videoSize.width >= videoSize.height
            ? long : max(1, Int((CGFloat(long) * videoSize.width / videoSize.height).rounded()))
        let height = videoSize.width >= videoSize.height
            ? max(1, Int((CGFloat(long) * videoSize.height / videoSize.width).rounded())) : long

        let name: String
        switch textures.storage {
        case .biPlanar: name = colorMode.isAppleLog && !composited
            ? AppleLogSpecialization.key("gradeToTextureAppleLog", isLog2: colorMode == .appleLog2)
            : "gradeToTextureYUV"
        case .bgra: name = "gradeToTextureBGRA"
        case .linearHalf: name = "gradeToTextureHDR"
        }
        guard let pipeline = gradeToTexture[name] else { return nil }
        // 32-bit float so the readback needs no unpacking and no precision is
        // lost; it is written and copied, never filtered.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let destination = context.device.makeTexture(descriptor: descriptor),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        command.label = "GradeLab Eyedropper"
        encoder.setComputePipelineState(pipeline)
        var yuv = YUVUniforms.make(for: pixelBuffer, fallbackMatrix: fallbackMatrix)
        var hdr = HDRDisplayUniforms()
        switch textures.storage {
        case .biPlanar(_, let luma, _, let chroma):
            encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
            encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        case .bgra(_, let texture):
            encoder.setTexture(texture, index: 0)
        case .linearHalf(_, let texture):
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        }
        encoder.setTexture(destination, index: 2)
        encoder.setTexture(context.luts.texture(for: program.lookIdentifier), index: 3)
        encoder.setTexture(context.curves.texture(for: program.curveRows), index: 6)
        encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        program.locals.bind(encoder)
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height)),
                depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        guard command.status == .completed else { return nil }

        // Average a small neighbourhood. A single pixel of compressed video is
        // noisy enough that two taps a pixel apart could pick different hues.
        let centreX = Int((Double(uv.x) * Double(width - 1)).rounded())
        let centreY = Int((Double(uv.y) * Double(height - 1)).rounded())
        let radius = 1
        let originX = max(0, min(width - (radius * 2 + 1), centreX - radius))
        let originY = max(0, min(height - (radius * 2 + 1), centreY - radius))
        let side = min(radius * 2 + 1, min(width, height))
        var pixels = [Float](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buffer in
            destination.getBytes(
                buffer.baseAddress!,
                bytesPerRow: side * 4 * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(originX, originY, side, side),
                mipmapLevel: 0)
        }
        var total = SIMD3<Float>.zero
        for index in 0..<(side * side) {
            total += SIMD3(pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2])
        }
        let sample = total / Float(side * side)
        return sample.x.isFinite && sample.y.isFinite && sample.z.isFinite ? sample : nil
    }

    /// Where the picture sits inside the preview view, as 0...1 from its
    /// top-left. The same aspect fit `makeVertices` applies, so the two cannot
    /// disagree about which pixel is under a finger.
    func displayedVideoRect() -> CGRect? {
        stateLock.lock()
        let video = sourceSize
        let drawable = lastDrawableSize
        stateLock.unlock()
        guard video.width > 0, video.height > 0, drawable.width > 0, drawable.height > 0 else { return nil }
        let viewAspect = drawable.width / drawable.height
        let videoAspect = video.width / video.height
        let width = videoAspect > viewAspect ? 1 : videoAspect / viewAspect
        let height = videoAspect > viewAspect ? viewAspect / videoAspect : 1
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func makeVertices(drawableSize: CGSize) -> [Vertex] {
        let viewAspect = max(drawableSize.width, 1) / max(drawableSize.height, 1)
        let videoAspect = max(sourceSize.width, 1) / max(sourceSize.height, 1)
        let xScale: Float
        let yScale: Float
        if videoAspect > viewAspect {
            xScale = 1
            yScale = Float(viewAspect / videoAspect)
        } else {
            xScale = Float(videoAspect / viewAspect)
            yScale = 1
        }

        let positions = [
            SIMD2<Float>(-xScale, -yScale),
            SIMD2<Float>( xScale, -yScale),
            SIMD2<Float>(-xScale,  yScale),
            SIMD2<Float>( xScale,  yScale)
        ]
        return zip(positions, textureCoordinates).map(Vertex.init)
    }
}

/// Converts the complete AVAsset preferred transform (including either reflection axis)
/// into Metal texture coordinates ordered bottom-left, bottom-right, top-left, top-right.
enum VideoTextureGeometry {
    static func textureCoordinates(
        encodedSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> [SIMD2<Float>] {
        let width = encodedSize.width
        let height = encodedSize.height
        let determinant = preferredTransform.a * preferredTransform.d
            - preferredTransform.b * preferredTransform.c
        guard width > 0,
              height > 0,
              abs(determinant) > CGFloat.ulpOfOne else {
            return fallbackCoordinates
        }

        let presentationBounds = CGRect(
            origin: .zero,
            size: encodedSize
        )
        .applying(preferredTransform)
        .standardized
        guard presentationBounds.width > 0, presentationBounds.height > 0 else {
            return fallbackCoordinates
        }

        let displayedCorners = [
            CGPoint(x: presentationBounds.minX, y: presentationBounds.maxY),
            CGPoint(x: presentationBounds.maxX, y: presentationBounds.maxY),
            CGPoint(x: presentationBounds.minX, y: presentationBounds.minY),
            CGPoint(x: presentationBounds.maxX, y: presentationBounds.minY)
        ]
        let inverse = preferredTransform.inverted()
        return displayedCorners.map { corner in
            let source = corner.applying(inverse)
            return SIMD2(
                Float(min(max(source.x / width, 0), 1)),
                Float(min(max(source.y / height, 0), 1))
            )
        }
    }

    private static let fallbackCoordinates: [SIMD2<Float>] = [
        .init(0, 1), .init(1, 1), .init(0, 0), .init(1, 0)
    ]
}
