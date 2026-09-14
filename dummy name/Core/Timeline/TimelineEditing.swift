import Foundation
import CoreMedia

enum TimelineGestureEdit: String { case move = "Move", trimStart = "Trim Start", trimEnd = "Trim End" }

/// Phase 3 deliberately supports non-overlapping main-track clips from the imported
/// asset. Other layers must wait for the compositing milestone, not be ignored.
enum TimelineEditing {
    /// Ripple deletion also closes pre-existing empty sections on the main track.
    static func deleteClosingGaps(_ id: UUID, in project: inout VideoProject) throws {
        let original = try editable(id, in: project)
        let ordered = try clips(in: project).filter { $0.placement.trackID == original.placement.trackID }
        var candidate = project
        try replace(id, with: [], in: &candidate)
        if project.timeline.tracks.first(where: { $0.id == original.placement.trackID })?.kind != .mainVideo {
            project = candidate; return
        }
        var cursor = TimelineTime.zero
        for var clip in ordered where clip.id != id {
            if clip.placement.timelineStart != cursor {
                clip.placement.timelineStart = cursor
                try replace(clip.id, with: [clip], in: &candidate)
            }
            cursor = try cursor.adding(clip.placement.duration)
        }
        _ = try clips(in: candidate)
        project = candidate
    }

    static func snapPlayhead(_ seconds: Double, clips: [VideoClip], markers: [TimelineMarker] = [], tolerance: Double) -> Double {
        var boundaries: [Double] = [0]
        for clip in clips {
            boundaries.append(clip.placement.timelineStart.seconds)
            if let end = try? clip.placement.range.end { boundaries.append(end.seconds) }
        }
        let duration = boundaries.max() ?? 0
        boundaries += markers.map { $0.time.seconds }.filter { $0 >= 0 && $0 <= duration }
        guard let nearest = boundaries.min(by: { abs($0-seconds) < abs($1-seconds) }),
              abs(nearest-seconds) <= tolerance else { return seconds }
        return nearest
    }
    static func splitTarget(in project: VideoProject, at time: TimelineTime, trackID: UUID? = nil) -> UUID? {
        guard let all = try? clips(in: project),
              case let clips = all.filter({ trackID == nil || $0.placement.trackID == trackID }),
              let clip = activeClip(in: clips, at: time.cmTime),
              (try? editable(clip.id, in: project)) != nil,
              let boundary = try? snapped(time, frame: project.canvas.frameDuration),
              let left = try? boundary.subtracting(clip.placement.timelineStart),
              let right = try? clip.placement.duration.subtracting(left) else { return nil }
        let minimum = project.canvas.frameDuration?.seconds ?? 0.01
        return left.seconds >= minimum && right.seconds >= minimum ? clip.id : nil
    }

    /// Drop between whole clips. Close the removed slot and open the destination
    /// slot, preserving source ranges and grades. Drops target clip boundaries.
    static func insertMove(_ id: UUID, to time: TimelineTime, in project: inout VideoProject) throws {
        var moving = try editable(id, in: project)
        let ordered = try clips(in: project).filter { $0.placement.trackID == moving.placement.trackID }
        if project.timeline.tracks.first(where: { $0.id == moving.placement.trackID })?.kind != .mainVideo {
            try move(id, to: time, in: &project); return
        }
        let remaining = ordered.filter { $0.id != id }
        let insertion = remaining.firstIndex {
            time.seconds < $0.placement.timelineStart.seconds + $0.placement.duration.seconds / 2
        } ?? remaining.count
        if ordered.firstIndex(where: { $0.id == id }) == insertion { return }
        let oldEnd = try moving.placement.range.end
        var shifted = try remaining.map { original -> VideoClip in
            var clip = original
            if clip.placement.timelineStart >= oldEnd {
                clip.placement.timelineStart = try clip.placement.timelineStart.subtracting(moving.placement.duration)
            }
            return clip
        }
        let destination: TimelineTime
        if insertion < shifted.count { destination = shifted[insertion].placement.timelineStart }
        else { destination = try shifted.last?.placement.range.end ?? .zero }
        for index in insertion..<shifted.count {
            shifted[index].placement.timelineStart = try shifted[index].placement.timelineStart.adding(moving.placement.duration)
        }
        moving.placement.timelineStart = destination
        shifted.insert(moving, at: insertion)
        var candidate = project
        for clip in shifted where project.timeline.videoClip(id: clip.id) != clip {
            try replace(clip.id, with: [clip], in: &candidate)
        }
        _ = try clips(in: candidate)
        project = candidate
    }

