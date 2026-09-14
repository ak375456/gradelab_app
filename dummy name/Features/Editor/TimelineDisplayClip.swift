import Foundation

/// Presentation-only adapter: audio remains a real AudioClip in the project.
struct TimelineDisplayClip: Identifiable {
    let placement: ItemPlacement
    let assetID: UUID
    let sourceRange: TimelineRange
    let isAudio: Bool
    let isText: Bool
    var title: String? = nil
    let isMuted: Bool
    let embeddedAudio: EmbeddedAudio?
    /// Fade lengths as they will actually be heard, so the timeline draws the
    /// same thing the mix applies.
    let fade: (rise: Double, fall: Double)
    var id: UUID { placement.id }
    init?(_ item: TimelineItem) {
        placement = item.placement
        switch item {
        case .video(let c):
            assetID = c.assetID; sourceRange = c.sourceRange; isAudio = false; isText = false
            isMuted = c.embeddedAudio?.isMuted ?? false; embeddedAudio = c.embeddedAudio
            fade = c.embeddedAudio.map {
                AudioFade.resolved(duration: c.placement.duration.seconds, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut)
            } ?? (0, 0)
        case .audio(let c):
            assetID = c.assetID; sourceRange = c.sourceRange; isAudio = true; isText = false
            isMuted = c.isMuted; embeddedAudio = nil
            fade = AudioFade.resolved(duration: c.placement.duration.seconds,
                                      fadeIn: c.fadeIn, fadeOut: c.fadeOut)
        case .text(let c):
            assetID = c.id; sourceRange = .init(start: .zero, duration: c.placement.duration); isAudio = false; isText = true
            title = c.text.isEmpty ? "Text" : c.text.replacingOccurrences(of: "\n", with: " ")
            isMuted = false; embeddedAudio = nil; fade = (0, 0)
        }
    }
}

extension TimelineEditing {
    /// The playhead magnet. `keyframes` are the selected clip's keyframe times, so scrubbing
    /// lands exactly on a keyframe the same way it lands on a cut or a marker.
    static func snapPlayhead(_ seconds: Double, clips: [TimelineDisplayClip], markers: [TimelineMarker],
                             keyframes: [Double] = [], tolerance: Double) -> Double {
        var boundaries: [Double] = [0]
        for clip in clips {
            boundaries.append(clip.placement.timelineStart.seconds)
            if let end = try? clip.placement.range.end { boundaries.append(end.seconds) }
        }
        let duration = boundaries.max() ?? 0
        boundaries += markers.map { $0.time.seconds }.filter { $0 >= 0 && $0 <= duration }
        boundaries += keyframes.filter { $0 >= 0 && $0 <= duration }
        guard let nearest = boundaries.min(by: { abs($0-seconds) < abs($1-seconds) }), abs(nearest-seconds) <= tolerance else { return seconds }
        return nearest
    }
}
