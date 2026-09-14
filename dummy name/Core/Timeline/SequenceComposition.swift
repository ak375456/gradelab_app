@preconcurrency import AVFoundation

/// One immutable scheduling result shared by preview and export. No media is written.
struct SequenceComposition {
    let source: ExportSourceInfo
    let clips: [VideoClip]
    var layerState: LayerRenderState? = nil
    var audioRouting = TimelineAudioMix()

    static func build(project: VideoProject, forExport: Bool = true, context: MetalContext? = nil) async throws -> Self {
        if project.needsLayerCompositor { return try await buildLayers(project: project, forExport: forExport, context: context) }
        let clips = try TimelineEditing.clips(in: project)
        guard !clips.isEmpty, let frame = project.canvas.frameDuration else {
            throw TimelineError.invalid("Add a clip with a known frame rate before playing or exporting.")
        }
        let original = try await ExportSourceInspector.inspect(VideoAsset(url: project.sourceURL, metadata: project.metadata), requireExportColorTags: forExport)
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TimelineError.invalid("Could not create the sequence video track.")
        }
        var audio: [ExportAudioTrackInfo] = []
        for originalAudio in original.audioTracks {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TimelineError.invalid("Could not create a linked audio track.")
            }
            for clip in clips {
                let intersection = CMTimeRangeGetIntersection(clip.sourceRange.cmTimeRange, otherRange: originalAudio.timeRange)
                if intersection.duration > .zero {
                    // The offset into the clip is a SOURCE distance; the place it
                    // lands on the timeline is that distance at the clip's speed.
                    let sourceOffset = CMTimeSubtract(intersection.start, clip.sourceRange.start.cmTime)
                    let timelineOffset = clip.isRetimed
                        ? ((try? ClipSpeed.timelineDuration(
                            sourceDuration: try TimelineTime(sourceOffset), speed: clip.speed))?.cmTime ?? sourceOffset)
                        : sourceOffset
                    let insertedAt = CMTimeAdd(clip.placement.timelineStart.cmTime, timelineOffset)
                    try track.insertTimeRange(intersection, of: originalAudio.track, at: insertedAt)
                    if clip.isRetimed {
                        // Scaled through the same conversion the picture uses, so
                        // the two cannot round to different lengths and drift.
                        // Pitch is preserved by the time-pitch algorithm on the
                        // player item and the reader, not here.
                        let target = try ClipSpeed.timelineDuration(
                            sourceDuration: try TimelineTime(intersection.duration), speed: clip.speed)
                        track.scaleTimeRange(
                            CMTimeRange(start: insertedAt, duration: intersection.duration),
                            toDuration: target.cmTime
                        )
                    }
                }
            }
            let range = try await track.load(.timeRange)
            if range.duration > .zero {
                audio.append(.init(track: track, formatID: originalAudio.formatID,
                    sourceFormatDescription: originalAudio.sourceFormatDescription, sampleRate: originalAudio.sampleRate,
                    channelCount: originalAudio.channelCount, channelLayout: originalAudio.channelLayout,
                    timeRange: range, naturalTimeScale: originalAudio.naturalTimeScale))
            } else { composition.removeTrack(track) }
        }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = TimelineTime.zero
        func instruction(start: TimelineTime, duration: TimelineTime, visible: Bool) -> AVMutableVideoCompositionInstruction {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: start.cmTime, duration: duration.cmTime)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = visible ? [AVMutableVideoCompositionLayerInstruction(assetTrack: video)] : []
            return instruction
        }
        for clip in clips {
            try Task.checkCancellation()
            if clip.placement.timelineStart > cursor {
                let gap = try clip.placement.timelineStart.subtracting(cursor)
                video.insertEmptyTimeRange(CMTimeRange(start: cursor.cmTime, duration: gap.cmTime))
                instructions.append(instruction(start: cursor, duration: gap, visible: false))
            }
            try video.insertTimeRange(clip.sourceRange.cmTimeRange, of: original.videoTrack, at: clip.placement.timelineStart.cmTime)
            // Retime: the source range was inserted at its natural length, so
            // scaling it to the clip's timeline duration is what actually makes
            // it play faster or slower. Preview and export share this
            // composition, so they cannot disagree about the rate.
            if clip.isRetimed {
                video.scaleTimeRange(
                    CMTimeRange(start: clip.placement.timelineStart.cmTime,
                                duration: clip.sourceRange.duration.cmTime),
                    toDuration: clip.placement.duration.cmTime
                )
            }
            instructions.append(instruction(start: clip.placement.timelineStart, duration: clip.placement.duration, visible: true))
            cursor = try clip.placement.range.end
        }
        // The instructions must cover the whole composition. When they do not,
        // AVFoundation rejects the video composition without reporting anything:
        // no frame is ever rendered and the preview holds its last picture while
        // the audio keeps playing. The gap can be a single tick -- a source's
        // audio track rarely ends exactly where its video does, and retiming
        // rounds the two separately -- so the last instruction is stretched to
        // the composition's real end.
        let composedDuration = try await composition.load(.duration)
        if let last = instructions.last, composedDuration > last.timeRange.end {
            last.timeRange = CMTimeRange(start: last.timeRange.start, end: composedDuration)
        }
        let videoComposition = AVMutableVideoComposition()
        // Keep source encoded orientation here; the existing renderer/writer each
        // apply the source preferred transform once at their presentation boundary.
        videoComposition.renderSize = CGSize(width: original.encodedWidth, height: original.encodedHeight)
        videoComposition.frameDuration = frame.cmTime
        videoComposition.instructions = instructions
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let range = CMTimeRange(start: .zero, duration: project.timeline.duration.cmTime)
            // The project decides the colour mode, and it has to travel with the
            // composition: the capability check inspects the source directly and
            // sees HDR, but the exporter reads THIS value to pick the reader
            // format, the encoder profile and the output tags. Leaving it at the
            // default meant an HDR project was checked as HDR and then written
            // through the 8-bit Rec.709 path.
        // Reduced copies for playback only, and only for the preview: export
        // renders the full canvas. Built here, where the instructions and the
        // track are already in hand, so switching quality later costs nothing.
        let playbackCompositions = forExport
            ? [:]
            : Self.playbackCompositions(base: videoComposition, scalingTrack: video)
        return Self(source: ExportSourceInfo(asset: composition, videoTrack: video,
            encodedWidth: original.encodedWidth, encodedHeight: original.encodedHeight,
            duration: range.duration, videoTimeRange: range, sessionStartTime: .zero,
            preferredTransform: original.preferredTransform, nominalFrameRate: 1 / frame.seconds,
            naturalTimeScale: TimelineTime.projectTimescale, audioTracks: audio,
            videoComposition: videoComposition, playbackVideoCompositions: playbackCompositions,
            timelineClips: clips,
            colorMode: project.colorMode), clips: clips)
    }
}