    /// Moves one visual clip between layers. Passing no destination creates a new
    /// overlay row at `newOverlayIndex`, which is the gesture used when a clip is
    /// pulled out of the main timeline. The edit is assembled on a copy so a
    /// locked target or an overlap can never leave the source track half-edited.
    static func moveToVideoLayer(
        _ id: UUID,
        destinationTrackID: UUID?,
        newOverlayIndex: Int? = nil,
        at time: TimelineTime,
        in project: inout VideoProject
    ) throws {
        let original = try editable(id, in: project)
        guard let sourceIndex = project.timeline.tracks.firstIndex(where: { $0.id == original.placement.trackID }),
              project.timeline.tracks[sourceIndex].kind == .mainVideo ||
                project.timeline.tracks[sourceIndex].kind == .videoOverlay else {
            throw TimelineError.invalid("Only video and image clips can move between visual layers.")
        }

        if destinationTrackID == original.placement.trackID {
            try insertMove(id, to: time, in: &project)
            return
        }

        var candidate = project
        guard let sourceItemIndex = candidate.timeline.tracks[sourceIndex].items.firstIndex(where: { $0.id == id }) else {
            throw TimelineError.invalid("Clip not found on its layer.")
        }
        candidate.timeline.tracks[sourceIndex].items.remove(at: sourceItemIndex)
        if candidate.timeline.tracks[sourceIndex].kind == .mainVideo {
            try pack(trackAt: sourceIndex, in: &candidate)
        }

        // Empty overlay rows disappear, just like CapCut's temporary overlay
        // lanes. The main row is permanent even when its last clip is lifted.
        var removedSourceIndex: Int?
        if candidate.timeline.tracks[sourceIndex].kind == .videoOverlay,
           candidate.timeline.tracks[sourceIndex].items.isEmpty {
            candidate.timeline.tracks.remove(at: sourceIndex)
            removedSourceIndex = sourceIndex
        }

        let destinationIndex: Int
        if let destinationTrackID {
            guard let index = candidate.timeline.tracks.firstIndex(where: { $0.id == destinationTrackID }) else {
                throw TimelineError.invalid("That destination layer is no longer available.")
            }
            destinationIndex = index
        } else {
            var insertion = min(max(newOverlayIndex ?? 0, 0), project.timeline.tracks.count)
            if let removedSourceIndex, removedSourceIndex < insertion { insertion -= 1 }
            insertion = min(max(insertion, 0), candidate.timeline.tracks.count)
            let number = candidate.timeline.tracks.filter { $0.kind == .videoOverlay }.count + 1
            candidate.timeline.tracks.insert(
                .init(id: UUID(), name: "Overlay \(number)", kind: .videoOverlay),
                at: insertion
            )
            destinationIndex = insertion
        }

        guard !candidate.timeline.tracks[destinationIndex].isLocked else {
            throw TimelineError.invalid("Unlock the destination layer before moving this clip.")
        }
        let destinationKind = candidate.timeline.tracks[destinationIndex].kind
        guard destinationKind == .mainVideo || destinationKind == .videoOverlay else {
            throw TimelineError.invalid("Video clips can only be dropped on video layers.")
        }

        var moving = original
        moving.placement.trackID = candidate.timeline.tracks[destinationIndex].id
        moving.placement.timelineStart = try snapped(max(.zero, time), frame: candidate.canvas.frameDuration)
        candidate.timeline.tracks[destinationIndex].items.append(.video(moving))

        if destinationKind == .mainVideo {
            try pack(trackAt: destinationIndex, in: &candidate)
        }
        _ = try clips(in: candidate)
        project = candidate
    }
    static func clips(in project: VideoProject) throws -> [VideoClip] {
        try project.validate()
        var result: [VideoClip] = []
        for track in project.timeline.tracks {
            if track.kind == .audio { try AudioEditing.validate(track); continue }
            if track.kind == .text { continue }
            guard track.kind == .mainVideo || track.kind == .videoOverlay else {
                throw TimelineError.invalid("Text tracks are not supported yet.")
            }
            let clips = try track.items.map { item -> VideoClip in
                guard case .video(let clip) = item,
                      clip.opacity.isFinite, (0...1).contains(clip.opacity),
                      [clip.transform.positionX, clip.transform.positionY, clip.transform.scale,
                       clip.transform.rotationDegrees, clip.transform.widthScale, clip.transform.heightScale,
                       clip.transform.anchorX, clip.transform.anchorY].allSatisfy(\.isFinite),
                      clip.transform.scale > 0, clip.transform.widthScale > 0, clip.transform.heightScale > 0 else {
                    throw TimelineError.invalid("Invalid visual clip or transform.")
                }
                return clip
            }.sorted { $0.placement.timelineStart < $1.placement.timelineStart }
            for pair in zip(clips, clips.dropFirst()) {
                guard try pair.0.placement.range.end <= pair.1.placement.timelineStart else {
                    throw TimelineError.invalid("Clips on the same track cannot overlap. Use an overlay track.")
                }
            }
            result += clips
        }
        return result
    }

