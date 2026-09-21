import Foundation

/// Presentation-only adapter: audio remains a real AudioClip in the project.
struct TimelineDisplayClip: Identifiable {
    let placement: ItemPlacement
    let assetID: UUID
    let sourceRange: TimelineRange
    let isAudio: Bool
    let isText: Bool
    let isShape: Bool
    /// Text and shapes: rows the app draws rather than reads from media. They
    /// share every timeline behaviour — no filmstrip, a short row, and free
    /// movement across the whole timeline rather than within one track.
    var isDrawnOverlay: Bool { isText || isShape }
    var title: String? = nil
    let isMuted: Bool
    let embeddedAudio: EmbeddedAudio?
    let speed: Double
    /// Fade lengths as they will actually be heard, so the timeline draws the
    /// same thing the mix applies.
    let fade: (rise: Double, fall: Double)
    var id: UUID { placement.id }
    init?(_ item: TimelineItem) {
        placement = item.placement
        switch item {
        case .video(let c):
            assetID = c.assetID; sourceRange = c.sourceRange; isAudio = false; isText = false; isShape = false
            isMuted = c.embeddedAudio?.isMuted ?? false; embeddedAudio = c.embeddedAudio
            speed = c.speed
            fade = c.embeddedAudio.map {
                AudioFade.resolved(duration: c.placement.duration.seconds, fadeIn: $0.fadeIn, fadeOut: $0.fadeOut)
            } ?? (0, 0)
        case .audio(let c):
            assetID = c.assetID; sourceRange = c.sourceRange; isAudio = true; isText = false; isShape = false
            isMuted = c.isMuted; embeddedAudio = nil
            speed = 1
            fade = AudioFade.resolved(duration: c.placement.duration.seconds,
                                      fadeIn: c.fadeIn, fadeOut: c.fadeOut)
        case .text(let c):
            assetID = c.id; sourceRange = .init(start: .zero, duration: c.placement.duration)
            isAudio = false; isText = true; isShape = false
            title = c.text.isEmpty ? "Text" : c.text.replacingOccurrences(of: "\n", with: " ")
            isMuted = false; embeddedAudio = nil; speed = 1; fade = (0, 0)
        case .shape(let c):
            assetID = c.id; sourceRange = .init(start: .zero, duration: c.placement.duration)
            isAudio = false; isText = false; isShape = true
            title = c.kind.title
            isMuted = false; embeddedAudio = nil; speed = 1; fade = (0, 0)
        }
    }
}

extension TimelineEditing {
    /// Magnetic anchors shared by clip moves and edge trims. Passing a track
    /// limits cuts to that row; a drawn overlay passes no track so its edges can
    /// meet the picture edits underneath it.
    private static func magnetBoundaries(
        clips: [TimelineDisplayClip],
        markers: [TimelineMarker],
        excluding clipID: UUID?,
        trackID: UUID?,
        playhead: Double?
    ) -> [Double] {
        var boundaries = [0.0]
        if let playhead { boundaries.append(playhead) }
        boundaries += markers.map { $0.time.seconds }
        for clip in clips where clip.id != clipID && (trackID == nil || clip.placement.trackID == trackID) {
            boundaries.append(clip.placement.timelineStart.seconds)
            if let end = try? clip.placement.range.end.seconds { boundaries.append(end) }
        }
        return boundaries.filter { $0 >= 0 && $0.isFinite }
    }

    /// Snaps one trim edge to a playhead, marker, or clip cut.
    static func snapClipEdge(
        _ seconds: Double,
        clips: [TimelineDisplayClip],
        markers: [TimelineMarker],
        excluding clipID: UUID? = nil,
        trackID: UUID? = nil,
        playhead: Double? = nil,
        tolerance: Double
    ) -> Double {
        let boundaries = magnetBoundaries(clips: clips, markers: markers, excluding: clipID,
                                           trackID: trackID, playhead: playhead)
        guard let nearest = boundaries.min(by: { abs($0-seconds) < abs($1-seconds) }),
              abs(nearest-seconds) <= tolerance else { return seconds }
        return nearest
    }

    /// Snaps either end of a moving layer. Returning the corresponding start
    /// lets a title's head or tail attach cleanly to a cut or marker.
    static func snapMovingClipStart(
        _ seconds: Double,
        duration: Double,
        clips: [TimelineDisplayClip],
        markers: [TimelineMarker],
        excluding clipID: UUID,
        playhead: Double? = nil,
        tolerance: Double
    ) -> Double {
        let boundaries = magnetBoundaries(clips: clips, markers: markers, excluding: clipID,
                                           trackID: nil, playhead: playhead)
        let candidates = boundaries + boundaries.map { $0-duration }
        guard let nearest = candidates.filter({ $0 >= 0 }).min(by: { abs($0-seconds) < abs($1-seconds) }),
              abs(nearest-seconds) <= tolerance else { return seconds }
        return nearest
    }

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
