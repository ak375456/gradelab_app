@preconcurrency import AVFoundation

extension SequenceComposition {
    /// Preview composites at most this many pixels on the long edge.
    ///
    /// Every layer pass is a full-canvas read and write, and at 4K each of those
    /// surfaces is tens of megabytes — enough that a smoothed 4K clip cannot be
    /// composited in a frame interval on a phone. A phone screen is nowhere near
    /// 4K, so the preview is composited at a size it can actually sustain while
    /// export keeps the full canvas. Nothing else changes: the compositor is
    /// normalised to whatever canvas it is handed.
    static let previewLongEdgeLimit = 1920

    static func previewRenderSize(width: Int, height: Int) -> CGSize {
        let longest = max(width, height)
        guard longest > previewLongEdgeLimit, longest > 0 else {
            return CGSize(width: width, height: height)
        }
        let scale = Double(previewLongEdgeLimit) / Double(longest)
        // Even dimensions: 4:2:0 chroma is subsampled by two in each direction.
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    /// The size a layered export should actually composite at.
    ///
    /// Never larger than the canvas — compositing above the authored resolution
    /// invents nothing — and rounded to even dimensions because 4:2:0 chroma is
    /// subsampled by two in each direction.
    static func exportRenderSize(requested: CGSize, canvas: CGSize) -> CGSize {
        guard requested.width > 0, requested.height > 0,
              requested.width.isFinite, requested.height.isFinite,
              max(requested.width, requested.height) < max(canvas.width, canvas.height) else { return canvas }
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(requested.width), height: even(requested.height))
    }

