import Foundation

enum TextEditing {
    static func replace(_ id: UUID, with clip: TextClip, in project: inout VideoProject) throws {
        guard let t = project.timeline.tracks.firstIndex(where: { $0.id == clip.placement.trackID }),
              let i = project.timeline.tracks[t].items.firstIndex(where: { $0.id == id }),
              !project.timeline.tracks[t].isLocked, !project.timeline.tracks[t].items[i].placement.isLocked else { throw TimelineError.invalid("Unlock the text track before editing.") }
        project.timeline.tracks[t].items[i] = .text(clip)
    }
    static func delete(_ id: UUID, in project: inout VideoProject) throws {
        guard case .text(let clip) = project.timeline.item(id: id) else { return }
        try replace(id, with: clip, in: &project)
        let index = project.timeline.tracks.firstIndex { $0.id == clip.placement.trackID }!
        project.timeline.tracks[index].items.removeAll { $0.id == id }
        if project.timeline.tracks[index].items.isEmpty { project.timeline.tracks.remove(at: index) }
    }
    static func paste(_ original: TextClip, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        var clip = original
        let trackID = UUID()
        clip.placement = .init(id: UUID(), trackID: trackID, timelineStart: max(.zero, try TimelineEditing.snapped(time, frame: project.canvas.frameDuration)), duration: original.placement.duration)
        project.timeline.tracks.insert(.init(id: trackID, name: "Text", kind: .text, items: [.text(clip)]), at: 0)
        return clip.id
    }
    static func splitTarget(in project: VideoProject, at time: TimelineTime, trackID: UUID?) -> UUID? {
        let frame = project.canvas.frameDuration?.seconds ?? 0.01
        return project.timeline.items.first { item in
            guard case .text = item, item.placement.trackID == trackID, !item.placement.isLocked,
                  project.timeline.tracks.first(where: { $0.id == trackID })?.isLocked == false else { return false }
            return time.seconds-item.placement.timelineStart.seconds >= frame && ((try? item.placement.range.end.seconds) ?? 0)-time.seconds >= frame
        }?.id
    }
    static func split(_ id: UUID, at time: TimelineTime, in project: inout VideoProject) throws -> UUID {
        guard case .text(var left) = project.timeline.item(id: id), splitTarget(in: project, at: time, trackID: left.placement.trackID) == id else { throw TimelineError.invalid("Place the playhead inside the text clip.") }
        let boundary = try TimelineEditing.snapped(time, frame: project.canvas.frameDuration)
        var right = left
        let leftDuration = try boundary.subtracting(left.placement.timelineStart)
        right.placement = .init(id: UUID(), trackID: left.placement.trackID, timelineStart: boundary, duration: try left.placement.range.end.subtracting(boundary))
        // Both halves keep the identical keyframe list; only the window each reads moves.
        // Easing across the split is therefore exact, with no interpolated boundary keyframe.
        right.shiftAnimationWindow(by: leftDuration)
        left.placement.duration = leftDuration
        try replace(id, with: left, in: &project)
        project.timeline.tracks[project.timeline.tracks.firstIndex(where: { $0.id == left.placement.trackID })!].items.append(.text(right))
        return right.id
    }
    static func edit(_ id: UUID, operation: TimelineGestureEdit, to time: TimelineTime, in project: inout VideoProject) throws {
        guard let item = project.timeline.item(id: id), case .text(var clip) = item else { throw TimelineError.invalid("Text clip not found.") }
        let target = max(.zero, try TimelineEditing.snapped(time, frame: project.canvas.frameDuration))
        switch operation {
        case .move: clip.placement.timelineStart = target
        case .trimStart:
            let end = try clip.placement.range.end
            let previousStart = clip.placement.timelineStart
            clip.placement.timelineStart = min(target, try end.subtracting(project.canvas.frameDuration ?? .zero))
            clip.placement.duration = try end.subtracting(clip.placement.timelineStart)
            // The head moved but the content did not: slide the animation window with it.
            clip.shiftAnimationWindow(by: try clip.placement.timelineStart.subtracting(previousStart))
        case .trimEnd: clip.placement.duration = max(project.canvas.frameDuration ?? .zero, try target.subtracting(clip.placement.timelineStart))
        }
        guard clip.placement.duration >= (project.canvas.frameDuration ?? .zero) else { throw TimelineError.invalid("Keep at least one frame of text.") }
        try replace(id, with: clip, in: &project)
    }
}
