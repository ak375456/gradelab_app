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
            throw TimelineError.invalid(String(localized: "Only video and image clips can move between visual layers."))
        }

        if destinationTrackID == original.placement.trackID {
            try insertMove(id, to: time, in: &project)
            return
        }

        var candidate = project
        guard let sourceItemIndex = candidate.timeline.tracks[sourceIndex].items.firstIndex(where: { $0.id == id }) else {
            throw TimelineError.invalid(String(localized: "Clip not found on its layer."))
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
                throw TimelineError.invalid(String(localized: "That destination layer is no longer available."))
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
            throw TimelineError.invalid(String(localized: "Unlock the destination layer before moving this clip."))
        }
        let destinationKind = candidate.timeline.tracks[destinationIndex].kind
        guard destinationKind == .mainVideo || destinationKind == .videoOverlay else {
            throw TimelineError.invalid(String(localized: "Video clips can only be dropped on video layers."))
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
    /// Whether an item would be sounding, or on screen, at the same time as
    /// something already on a row.
    ///
    /// Clips that merely touch — one ending exactly where the next begins — do
    /// not overlap. That is the whole point: a row holds a *sequence*, so a
    /// second sound or title may share it with one already there as long as the
    /// two never run together.
    static func overlaps(_ item: TimelineItem, in track: TimelineTrack) -> Bool {
        guard let end = try? item.placement.range.end else { return true }
        let start = item.placement.timelineStart
        return track.items.contains { other in
            guard other.id != item.id, let otherEnd = try? other.placement.range.end else { return false }
            return start < otherEnd && other.placement.timelineStart < end
        }
    }

    /// Keeps a clip inside the gap it is being dragged through, so a row
    /// holding several clips slides them up against each other instead of
    /// refusing the edit.
    ///
    /// The bounds are its neighbours on that row: the end of the last clip
    /// starting before the target, and the start of the first clip beginning at
    /// or after it. A gap too short to hold the clip leaves it where it was —
    /// there is nowhere to put it, and sliding it somewhere else entirely is not
    /// what the drag asked for.
    static func clampedStart(_ target: TimelineTime, duration: TimelineTime, itemID: UUID,
                             on trackID: UUID, fallback: TimelineTime,
                             in project: VideoProject) throws -> TimelineTime {
        guard let track = project.timeline.tracks.first(where: { $0.id == trackID }),
              track.items.contains(where: { $0.id != itemID }) else { return target }
        var lower = TimelineTime.zero
        var upper: TimelineTime?
        for other in track.items where other.id != itemID {
            let otherEnd = try other.placement.range.end
            if other.placement.timelineStart <= target {
                if otherEnd > lower { lower = otherEnd }
            } else if upper.map({ other.placement.timelineStart < $0 }) ?? true {
                upper = other.placement.timelineStart
            }
        }
        let latest = try upper.map { try $0.subtracting(duration) }
        guard latest.map({ lower <= $0 }) ?? true else { return fallback }
        var result = max(target, lower)
        if let latest { result = min(result, latest) }
        return result
    }

    /// Moves one item to another row of its own kind, or to a new row of that
    /// kind when no destination is given.
    ///
    /// Video keeps its own path below: the main row packs from zero and its
    /// overlays have stacking rules. Audio, text and shapes all behave the same
    /// way — a plain non-overlapping sequence per row — so they share one body.
    static func moveToLayer(_ id: UUID, destinationTrackID: UUID?, newTrackIndex: Int? = nil,
                            at time: TimelineTime, in project: inout VideoProject) throws {
        guard let item = project.timeline.item(id: id) else {
            throw TimelineError.invalid(String(localized: "That clip is no longer on the timeline."))
        }
        if case .video = item {
            try moveToVideoLayer(id, destinationTrackID: destinationTrackID,
                                 newOverlayIndex: newTrackIndex, at: time, in: &project)
            return
        }
        try moveToSequencedLayer(item, destinationTrackID: destinationTrackID,
                                 newTrackIndex: newTrackIndex, at: time, in: &project)
    }

    /// The move for rows that hold nothing but a non-overlapping sequence.
    ///
    /// A destination that has gone away, is locked, holds another kind, or is
    /// already busy at this moment gets the clip a fresh row instead of an
    /// error. The drag preview and this frame-snapped result can disagree by
    /// less than a frame, and a sub-frame disagreement is not something to hand
    /// back to somebody as a failed edit. Assembled on a copy, so none of those
    /// outcomes can leave the source row half-edited.
    private static func moveToSequencedLayer(
        _ item: TimelineItem,
        destinationTrackID: UUID?,
        newTrackIndex: Int?,
        at time: TimelineTime,
        in project: inout VideoProject
    ) throws {
        let kind = item.trackKind
        guard let sourceIndex = project.timeline.tracks.firstIndex(where: { $0.id == item.placement.trackID }),
              !project.timeline.tracks[sourceIndex].isLocked, !item.placement.isLocked else {
            throw TimelineError.invalid(String(localized: "Unlock this clip's layer before moving it."))
        }
        var placement = item.placement
        placement.timelineStart = max(.zero, try snapped(time, frame: project.canvas.frameDuration))

        // Dropped back on the row it started from, this is an ordinary move.
        // Taking the general path would empty the row, delete it for being
        // empty, and build a replacement — costing the row its name, its
        // height, its lock and the identity the timeline keys those to.
        if destinationTrackID == item.placement.trackID {
            placement.timelineStart = try clampedStart(
                placement.timelineStart, duration: placement.duration, itemID: item.id,
                on: item.placement.trackID, fallback: item.placement.timelineStart, in: project)
            var candidate = project
            let row = candidate.timeline.tracks.firstIndex { $0.id == item.placement.trackID }!
            let slot = candidate.timeline.tracks[row].items.firstIndex { $0.id == item.id }!
            candidate.timeline.tracks[row].items[slot] = item.withPlacement(placement)
            _ = try clips(in: candidate)
            project = candidate
            return
        }
        let placed = item.withPlacement(placement)

        var candidate = project
        candidate.timeline.tracks[sourceIndex].items.removeAll { $0.id == item.id }

        // An emptied row disappears, the same way it does when its last clip is
        // deleted. That shifts every later index, so the destination is resolved
        // by identity afterwards rather than from an index read before the
        // removal.
        var removedSourceIndex: Int?
        if candidate.timeline.tracks[sourceIndex].items.isEmpty {
            candidate.timeline.tracks.remove(at: sourceIndex)
            removedSourceIndex = sourceIndex
        }

        var destination = destinationTrackID.flatMap { id in
            candidate.timeline.tracks.firstIndex { $0.id == id }
        }
        if let index = destination,
           candidate.timeline.tracks[index].isLocked
            || candidate.timeline.tracks[index].kind != kind
            || overlaps(placed, in: candidate.timeline.tracks[index]) {
            destination = nil
        }

        let target: Int
        if let destination {
            target = destination
        } else {
            // Sound goes under the picture and drawn layers go over it, which is
            // where each was put when it was added and where the eye expects to
            // find it. Enforced here rather than trusted to the caller: a drawn
            // layer under the picture is simply hidden by it, so an index that
            // says otherwise is a mistake whatever asked for it.
            var insertion = newTrackIndex ?? (kind == .audio ? project.timeline.tracks.count : 0)
            if let removedSourceIndex, removedSourceIndex < insertion { insertion -= 1 }
            let main = candidate.timeline.tracks.firstIndex { $0.kind == .mainVideo }
                ?? candidate.timeline.tracks.count
            insertion = kind == .audio ? max(insertion, main + 1) : min(insertion, main)
            insertion = min(max(insertion, 0), candidate.timeline.tracks.count)
            candidate.timeline.tracks.insert(
                .init(id: UUID(), name: TimelineTrack.defaultName(for: kind), kind: kind), at: insertion)
            target = insertion
        }

        placement.trackID = candidate.timeline.tracks[target].id
        candidate.timeline.tracks[target].items.append(placed.withPlacement(placement))
        _ = try clips(in: candidate)
        project = candidate
    }

    static func clips(in project: VideoProject) throws -> [VideoClip] {
        try project.validate()
        var result: [VideoClip] = []
        for track in project.timeline.tracks {
            if track.kind == .audio { try AudioEditing.validate(track); continue }
            if track.kind == .text || track.kind == .shape { continue }
            guard track.kind == .mainVideo || track.kind == .videoOverlay else {
                throw TimelineError.invalid(String(localized: "Only video, audio and drawn overlay tracks are supported."))
            }
            let clips = try track.items.map { item -> VideoClip in
                guard case .video(let clip) = item,
                      clip.opacity.isFinite, (0...1).contains(clip.opacity),
                      [clip.transform.positionX, clip.transform.positionY, clip.transform.scale,
                       clip.transform.rotationDegrees, clip.transform.widthScale, clip.transform.heightScale,
                       clip.transform.anchorX, clip.transform.anchorY].allSatisfy(\.isFinite),
                      clip.transform.scale > 0, clip.transform.widthScale > 0, clip.transform.heightScale > 0 else {
                    throw TimelineError.invalid(String(localized: "Invalid visual clip or transform."))
                }
                return clip
            }.sorted { $0.placement.timelineStart < $1.placement.timelineStart }
            for pair in zip(clips, clips.dropFirst()) {
                guard try pair.0.placement.range.end <= pair.1.placement.timelineStart else {
                    throw TimelineError.invalid(String(localized: "Clips on the same track cannot overlap. Use an overlay track."))
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
        guard count.isFinite, abs(count) < Double(Int32.max) else { throw TimelineError.invalid(String(localized: "Timeline is too long to snap safely.")) }
        return try TimelineTime(CMTimeMultiply(frame.cmTime, multiplier: Int32(count)))
    }

    static func editable(_ id: UUID, in project: VideoProject) throws -> VideoClip {
        guard let clip = project.timeline.videoClip(id: id), !clip.placement.isLocked,
              project.timeline.tracks.first(where: { $0.id == clip.placement.trackID })?.isLocked == false else {
            throw TimelineError.invalid(String(localized: "Unlock the clip and its track before editing."))
        }
        return clip
    }

    static func replace(_ id: UUID, with clips: [VideoClip], in project: inout VideoProject) throws {
        let original = try editable(id, in: project)
        guard let track = project.timeline.tracks.firstIndex(where: { $0.id == original.placement.trackID }),
              let index = project.timeline.tracks[track].items.firstIndex(where: { $0.id == id }) else { return }
        project.timeline.tracks[track].items.replaceSubrange(index...index, with: clips.map(TimelineItem.video))
        // Removing a clip that another layer used as its track matte clears that
        // relationship here, in the same mutation, so nothing downstream ever
        // sees — or refuses — a reference to a clip that is gone.
        project.timeline.reconcileTrackMattes()
    }

    static func split(_ id: UUID, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        let original = try editable(id, in: project)
        let split = try snapped(time, frame: project.canvas.frameDuration)
        let leftDuration = try split.subtracting(original.placement.timelineStart)
        let rightDuration = try original.placement.duration.subtracting(leftDuration)
        let minimum = try project.canvas.frameDuration ?? TimelineTime.seconds(0.01)
        guard leftDuration >= minimum, rightDuration >= minimum else {
            throw TimelineError.invalid(String(localized: "Place the playhead inside the clip, at least one frame from either edge."))
        }
        // Timeline distance is not source distance on a retimed clip: at 2x, the
        // left half covers twice as much source as it does timeline. Splitting
        // with the raw timeline durations produced a source range that ran past
        // the end of the media.
        let leftSource = try original.sourceDuration(forTimelineDuration: leftDuration)
        // Derived by subtraction rather than converted again, so the two halves
        // always account for exactly the original source range with nothing lost
        // or duplicated at the seam.
        let rightSource = try original.sourceRange.duration.subtracting(leftSource)
        guard leftSource > .zero, rightSource > .zero else {
            throw TimelineError.invalid(String(localized: "Place the playhead inside the clip, at least one frame from either edge."))
        }

        var left = original, right = original
        // A ramped clip's curve is cut at the same source frame the picture is,
        // and a reversed one takes its two halves from opposite ends of the
        // source — the first half of a backwards clip is the LAST of the media.
        if original.isRamped || original.isReversed {
            let (leading, trailing) = original.resolvedRemap.split(
                atSourceOffset: leftSource, sourceDuration: original.sourceRange.duration)
            if original.isReversed {
                left.sourceRange = .init(start: try original.sourceRange.start.adding(leftSource),
                                         duration: rightSource)
                left.timeRemap = trailing
                right.sourceRange = .init(start: original.sourceRange.start, duration: leftSource)
                right.timeRemap = leading
            } else {
                left.sourceRange.duration = leftSource
                left.timeRemap = leading
                right.sourceRange = .init(start: try original.sourceRange.start.adding(leftSource),
                                          duration: rightSource)
                right.timeRemap = trailing
            }
        } else {
            left.sourceRange.duration = leftSource
            right.sourceRange = .init(start: try original.sourceRange.start.adding(leftSource),
                                      duration: rightSource)
        }
        left.placement.duration = try left.timelineDuration(forSourceDuration: left.sourceRange.duration)
        // The right half starts where the left one actually ends, so rounding in
        // the conversion can never open a gap or an overlap between them.
        let seam = try original.placement.timelineStart.adding(left.placement.duration)
        right.placement = .init(
            id: UUID(), trackID: original.placement.trackID, timelineStart: seam,
            duration: try right.timelineDuration(forSourceDuration: right.sourceRange.duration)
        )
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
            guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { throw TimelineError.invalid(String(localized: "Missing source.")) }
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
            let sourceDelta = try clip.sourceDuration(forTimelineDuration: delta)
            // The curve is measured from the clip's first frame, so moving that
            // frame moves the whole curve with it. A reversed clip hides source
            // off the far end instead, and its curve is untouched.
            if clip.isRamped, !clip.isReversed, sourceDelta > .zero {
                clip.timeRemap = clip.resolvedRemap.trimmedHead(
                    bySource: sourceDelta, sourceDuration: clip.sourceRange.duration)
            }
            if !clip.isReversed {
                clip.sourceRange.start = try clip.sourceRange.start.adding(sourceDelta)
            }
            clip.placement.timelineStart = boundary
            clip.placement.duration = try end.subtracting(boundary)
            // Head trims hide animation rather than discarding it; extending restores it.
            clip.shiftAnimationWindow(by: delta)
        } else {
            clip.placement.duration = try boundary.subtracting(clip.placement.timelineStart)
        }
        clip.sourceRange.duration = try clip.sourceDuration(
            forTimelineDuration: clip.placement.duration)
        // Re-derive from the stored source so the document invariant
        // (timeline duration is what the time map makes of the source range)
        // holds exactly rather than approximately after the conversion rounds.
        clip.placement.duration = try clip.timelineDuration(
            forSourceDuration: clip.sourceRange.duration)
        guard clip.placement.duration >= minimum else { throw TimelineError.invalid(String(localized: "Keep at least one frame in the clip.")) }
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
        try retime(id, in: &project) { clip in
            let resolved = ClipSpeed.clamped(speed)
            guard resolved != clip.speed || clip.isRamped else { return false }
            // Setting one rate is also how the ramp is left behind, which is
            // what a user dragging the plain Speed slider means by it.
            if clip.timeRemap != nil {
                clip.timeRemap?.resetCurve()
                clip.timeRemap?.constantSpeed = resolved
            } else {
                clip.speed = resolved
            }
            return true
        }
    }

    /// Replaces a clip's whole retiming.
    ///
    /// Every ramp edit funnels through here, so the duration, the keyframes and
    /// the ripple are worked out in exactly one place. A panel that added a
    /// point and recomputed the length itself would be a second implementation
    /// of the thing this file exists to own.
    static func setTimeRemap(
        _ id: UUID,
        to remap: TimeRemap,
        in project: inout VideoProject
    ) throws {
        try retime(id, in: &project) { clip in
            guard clip.resolvedRemap != remap else { return false }
            clip.timeRemap = remap
            // The old boolean would otherwise keep answering for a clip that now
            // has a real frame-interpolation setting.
            clip.blendsRetimedFrames = nil
            return true
        }
    }

    /// Edits a clip's retiming in place. `edit` reports whether it changed anything.
    static func editTimeRemap(
        _ id: UUID,
        in project: inout VideoProject,
        _ edit: (inout TimeRemap) -> Void
    ) throws {
        let clip = try editable(id, in: project)
        var remap = clip.resolvedRemap
        edit(&remap)
        try setTimeRemap(id, to: remap, in: &project)
    }

    // MARK: - Ramp operations
    //
    // Each of these is one undoable action and nothing more: they describe the
    // change and leave the length, the keyframes and the ripple to `retime`.

    /// Adds a speed point at a timeline position, carrying the speed already in
    /// force there.
    ///
    /// Deliberately does NOT change the shape of the curve: dropping a point on
    /// a ramp and letting go should leave the picture exactly as it was, with
    /// something to drag. Inventing a new speed at the moment of the tap is the
    /// behaviour that makes a curve editor feel like it is fighting you.
    @discardableResult
    static func addSpeedPoint(_ id: UUID, atTimeline time: TimelineTime,
                              in project: inout VideoProject) throws -> UUID? {
        let clip = try editable(id, in: project)
        let local = min(clip.placement.duration,
                        max(.zero, try time.subtracting(clip.placement.timelineStart)))
        let sourceOffset = clip.timeMap.sourceOffset(atTimelineOffset: local)
        var remap = clip.resolvedRemap
        if remap.points.contains(where: { $0.sourceOffset == sourceOffset }) { return nil }
        let point = SpeedPoint(sourceOffset: sourceOffset,
                               speed: clip.timeMap.speed(atTimelineOffset: local),
                               interpolation: .easeInOut)
        // A ramp needs two points to be a ramp. The first one added to a clip at
        // a single rate brings an anchor at the head with it, so the very next
        // drag produces a transition rather than silently restating the constant.
        if remap.points.isEmpty, sourceOffset > .zero {
            remap.points.append(SpeedPoint(sourceOffset: .zero, speed: remap.constantSpeed,
                                           interpolation: .easeInOut))
        }
        remap.points.append(point)
        remap.points.sort { $0.sourceOffset < $1.sourceOffset }
        try setTimeRemap(id, to: remap, in: &project)
        return point.id
    }

    static func removeSpeedPoint(_ id: UUID, point: UUID, in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { $0.removePoint(point) }
    }

    /// Moves a point along the clip and changes its rate in one edit, which is
    /// what a single drag in the curve editor is.
    static func moveSpeedPoint(_ id: UUID, point: UUID, toTimeline time: TimelineTime?,
                               speed: Double?, in project: inout VideoProject) throws {
        let clip = try editable(id, in: project)
        var remap = clip.resolvedRemap
        guard let index = remap.points.firstIndex(where: { $0.id == point }) else { return }
        if let time {
            let local = min(clip.placement.duration,
                            max(.zero, try time.subtracting(clip.placement.timelineStart)))
            remap.points[index].sourceOffset = clip.timeMap.sourceOffset(atTimelineOffset: local)
        }
        if let speed { remap.points[index].speed = ClipSpeed.clamped(speed) }
        try setTimeRemap(id, to: remap, in: &project)
    }

    static func setSpeedPointInterpolation(_ id: UUID, point: UUID, to interpolation: SpeedInterpolation,
                                           in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { remap in
            guard let index = remap.points.firstIndex(where: { $0.id == point }) else { return }
            remap.points[index].interpolation = interpolation
        }
    }

    static func setSpeedPointHandles(_ id: UUID, point: UUID, outgoing: BezierHandle?,
                                     incoming: BezierHandle?, in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { remap in
            guard let index = remap.points.firstIndex(where: { $0.id == point }) else { return }
            if let outgoing { remap.points[index].outgoingHandle = outgoing.clamped }
            if let incoming { remap.points[index].incomingHandle = incoming.clamped }
            remap.points[index].interpolation = .bezier
        }
    }

    static func resetSpeedCurve(_ id: UUID, in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { $0.resetCurve() }
    }

    static func applySpeedPreset(_ id: UUID, preset: TimeRemap.Preset,
                                 in project: inout VideoProject) throws {
        let clip = try editable(id, in: project)
        var remap = clip.resolvedRemap
        // A preset is nothing but a set of ordinary points. Nothing records that
        // one was applied, and every point it left behind is as editable as one
        // placed by hand.
        remap.points = preset.points(sourceDuration: clip.sourceRange.duration)
        try setTimeRemap(id, to: remap, in: &project)
    }

    static func setReversed(_ id: UUID, _ reversed: Bool, in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { $0.reverses = reversed }
    }

    static func setFrameInterpolation(_ id: UUID, to mode: FrameInterpolation,
                                      in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { $0.frameInterpolation = mode }
    }

    static func setOpticalFlowQuality(_ id: UUID, to quality: OpticalFlowQuality,
                                      in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { $0.opticalFlowQuality = quality }
    }

    static func setRetimedAudioBehaviour(_ id: UUID, to behaviour: RetimedAudioBehaviour,
                                         in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { $0.audioBehaviour = behaviour }
    }

    /// Holds the frame under the playhead for a given length of timeline.
    ///
    /// The width of the hold is one frame of the media it came from, taken from
    /// the asset rather than from the canvas: a 24 fps clip on a 30 fps timeline
    /// holds one of ITS frames, and using the canvas cadence would consume a
    /// fraction of a frame more or less than the picture being held.
    @discardableResult
    static func freezeFrame(_ id: UUID, atTimeline time: TimelineTime, duration: TimelineTime,
                            in project: inout VideoProject) throws -> UUID? {
        guard duration > .zero else { return nil }
        let clip = try editable(id, in: project)
        guard let frameDuration = project.assets.first(where: { $0.id == clip.assetID })?.frameDuration
                ?? project.canvas.frameDuration, frameDuration > .zero else {
            throw TimelineError.invalid(String(localized: "A freeze needs the source's frame rate, and this media does not report one."))
        }
        let local = min(clip.placement.duration,
                        max(.zero, try time.subtracting(clip.placement.timelineStart)))
        var offset = clip.timeMap.sourceOffset(atTimelineOffset: local)
        // A hold at the very end would run past the source range. Backing it up
        // by one frame holds the last frame, which is what was asked for.
        if try offset.adding(frameDuration) > clip.sourceRange.duration {
            offset = max(.zero, try clip.sourceRange.duration.subtracting(frameDuration))
        }
        var remap = clip.resolvedRemap
        guard remap.freeze(atSourceOffset: offset,
                           sourceDuration: clip.sourceRange.duration) == nil else { return nil }
        let freeze = FreezeSegment(sourceOffset: offset, duration: duration,
                                   sourceWidth: frameDuration)
        remap.freezes.append(freeze)
        try setTimeRemap(id, to: remap, in: &project)
        return freeze.id
    }

    static func setFreezeDuration(_ id: UUID, freeze: UUID, to duration: TimelineTime,
                                  in project: inout VideoProject) throws {
        let floor = (try? TimelineTime.seconds(FreezeSegment.minimumDuration)) ?? .zero
        try editTimeRemap(id, in: &project) { remap in
            guard let index = remap.freezes.firstIndex(where: { $0.id == freeze }) else { return }
            remap.freezes[index].duration = max(floor, duration)
        }
    }

    static func removeFreeze(_ id: UUID, freeze: UUID, in project: inout VideoProject) throws {
        try editTimeRemap(id, in: &project) { remap in
            remap.freezes.removeAll { $0.id == freeze }
        }
    }

    // MARK: - The one retiming transaction

    /// Applies a retiming change and settles everything that follows from it.
    ///
    /// Four things always happen together, and separating them is how a clip
    /// ends up a different length from the frames inside it:
    ///
    /// 1. the clip's timeline duration is re-derived from its new time map;
    /// 2. keyframes are moved so they stay on the pictures they were authored
    ///    against;
    /// 3. the rest of the track ripples by the change in length;
    /// 4. the whole thing is validated before it is allowed to land.
    private static func retime(
        _ id: UUID,
        in project: inout VideoProject,
        _ change: (inout VideoClip) throws -> Bool
    ) throws {
        var clip = try editable(id, in: project)
        let before = clip
        guard try change(&clip) else { return }

        let newDuration = try clip.timelineDuration(forSourceDuration: clip.sourceRange.duration)
        guard newDuration > .zero else {
            throw TimelineError.invalid(String(localized: "That speed would leave the clip with no duration."))
        }
        let previousDuration = before.placement.duration
        let shift = try newDuration.subtracting(previousDuration)

        // Keyframe times are clip-local timeline coordinates, so they have to
        // move when the clip is retimed or they would describe the wrong frames
        // — and a clip that got shorter would push half its animation past its
        // own end.
        //
        // A single rate is still scaled by a single factor, exactly as it always
        // was, so no existing project's animation moves by even a tick. A ramp
        // has no single factor, so each keyframe goes out through the old map
        // and back in through the new one, which lands it on the same picture.
        if previousDuration > .zero {
            let wasRamped = before.isRamped || before.isReversed
            let isRamped = clip.isRamped || clip.isReversed
            if wasRamped || isRamped {
                let old = before.timeMap, new = clip.timeMap
                let remap: (TimelineTime) -> TimelineTime = { time in
                    new.timelineOffset(atSourceOffset: old.sourceOffset(atTimelineOffset: time))
                }
                if let animation = clip.animation, !animation.isEmpty {
                    clip.animation = animation.retimed(through: remap)
                }
                if let masks = clip.maskedGrades, masks.contains(where: \.isAnimated) {
                    clip.maskedGrades = masks.map { $0.retimed(through: remap) }
                }
                if let relight = clip.gradeSettings.advanced?.relight, relight.isAnimated {
                    clip.gradeSettings.advanced?.relight = relight.retimed(through: remap)
                }
            } else {
                let factor = newDuration.seconds / previousDuration.seconds
                if let animation = clip.animation, !animation.isEmpty {
                    clip.animation = animation.retimed(by: factor)
                }
                if let masks = clip.maskedGrades, masks.contains(where: \.isAnimated) {
                    clip.maskedGrades = masks.map { $0.retimed(by: factor) }
                }
                if let relight = clip.gradeSettings.advanced?.relight, relight.isAnimated {
                    clip.gradeSettings.advanced?.relight = relight.retimed(by: factor)
                }
            }
        }
        clip.placement.duration = newDuration

        // Read the clips to ripple from the timeline as it stands NOW, before the
        // clip is lengthened. Reading them afterwards means asking `clips(in:)`
        // to validate a timeline in which the longer clip already sits on top of
        // its neighbour, and it refuses that ("Clips on the same track cannot
        // overlap") before the ripple that would resolve it can run.
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
              !project.timeline.tracks[index].isLocked else { throw TimelineError.invalid(String(localized: "Unlock the main track before pasting.")) }
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
