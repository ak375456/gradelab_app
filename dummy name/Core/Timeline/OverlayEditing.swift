import Foundation

/// A layer whose picture the app draws rather than reading it from an asset.
///
/// Text and shapes are the two, and their timeline lifecycle is identical: no
/// source range, a track of their own, free placement with nothing underneath
/// them to respect, and an animation window that has to survive a trim or a
/// split. So it is implemented once, here, instead of in two files that would
/// drift apart the first time one of them was fixed.
protocol DrawnOverlayClip: AnimatableClip {
    static var trackKind: TimelineTrack.Kind { get }
    /// The noun used in the messages a person actually reads.
    static var noun: String { get }
    /// The `TimelineItem` case that carries this clip type.
    var timelineItem: TimelineItem { get }
}

extension TextClip: DrawnOverlayClip {
    static let trackKind = TimelineTrack.Kind.text
    static let noun = "text"
    var timelineItem: TimelineItem { .text(self) }
}

extension ShapeClip: DrawnOverlayClip {
    static let trackKind = TimelineTrack.Kind.shape
    static let noun = "shape"
    var timelineItem: TimelineItem { .shape(self) }
}

/// Placement, trimming, splitting and deletion for drawn overlay layers.
///
/// The id-taking entry points switch over the item ONCE and then run the same
/// generic body, so there is exactly one implementation of each rule — notably
/// the animation-window handling on a head trim and on a split, which is the
/// part that is easy to get subtly wrong twice.
enum OverlayEditing {
    static func replace<Clip: DrawnOverlayClip>(_ id: UUID, with clip: Clip, in project: inout VideoProject) throws {
        guard let t = project.timeline.tracks.firstIndex(where: { $0.id == clip.placement.trackID }),
              let i = project.timeline.tracks[t].items.firstIndex(where: { $0.id == id }),
              !project.timeline.tracks[t].isLocked,
              !project.timeline.tracks[t].items[i].placement.isLocked else {
            throw TimelineError.invalid(String(localized: "Unlock the \(Clip.noun) track before editing."))
        }
        project.timeline.tracks[t].items[i] = clip.timelineItem
    }

    static func delete(_ id: UUID, in project: inout VideoProject) throws {
        switch project.timeline.item(id: id) {
        case .text(let clip): try delete(clip, in: &project)
        case .shape(let clip): try delete(clip, in: &project)
        default: return
        }
    }

    static func delete<Clip: DrawnOverlayClip>(_ clip: Clip, in project: inout VideoProject) throws {
        // Routed through `replace` first so a locked track refuses the delete
        // for the same reason, with the same message, that it refuses an edit.
        try replace(clip.id, with: clip, in: &project)
        let index = project.timeline.tracks.firstIndex { $0.id == clip.placement.trackID }!
        project.timeline.tracks[index].items.removeAll { $0.id == clip.id }
        if project.timeline.tracks[index].items.isEmpty { project.timeline.tracks.remove(at: index) }
        // A title used as somebody's track matte takes the relationship with it.
        project.timeline.reconcileTrackMattes()
    }

    /// Pasting a drawn layer gives it a track of its own rather than hunting for
    /// room on an existing one: it has no media edit to line up with, and a new
    /// row is both predictable and immediately visible.
    static func paste<Clip: DrawnOverlayClip>(_ original: Clip, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        var clip = original
        let trackID = UUID()
        clip.placement = .init(
            id: UUID(), trackID: trackID,
            timelineStart: max(.zero, try TimelineEditing.snapped(time, frame: project.canvas.frameDuration)),
            duration: original.placement.duration)
        project.timeline.tracks.insert(
            .init(id: trackID, name: TimelineTrack.defaultName(for: Clip.trackKind),
                  kind: Clip.trackKind, items: [clip.timelineItem]), at: 0)
        return clip.id
    }

    /// The clip a split would cut, or nil when the playhead is not at least one
    /// frame inside one. Type-agnostic on purpose: a track holds a single kind,
    /// so the track identity already decides which kind is being asked about.
    static func splitTarget(in project: VideoProject, at time: TimelineTime, trackID: UUID?) -> UUID? {
        let frame = project.canvas.frameDuration?.seconds ?? 0.01
        return project.timeline.items.first { item in
            guard item.isDrawnOverlay, item.placement.trackID == trackID, !item.placement.isLocked,
                  project.timeline.tracks.first(where: { $0.id == trackID })?.isLocked == false else { return false }
            return time.seconds-item.placement.timelineStart.seconds >= frame
                && ((try? item.placement.range.end.seconds) ?? 0)-time.seconds >= frame
        }?.id
    }