    static func activeClip(in clips: [VideoClip], at time: CMTime) -> VideoClip? {
        guard let time = try? TimelineTime(time) else { return nil }
        return clips.first { clip in
            guard let end = try? clip.placement.range.end else { return false }
            return clip.placement.timelineStart <= time && time < end
        }
    }

    static func snapped(_ time: TimelineTime, frame: TimelineTime?) throws -> TimelineTime {
        guard let frame, frame > .zero else { return time }
        // Time from gestures is a UI boundary. Frame-count conversion happens once;
        // the resulting edit coordinate is an exact rational frame multiple.
        let count = (time.seconds / frame.seconds).rounded()
        guard count.isFinite, abs(count) < Double(Int32.max) else { throw TimelineError.invalid("Timeline is too long to snap safely.") }
        return try TimelineTime(CMTimeMultiply(frame.cmTime, multiplier: Int32(count)))
    }

    static func editable(_ id: UUID, in project: VideoProject) throws -> VideoClip {
        guard let clip = project.timeline.videoClip(id: id), !clip.placement.isLocked,
              project.timeline.tracks.first(where: { $0.id == clip.placement.trackID })?.isLocked == false else {
            throw TimelineError.invalid("Unlock the clip and its track before editing.")
        }
        return clip
    }

    static func replace(_ id: UUID, with clips: [VideoClip], in project: inout VideoProject) throws {
        let original = try editable(id, in: project)
        guard let track = project.timeline.tracks.firstIndex(where: { $0.id == original.placement.trackID }),
              let index = project.timeline.tracks[track].items.firstIndex(where: { $0.id == id }) else { return }
        project.timeline.tracks[track].items.replaceSubrange(index...index, with: clips.map(TimelineItem.video))
    }

