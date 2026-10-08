@preconcurrency import AVFoundation

/// Composition track IDs stay stable during live volume changes. The same mix
/// is attached to AVPlayerItem and AVAssetReaderAudioMixOutput.
struct TimelineAudioMix {
    var clipsByTrack: [CMPersistentTrackID: UUID] = [:]
    func makeMix(_ project: VideoProject) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = clipsByTrack.map { trackID, clipID in
            let parameter = AVMutableAudioMixInputParameters()
            parameter.trackID = trackID
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
            // Fades are ramps on the same input parameters the level uses, so
            // preview and export get them from one place and cannot disagree.
            // Each clip owns its own composition track, so a ramp addresses one
            // clip and nothing else.
            if level > 0, let placement, fade.rise > 0 || fade.fall > 0 {
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
            if let clip = project.timeline.videoClip(id: clipID) {
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