    static func split(_ id: UUID, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        switch project.timeline.item(id: id) {
        case .text(let clip): return try split(clip, at: time, in: &project)
        case .shape(let clip): return try split(clip, at: time, in: &project)
        default: throw TimelineError.invalid(String(localized: "Select a text or shape layer to split."))
        }
    }

    static func split<Clip: DrawnOverlayClip>(_ clip: Clip, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        var left = clip
        guard splitTarget(in: project, at: time, trackID: left.placement.trackID) == left.id else {
            throw TimelineError.invalid(String(localized: "Place the playhead inside the \(Clip.noun) clip."))
        }
        let boundary = try TimelineEditing.snapped(time, frame: project.canvas.frameDuration)
        var right = left
        let leftDuration = try boundary.subtracting(left.placement.timelineStart)
        right.placement = .init(id: UUID(), trackID: left.placement.trackID, timelineStart: boundary,
                                duration: try left.placement.range.end.subtracting(boundary))
        // Both halves keep the identical keyframe list; only the window each reads moves.
        // Easing across the split is therefore exact, with no interpolated boundary keyframe.
        right.shiftAnimationWindow(by: leftDuration)
        left.placement.duration = leftDuration
        try replace(left.id, with: left, in: &project)
        project.timeline.tracks[project.timeline.tracks.firstIndex(where: { $0.id == left.placement.trackID })!]
            .items.append(right.timelineItem)
        return right.id
    }

    static func edit(_ id: UUID, operation: TimelineGestureEdit, to time: TimelineTime, in project: inout VideoProject) throws {
        switch project.timeline.item(id: id) {
        case .text(let clip): try edit(clip, operation: operation, to: time, in: &project)
        case .shape(let clip): try edit(clip, operation: operation, to: time, in: &project)
        default: throw TimelineError.invalid(String(localized: "Overlay clip not found."))
        }
    }

    static func edit<Clip: DrawnOverlayClip>(_ original: Clip, operation: TimelineGestureEdit, to time: TimelineTime, in project: inout VideoProject) throws {
        var clip = original
        let target = max(.zero, try TimelineEditing.snapped(time, frame: project.canvas.frameDuration))
        // Every edge stops at this clip's neighbours on the row. A row is a
        // sequence, so an edge dragged past the clip beside it would put two of
        // them on screen at once.
        let neighbours = (project.timeline.tracks.first { $0.id == clip.placement.trackID }?.items ?? [])
            .filter { $0.id != clip.id }
        switch operation {
        case .move:
            clip.placement.timelineStart = try TimelineEditing.clampedStart(
                target, duration: clip.placement.duration, itemID: clip.id,
                on: clip.placement.trackID, fallback: clip.placement.timelineStart, in: project)
        case .trimStart:
            var head = target
            for other in neighbours where other.placement.timelineStart < clip.placement.timelineStart {
                head = max(head, try other.placement.range.end)
            }
            let end = try clip.placement.range.end
            let previousStart = clip.placement.timelineStart
            clip.placement.timelineStart = min(head, try end.subtracting(project.canvas.frameDuration ?? .zero))
            clip.placement.duration = try end.subtracting(clip.placement.timelineStart)
            // The head moved but the content did not: slide the animation window with it.
            clip.shiftAnimationWindow(by: try clip.placement.timelineStart.subtracting(previousStart))
        case .trimEnd:
            var tail = target
            let end = try clip.placement.range.end
            for other in neighbours where other.placement.timelineStart >= end {
                tail = min(tail, other.placement.timelineStart)
            }
            clip.placement.duration = max(project.canvas.frameDuration ?? .zero,
                                          try tail.subtracting(clip.placement.timelineStart))
        }
        guard clip.placement.duration >= (project.canvas.frameDuration ?? .zero) else {
            throw TimelineError.invalid(String(localized: "Keep at least one frame of \(Clip.noun)."))
        }
        try replace(clip.id, with: clip, in: &project)
    }
}