    static func split(_ id: UUID, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        let original = try editable(id, in: project)
        let split = try snapped(time, frame: project.canvas.frameDuration)
        let leftDuration = try split.subtracting(original.placement.timelineStart)
        let rightDuration = try original.placement.duration.subtracting(leftDuration)
        let minimum = try project.canvas.frameDuration ?? TimelineTime.seconds(0.01)
        guard leftDuration >= minimum, rightDuration >= minimum else {
            throw TimelineError.invalid("Place the playhead inside the clip, at least one frame from either edge.")
        }
        // Timeline distance is not source distance on a retimed clip: at 2x, the
        // left half covers twice as much source as it does timeline. Splitting
        // with the raw timeline durations produced a source range that ran past
        // the end of the media.
        let leftSource = try ClipSpeed.sourceDuration(timelineDuration: leftDuration, speed: original.speed)
        // Derived by subtraction rather than converted again, so the two halves
        // always account for exactly the original source range with nothing lost
        // or duplicated at the seam.
        let rightSource = try original.sourceRange.duration.subtracting(leftSource)
        guard leftSource > .zero, rightSource > .zero else {
            throw TimelineError.invalid("Place the playhead inside the clip, at least one frame from either edge.")
        }

        var left = original, right = original
        left.sourceRange.duration = leftSource
        left.placement.duration = try ClipSpeed.timelineDuration(sourceDuration: leftSource, speed: original.speed)
        // The right half starts where the left one actually ends, so rounding in
        // the conversion can never open a gap or an overlap between them.
        let seam = try original.placement.timelineStart.adding(left.placement.duration)
        right.placement = .init(
            id: UUID(), trackID: original.placement.trackID, timelineStart: seam,
            duration: try ClipSpeed.timelineDuration(sourceDuration: rightSource, speed: original.speed)
        )
        right.sourceRange = .init(start: try original.sourceRange.start.adding(leftSource), duration: rightSource)
        // Same rule as text: keep the whole curve on both halves and move the window.
        right.shiftAnimationWindow(by: left.placement.duration)
        // An audio fade belongs to the edge it was drawn on, so each half keeps
        // only the one that is still on an outside edge.
        left.embeddedAudio?.fadeOut = nil
        right.embeddedAudio?.fadeIn = nil
        try replace(id, with: [left, right], in: &project)
        // The original ID remains on the left. A transition attached to the
        // original clip's old right edge must follow that edge to the new right
        // half; a transition at the original left edge correctly stays put.
        for index in project.timeline.transitions.indices
        where project.timeline.transitions[index].outgoingClipID == id &&
              project.timeline.transitions[index].editTime > split {
            project.timeline.transitions[index].outgoingClipID = right.id
        }
        return right.id
    }

    enum Edge { case left, right }
    static func trimClosingGaps(_ id: UUID, edge: Edge, to time: TimelineTime, in project: inout VideoProject) throws {
        var candidate = project
        try trim(id, edge: edge, to: time, clamping: true, in: &candidate)
        let trackID = try editable(id, in: candidate).placement.trackID
        guard let index = candidate.timeline.tracks.firstIndex(where: { $0.id == trackID }),
              candidate.timeline.tracks[index].kind == .mainVideo else {
            project = candidate; return
        }
        // Packed before anything validates the result. Growing a clip on a
        // gapless track momentarily overlaps the one after it, and that overlap
        // is not an error to report — it is the thing this closes by moving the
        // neighbour along.
        try pack(trackAt: index, in: &candidate)
        _ = try clips(in: candidate)
        project = candidate
    }

    /// Lays a gapless track out from zero, in start order.
    ///
    /// This is the whole ripple: a clip that grew pushes everything after it
    /// further along, and a clip that shrank pulls them back. Both directions
    /// are the same operation, which is why extending is no longer blocked by
    /// whatever happens to sit next to the clip.
    private static func pack(trackAt index: Int, in project: inout VideoProject) throws {
        var items = project.timeline.tracks[index].items
            .sorted { $0.placement.timelineStart < $1.placement.timelineStart }
        var cursor = TimelineTime.zero
        for position in items.indices {
            guard case .video(var clip) = items[position] else {
                cursor = try cursor.adding(items[position].placement.duration)
                continue
            }
            if clip.placement.timelineStart != cursor {
                clip.placement.timelineStart = cursor
                items[position] = .video(clip)
            }
            cursor = try cursor.adding(clip.placement.duration)
        }
        project.timeline.tracks[index].items = items
    }

