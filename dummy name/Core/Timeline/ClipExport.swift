import Foundation

// ---------------------------------------------------------------------------
// Exporting one clip on its own
//
// Nothing about the open timeline changes. This builds a *separate* project
// that contains only the chosen clip, starting at zero, and hands it to the
// ordinary export screen — so the encode, the colour handling and the capability
// checks are the ones already shipping, and there is no second export path to
// drift from the first.
//
// The clip's grade travels with it because the grade is stored on the clip, so
// what comes out is what that clip looks like on the timeline.
// ---------------------------------------------------------------------------

enum SingleClipExport {
    /// A project containing only `clipID`, or nil when the id is not a video
    /// clip or the result would not be a valid document.
    static func isolate(clipID: UUID, in source: VideoProject) -> VideoProject? {
        guard let track = source.timeline.tracks.first(where: { track in
            track.items.contains { $0.id == clipID }
        }),
        let item = track.items.first(where: { $0.id == clipID }),
        case .video(var clip) = item else { return nil }

        // Moved to the head of its own timeline, so the export starts on the
        // first frame of the clip rather than after however much empty time sat
        // in front of it.
        clip.placement.timelineStart = .zero
        // Hidden and locked are editing states. Someone who asks to export this
        // clip means this clip; handing back a black frame instead would be a
        // strange reading of that.
        clip.placement.isEnabled = true
        clip.placement.isLocked = false

        var isolated = track
        isolated.isEnabled = true
        isolated.isLocked = false
        isolated.items = [.video(clip)]

        var project = source
        // Every other track goes, and the markers with them: the point is this
        // clip and what is on it, not the timeline it came from. The assets are
        // left alone — the document's primary asset has to stay present, and an
        // asset no clip references costs the export nothing.
        project.timeline = Timeline(tracks: [isolated])
        project.displayName = name(for: clipID, in: source)
        guard (try? project.validate()) != nil else { return nil }
        return project
    }

    /// The grade that clip carries, for the export screen's fallback settings.
    static func grade(for clipID: UUID, in source: VideoProject) -> GradeSettings {
        source.timeline.videoClip(id: clipID)?.gradeSettings ?? .neutral
    }

    /// "Project · Clip 2", numbered by position on the timeline so two exports
    /// from the same project are told apart.
    static func name(for clipID: UUID, in source: VideoProject) -> String {
        let ordered = source.timeline.tracks
            .flatMap(\.items)
            .filter { if case .video = $0 { true } else { false } }
            .sorted { $0.placement.timelineStart < $1.placement.timelineStart }
        let index = (ordered.firstIndex { $0.id == clipID } ?? 0) + 1
        return "\(source.displayName) · Clip \(index)"
    }
}
