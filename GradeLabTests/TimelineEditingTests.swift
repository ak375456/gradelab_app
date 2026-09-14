import XCTest
@testable import GradeLab

final class TimelineEditingTests: XCTestCase {
    func testMagneticInsertionPreservesWholeClipsAndDuration() throws {
        var project = project()
        let first = project.timeline.firstVideoClip!.id
        let middle = try TimelineEditing.split(first, at: .seconds(3), in: &project)
        let last = try TimelineEditing.split(middle, at: .seconds(6), in: &project)
        let original = project
        try TimelineEditing.insertMove(last, to: .seconds(3), in: &project)
        let clips = try TimelineEditing.clips(in: project)
        XCTAssertEqual(clips.map(\.id), [first, last, middle])
        XCTAssertEqual(project.timeline.duration, original.timeline.duration)
        for clip in clips {
            XCTAssertEqual(clip.sourceRange, original.timeline.videoClip(id: clip.id)?.sourceRange)
            XCTAssertEqual(clip.gradeSettings, original.timeline.videoClip(id: clip.id)?.gradeSettings)
        }
        XCTAssertEqual(TimelineEditing.splitTarget(in: original, at: try .seconds(7)), last)
        XCTAssertNil(TimelineEditing.splitTarget(in: original, at: .zero))
    }

    func testInsertionIsAtomicWhenNeighborIsLocked() throws {
        var project = project()
        let first = project.timeline.firstVideoClip!.id
        let last = try TimelineEditing.split(first, at: .seconds(5), in: &project)
        var locked = project.timeline.videoClip(id: first)!
        locked.placement.isLocked = true
        try TimelineEditing.replace(first, with: [locked], in: &project)
        let original = project
        XCTAssertThrowsError(try TimelineEditing.insertMove(last, to: .zero, in: &project))
        XCTAssertEqual(project, original)
    }

    func testVerticalDragCanLiftMainClipIntoANewOverlayLayer() throws {
        var project = project()
        let first = project.timeline.firstVideoClip!.id
        let lifted = try TimelineEditing.split(first, at: .seconds(5), in: &project)

        try TimelineEditing.moveToVideoLayer(
            lifted, destinationTrackID: nil, newOverlayIndex: 0,
            at: .seconds(1), in: &project
        )

        XCTAssertEqual(project.timeline.tracks.first?.kind, .videoOverlay)
        XCTAssertEqual(project.timeline.videoClip(id: lifted)?.placement.trackID,
                       project.timeline.tracks.first?.id)
        XCTAssertEqual(project.timeline.videoClip(id: lifted)?.placement.timelineStart,
                       try .seconds(1))
        // Removing a clip from the magnetic main timeline closes its old gap.
        XCTAssertEqual(project.timeline.videoClip(id: first)?.placement.timelineStart, .zero)
        XCTAssertEqual(project.timeline.duration, try .seconds(6))
        _ = try TimelineEditing.clips(in: project)
    }

    func testMovingBetweenLayersIsAtomicWhenDestinationOverlaps() throws {
        var project = project()
        let first = project.timeline.firstVideoClip!.id
        let lifted = try TimelineEditing.split(first, at: .seconds(5), in: &project)
        try TimelineEditing.moveToVideoLayer(
            lifted, destinationTrackID: nil, newOverlayIndex: 0,
            at: .zero, in: &project
        )
        let overlayID = project.timeline.videoClip(id: lifted)!.placement.trackID
        let original = project

        XCTAssertThrowsError(
            try TimelineEditing.moveToVideoLayer(
                first, destinationTrackID: overlayID, at: .seconds(1), in: &project
            )
        )
        XCTAssertEqual(project, original)
    }

    /// The main video track ripples: a neighbour is not a wall, it moves along.
    /// The limits that remain are the real ones — how much source there is, and
    /// the minimum length.
    func testTrimRipplesPastNeighboursButNotPastTheSource() throws {
        var project = project()
        let first = project.timeline.firstVideoClip!.id
        let second = try TimelineEditing.split(first, at: .seconds(5), in: &project)

        // Extending the first clip's tail past the second one: allowed, and
        // stopped only by the end of its source.
        try TimelineEditing.trimClosingGaps(first, edge: .right, to: .seconds(100), in: &project)
        XCTAssertEqual(project.timeline.videoClip(id: first)?.placement.duration, try .seconds(10))
        // ...and the clip that was in the way has moved forward to make room.
        XCTAssertEqual(project.timeline.videoClip(id: second)?.placement.timelineStart, try .seconds(10))
        XCTAssertEqual(project.timeline.duration, try .seconds(15))
        _ = try TimelineEditing.clips(in: project)

        // Extending the second clip's head reveals earlier source, so the clip
        // gets longer. On a gapless track it cannot move left into its
        // neighbour, so its start stays where it is and its tail grows.
        try TimelineEditing.trimClosingGaps(second, edge: .left, to: .zero, in: &project)
        XCTAssertEqual(project.timeline.videoClip(id: second)?.placement.duration, try .seconds(10))
        XCTAssertEqual(project.timeline.videoClip(id: second)?.placement.timelineStart, try .seconds(10))
        _ = try TimelineEditing.clips(in: project)
    }

