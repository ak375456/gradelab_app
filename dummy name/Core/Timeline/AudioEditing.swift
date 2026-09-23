import Foundation

extension Timeline {
    var items: [TimelineItem] { tracks.flatMap(\.items) }
    var audioClips: [AudioClip] { items.compactMap { if case .audio(let c) = $0 { return c }; return nil } }
    func item(id: UUID) -> TimelineItem? { items.first { $0.id == id } }
    func audioClip(id: UUID) -> AudioClip? { audioClips.first { $0.id == id } }
}

/// Audio edits preserve source media and never ripple unrelated video or audio.
enum AudioEditing {
    static func editable(_ id: UUID, in project: VideoProject) throws -> AudioClip {
        guard let clip = project.timeline.audioClip(id: id), !clip.placement.isLocked,
              project.timeline.tracks.first(where: { $0.id == clip.placement.trackID })?.isLocked == false else {
            throw TimelineError.invalid(String(localized: "Unlock the audio track before editing."))
        }
        return clip
    }
    static func replace(_ id: UUID, with clips: [AudioClip], in project: inout VideoProject) throws {
        let original = try editable(id, in: project)
        guard let t = project.timeline.tracks.firstIndex(where: { $0.id == original.placement.trackID }),
              let i = project.timeline.tracks[t].items.firstIndex(where: { $0.id == id }) else { return }
        project.timeline.tracks[t].items.replaceSubrange(i...i, with: clips.map(TimelineItem.audio))
        if project.timeline.tracks[t].items.isEmpty { project.timeline.tracks.remove(at: t) }
    }
    static func validate(_ track: TimelineTrack) throws {
        let ordered = track.items.sorted { $0.placement.timelineStart < $1.placement.timelineStart }
        for item in ordered {
            guard case .audio(let clip) = item, clip.volume.isFinite, (0...1).contains(clip.volume),
                  clip.fadeIn.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  clip.fadeOut.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  clip.sourceTrackIndex.map({ $0 >= 0 }) ?? true else { throw TimelineError.invalid(String(localized: "Invalid audio clip.")) }
        }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            guard try left.placement.range.end <= right.placement.timelineStart else {
                throw TimelineError.invalid(String(localized: "Audio clips on this track cannot overlap. Paste onto a new audio track to mix them."))
            }
        }
    }
    static func separate(_ id: UUID, in project: inout VideoProject) throws -> UUID {
        var candidate = project
        var video = try TimelineEditing.editable(id, in: candidate)
        guard let linked = video.embeddedAudio else { throw TimelineError.invalid(String(localized: "This clip has no linked audio to separate.")) }
        let trackID = UUID()
        let clip = AudioClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: video.placement.timelineStart,
            duration: video.placement.duration, isEnabled: video.placement.isEnabled), assetID: video.assetID,
            sourceRange: video.sourceRange, volume: linked.volume, isMuted: linked.isMuted)
        let enabled = candidate.timeline.tracks.first { $0.id == video.placement.trackID }?.isEnabled ?? true
        video.embeddedAudio = nil
        try TimelineEditing.replace(id, with: [video], in: &candidate)
        candidate.timeline.tracks.append(.init(id: trackID, name: "Separated audio", kind: .audio, isEnabled: enabled, items: [.audio(clip)]))
        try candidate.validate(); project = candidate
        return clip.id
    }
    static func splitTarget(in project: VideoProject, at time: TimelineTime, trackID: UUID?) -> UUID? {
        guard let boundary = try? TimelineEditing.snapped(time, frame: project.canvas.frameDuration) else { return nil }
        let minimum = project.canvas.frameDuration?.seconds ?? 0.01
        return project.timeline.audioClips.first { clip in
            clip.placement.trackID == trackID && (try? editable(clip.id, in: project)) != nil &&
            boundary.seconds - clip.placement.timelineStart.seconds >= minimum - 0.000001 &&
            ((try? clip.placement.range.end.seconds) ?? 0) - boundary.seconds >= minimum - 0.000001
        }?.id
    }
    static func split(_ id: UUID, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        var left = try editable(id, in: project)
        let boundary = try TimelineEditing.snapped(time, frame: project.canvas.frameDuration)
        guard splitTarget(in: project, at: boundary, trackID: left.placement.trackID) == id else {
            throw TimelineError.invalid(String(localized: "Place the playhead inside the audio clip, away from its edges."))
        }
        let length = try boundary.subtracting(left.placement.timelineStart)
        var right = left
        right.placement = .init(id: UUID(), trackID: left.placement.trackID, timelineStart: boundary,
            duration: try left.placement.duration.subtracting(length), isEnabled: left.placement.isEnabled)
        right.sourceRange = .init(start: try left.sourceRange.start.adding(length), duration: right.placement.duration)
        left.placement.duration = length; left.sourceRange.duration = length
        // A fade belongs to the edge it was drawn on. Copying both halves' fades
        // wholesale would leave a fade-out in the middle of the sound and a
        // fade-in after it.
        left.fadeOut = nil
        right.fadeIn = nil
        try replace(id, with: [left, right], in: &project)
        return right.id
    }
    static func edit(_ id: UUID, operation: TimelineGestureEdit, to time: TimelineTime, clamping: Bool = false, in project: inout VideoProject) throws {
        var clip = try editable(id, in: project)
        var target = max(.zero, try TimelineEditing.snapped(time, frame: project.canvas.frameDuration))
        let minimum = try project.canvas.frameDuration ?? TimelineTime.seconds(0.01)
        if clamping, operation != .move {
            guard let media = project.assets.first(where: { $0.id == clip.assetID }) else { throw TimelineError.invalid(String(localized: "Audio source is missing.")) }
            let end = try clip.placement.range.end
            let others = project.timeline.audioClips.filter { $0.id != id && $0.placement.trackID == clip.placement.trackID }
            if operation == .trimStart {
                let available = try clip.sourceRange.start.subtracting(media.sourceRange.start)
                var lower = max(.zero, try clip.placement.timelineStart.subtracting(available))
                for other in others where other.placement.timelineStart < clip.placement.timelineStart { lower = max(lower, try other.placement.range.end) }
                target = max(lower, min(target, try end.subtracting(minimum)))
            } else {
                var upper = try end.adding(media.sourceRange.end.subtracting(clip.sourceRange.end))
                for other in others where other.placement.timelineStart >= end { upper = min(upper, other.placement.timelineStart) }
                target = min(upper, max(target, try clip.placement.timelineStart.adding(minimum)))
            }
        }
        switch operation {
        case .move:
            // A row holds a sequence, so a move stops against whatever else is
            // on this one rather than being refused for landing on it.
            clip.placement.timelineStart = try TimelineEditing.clampedStart(
                target, duration: clip.placement.duration, itemID: id,
                on: clip.placement.trackID, fallback: clip.placement.timelineStart, in: project)
        case .trimStart:
            let delta = try target.subtracting(clip.placement.timelineStart)
            clip.sourceRange.start = try clip.sourceRange.start.adding(delta)
            clip.placement.duration = try clip.placement.duration.subtracting(delta)
            clip.placement.timelineStart = target
        case .trimEnd: clip.placement.duration = try target.subtracting(clip.placement.timelineStart)
        }
        guard clip.placement.duration >= minimum else {
            throw TimelineError.invalid(String(localized: "Keep at least one frame of audio."))
        }
        clip.sourceRange.duration = clip.placement.duration
        var candidate = project
        try replace(id, with: [clip], in: &candidate)
        _ = try TimelineEditing.clips(in: candidate); project = candidate
    }
    static func paste(_ original: AudioClip, at time: TimelineTime, trackID: UUID?, in project: inout VideoProject) throws -> UUID {
        var clip = original
        let start = max(.zero, try TimelineEditing.snapped(time, frame: project.canvas.frameDuration))
        let end = try start.adding(clip.placement.duration)
        var index = project.timeline.tracks.firstIndex { $0.id == trackID && $0.kind == .audio }
        if let i = index {
            guard !project.timeline.tracks[i].isLocked else { throw TimelineError.invalid(String(localized: "Unlock this audio track before pasting.")) }
            if project.timeline.tracks[i].items.contains(where: { $0.placement.timelineStart < end && ((try? $0.placement.range.end) ?? .zero) > start }) { index = nil }
        }
        if index == nil {
            project.timeline.tracks.append(.init(id: UUID(), name: "Audio", kind: .audio))
            index = project.timeline.tracks.count - 1
        }
        let i = index!
        clip.placement = .init(id: UUID(), trackID: project.timeline.tracks[i].id, timelineStart: start,
            duration: original.placement.duration, isEnabled: original.placement.isEnabled)
        project.timeline.tracks[i].items.append(.audio(clip))
        return clip.id
    }
}
