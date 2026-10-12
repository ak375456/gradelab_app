@preconcurrency import AVFoundation

/// Composition track IDs stay stable during live volume changes. The same mix
/// is attached to AVPlayerItem and AVAssetReaderAudioMixOutput.
struct TimelineAudioMix {
    var clipsByTrack: [CMPersistentTrackID: UUID] = [:]
    private let processing = AudioProcessingRegistry()

    func prepareDucking(_ project: VideoProject, composition: AVComposition) async throws {
        let ids = Set(clipsByTrack.values.compactMap { settings(for: $0, in: project).ducking }
            .filter(\.isEnabled).compactMap(\.sourceClipID))
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        for id in ids {
            try Task.checkCancellation()
            guard let item = project.timeline.item(id: id) else { continue }
            let sources = tracks.filter { clipsByTrack[$0.trackID] == id }
            processing.activity[id] = try await AudioActivityEnvelope.analyze(asset: composition, tracks: sources,
                start: item.placement.timelineStart.seconds, duration: item.placement.duration.seconds)
        }
    }

    func duckingEnvelope(for clipID: UUID, in project: VideoProject) -> AudioDuckingEnvelope? {
        guard let duck = settings(for: clipID, in: project).ducking, duck.isEnabled,
              let sourceID = duck.sourceClipID, sourceID != clipID,
              let activity = processing.activity[sourceID] else { return nil }
        let source = Self.levelEnvelope(for: sourceID, in: project)
        return .init(intervals: activity.intervals(threshold: duck.threshold, level: source.gain), settings: duck)
    }