    static func trim(_ id: UUID, edge: Edge, to time: TimelineTime, clamping: Bool = false, in project: inout VideoProject) throws {
        var clip = try editable(id, in: project)
        var boundary = try snapped(time, frame: project.canvas.frameDuration)
        let end = try clip.placement.range.end
        let minimum = try project.canvas.frameDuration ?? TimelineTime.seconds(0.01)
        if clamping {
            let others = try clips(in: project).filter { $0.id != id && $0.placement.trackID == clip.placement.trackID }
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { throw TimelineError.invalid("Missing source.") }
            let source = asset.sourceRange
            // The main video track is repacked from zero after every timing
            // edit, so a neighbour there is not a wall: it is something that
            // moves out of the way. Overlay tracks keep their positions and
            // cannot overlap, so they keep the hard limits.
            let ripples = project.timeline.tracks
                .first { $0.id == clip.placement.trackID }?.kind == .mainVideo
            if edge == .left {
                let available = try clip.sourceRange.start.subtracting(source.start)
                var lower = max(.zero, try clip.placement.timelineStart.subtracting(available))
                for other in others where other.placement.timelineStart < clip.placement.timelineStart {
                    // A rippling neighbour only has to keep its order. Stopping
                    // one frame short of its start is what guarantees that:
                    // repacking sorts by start time, and two clips that crossed
                    // would come back in the wrong order.
                    lower = max(lower, ripples
                        ? try other.placement.timelineStart.adding(minimum)
                        : try other.placement.range.end)
                }
                boundary = max(lower, min(boundary, try end.subtracting(minimum)))
            } else {
                let available = asset.stillImage != nil ? try max(.zero, time.subtracting(end)) : try source.end.subtracting(clip.sourceRange.end)
                var upper = try end.adding(available)
                if !ripples {
                    for other in others where other.placement.timelineStart >= end {
                        upper = min(upper, other.placement.timelineStart)
                    }
                }
                boundary = min(upper, max(boundary, try clip.placement.timelineStart.adding(minimum)))
            }
        }
        if edge == .left {
            // The edge moved `delta` along the timeline; the source that hides is
            // that distance at the clip's speed, which for a retimed clip is not
            // the same number.
            let delta = try boundary.subtracting(clip.placement.timelineStart)
            let sourceDelta = try ClipSpeed.sourceDuration(timelineDuration: delta, speed: clip.speed)
            clip.sourceRange.start = try clip.sourceRange.start.adding(sourceDelta)
            clip.placement.timelineStart = boundary
            clip.placement.duration = try end.subtracting(boundary)
            // Head trims hide animation rather than discarding it; extending restores it.
            clip.shiftAnimationWindow(by: delta)
        } else {
            clip.placement.duration = try boundary.subtracting(clip.placement.timelineStart)
        }
        clip.sourceRange.duration = try ClipSpeed.sourceDuration(
            timelineDuration: clip.placement.duration, speed: clip.speed
        )
        // Re-derive from the stored source so the document invariant
        // (timeline duration == source duration / speed) holds exactly rather
        // than approximately after the conversion rounds.
        clip.placement.duration = try ClipSpeed.timelineDuration(
            sourceDuration: clip.sourceRange.duration, speed: clip.speed
        )
        guard clip.placement.duration >= minimum else { throw TimelineError.invalid("Keep at least one frame in the clip.") }
        try replace(id, with: [clip], in: &project)
    }

