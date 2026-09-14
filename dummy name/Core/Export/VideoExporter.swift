@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Metal

final class VideoExporter: @unchecked Sendable {
    typealias StateHandler = @MainActor @Sendable (ExportState) -> Void

    /// Everything one frame needs from a grade: the uniform block, plus which
    /// creative look to bind. The identifier cannot live inside `GradeUniforms`,
    /// which is a fixed-layout block of floats shared with the shader.
    private struct FrameGrade {
        var uniforms: GradeUniforms
        let lookIdentifier: String?
        /// The curve control points, for the same reason: they resolve to a
        /// lookup texture, which cannot live inside the uniform block either.
        /// One block for the clip's own curves, then one per masked local grade.
        let curves: [AdvancedCurves?]
        /// The clip's masked local grades. Never carries a matte: Show Mask is
        /// an editor state and this type has no way to express one, so a matte
        /// cannot reach a file.
        let locals: LocalGradeStack

        init(settings: GradeSettings, masks: [MaskedGradeLayer] = [], bypass: Bool,
             aspect: Double = 1) {
            let program = GradeProgram(settings: settings, masks: masks,
                                       bypass: bypass, aspect: aspect)
            uniforms = program.uniforms
            lookIdentifier = program.lookIdentifier
            curves = program.curveRows
            locals = program.locals
        }
    }

    private let context: MetalContext
    private let computePipeline: MTLComputePipelineState
    /// Built lazily: 8-bit SDR exports never touch these.
    private let hdrPipeline: MTLComputePipelineState?
    private let sdr10Pipeline: MTLComputePipelineState?
    /// The colour mode of the export in flight. `render` branches on the source
    /// and destination formats, and an Apple Log frame is indistinguishable
    /// from a wide-SDR one by format alone — both are 10-bit 4:2:2 YCbCr — so
    /// the mode has to be carried rather than inferred.
    private var activeColorMode: ProjectColorMode = .sdr
    /// Apple Log to Rec.709, built on first use for an Apple Log export.
    private lazy var appleLogSDR10Pipeline: MTLComputePipelineState? = {
        guard let function = context.library.makeFunction(name: "gradeExportAppleLogSDR10") else { return nil }
        return try? context.device.makeComputePipelineState(function: function)
    }()
    private let stateLock = NSLock()
    private var activeSession: ExportSession?

    init(context: MetalContext) throws {
        self.context = context
        guard let function = context.library.makeFunction(name: "gradeExportBGRA") else {
            throw GradeLabError.rendererInitializationFailed
        }
        do {
            computePipeline = try context.device.makeComputePipelineState(function: function)
            hdrPipeline = try context.library.makeFunction(name: "gradeExportHDR").map {
                try context.device.makeComputePipelineState(function: $0)
            }
            sdr10Pipeline = try context.library.makeFunction(name: "gradeExportSDR10").map {
                try context.device.makeComputePipelineState(function: $0)
            }
        } catch {
            #if DEBUG
            print("Metal export pipeline failed: \(error)")
            #endif
            throw GradeLabError.rendererInitializationFailed
        }
    }

    func capabilities(
        for asset: VideoAsset,
        configuration: ExportConfiguration = .maximumQuality
    ) async -> ExportCapabilities {
        await ExportCapabilityChecker().check(asset: asset, configuration: configuration)
    }

    /// Streams decoded NV12 frames through Metal and returns the completed movie URL.
    /// State callbacks are delivered on the main actor for direct UI consumption.
    func export(
        asset: VideoAsset,
        settings: GradeSettings,
        configuration: ExportConfiguration = .maximumQuality,
        project: VideoProject? = nil,
        outputURL: URL? = nil,
        onStateChange: StateHandler? = nil
    ) async throws -> URL {
        let destinationURL = try makeDestinationURL(outputURL, configuration: configuration)
        let session = ExportSession(outputURL: destinationURL)
        try install(session)
        defer { removeActiveSession(ifMatching: session) }

        return try await withTaskCancellationHandler {
            do {
                await onStateChange?(.preparing)
                try session.checkCancellation()
                try ExportMediaSettings.validate(configuration)
                let source: ExportSourceInfo
                if let project { source = try await SequenceComposition.build(project: project, context: self.context).source }
                else { source = try await ExportSourceInspector.inspect(asset) }
                try session.checkCancellation()

                let pipeline = try makeMediaPipeline(
                    source: source,
                    configuration: configuration,
                    destinationURL: destinationURL
                )
                session.attach(reader: pipeline.reader, writer: pipeline.writer)
                try session.checkCancellation()

                activeColorMode = source.colorMode
                if source.colorMode == .appleLog {
                    // Parsed once, off the frame loop: Apple's rendering LUT is
                    // 65 cubed.
                    context.luts.prepareRenderingLUT(named: AppleLogRendering.rec709LUTResourceName)
                }
                try start(pipeline, at: source.sessionStartTime)
                let initialProgress = ExportProgress.initial(
                    totalDuration: source.videoDurationSeconds,
                    presentationTime: source.videoTimeRange.start.seconds
                )
                await onStateChange?(.exporting(initialProgress))

                let finalProgress = try await encode(
                    pipeline: pipeline,
                    source: source,
                    settings: settings,
                    configuration: configuration,
                    session: session,
                    onStateChange: onStateChange
                )
                try session.checkCancellation()
                await onStateChange?(.finishing(finalProgress))

                var endTime = CMTimeRangeGetEnd(source.videoTimeRange)
                for audio in source.audioTracks {
                    let audioEnd = CMTimeRangeGetEnd(audio.timeRange)
                    if CMTimeCompare(audioEnd, endTime) > 0 { endTime = audioEnd }
                }
                pipeline.writer.endSession(atSourceTime: endTime)
                await pipeline.writer.finishWriting()
                try session.checkCancellation()
                guard pipeline.writer.status == .completed else {
                    throw writerFailure(pipeline.writer)
                }

                context.flushTextureCache()

                // Open the file we just wrote and confirm it actually contains
                // what was asked for. An encoder can accept a configuration and
                // still produce something else; reporting the request as the
                // result would be reporting a guess as a measurement.
                let report = try await ExportOutputInspector.verify(
                    destinationURL, expecting: source.colorMode
                )
                #if DEBUG
                print("Export verified: \(report.summary)")
                #endif

                session.markCompleted()
                await onStateChange?(.completed(destinationURL))
                return destinationURL
            } catch {
                let resolvedError = resolve(error, session: session)
                session.cancelIO()
                context.flushTextureCache()
                await removeIncompleteOutput(at: destinationURL)

                switch resolvedError {
                case .exportCancelled:
                    await onStateChange?(.cancelled)
                default:
                    await onStateChange?(.failed(resolvedError.localizedDescription))
                }
                throw resolvedError
            }
        } onCancel: {
            session.requestCancellation()
        }
    }