    func testTrimStopsAtTheMinimumFrame() throws {
        var project = project()
        let first = project.timeline.firstVideoClip!.id
        _ = try TimelineEditing.split(first, at: .seconds(5), in: &project)
        try TimelineEditing.trim(first, edge: .left, to: .seconds(100), clamping: true, in: &project)
        XCTAssertEqual(project.timeline.videoClip(id: first)?.placement.duration, project.canvas.frameDuration)
        _ = try TimelineEditing.clips(in: project)
    }
    private func project() -> VideoProject {
        VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "Editing",
                     metadata: makeVideoMetadata(durationSeconds: 10))
    }

    func testSplitHasIndependentGradesAndExactRanges() throws {
        var project = project()
        let left = project.timeline.firstVideoClip!.id
        var grade = GradeSettings.neutral
        grade.advanced = .neutral; grade.advanced?.curves[1].midtones = 0.6
        project.timeline.setGrade(grade, for: left)
        let right = try TimelineEditing.split(left, at: .seconds(4.5), in: &project)
        let clips = try TimelineEditing.clips(in: project)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].placement.duration, try .seconds(4.5))
        XCTAssertEqual(clips[1].sourceRange.start, try .seconds(4.5))
        XCTAssertEqual(clips[1].placement.duration, try .seconds(5.5))
        XCTAssertEqual(clips[1].gradeSettings, grade)
        project.timeline.setGrade(.neutral, for: right)
        XCTAssertEqual(project.timeline.videoClip(id: left)?.gradeSettings, grade)
        XCTAssertEqual(clips[0].assetID, clips[1].assetID)
    }

    func testTrimMoveAndOutOfSourceRejection() throws {
        var project = project()
        let id = project.timeline.firstVideoClip!.id
        try TimelineEditing.trim(id, edge: .left, to: .seconds(2), in: &project)
        try TimelineEditing.trim(id, edge: .right, to: .seconds(8), in: &project)
        try TimelineEditing.move(id, to: .seconds(4), in: &project)
        let clip = try TimelineEditing.clips(in: project)[0]
        XCTAssertEqual(clip.sourceRange.start, try .seconds(2))
        XCTAssertEqual(clip.sourceRange.duration, try .seconds(6))
        XCTAssertEqual(clip.placement.timelineStart, try .seconds(4))
        XCTAssertNil(TimelineEditing.activeClip(in: [clip], at: TimelineTime.zero.cmTime))
        try TimelineEditing.trim(id, edge: .right, to: .seconds(50), in: &project)
        XCTAssertThrowsError(try TimelineEditing.clips(in: project))
    }

    func testDeletePasteAndUndoRedo() throws {
        let original = project()
        var edited = original
        let copied = original.timeline.firstVideoClip!
        try TimelineEditing.replace(copied.id, with: [], in: &edited)
        XCTAssertTrue(try TimelineEditing.clips(in: edited).isEmpty)
        var history = TimelineHistory()
        history.record("Cut", before: original, after: edited)
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), edited)
        let id = try TimelineEditing.paste(copied, at: .zero, in: &edited)
        XCTAssertNotEqual(id, copied.id)
        XCTAssertEqual(edited.timeline.videoClip(id: id)?.sourceRange, copied.sourceRange)
        history.record("Paste", before: original, after: edited)
        XCTAssertTrue(history.redoEntries.isEmpty)
    }

    func testLocksOverlapAndBoundarySplitAreRejected() throws {
        var project = project()
        let id = project.timeline.firstVideoClip!.id
        XCTAssertThrowsError(try TimelineEditing.split(id, at: .zero, in: &project))
        project.timeline.tracks[0].isLocked = true
        XCTAssertThrowsError(try TimelineEditing.move(id, to: .seconds(1), in: &project))
        XCTAssertThrowsError(try TimelineEditing.replace(id, with: [], in: &project))
        project.timeline.tracks[0].isLocked = false
        let copied = project.timeline.firstVideoClip!
        _ = try TimelineEditing.paste(copied, at: .seconds(5), in: &project)
        XCTAssertThrowsError(try TimelineEditing.clips(in: project))
    }
}