    /// Changes a clip's playback speed.
    ///
    /// The clip's source range is untouched — the same frames play, just over a
    /// different span of timeline — and everything after it on the track ripples
    /// so no clip is overwritten or left with a gap it did not have.
    static func setSpeed(
        _ id: UUID,
        to speed: Double,
        in project: inout VideoProject
    ) throws {
        var clip = try editable(id, in: project)
        let resolved = ClipSpeed.clamped(speed)
        guard resolved != clip.speed else { return }

        let newDuration = try ClipSpeed.timelineDuration(
            sourceDuration: clip.sourceRange.duration, speed: resolved
        )
        guard newDuration > .zero else {
            throw TimelineError.invalid("That speed would leave the clip with no duration.")
        }
        let previousDuration = clip.placement.duration
        let shift = try newDuration.subtracting(previousDuration)

        // Keyframe times are clip-local timeline coordinates, so they scale with
        // the clip rather than staying at absolute offsets that would fall
        // outside it.
        if previousDuration > .zero {
            let factor = newDuration.seconds / previousDuration.seconds
            if let animation = clip.animation, !animation.isEmpty {
                clip.animation = animation.retimed(by: factor)
            }
            // Mask geometry keyframes are clip-local times too, and they live on
            // the mask rather than on the clip, so they need the same scaling.
            if let masks = clip.maskedGrades, masks.contains(where: \.isAnimated) {
                clip.maskedGrades = masks.map { $0.retimed(by: factor) }
            }
        }
        clip.speed = resolved
        clip.placement.duration = newDuration

        // Read the clips to ripple from the timeline as it stands NOW, before the
        // clip is lengthened. Reading them afterwards means asking `clips(in:)`
        // to validate a timeline in which the longer clip already sits on top of
        // its neighbour, and it refuses that ("Clips on the same track cannot
        // overlap") before the ripple that would resolve it can run. Slowing a
        // clip with anything after it on the track was rejected for that reason
        // alone; a clip at the end of the track had nothing to overlap, so it
        // worked, which is what made the failure look arbitrary.
        let following = try clips(in: project)
            .filter { $0.placement.trackID == clip.placement.trackID
                && $0.id != clip.id
                && $0.placement.timelineStart >= clip.placement.timelineStart }

        var updated = project
        try replace(id, with: [clip], in: &updated)

        // Ripple the rest of the track by the change in length. Speeding a clip
        // up shortens it, so the shift is negative and the clips after it move
        // back to close the gap.
        if shift != .zero {
            for var other in following {
                other.placement.timelineStart = try other.placement.timelineStart.adding(shift)
                try replace(other.id, with: [other], in: &updated)
            }
        }
        try updated.validate()
        project = updated
    }

    static func move(_ id: UUID, to time: TimelineTime, in project: inout VideoProject) throws {
        var clip = try editable(id, in: project)
        clip.placement.timelineStart = try snapped(max(.zero, time), frame: project.canvas.frameDuration)
        try replace(id, with: [clip], in: &project)
    }

    static func paste(_ copied: VideoClip, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        guard let index = project.timeline.tracks.firstIndex(where: { $0.kind == .mainVideo }),
              !project.timeline.tracks[index].isLocked else { throw TimelineError.invalid("Unlock the main track before pasting.") }
        var clip = copied
        clip.placement = .init(id: UUID(), trackID: project.timeline.tracks[index].id,
            timelineStart: try snapped(max(.zero, time), frame: project.canvas.frameDuration), duration: copied.placement.duration)
        project.timeline.tracks[index].items.append(.video(clip))
        return clip.id
    }
}

struct TimelineHistory {
    struct Entry { let name: String; let before: VideoProject; let after: VideoProject }
    private(set) var undoEntries: [Entry] = []
    private(set) var redoEntries: [Entry] = []
    mutating func record(_ name: String, before: VideoProject, after: VideoProject) {
        guard before.timeline != after.timeline || before.canvas != after.canvas else { return }
        undoEntries.append(.init(name: name, before: before, after: after))
        if undoEntries.count > 100 { undoEntries.removeFirst() }
        redoEntries.removeAll()
    }
    mutating func undo() -> VideoProject? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(entry); return entry.before
    }
    mutating func redo() -> VideoProject? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(entry); return entry.after
    }
}