    /// - Parameter requestedRenderSize: the size the export will actually
    ///   write. Compositing above it is work and memory thrown away — the
    ///   writer only scales the result back down again.
    static func buildLayers(project: VideoProject, forExport: Bool, context: MetalContext? = nil,
                            requestedRenderSize: CGSize? = nil) async throws -> Self {
        if project.colorMode.isAppleLog {
            let expected: SourceColorProfile = project.colorMode == .appleLog2 ? .appleLog2 : .appleLog
            guard let identifier = project.metadata.logProfileIdentifier,
                  SourceColorProfile.fromLogIdentifier(identifier) == expected else {
                throw GradeLabError.unsupportedExport(
                    String(localized: "This project is set to \(expected.displayName), but the source declares no matching Log profile. GradeLab does not infer Log from the picture."))
            }
        }
        let clips = try TimelineEditing.clips(in: project)
        guard project.timeline.duration > .zero, let cadence = project.canvas.frameDuration else { throw TimelineError.invalid(String(localized: "Add media before playback.")) }
        // The layer compositor has its own Metal context during preview, while
        // export supplies the exporter's context. Load every referenced look
        // into the context that will actually execute the grade before the
        // first composition frame is requested.
        let lookIdentifiers = Set(clips.compactMap { $0.gradeSettings.advanced?.lut })
        _ = await CompositorResources.prepareLooks(lookIdentifiers, context: context)
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        var sources: [UUID: ExportSourceInfo] = [:]
        for asset in project.assets where clips.contains(where: { $0.assetID == asset.id }) {
            if asset.stillImage != nil { continue }
            guard let metadata = asset.videoMetadata else { throw TimelineError.invalid(String(localized: "Missing video metadata.")) }
            sources[asset.id] = try await ExportSourceInspector.inspect(.init(url: asset.url, metadata: metadata), requireExportColorTags: forExport || (project.colorMode.isAppleLog && metadata.logProfileIdentifier != nil))
            try Task.checkCancellation()
        }
        var ids: [UUID: CMPersistentTrackID] = [:]
        var blendIDs: [UUID: CMPersistentTrackID] = [:]
        var videos: [AVAssetTrack] = []
        // Sequential edits of one asset share a decoder track. Overlapping
        // layers and transition handles still need independent source frames.
        var videoSlots: [(assetID: UUID, track: AVMutableCompositionTrack, end: CMTime)] = []
        var blendSlots: [(assetID: UUID, track: AVMutableCompositionTrack, end: CMTime)] = []
        func decoderTrack(assetID: UUID, start: CMTime, end: CMTime,
                          slots: inout [(assetID: UUID, track: AVMutableCompositionTrack, end: CMTime)]) throws -> AVMutableCompositionTrack {
            if let index = slots.firstIndex(where: { $0.assetID == assetID && $0.end <= start }) {
                slots[index].end = end
                return slots[index].track
            }
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TimelineError.invalid(String(localized: "Could not create video layer."))
            }
            slots.append((assetID, track, end))
            videos.append(track)
            return track
        }
        var audio: [ExportAudioTrackInfo] = []
        var routing = TimelineAudioMix()
        for clip in clips.sorted(by: { $0.placement.timelineStart < $1.placement.timelineStart }) {
            let media = project.assets.first(where: { $0.id == clip.assetID })
            if media?.stillImage != nil { continue }
            guard let source = sources[clip.assetID] else {
                throw TimelineError.invalid(String(localized: "Could not create video layer."))
            }
            // Transition handles are scheduled on the clip's own composition
            // track. The authored clip placement remains non-overlapping; only
            // these decoder tracks extend across the centered transition range.
            let outgoingTransition = project.timeline.transitions.first { $0.enabled && $0.outgoingClipID == clip.id }
            let incomingTransition = project.timeline.transitions.first { $0.enabled && $0.incomingClipID == clip.id }
            let tail = try outgoingTransition.map {
                try TimelineTime(CMTimeMultiplyByRatio($0.duration.cmTime, multiplier: 1, divisor: 2))
            } ?? .zero
            let lead = try incomingTransition.map {
                try TimelineTime(CMTimeMultiplyByRatio($0.duration.cmTime, multiplier: 1, divisor: 2))
            } ?? .zero
            let sourceLead = try ClipSpeed.sourceDuration(timelineDuration: lead, speed: clip.speed)
            let sourceTail = try ClipSpeed.sourceDuration(timelineDuration: tail, speed: clip.speed)
            let extendedSourceStart = try clip.sourceRange.start.subtracting(sourceLead)
            let extendedSourceDuration = try clip.sourceRange.duration.adding(sourceLead).adding(sourceTail)
            let extendedTimelineStart = try clip.placement.timelineStart.subtracting(lead)
            let extendedTimelineDuration = try clip.placement.duration.adding(lead).adding(tail)
            let video = try decoderTrack(assetID: clip.assetID, start: extendedTimelineStart.cmTime,
                end: CMTimeAdd(extendedTimelineStart.cmTime, extendedTimelineDuration.cmTime), slots: &videoSlots)
            try video.insertTimeRange(
                CMTimeRange(start: extendedSourceStart.cmTime, duration: extendedSourceDuration.cmTime),
                of: source.videoTrack, at: extendedTimelineStart.cmTime)
            // Retime: the source range was inserted at its natural length, so
            // scaling it to the clip's timeline duration is what actually makes
            // it play faster or slower. Preview and export share this
            // composition, so they cannot disagree about the rate.
            //
            // A ramp is the same operation applied piece by piece. The pieces
            // come from the clip's own time map, which is also what the grade,
            // the masks and the tracking read, so the picture AVFoundation
            // schedules and the frame the rest of the app thinks is there are
            // the same frame.
            let rampSegments = clip.isRamped
                ? clip.timeMap.retimeSegments()
                : []
            if !rampSegments.isEmpty {
                // Transition handles sit outside the clip's own source range and
                // therefore outside the curve. They keep the rate of the piece
                // they adjoin, which is the rate the picture is actually moving
                // at where the dissolve begins.
                var pieces: [RetimeSegment] = []
                if sourceLead > .zero, let first = rampSegments.first {
                    pieces.append(RetimeSegment(sourceOffset: .zero, sourceDuration: sourceLead,
                                                timelineDuration: lead > .zero ? lead : first.timelineDuration))
                }
                pieces.append(contentsOf: rampSegments)
                if sourceTail > .zero, let last = rampSegments.last {
                    pieces.append(RetimeSegment(sourceOffset: .zero, sourceDuration: sourceTail,
                                                timelineDuration: tail > .zero ? tail : last.timelineDuration))
                }
                TimeMap.applySegments(pieces, to: video, startingAt: extendedTimelineStart.cmTime)
            } else if clip.isRetimed {
                video.scaleTimeRange(
                    CMTimeRange(start: extendedTimelineStart.cmTime,
                                duration: extendedSourceDuration.cmTime),
                    toDuration: extendedTimelineDuration.cmTime
                )
            }
            ids[clip.id] = video.trackID

            // Smoothing needs the NEXT source frame as well as the current one,
            // and a compositor is only handed the frame at the composition time.
            // So the same source goes in a second time, shifted forward by one
            // frame; the compositor then has both sides of every gap and can
            // cross-dissolve between them.
            //
            // The shift is the same frame duration `LayerCompositor` uses to
            // work out how far between two frames a moment falls. Taking one
            // from the track and the other from the asset lets them disagree on
            // a variable-frame-rate source, and the dissolve then runs on the
            // wrong ramp.
            let loadedMinFrameDuration = try? await source.videoTrack.load(.minFrameDuration)
            let blendFrameDuration = media?.frameDuration?.cmTime
                ?? (loadedMinFrameDuration?.isNumeric == true && loadedMinFrameDuration! > .zero
                    ? loadedMinFrameDuration : nil)
            if clip.smoothsMotion,
               let frameDuration = blendFrameDuration, frameDuration > .zero {
                let shifted = CMTimeAdd(clip.sourceRange.start.cmTime, frameDuration)
                let available = CMTimeSubtract(source.videoTimeRange.end, shifted)
                let duration = CMTimeMinimum(clip.sourceRange.duration.cmTime, available)
                if duration > .zero {
                    let partner = try decoderTrack(assetID: clip.assetID, start: clip.placement.timelineStart.cmTime,
                        end: clip.placement.range.end.cmTime, slots: &blendSlots)
                    try partner.insertTimeRange(
                        CMTimeRange(start: shifted, duration: duration),
                        of: source.videoTrack, at: clip.placement.timelineStart.cmTime)
                    // Scaled over the CLIP's source length rather than the
                    // partner's own, so the partner lands on exactly the same
                    // timeline end as the picture it accompanies. Holding the
                    // last frame to fill the missing tail instead would add a
                    // second segment that scales to a slightly longer end, and a
                    // track that outlives the final instruction takes the whole
                    // video composition down with it. The tail needs no filling:
                    // with no partner frame the compositor uses the source frame
                    // unblended, which is what the last frame should be anyway.
                    // Scaled by exactly the same pieces as the picture, so the
                    // partner never drifts away from the frame it is supposed to
                    // be one frame ahead of. A ramp that scaled the two
                    // differently would blend frames that are seconds apart at
                    // the fast end of the curve.
                    if !rampSegments.isEmpty {
                        TimeMap.applySegments(rampSegments, to: partner,
                                              startingAt: clip.placement.timelineStart.cmTime)
                    } else if clip.isRetimed {
                        partner.scaleTimeRange(
                            CMTimeRange(start: clip.placement.timelineStart.cmTime,
                                        duration: clip.sourceRange.duration.cmTime),
                            toDuration: clip.placement.duration.cmTime)
                    }
                    blendIDs[clip.id] = partner.trackID
                }
            }
            // A reversed clip has no audio. Reversing samples is not something
            // an edit list can express any more than reversing pictures is, and
            // the honest options are silence or a rendered file. Silence is
            // chosen, and the panel says so — the alternative is audio that
            // plays forwards under a picture that does not, which is worse than
            // nothing and much harder to notice.
            //
            // The muting is here rather than on the document so that turning
            // Reverse off brings the sound back exactly as it was.
            if clip.embeddedAudio != nil, !clip.isReversed,
               clip.resolvedRemap.audioBehaviour != .mute {
                for original in source.audioTracks {
                    let range = CMTimeRangeGetIntersection(clip.sourceRange.cmTimeRange, otherRange: original.timeRange)
                    guard range.duration > .zero else { continue }
                    guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw TimelineError.invalid(String(localized: "Could not create linked audio.")) }
                    let offset = CMTimeSubtract(range.start, clip.sourceRange.start.cmTime)
                    let insertedAt = CMTimeAdd(clip.placement.timelineStart.cmTime, offset)
                    try track.insertTimeRange(range, of: original.track, at: insertedAt)
                    // Audio follows the same map the picture does, piece for
                    // piece, so a ramp cannot leave the two drifting apart. The
                    // window is the intersection that was actually inserted,
                    // which is not always the whole clip.
                    let audioSegments = clip.isRamped
                        ? clip.timeMap.retimeSegments(clippedToSource: CMTimeRange(
                            start: CMTimeSubtract(range.start, clip.sourceRange.start.cmTime),
                            duration: range.duration))
                        : []
                    if !audioSegments.isEmpty {
                        TimeMap.applySegments(audioSegments, to: track, startingAt: insertedAt)
                    } else if clip.isRetimed {
                        // The same conversion the picture uses. A raw float
                        // multiply lands on a nanosecond timescale and can round
                        // a few ticks PAST the video it was cut from, pushing the
                        // end of the composition outside the last instruction.
                        let target = try ClipSpeed.timelineDuration(
                            sourceDuration: try TimelineTime(range.duration), speed: clip.speed)
                        track.scaleTimeRange(
                            CMTimeRange(start: insertedAt, duration: range.duration),
                            toDuration: target.cmTime
                        )
                    }
                    audio.append(.init(track: track, formatID: original.formatID,
                        sourceFormatDescription: original.sourceFormatDescription, sampleRate: original.sampleRate, channelCount: original.channelCount,
                        channelLayout: original.channelLayout, timeRange: try await track.load(.timeRange), naturalTimeScale: original.naturalTimeScale))
                    routing.clipsByTrack[track.trackID] = clip.id
                }
            }
        }
        var independentSources: [UUID: [ExportAudioTrackInfo]] = [:]
        // AVAssetTrack does not keep its owning asset alive. Retain audio-only
        // assets until all their source ranges have been inserted.
        var audioAssets: [AVAsset] = []
        defer { withExtendedLifetime(audioAssets) {} }
        for clip in project.timeline.audioClips {
            if independentSources[clip.assetID] == nil {
                if let existing = sources[clip.assetID] { independentSources[clip.assetID] = existing.audioTracks }
                else {
                    guard let media = project.assets.first(where: { $0.id == clip.assetID }) else { throw TimelineError.invalid(String(localized: "Audio source is missing.")) }
                    let asset = AVURLAsset(url: media.url)
                    audioAssets.append(asset)
                    guard try await !asset.load(.hasProtectedContent) else { throw TimelineError.invalid(String(localized: "Protected audio cannot be edited.")) }
                    var inspected: [ExportAudioTrackInfo] = []
                    let embeddedTracks = try await asset.loadTracks(withMediaType: .audio)
                    let enabledTracks = try await AudioTrackSelection.enabledTracks(from: embeddedTracks)
                    for track in enabledTracks {
                        inspected.append(try await ExportSourceInspector.inspectAudioTrack(track))
                    }
                    independentSources[clip.assetID] = inspected
                }
            }
            let originals = independentSources[clip.assetID] ?? []
            guard !originals.isEmpty, clip.sourceTrackIndex.map({ originals.indices.contains($0) }) ?? true else {
                throw TimelineError.invalid(String(localized: "The selected source audio track is unavailable."))
            }
            for (index, original) in originals.enumerated() where clip.sourceTrackIndex == nil || clip.sourceTrackIndex == index {
                let range = CMTimeRangeGetIntersection(clip.sourceRange.cmTimeRange, otherRange: original.timeRange)
                guard range.duration > .zero else { continue }
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw TimelineError.invalid(String(localized: "Could not create audio track.")) }
                let offset = CMTimeSubtract(range.start, clip.sourceRange.start.cmTime)
                try track.insertTimeRange(range, of: original.track, at: CMTimeAdd(clip.placement.timelineStart.cmTime, offset))
                audio.append(.init(track: track, formatID: original.formatID,
                    sourceFormatDescription: original.sourceFormatDescription, sampleRate: original.sampleRate, channelCount: original.channelCount,
                    channelLayout: original.channelLayout, timeRange: try await track.load(.timeRange), naturalTimeScale: original.naturalTimeScale))
                routing.clipsByTrack[track.trackID] = clip.id
            }
            try Task.checkCancellation()
        }
        let state = LayerRenderState(project, context: context, forExport: forExport)
        if videos.isEmpty {
            guard let clock = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw TimelineError.invalid(String(localized: "Could not create image timeline.")) }
            clock.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: project.timeline.duration.cmTime))
            videos.append(clock)
        }
        var boundaries: [TimelineTime] = [.zero, project.timeline.duration]
        for clip in clips { boundaries.append(clip.placement.timelineStart); boundaries.append(try clip.placement.range.end) }
        for transition in project.timeline.transitions where transition.enabled {
            if let range = transition.range {
                boundaries.append(range.start)
                boundaries.append(try range.end)
            }
        }
        let sorted = boundaries.sorted().reduce(into: [TimelineTime]()) { result, time in if result.last != time { result.append(time) } }
        var instructions: [LayerInstruction] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) {
            let active = clips.filter { clip in
                if TimelineEditing.activeClip(in: [clip], at: start.cmTime) != nil { return true }
                return project.timeline.transitions.contains { transition in
                    guard transition.enabled, transition.outgoingClipID == clip.id || transition.incomingClipID == clip.id,
                          let range = transition.range else { return false }
                    return range.cmTimeRange.containsTime(start.cmTime)
                }
            }
            let activeIDs = Dictionary(uniqueKeysWithValues: active.compactMap { clip in ids[clip.id].map { (clip.id, $0) } })
            // Retiming partners only contain the authored clip range. A clip
            // may be active here solely because transition handles extend its
            // primary track; requiring the non-extended partner in that region
            // asks AVFoundation for a source frame that does not exist.
            let activeBlendIDs = blendIDs.filter { clipID, _ in
                guard activeIDs.keys.contains(clipID),
                      let clip = clips.first(where: { $0.id == clipID }) else { return false }
                return TimelineEditing.activeClip(in: [clip], at: start.cmTime) != nil
            }
            instructions.append(LayerInstruction(
                range: CMTimeRange(start: start.cmTime, duration: try end.subtracting(start).cmTime),
                tracks: activeIDs, blendTracks: activeBlendIDs, state: state))
        }
        // AVFoundation validates that the instructions cover the composition,
        // and enforces it silently: if any part of the timeline falls outside
        // every instruction the compositor is never called AT ALL, so the
        // picture holds its last frame while the audio plays on. Sub-tick
        // overshoots are easy to produce -- a source's audio track rarely ends
        // on exactly the same tick as its video, and retiming rounds them
        // separately -- so cover whatever the composition actually came out to
        // be rather than what the timeline says it should be.
        let composedDuration = try await composition.load(.duration)
        if let last = instructions.last, composedDuration > last.timeRange.end {
            instructions[instructions.count - 1] = LayerInstruction(
                range: CMTimeRange(start: last.timeRange.start, end: composedDuration),
                tracks: last.trackIDs, blendTracks: last.blendTrackIDs, state: state)
        }
        let canvas = CGSize(width: project.canvas.width, height: project.canvas.height)
        // Export used to composite at the full canvas whatever resolution was
        // asked for, so a 1080p export of a 4K project built every layer at 4K
        // and then handed the writer frames it immediately scaled back down —
        // four times the pixels, in every working buffer and every decoded
        // still, for a file that could never show them.
        let renderSize = forExport
            ? requestedRenderSize.map { Self.exportRenderSize(requested: $0, canvas: canvas) } ?? canvas
            : Self.previewRenderSize(width: project.canvas.width, height: project.canvas.height)
        let vc = AVMutableVideoComposition()
        // Compositor types rather than one configured instance:
        // AVFoundation builds the compositor itself and reads its surface
        // attributes before any instruction is seen, so the choice has to be
        // carried by the type.
        if project.colorMode.isAppleLog {
            vc.customVideoCompositorClass = forExport
                ? AppleLogExportLayerCompositor.self : AppleLogLayerCompositor.self
        } else {
            vc.customVideoCompositorClass = project.colorMode.isHDR
                ? HDRLayerCompositor.self : LayerCompositor.self
        }
        vc.renderSize = renderSize
        vc.frameDuration = cadence.cmTime; vc.instructions = instructions
        if project.colorMode.isHDR {
            // These tags describe the frames the compositor produces. Measured:
            // they also relabel the source frames handed to it, which is what
            // makes an HLG source arrive tagged as the HLG signal it is.
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else if !project.colorMode.isAppleLog {
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        // Apple Log has no AVFoundation transfer tag. Leave composition tags
        // unset to avoid imposing Rec.709 on decoder inputs; the compositor tags
        // its finished buffers as Rec.709. ValidateAppleLogLayers compares this
        // boundary with a direct native decode on the supplied camera clip.
        let range = CMTimeRange(start: .zero, duration: project.timeline.duration.cmTime)
            // The project decides the colour mode, and it has to travel with the
            // composition: the capability check inspects the source directly and
            // sees HDR, but the exporter reads THIS value to pick the reader
            // format, the encoder profile and the output tags. Leaving it at the
            // default meant an HDR project was checked as HDR and then written
            // through the 8-bit Rec.709 path.
        // Playing a layered timeline is the most expensive thing the preview
        // does — every layer is a full-canvas read and write — so the reduced
        // copies matter most here. The custom compositor normalises to whatever
        // canvas it is handed, so only the render size changes.
        let playbackCompositions = forExport
            ? [:]
            : Self.playbackCompositions(base: vc, scalingTrack: nil)
        return Self(source: .init(asset: composition, videoTrack: videos[0], encodedWidth: Int(renderSize.width),
            encodedHeight: Int(renderSize.height), duration: range.duration, videoTimeRange: range, sessionStartTime: .zero,
            preferredTransform: .identity, nominalFrameRate: 1/cadence.seconds, naturalTimeScale: TimelineTime.projectTimescale,
            audioTracks: audio, videoComposition: vc, playbackVideoCompositions: playbackCompositions,
            timelineClips: nil, compositionVideoTracks: videos,
            gradesBaked: true, audioMix: routing.makeMix(project),
            // Log is an input profile. This source now carries rendered Rec.709;
            // leaving it marked Log would apply the input transform a second time.
            colorMode: project.colorMode.isAppleLog ? .sdrWide : project.colorMode),
            clips: clips, layerState: state, audioRouting: routing)
    }
}