    private static func levelEnvelope(for id: UUID, in project: VideoProject) -> AudioTimelineLevel {
        guard let item = project.timeline.item(id: id), item.placement.isEnabled,
              project.timeline.tracks.first(where: { $0.id == item.placement.trackID })?.isEnabled == true else { return .init() }
        let start = item.placement.timelineStart.seconds, duration = item.placement.duration.seconds
        let audio: EmbeddedAudio
        var silences: [AudioActivityInterval] = []
        switch item {
        case .audio(let clip): audio = .init(volume: clip.volume, isMuted: clip.isMuted, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
        case .video(let clip):
            guard let linked = clip.embeddedAudio else { return .init() }; audio = linked
            let map = clip.timeMap
            for hold in clip.resolvedRemap.resolvedFreezes(sourceDuration: clip.sourceRange.duration) where hold.silencesAudio == true {
                let a = map.timelineOffset(atSourceOffset: hold.sourceOffset).seconds
                let b = map.timelineOffset(atSourceOffset: hold.sourceEnd).seconds
                silences.append(.init(start: start + min(a, b), end: start + max(a, b)))
            }
        default: return .init()
        }
        guard !audio.isMuted else { return .init() }
        let fade = AudioFade.resolved(duration: duration, fadeIn: audio.fadeIn, fadeOut: audio.fadeOut)
        return .init(start: start, duration: duration, volume: min(1, max(0, audio.volume)),
                     rise: fade.rise, fall: fade.fall, silences: silences)
    }

    /// Tone/pan changes update small control snapshots without replacing the
    /// player's mix or throwing away the running filters on every slider tick.
    func updateProcessing(_ project: VideoProject) {
        for (trackID, clipID) in clipsByTrack {
            processing.controls[trackID]?.update(settings(for: clipID, in: project))
        }
    }

    func level(for clipID: UUID) -> AudioLevelReading {
        let now = Date.timeIntervalSinceReferenceDate
        return clipsByTrack.filter { $0.value == clipID }.keys.compactMap { processing.controls[$0]?.level }
            .filter { now - $0.measuredAt < 0.3 }
            .max { $0.peak < $1.peak } ?? AudioLevelReading()
    }

    private func settings(for clipID: UUID, in project: VideoProject) -> AudioProcessingSettings {
        switch project.timeline.item(id: clipID) {
        case .audio(let clip): return clip.processing ?? .init()
        case .video(let clip): return clip.embeddedAudio?.processing ?? .init()
        default: return .init()
        }
    }

    func makeMix(_ project: VideoProject) throws -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = try clipsByTrack.map { trackID, clipID in
            let parameter = AVMutableAudioMixInputParameters()
            parameter.trackID = trackID
            let control = processing.controls[trackID] ?? AudioTapControl(settings: settings(for: clipID, in: project))
            control.update(settings(for: clipID, in: project))
            processing.controls[trackID] = control
            parameter.audioTapProcessor = try AudioProcessingTap.make(control: control)
            var gain = 0.0
            var fade: (rise: Double, fall: Double) = (0, 0)
            var placement: ItemPlacement?
            if let item = project.timeline.item(id: clipID), item.placement.isEnabled,
               project.timeline.tracks.first(where: { $0.id == item.placement.trackID })?.isEnabled == true {
                let duration = item.placement.duration.seconds
                switch item {
                case .audio(let clip):
                    gain = clip.isMuted ? 0 : clip.volume
                    fade = AudioFade.resolved(duration: duration, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
                case .video(let clip):
                    gain = clip.embeddedAudio.map { $0.isMuted ? 0 : $0.volume } ?? 0
                    fade = clip.embeddedAudio.map {
                        AudioFade.resolved(duration: duration, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut)
                    } ?? (0, 0)
                case .text, .shape: break
                }
                placement = item.placement
            }
            let level = Float(min(1, max(0, gain)))
            parameter.setVolume(level, at: .zero)
            let duck = duckingEnvelope(for: clipID, in: project)
            // Fades are ramps on the same input parameters the level uses, so
            // preview and export get them from one place and cannot disagree.
            // Each clip owns its own composition track, so a ramp addresses one
            // clip and nothing else.
            if let duck, level > 0, let placement {
                let start = placement.timelineStart.seconds, end = start + placement.duration.seconds
                // Multiply fades and ducking into one bounded 40 Hz envelope,
                // rather than scheduling competing volume ramps.
                let step = max(0.025, (end - start) / 65_536)
                let target = Self.levelEnvelope(for: clipID, in: project)
                var times = stride(from: start, to: end, by: step).map { $0 }
                times += [end, start + fade.rise, end - fade.fall]
                times += duck.boundaries.filter { $0 > start && $0 < end }
                times += target.silences.flatMap { [$0.start - 1 / 60_000, $0.start, $0.end - 1 / 60_000, $0.end] }
                    .filter { $0 > start && $0 < end }
                let scale = TimelineTime.projectTimescale
                let ticks = Array(Set(times.map { Int64(($0 * Double(scale)).rounded()) })).sorted()
                for (a, b) in zip(ticks, ticks.dropFirst()) where b > a {
                    let first = Double(a) / Double(scale), last = Double(b) / Double(scale)
                    parameter.setVolumeRamp(
                        fromStartVolume: Float(target.gain(at: first) * duck.gain(at: first)),
                        toEndVolume: Float(target.gain(at: last) * duck.gain(at: last)),
                        timeRange: CMTimeRange(start: CMTime(value: a, timescale: scale), duration: CMTime(value: b - a, timescale: scale)))
                }
            } else if level > 0, let placement, fade.rise > 0 || fade.fall > 0 {
                let start = placement.timelineStart.cmTime
                let end = CMTimeAdd(start, placement.duration.cmTime)
                if fade.rise > 0 {
                    parameter.setVolumeRamp(
                        fromStartVolume: 0, toEndVolume: level,
                        timeRange: CMTimeRange(start: start, duration: Self.time(fade.rise)))
                }
                if fade.fall > 0 {
                    let length = Self.time(fade.fall)
                    parameter.setVolumeRamp(
                        fromStartVolume: level, toEndVolume: 0,
                        timeRange: CMTimeRange(start: CMTimeSubtract(end, length), duration: length))
                }
            }
            if duck == nil, let clip = project.timeline.videoClip(id: clipID) {
                for hold in clip.resolvedRemap.resolvedFreezes(sourceDuration: clip.sourceRange.duration)
                    where hold.silencesAudio == true {
                    let map = clip.timeMap
                    let first = map.timelineOffset(atSourceOffset: hold.sourceOffset)
                    let last = map.timelineOffset(atSourceOffset: hold.sourceEnd)
                    let start = CMTimeAdd(clip.placement.timelineStart.cmTime, min(first, last).cmTime)
                    let end = CMTimeAdd(clip.placement.timelineStart.cmTime, max(first, last).cmTime)
                    parameter.setVolume(0, at: start)
                    parameter.setVolume(level, at: end)
                }
            }
            return parameter
        }
        return mix
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: TimelineTime.projectTimescale)
    }
}

private struct AudioTimelineLevel {
    var start = 0.0, duration = 0.0, volume = 0.0, rise = 0.0, fall = 0.0
    var silences: [AudioActivityInterval] = []
    func gain(at time: Double) -> Double {
        let offset = time - start
        guard offset >= 0, offset <= duration,
              !silences.contains(where: { time >= $0.start && time < $0.end }) else { return 0 }
        let first = rise > 0 ? min(1, offset / rise) : 1
        let last = fall > 0 ? min(1, (duration - offset) / fall) : 1
        return volume * max(0, min(first, last))
    }
}

private final class AudioProcessingRegistry {
    var controls: [CMPersistentTrackID: AudioTapControl] = [:]
    var activity: [UUID: AudioActivityEnvelope] = [:]
}