    /// Cancels the currently active export. It is safe to call from UI code or a task
    /// cancellation handler; the in-flight export performs final file cleanup.
    func cancel() {
        stateLock.lock()
        let session = activeSession
        stateLock.unlock()
        session?.requestCancellation()
    }

    private func makeMediaPipeline(
        source: ExportSourceInfo,
        configuration: ExportConfiguration,
        destinationURL: URL
    ) throws -> MediaPipeline {
        let dimensions = configuration.dimensions(width: source.encodedWidth, height: source.encodedHeight)
        let fps = configuration.frameRate.value ?? source.nominalFrameRate
        guard ExportCapabilityProbe.hardwareHEVCIsSupported(
            width: dimensions.width,
            height: dimensions.height,
            expectedFrameRate: fps,
            videoBitRate: configuration.resolvedBitRate(width: dimensions.width, height: dimensions.height, fps: fps),
            codec: configuration.codec
        ) else {
            throw GradeLabError.unsupportedExport(
                "This device cannot encode the selected configuration. Try another codec or lower dimensions."
            )
        }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: source.asset)
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: configuration.resolvedContainer.fileType)
        } catch {
            #if DEBUG
            print("Could not create export reader/writer: \(error)")
            #endif
            throw GradeLabError.exportFailed("The export session could not be prepared.")
        }
        writer.shouldOptimizeForNetworkUse = configuration.optimizeForNetworkUse

        let videoOutput: AVAssetReaderOutput
        if let composition = source.videoComposition {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: source.compositionVideoTracks ?? [source.videoTrack], videoSettings: ExportMediaSettings.videoReaderSettings(colorMode: source.colorMode))
            output.videoComposition = composition
            videoOutput = output
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: source.videoTrack, outputSettings: ExportMediaSettings.videoReaderSettings(colorMode: source.colorMode))
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw GradeLabError.unsupportedExport(
                "The source video cannot be decoded as \(ExportMediaSettings.readerFormatDescription(colorMode: source.colorMode)) on this device."
            )
        }
        reader.add(videoOutput)

        let videoSettings = ExportMediaSettings.videoWriterSettings(
            source: source,
            configuration: configuration
        )
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw GradeLabError.unsupportedExport(
                "This device cannot apply the requested video export settings."
            )
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let sx = CGFloat(dimensions.width) / CGFloat(source.encodedWidth)
        let sy = CGFloat(dimensions.height) / CGFloat(source.encodedHeight)
        var transform = source.preferredTransform
        // Scale the presentation translation along its transformed output axes.
        transform.tx *= abs(transform.a) > abs(transform.c) ? sx : sy
        transform.ty *= abs(transform.b) > abs(transform.d) ? sx : sy
        videoInput.transform = transform
        if source.naturalTimeScale > 0 {
            videoInput.mediaTimeScale = source.naturalTimeScale
        }
        guard writer.canAdd(videoInput) else {
            throw GradeLabError.unsupportedExport(
                "This device cannot encode a video track at the requested dimensions."
            )
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: ExportMediaSettings.writerPixelBufferAttributes(
                source: source,
                configuration: configuration
            )
        )

        var audioPipelines: [AudioPipeline] = []
        audioPipelines.reserveCapacity(source.audioTracks.count)
        let audioSources = source.gradesBaked ? Array(source.audioTracks.prefix(1)) : source.audioTracks
        for (index, originalAudioSource) in audioSources.enumerated() {
            // A composited timeline is mixed to one stereo track; otherwise each
            // source track is preserved as its own.
            let audioSource: ExportAudioTrackInfo = source.gradesBaked
                ? .init(track: originalAudioSource.track, formatID: kAudioFormatLinearPCM,
                        sourceFormatDescription: nil,
                        sampleRate: 48_000, channelCount: 2,
                        channelLayout: nil, timeRange: source.videoTimeRange, naturalTimeScale: 48_000)
                : originalAudioSource

            // Decided BEFORE the reader is built. A spatial layout the AAC
            // encoder refuses folds the track down to stereo, and the reader has
            // to be asked for that same channel count — handing a stereo encoder
            // four channels of PCM is not something it can reconcile later.
            let settings = ExportMediaSettings.audioWriterSettings(
                source: audioSource,
                configuration: configuration,
                acceptedBy: writer
            )
            let encodedChannels = settings[AVNumberOfChannelsKey] as? Int ?? audioSource.channelCount

            let output: AVAssetReaderOutput
            let writerSourceFormatHint: CMFormatDescription?
            if source.gradesBaked {
                var readerSettings = ExportMediaSettings.audioReaderSettings()
                readerSettings[AVSampleRateKey] = 48_000
                readerSettings[AVNumberOfChannelsKey] = 2
                let mixed = AVAssetReaderAudioMixOutput(audioTracks: source.audioTracks.map(\.track), audioSettings: readerSettings)
                mixed.audioMix = source.audioMix
                // Match the preview: retimed audio keeps its pitch rather than
                // rising and falling with the rate.
                mixed.audioTimePitchAlgorithm = .spectral
                output = mixed
                writerSourceFormatHint = nil
            } else {
                let hasRetimedAudio = source.timelineClips?.contains(where: \.isRetimed) == true
                // Read native PCM when no mixing or retiming is needed. The
                // inspector validates its writer hint separately from the source
                // track's potentially contradictory spatial layout metadata.
                let readerSettings = ExportMediaSettings.audioReaderSettings(
                    sourceFormatID: audioSource.formatID,
                    sourceChannelCount: audioSource.channelCount,
                    encodedChannelCount: encodedChannels,
                    requiresTimePitchProcessing: hasRetimedAudio
                )
                let usesNativePCM = readerSettings == nil
                let track = AVAssetReaderTrackOutput(track: audioSource.track, outputSettings: readerSettings)
                if !usesNativePCM {
                    track.audioTimePitchAlgorithm = .spectral
                }
                output = track
                writerSourceFormatHint = usesNativePCM ? audioSource.sourceFormatDescription : nil
            }
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw GradeLabError.unsupportedExport(
                    "Audio track \(index + 1) cannot be decoded for preservation."
                )
            }
            reader.add(output)

            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                throw GradeLabError.unsupportedExport(
                    "Audio track \(index + 1) cannot be preserved as AAC with this configuration."
                )
            }
            guard encodedChannels <= 2 || settings[AVChannelLayoutKey] != nil else {
                // Belt and braces for the crash above: never hand the input
                // settings it will trap on, whatever `canApply` says.
                throw GradeLabError.unsupportedExport(
                    "Audio track \(index + 1) has \(encodedChannels) channels and no layout AAC can carry."
                )
            }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: settings,
                sourceFormatHint: writerSourceFormatHint
            )
            input.expectsMediaDataInRealTime = false
            // Audio inputs must keep AVAssetWriter's default mediaTimeScale.
            // AAC timing comes from the configured sample rate and the original
            // timestamps on appended audio samples, not a track timescale override.
            guard writer.canAdd(input) else {
                throw GradeLabError.unsupportedExport(
                    "Audio track \(index + 1) cannot be added to the output movie."
                )
            }
            writer.add(input)
            audioPipelines.append(AudioPipeline(
                output: output,
                input: input
            ))
        }

        return MediaPipeline(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            adaptor: adaptor,
            audio: audioPipelines
        )
    }

    private func start(_ pipeline: MediaPipeline, at sourceTime: CMTime) throws {
        guard pipeline.writer.startWriting() else {
            throw writerFailure(pipeline.writer)
        }
        pipeline.writer.startSession(atSourceTime: sourceTime)

        guard pipeline.reader.startReading() else {
            throw readerFailure(pipeline.reader)
        }
        guard pipeline.adaptor.pixelBufferPool != nil else {
            throw GradeLabError.exportFailed(
                "The video encoder could not allocate its Metal-compatible frame pool."
            )
        }
    }

    private func encode(
        pipeline: MediaPipeline,
        source: ExportSourceInfo,
        settings: GradeSettings,
        configuration: ExportConfiguration,
        session: ExportSession,
        onStateChange: StateHandler?
    ) async throws -> ExportProgress {
        var videoIsActive = true
        var audioIsActive = Array(repeating: true, count: pipeline.audio.count)
        var frameCount = 0
        var lastReportedFraction = -Double.infinity
        var finalProgress = ExportProgress.initial(
            totalDuration: source.videoDurationSeconds,
            presentationTime: source.videoTimeRange.start.seconds
        )
        let grade = FrameGrade(settings: settings, bypass: false)
        // The render loop only reads the LUT cache, so every look this export
        // can reach has to be on the GPU before the first frame.
        prepareLooks(settings: settings, source: source)
        let sampler = ExportFrameSampler(output: pipeline.videoOutput, range: source.videoTimeRange, fps: configuration.frameRate.value)

        while videoIsActive || audioIsActive.contains(true) {
            try session.checkCancellation()
            try checkIOStatus(reader: pipeline.reader, writer: pipeline.writer)
            var madeProgress = false

            if videoIsActive, pipeline.videoInput.isReadyForMoreMediaData {
                let step = try autoreleasepool {
                    try processNextVideoFrame(
                        sampler: sampler,
                        adaptor: pipeline.adaptor,
                        source: source,
                        grade: grade
                    )
                }
                switch step {
                case .appended(let presentationTime):
                    madeProgress = true
                    frameCount += 1
                    finalProgress = progress(
                        presentationTime: presentationTime,
                        sourceRange: source.videoTimeRange,
                        forceComplete: false
                    )
                    if finalProgress.fractionCompleted - lastReportedFraction >= 0.001 {
                        lastReportedFraction = finalProgress.fractionCompleted
                        await onStateChange?(.exporting(finalProgress))
                    }
                    if frameCount.isMultiple(of: 120) {
                        context.flushTextureCache()
                    }
                case .finished:
                    pipeline.videoInput.markAsFinished()
                    videoIsActive = false
                    madeProgress = true
                }
            }

            for index in pipeline.audio.indices where audioIsActive[index] {
                let audio = pipeline.audio[index]
                guard audio.input.isReadyForMoreMediaData else { continue }
                let appended = try autoreleasepool {
                    try processNextAudioSample(
                        output: audio.output,
                        input: audio.input,
                        writer: pipeline.writer,
                        trackNumber: index + 1
                    )
                }
                if appended {
                    madeProgress = true
                } else {
                    audio.input.markAsFinished()
                    audioIsActive[index] = false
                    madeProgress = true
                }
            }

            if !madeProgress {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        try checkIOStatus(reader: pipeline.reader, writer: pipeline.writer)
        guard pipeline.reader.status == .completed else {
            throw readerFailure(pipeline.reader)
        }
        guard frameCount > 0 else {
            throw GradeLabError.exportFailed("The source video did not contain any decodable frames.")
        }

        finalProgress = progress(
            presentationTime: CMTimeRangeGetEnd(source.videoTimeRange),
            sourceRange: source.videoTimeRange,
            forceComplete: true
        )
        return finalProgress
    }

    /// Loads every creative look referenced by this export, once, up front.
    private func prepareLooks(settings: GradeSettings, source: ExportSourceInfo) {
        var identifiers = Set<String>()
        if let look = settings.advanced?.lut { identifiers.insert(look) }
        for clip in source.timelineClips ?? [] {
            if let look = clip.gradeSettings.advanced?.lut { identifiers.insert(look) }
        }
        for identifier in identifiers { context.luts.prepare(identifier) }
    }

    private func processNextVideoFrame(
        sampler: ExportFrameSampler,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        source: ExportSourceInfo,
        grade: FrameGrade
    ) throws -> VideoStep {
        guard let frame = try sampler.next() else {
            return .finished
        }
        let sampleBuffer = frame.sample
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw GradeLabError.exportFailed("A decoded source frame was unavailable.")
        }

        let presentationTime = frame.time
        // Mask geometry is normalised to the source frame, so the aspect the
        // window is measured in is the encoded frame's — the same number the
        // preview used, which is what keeps the two identical.
        let maskAspect = CGSize(width: source.encodedWidth, height: source.encodedHeight).maskAspect
        var grade = source.gradesBaked ? FrameGrade(settings: .neutral, bypass: true) : source.timelineClips.map { clips in
            let clip = TimelineEditing.activeClip(in: clips, at: presentationTime)
            let frameTime = try? TimelineTime(presentationTime)
            let masks = clip.map { active in
                frameTime.map { active.evaluatedMaskedGrades(at: $0) } ?? active.resolvedMaskedGrades
            } ?? []
            // The same evaluator the preview uses, at the same clip-local time.
            // Export has no animation maths of its own; if it did, the two could
            // disagree, and the only place that would show is the finished file.
            let settings = clip.map { active in
                frameTime.map { active.effectiveGrade(at: $0) } ?? active.gradeSettings
            } ?? .neutral
            return FrameGrade(settings: settings, masks: masks,
                              bypass: false, aspect: maskAspect)
        } ?? grade
        // The same seed the preview used for this frame, so grain lands in the
        // same places rather than being a different random field.
        grade.uniforms.setGrainSeed(presentationTime.seconds)
        guard presentationTime.isNumeric else {
            throw GradeLabError.exportFailed("A source frame has an invalid presentation timestamp.")
        }
        let sourceFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer)
        guard ExportMediaSettings.acceptedReaderFormats(colorMode: source.colorMode).contains(sourceFormat) else {
            throw GradeLabError.unsupportedExport(
                "The decoder did not provide the required \(ExportMediaSettings.readerFormatDescription(colorMode: source.colorMode)) video frames."
            )
        }
        guard CVPixelBufferGetWidth(sourcePixelBuffer) == source.encodedWidth,
              CVPixelBufferGetHeight(sourcePixelBuffer) == source.encodedHeight else {
            throw GradeLabError.unsupportedExport(
                "The decoder changed the source dimensions; export stopped instead of resizing silently."
            )
        }

        guard let pool = adaptor.pixelBufferPool else {
            throw GradeLabError.exportFailed("The video encoder frame pool became unavailable.")
        }
        var optionalDestination: CVPixelBuffer?
        let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &optionalDestination
        )
        guard allocationStatus == kCVReturnSuccess, let destination = optionalDestination else {
            if allocationStatus == kCVReturnWouldExceedAllocationThreshold {
                throw GradeLabError.exportFailed("The video encoder could not recycle frame memory.")
            }
            throw GradeLabError.exportFailed("The video encoder could not allocate an output frame.")
        }

        try render(
            source: sourcePixelBuffer,
            destination: destination,
            grade: grade
        )
        guard adaptor.append(destination, withPresentationTime: presentationTime) else {
            throw GradeLabError.exportFailed("The video encoder rejected a processed frame.")
        }
        return .appended(presentationTime)
    }

    private func processNextAudioSample(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        trackNumber: Int
    ) throws -> Bool {
        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            return false
        }
        guard let encoderSample = try AudioExportFormat.sampleForWriter(sampleBuffer) else {
            return true
        }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            throw GradeLabError.exportFailed(
                "Decoded audio for track \(trackNumber) was unavailable."
            )
        }
        guard input.append(encoderSample) else {
            if writer.status == .failed {
                throw writerFailure(writer)
            }
            throw GradeLabError.exportFailed(
                "The AAC encoder rejected audio from track \(trackNumber)."
            )
        }
        return true
    }

    /// Grades one extended-range linear frame straight into the encoder's 10-bit
    /// 4:2:0 planes.
    ///
    /// One thread per chroma sample, so 4:2:0 subsampling averages the four
    /// graded colours rather than point-sampling one of them, and the luma plane
    /// keeps full resolution.
    private func renderHDRFrame(
        source: MTLTexture,
        destination: CVPixelBuffer,
        grade: FrameGrade
    ) throws {
        guard let hdrPipeline else {
            throw GradeLabError.unsupportedExport("This device could not build the HDR export pipeline.")
        }
        guard CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
            throw GradeLabError.exportFailed("The encoder frame pool did not provide 10-bit 4:2:0 surfaces.")
        }
        guard let lumaPlane = context.writableTexture(from: destination, pixelFormat: .r16Unorm, plane: 0),
              let chromaPlane = context.writableTexture(from: destination, pixelFormat: .rg16Unorm, plane: 1) else {
            throw GradeLabError.exportFailed("Metal could not map the 10-bit encoder planes.")
        }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GradeLabError.exportFailed("Metal could not create an export command buffer.")
        }
        commandBuffer.label = "GradeLab HDR Export Frame"
        encoder.label = "GradeLab gradeExportHDR"

        var gradeUniforms = grade.uniforms
        // The same transform the preview uses: what is shown is what is written.
        var hdrUniforms = HDRDisplayUniforms()
        encoder.setComputePipelineState(hdrPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(lumaPlane.texture, index: 1)
        encoder.setTexture(chromaPlane.texture, index: 2)
        encoder.setTexture(context.luts.texture(for: grade.lookIdentifier), index: 3)
        encoder.setTexture(context.curves.texture(for: grade.curves), index: 6)
        encoder.setBytes(&gradeUniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
        grade.locals.bind(encoder)

        let width = chromaPlane.texture.width
        let height = chromaPlane.texture.height
        let threadWidth = min(hdrPipeline.threadExecutionWidth, width)
        let threadHeight = max(1, min(hdrPipeline.maxTotalThreadsPerThreadgroup / max(threadWidth, 1), height))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(lumaPlane) {}
        withExtendedLifetime(chromaPlane) {}

        guard commandBuffer.status == .completed else {
            throw GradeLabError.exportFailed(
                commandBuffer.error.map { "HDR frame encoding failed: \($0.localizedDescription)" }
                    ?? "HDR frame encoding failed."
            )
        }
    }

    /// Grades a >8-bit Rec.709 frame straight into 10-bit encoder planes.
    ///
    /// The colour handling is the shared `applyLookAndGrade` — the identical
    /// path an 8-bit SDR export uses — so nothing about the look changes. Only
    /// the output container widens, which is what stops a 10- or 12-bit source
    /// being quietly reduced to 8 bits on the way out.
    private func renderWideSDRFrame(
        luma: MTLTexture,
        chroma: MTLTexture,
        sourcePixelBuffer: CVPixelBuffer,
        destination: CVPixelBuffer,
        grade: FrameGrade
    ) throws {
        guard let sdr10Pipeline else {
            throw GradeLabError.unsupportedExport("This device could not build the 10-bit export pipeline.")
        }
        guard let lumaPlane = context.writableTexture(from: destination, pixelFormat: .r16Unorm, plane: 0),
              let chromaPlane = context.writableTexture(from: destination, pixelFormat: .rg16Unorm, plane: 1) else {
            throw GradeLabError.exportFailed("Metal could not map the 10-bit encoder planes.")
        }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GradeLabError.exportFailed("Metal could not create an export command buffer.")
        }
        commandBuffer.label = "GradeLab 10-bit SDR Export Frame"
        encoder.label = "GradeLab gradeExportSDR10"

        var gradeUniforms = grade.uniforms
        var yuvUniforms = YUVUniforms.make(for: sourcePixelBuffer, fallbackMatrix: "BT.709")
        encoder.setComputePipelineState(sdr10Pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(context.luts.texture(for: grade.lookIdentifier), index: 3)
        encoder.setTexture(context.curves.texture(for: grade.curves), index: 6)
        encoder.setTexture(lumaPlane.texture, index: 4)
        encoder.setTexture(chromaPlane.texture, index: 5)
        encoder.setBytes(&gradeUniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        encoder.setBytes(&yuvUniforms, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        grade.locals.bind(encoder)

        let threadWidth = min(sdr10Pipeline.threadExecutionWidth, chromaPlane.texture.width)
        let threadHeight = max(1, min(sdr10Pipeline.maxTotalThreadsPerThreadgroup / max(threadWidth, 1),
                                      chromaPlane.texture.height))
        encoder.dispatchThreads(
            MTLSize(width: chromaPlane.texture.width, height: chromaPlane.texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(lumaPlane) {}
        withExtendedLifetime(chromaPlane) {}

        guard commandBuffer.status == .completed else {
            throw GradeLabError.exportFailed(
                commandBuffer.error.map { "10-bit frame encoding failed: \($0.localizedDescription)" }
                    ?? "10-bit frame encoding failed."
            )
        }
    }

    /// One Apple Log frame to Rec.709 10-bit.
    ///
    /// Deliberately the same three stages as `previewFragmentAppleLog`, in the
    /// same order, so the exported file matches what was on screen.
    private func renderAppleLogFrame(
        luma: MTLTexture,
        chroma: MTLTexture,
        destination: CVPixelBuffer,
        grade: FrameGrade
    ) throws {
        guard let pipeline = appleLogSDR10Pipeline else {
            throw GradeLabError.unsupportedExport("This device could not build the Apple Log export pipeline.")
        }
        guard let renderingLUT = context.luts.renderingTexture(
            named: AppleLogRendering.rec709LUTResourceName) else {
            // Refused rather than substituted: without Apple's rendering LUT
            // there is no defined display transform, and inventing one would be
            // exactly the guess this pipeline exists to avoid.
            throw GradeLabError.unsupportedExport(
                "Apple's Apple Log to Rec.709 rendering LUT could not be loaded, so the export has no defined display transform."
            )
        }
        guard let lumaPlane = context.writableTexture(from: destination, pixelFormat: .r16Unorm, plane: 0),
              let chromaPlane = context.writableTexture(from: destination, pixelFormat: .rg16Unorm, plane: 1) else {
            throw GradeLabError.exportFailed("Metal could not map the 10-bit encoder planes.")
        }
        if FilmEffectsStage.isActive(grade.uniforms) {
            guard let encodePipeline = effectPipelines["encodeAppleLogFromTexture"] else {
                throw GradeLabError.rendererInitializationFailed
            }
            try renderEffectedFrame(gradeKernel: "gradeToTextureAppleLog", width: luma.width, height: luma.height,
                grade: grade, workingSpace: true, bindSource: { encoder in
                    encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
                }, encode: { encoder, _ in
                    encoder.setTexture(lumaPlane.texture, index: 1); encoder.setTexture(chromaPlane.texture, index: 2)
                    encoder.setTexture(renderingLUT, index: 4)
                }, encodePipeline: encodePipeline, encodeWidth: chromaPlane.texture.width,
                encodeHeight: chromaPlane.texture.height)
            withExtendedLifetime(lumaPlane) {}; withExtendedLifetime(chromaPlane) {}
            return
        }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GradeLabError.exportFailed("Metal could not create an export command buffer.")
        }
        commandBuffer.label = "GradeLab Apple Log Export Frame"
        encoder.label = "GradeLab gradeExportAppleLogSDR10"

        var gradeUniforms = grade.uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(context.luts.texture(for: grade.lookIdentifier), index: 3)
        encoder.setTexture(lumaPlane.texture, index: 4)
        encoder.setTexture(chromaPlane.texture, index: 5)
        encoder.setTexture(context.curves.texture(for: grade.curves), index: 6)
        encoder.setTexture(renderingLUT, index: 7)
        encoder.setBytes(&gradeUniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        grade.locals.bind(encoder)

        let threadWidth = min(pipeline.threadExecutionWidth, chromaPlane.texture.width)
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / max(threadWidth, 1),
                                      chromaPlane.texture.height))
        encoder.dispatchThreads(
            MTLSize(width: chromaPlane.texture.width, height: chromaPlane.texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(lumaPlane) {}
        withExtendedLifetime(chromaPlane) {}
        guard commandBuffer.status == .completed else {
            throw GradeLabError.exportFailed(
                commandBuffer.error.map { "Apple Log frame encoding failed: \($0.localizedDescription)" }
                    ?? "Apple Log frame encoding failed."
            )
        }
    }

    /// Spatial finishing effects, shared with the preview so what was seen is
    /// what is written. Built on first use; a project with no effects never
    /// touches any of this.
    private lazy var effectsStage: FilmEffectsStage? = FilmEffectsStage(context: context)
    private var effectSurfaces: (MTLTexture, MTLTexture)?
    private lazy var effectPipelines: [String: MTLComputePipelineState] = {
        var built: [String: MTLComputePipelineState] = [:]
        for name in ["gradeToTextureYUV", "gradeToTextureHDR", "gradeToTextureAppleLog", "encodeAppleLogFromTexture", "effectWriteBGRA",
                     "encodeSDR10FromTexture", "encodeHDRFromTexture"] {
            if let function = context.library.makeFunction(name: name),
               let state = try? context.device.makeComputePipelineState(function: function) {
                built[name] = state
            }
        }
        return built
    }()

    private func effectTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let existing = effectSurfaces, existing.0.width == width, existing.0.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let first = context.device.makeTexture(descriptor: descriptor),
              let second = context.device.makeTexture(descriptor: descriptor) else { return nil }
        effectSurfaces = (first, second)
        return (first, second)
    }

    private static func dispatch(
        _ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
        width: Int, height: Int
    ) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height)),
                depth: 1))
    }

    /// Grades one frame into a texture, runs the spatial stage, and hands the
    /// finished frame to `encode` for whichever container this export writes.
    ///
    /// The stage is the same object the preview uses, driven by the same
    /// uniforms, so an exported frame and the frame that was on screen go
    /// through identical arithmetic.
    private func renderEffectedFrame(
        gradeKernel: String,
        width: Int,
        height: Int,
        grade: FrameGrade,
        workingSpace: Bool,
        bindSource: (MTLComputeCommandEncoder) -> Void,
        encode: (MTLComputeCommandEncoder, MTLTexture) -> Void,
        encodePipeline: MTLComputePipelineState,
        encodeWidth: Int,
        encodeHeight: Int
    ) throws {
        guard let stage = effectsStage,
              let gradePipeline = effectPipelines[gradeKernel],
              let surfaces = effectTextures(width: width, height: height),
              let command = context.commandQueue.makeCommandBuffer() else {
            throw GradeLabError.exportFailed("Metal could not prepare the finishing-effects pass.")
        }
        command.label = "GradeLab Export Frame (effects)"
        var gradeUniforms = grade.uniforms
        guard let gradeEncoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.exportFailed("Metal could not create an export command buffer.")
        }
        gradeEncoder.setComputePipelineState(gradePipeline)
        bindSource(gradeEncoder)
        gradeEncoder.setTexture(surfaces.0, index: 2)
        gradeEncoder.setTexture(context.luts.texture(for: grade.lookIdentifier), index: 3)
        gradeEncoder.setTexture(context.curves.texture(for: grade.curves), index: 6)
        gradeEncoder.setBytes(&gradeUniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        grade.locals.bind(gradeEncoder)
        Self.dispatch(gradeEncoder, pipeline: gradePipeline, width: width, height: height)
        gradeEncoder.endEncoding()

        guard stage.encode(source: surfaces.0, destination: surfaces.1,
                           grade: gradeUniforms, workingSpace: workingSpace, into: command) else {
            throw GradeLabError.exportFailed("The finishing-effects pass could not be encoded.")
        }

        guard let encodeEncoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.exportFailed("Metal could not create an export command buffer.")
        }
        encodeEncoder.setComputePipelineState(encodePipeline)
        encodeEncoder.setTexture(surfaces.1, index: 0)
        encode(encodeEncoder, surfaces.1)
        Self.dispatch(encodeEncoder, pipeline: encodePipeline, width: encodeWidth, height: encodeHeight)
        encodeEncoder.endEncoding()

        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw GradeLabError.exportFailed(
                command.error.map { "Frame encoding failed: \($0.localizedDescription)" }
                    ?? "Frame encoding failed.")
        }
    }

    private func render(
        source sourcePixelBuffer: CVPixelBuffer,
        destination destinationPixelBuffer: CVPixelBuffer,
        grade: FrameGrade
    ) throws {
        guard let sourceTextures = PixelBufferTextures(
            pixelBuffer: sourcePixelBuffer,
            context: context
        ),
        let destinationTextures = PixelBufferTextures(
            pixelBuffer: destinationPixelBuffer,
            context: context
        ) else {
            throw GradeLabError.exportFailed("Metal could not map an export frame without copying it.")
        }

        let spatialEffects = FilmEffectsStage.isActive(grade.uniforms)

        // HDR: extended-range linear in, 10-bit HLG BT.2020 planes out, with no
        // 8-bit stage anywhere between.
        if case .linearHalf(_, let sourceTexture) = sourceTextures.storage {
            if spatialEffects,
               let encodePipeline = effectPipelines["encodeHDRFromTexture"],
               let lumaPlane = context.writableTexture(from: destinationPixelBuffer, pixelFormat: .r16Unorm, plane: 0),
               let chromaPlane = context.writableTexture(from: destinationPixelBuffer, pixelFormat: .rg16Unorm, plane: 1) {
                var hdrUniforms = HDRDisplayUniforms()
                try renderEffectedFrame(
                    gradeKernel: "gradeToTextureHDR",
                    width: sourceTexture.width, height: sourceTexture.height,
                    grade: grade, workingSpace: true,
                    bindSource: { encoder in
                        encoder.setTexture(sourceTexture, index: 0)
                        encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
                    },
                    encode: { encoder, _ in
                        encoder.setTexture(lumaPlane.texture, index: 1)
                        encoder.setTexture(chromaPlane.texture, index: 2)
                        encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
                    },
                    encodePipeline: encodePipeline,
                    encodeWidth: chromaPlane.texture.width, encodeHeight: chromaPlane.texture.height)
                withExtendedLifetime(lumaPlane) {}; withExtendedLifetime(chromaPlane) {}
                withExtendedLifetime(sourceTextures) {}
                return
            }
            try renderHDRFrame(
                source: sourceTexture,
                destination: destinationPixelBuffer,
                grade: grade
            )
            withExtendedLifetime(sourceTextures) {}
            return
        }

        let luma: MTLTexture
        let chroma: MTLTexture
        switch sourceTextures.storage {
        case .biPlanar(_, let lumaTexture, _, let chromaTexture):
            luma = lumaTexture
            chroma = chromaTexture
        case .bgra, .linearHalf:
            throw GradeLabError.unsupportedExport("Export requires an NV12 decoder surface.")
        }

        var yuvForEffects = YUVUniforms.make(for: sourcePixelBuffer, fallbackMatrix: "BT.709")
        let sourceWidth = CVPixelBufferGetWidth(sourcePixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(sourcePixelBuffer)
        let bindYUV: (MTLComputeCommandEncoder) -> Void = { encoder in
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setBytes(&yuvForEffects, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        }

        // Apple Log: its own input transform and Apple's rendering LUT on the
        // way out. Checked before the wide-SDR branch below, which would
        // otherwise claim these frames — they are the same 10-bit YCbCr surface
        // and differ only in what the code values mean.
        if activeColorMode == .appleLog {
            try renderAppleLogFrame(
                luma: luma, chroma: chroma,
                destination: destinationPixelBuffer,
                grade: grade
            )
            withExtendedLifetime(sourceTextures) {}
            return
        }

        // Wide SDR: same grading, written as 10-bit rather than reduced to 8.
        if CVPixelBufferGetPixelFormatType(destinationPixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            if spatialEffects,
               let encodePipeline = effectPipelines["encodeSDR10FromTexture"],
               let lumaPlane = context.writableTexture(from: destinationPixelBuffer, pixelFormat: .r16Unorm, plane: 0),
               let chromaPlane = context.writableTexture(from: destinationPixelBuffer, pixelFormat: .rg16Unorm, plane: 1) {
                try renderEffectedFrame(
                    gradeKernel: "gradeToTextureYUV",
                    width: sourceWidth, height: sourceHeight,
                    grade: grade, workingSpace: false,
                    bindSource: bindYUV,
                    encode: { encoder, _ in
                        encoder.setTexture(lumaPlane.texture, index: 1)
                        encoder.setTexture(chromaPlane.texture, index: 2)
                    },
                    encodePipeline: encodePipeline,
                    encodeWidth: chromaPlane.texture.width, encodeHeight: chromaPlane.texture.height)
                withExtendedLifetime(lumaPlane) {}; withExtendedLifetime(chromaPlane) {}
                withExtendedLifetime(sourceTextures) {}
                return
            }
            try renderWideSDRFrame(
                luma: luma, chroma: chroma,
                sourcePixelBuffer: sourcePixelBuffer,
                destination: destinationPixelBuffer,
                grade: grade
            )
            withExtendedLifetime(sourceTextures) {}
            return
        }

        let destination: MTLTexture
        switch destinationTextures.storage {
        case .bgra(_, let texture):
            destination = texture
        case .biPlanar, .linearHalf:
            throw GradeLabError.exportFailed("The encoder frame pool did not provide BGRA surfaces.")
        }

        if spatialEffects, let encodePipeline = effectPipelines["effectWriteBGRA"] {
            try renderEffectedFrame(
                gradeKernel: "gradeToTextureYUV",
                width: sourceWidth, height: sourceHeight,
                grade: grade, workingSpace: false,
                bindSource: bindYUV,
                encode: { encoder, _ in encoder.setTexture(destination, index: 1) },
                encodePipeline: encodePipeline,
                encodeWidth: destination.width, encodeHeight: destination.height)
            withExtendedLifetime(sourceTextures) {}
            withExtendedLifetime(destinationTextures) {}
            return
        }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw GradeLabError.exportFailed("Metal could not create an export command buffer.")
        }
        commandBuffer.label = "GradeLab Export Frame"
        encoder.label = "GradeLab gradeExportBGRA"

        var gradeUniforms = grade.uniforms
        var yuvUniforms = YUVUniforms.make(for: sourcePixelBuffer, fallbackMatrix: "BT.709")
        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.setTexture(context.luts.texture(for: grade.lookIdentifier), index: 3)
        encoder.setTexture(context.curves.texture(for: grade.curves), index: 6)
        encoder.setBytes(
            &gradeUniforms,
            length: MemoryLayout<GradeUniforms>.stride,
            index: 0
        )
        encoder.setBytes(
            &yuvUniforms,
            length: MemoryLayout<YUVUniforms>.stride,
            index: 1
        )
        grade.locals.bind(encoder)

        let threadWidth = computePipeline.threadExecutionWidth
        let threadHeight = max(1, computePipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            #if DEBUG
            if let error = commandBuffer.error {
                print("Metal export frame failed: \(error)")
            }
            #endif
            throw GradeLabError.exportFailed("Metal could not process a video frame.")
        }
    }

    private func progress(
        presentationTime: CMTime,
        sourceRange: CMTimeRange,
        forceComplete: Bool
    ) -> ExportProgress {
        let elapsedTime = max(0, CMTimeSubtract(presentationTime, sourceRange.start).seconds)
        let duration = max(sourceRange.duration.seconds, 0)
        let fraction = forceComplete || duration == 0 ? 1 : min(elapsedTime / duration, 1)
        return ExportProgress(
            fractionCompleted: fraction,
            processedDuration: min(elapsedTime, duration),
            totalDuration: duration,
            presentationTime: presentationTime.seconds
        )
    }

    private func checkIOStatus(reader: AVAssetReader, writer: AVAssetWriter) throws {
        switch reader.status {
        case .failed:
            throw readerFailure(reader)
        case .cancelled:
            throw GradeLabError.exportCancelled
        default:
            break
        }

        switch writer.status {
        case .failed:
            throw writerFailure(writer)
        case .cancelled:
            throw GradeLabError.exportCancelled
        default:
            break
        }
    }

    private func readerFailure(_ reader: AVAssetReader) -> GradeLabError {
        #if DEBUG
        if let error = reader.error {
            print("Asset reader failed: \(error)")
        }
        #endif
        return .exportFailed("The source media could not be decoded completely.")
    }

    private func writerFailure(_ writer: AVAssetWriter) -> GradeLabError {
        #if DEBUG
        if let error = writer.error {
            print("Asset writer failed: \(error)")
        }
        #endif
        if let error = writer.error as NSError?,
           error.domain == NSCocoaErrorDomain,
           error.code == NSFileWriteOutOfSpaceError {
            return .insufficientStorage
        }
        return .exportFailed("The video encoder could not finish the exported movie.")
    }

    private func resolve(_ error: Error, session: ExportSession) -> GradeLabError {
        if session.isCancelled || error is CancellationError {
            return .exportCancelled
        }
        if let error = error as? GradeLabError {
            return error
        }
        #if DEBUG
        print("Unexpected export failure: \(error)")
        #endif
        return .exportFailed("The graded video could not be exported.")
    }

    private func makeDestinationURL(_ requestedURL: URL?, configuration: ExportConfiguration) throws -> URL {
        let url = requestedURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("GradeLab-\(UUID().uuidString)")
            .appendingPathExtension(configuration.resolvedContainer.fileExtension)
        guard url.isFileURL else {
            throw GradeLabError.exportFailed("The export destination must be a local file URL.")
        }
        guard url.pathExtension.lowercased() == configuration.resolvedContainer.fileExtension else {
            throw GradeLabError.unsupportedExport(
                "The destination extension must match the selected container."
            )
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw GradeLabError.exportFailed(
                "A file already exists at the selected export destination."
            )
        }
        return url
    }

    private func install(_ session: ExportSession) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession == nil else {
            throw GradeLabError.exportFailed("Another export is already in progress.")
        }
        activeSession = session
    }

    private func removeActiveSession(ifMatching session: ExportSession) {
        stateLock.lock()
        if activeSession === session {
            activeSession = nil
        }
        stateLock.unlock()
    }

    private func removeIncompleteOutput(at url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        for attempt in 0..<3 {
            do {
                try FileManager.default.removeItem(at: url)
                return
            } catch {
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                } else {
                    #if DEBUG
                    print("Could not remove incomplete export at \(url.path): \(error)")
                    #endif
                }
            }
        }
    }
}

private struct MediaPipeline {
    let reader: AVAssetReader
    let writer: AVAssetWriter
        let videoOutput: AVAssetReaderOutput
    let videoInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: [AudioPipeline]
}

private struct AudioPipeline {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
}

private enum VideoStep {
    case appended(CMTime)
    case finished
}

private final class ExportSession: @unchecked Sendable {
    let outputURL: URL

    private let lock = NSLock()
    private var cancellationRequested = false
    private var completed = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    var isCancelled: Bool {
        lock.lock()
        let result = cancellationRequested
        lock.unlock()
        return result
    }

    func attach(reader: AVAssetReader, writer: AVAssetWriter) {
        lock.lock()
        self.reader = reader
        self.writer = writer
        let shouldCancel = cancellationRequested
        lock.unlock()

        if shouldCancel {
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    func checkCancellation() throws {
        if isCancelled || Task.isCancelled {
            throw GradeLabError.exportCancelled
        }
    }

    func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        let reader = self.reader
        let writer = self.writer
        let completed = self.completed
        lock.unlock()

        guard !completed else { return }
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    func cancelIO() {
        lock.lock()
        let reader = self.reader
        let writer = self.writer
        let completed = self.completed
        lock.unlock()

        guard !completed else { return }
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}
