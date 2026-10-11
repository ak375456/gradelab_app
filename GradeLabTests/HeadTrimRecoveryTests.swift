import XCTest
@testable import GradeLab

final class HeadTrimRecoveryTests: XCTestCase {
    private func project() -> VideoProject {
        VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/head-recovery.mov"),
                     displayName: "Head recovery", metadata: makeVideoMetadata(durationSeconds: 12))
    }

    private func removeHead(_ project: inout VideoProject, at seconds: Double = 3) throws -> UUID {
        let original = try XCTUnwrap(project.timeline.firstVideoClip)
        let retained = try TimelineEditing.split(original.id, at: .seconds(seconds), in: &project)
        try TimelineEditing.deleteClosingGaps(original.id, in: &project)
        return retained
    }

    func testDeletedHeadCanBeRecoveredAfterRemainingClipMovesToZero() throws {
        var project = project()
        let retained = try removeHead(&project)
        XCTAssertEqual(project.timeline.videoClip(id: retained)?.placement.timelineStart, .zero)

        try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-2), in: &project)

        let clip = try XCTUnwrap(project.timeline.videoClip(id: retained))
        XCTAssertEqual(clip.placement.timelineStart, .zero)
        XCTAssertEqual(clip.sourceRange.start, try .seconds(1))
        XCTAssertEqual(clip.sourceRange.duration, try .seconds(11))
        XCTAssertEqual(clip.placement.duration, try .seconds(11))
        XCTAssertEqual(project.timeline.duration, try .seconds(11))
        _ = try TimelineEditing.clips(in: project)
    }

    func testHeadRecoveryStopsAtTheOriginalSourceStart() throws {
        var project = project()
        let retained = try removeHead(&project)
        try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-100), in: &project)
        let clip = try XCTUnwrap(project.timeline.videoClip(id: retained))
        XCTAssertEqual(clip.sourceRange, project.assets.first?.sourceRange)
        XCTAssertEqual(clip.placement.timelineStart, .zero)
        XCTAssertEqual(clip.placement.duration, try .seconds(12))
        let restored = project.timeline
        try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-1), in: &project)
        XCTAssertEqual(project.timeline, restored)
        _ = try TimelineEditing.clips(in: project)
    }

    func testHeadRecoveryKeepsClipOrderAndRipplesFollowingClips() throws {
        var project = project()
        let first = try XCTUnwrap(project.timeline.firstVideoClip).id
        let middle = try TimelineEditing.split(first, at: .seconds(2), in: &project)
        let last = try TimelineEditing.split(middle, at: .seconds(4), in: &project)
        let lastSource = project.timeline.videoClip(id: last)?.sourceRange

        try TimelineEditing.trimClosingGaps(middle, edge: .left, to: .seconds(-100), in: &project)

        let clips = try TimelineEditing.clips(in: project)
        XCTAssertEqual(clips.map(\.id), [first, middle, last])
        XCTAssertEqual(clips[1].placement.timelineStart, try .seconds(2))
        XCTAssertEqual(clips[1].sourceRange.start, .zero)
        XCTAssertEqual(clips[1].placement.duration, try .seconds(4))
        XCTAssertEqual(clips[2].placement.timelineStart, try .seconds(6))
        XCTAssertEqual(clips[2].sourceRange, lastSource)
    }

    func testRecoveryUsesThePlaybackRateForSourceTravel() throws {
        for rate in [0.5, 2.0] {
            var project = project()
            let original = try XCTUnwrap(project.timeline.firstVideoClip).id
            try TimelineEditing.setSpeed(original, to: rate, in: &project)
            let retained = try removeHead(&project, at: 4 / rate)
            try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-2 / rate), in: &project)
            let clip = try XCTUnwrap(project.timeline.videoClip(id: retained))
            XCTAssertEqual(clip.sourceRange.start, try .seconds(2))
            XCTAssertEqual(clip.sourceRange.duration, try .seconds(10))
            XCTAssertEqual(clip.placement.duration.seconds, 10 / rate, accuracy: 0.001)
            XCTAssertEqual(clip.placement.timelineStart, .zero)
            _ = try TimelineEditing.clips(in: project)
        }
    }

    func testReversedHeadRestoresFootageFromTheHighEndOfTheSource() throws {
        var project = project()
        let original = try XCTUnwrap(project.timeline.firstVideoClip).id
        var remap = TimeRemap()
        remap.reverses = true
        try TimelineEditing.setTimeRemap(original, to: remap, in: &project)
        let retained = try removeHead(&project)
        XCTAssertEqual(project.timeline.videoClip(id: retained)?.placement.duration, try .seconds(9))
        try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-2), in: &project)
        let clip = try XCTUnwrap(project.timeline.videoClip(id: retained))
        XCTAssertEqual(clip.sourceRange.start, .zero)
        XCTAssertEqual(try clip.sourceRange.end, try .seconds(11))
        XCTAssertEqual(clip.placement.duration, try .seconds(11))
        XCTAssertEqual(clip.placement.timelineStart, .zero)
        _ = try TimelineEditing.clips(in: project)
    }

    func testRampedRecoveryKeepsSpeedPointsOnTheirSourceFrames() throws {
        var project = project()
        let original = try XCTUnwrap(project.timeline.firstVideoClip).id
        var remap = TimeRemap()
        remap.points = [SpeedPoint(sourceOffset: .zero, speed: 1),
                        SpeedPoint(sourceOffset: try .seconds(12), speed: 2)]
        try TimelineEditing.setTimeRemap(original, to: remap, in: &project)
        let retained = try removeHead(&project)
        let before = try XCTUnwrap(project.timeline.videoClip(id: retained))
        try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-1), in: &project)
        let after = try XCTUnwrap(project.timeline.videoClip(id: retained))
        let restored = try before.sourceRange.start.subtracting(after.sourceRange.start)
        XCTAssertGreaterThan(restored, .zero)
        XCTAssertEqual(try before.sourceRange.end, try after.sourceRange.end)
        XCTAssertEqual(after.placement.timelineStart, .zero)
        for point in before.resolvedRemap.points {
            let moved = try XCTUnwrap(after.resolvedRemap.points.first { $0.id == point.id })
            XCTAssertEqual(moved.sourceOffset, try point.sourceOffset.adding(restored))
        }
        _ = try TimelineEditing.clips(in: project)
    }

    private func removeHeadOnVideoLayer(_ project: inout VideoProject) throws -> UUID {
        let original = try XCTUnwrap(project.timeline.firstVideoClip).id
        try TimelineEditing.moveToVideoLayer(original, destinationTrackID: nil, at: .zero, in: &project)
        let retained = try TimelineEditing.split(original, at: .seconds(3), in: &project)
        try TimelineEditing.deleteClosingGaps(original, in: &project)
        XCTAssertEqual(project.timeline.videoClip(id: retained)?.placement.timelineStart, try .seconds(3))
        try TimelineEditing.insertMove(retained, to: .zero, in: &project)
        return retained
    }

    func testVideoLayerRecoversDeletedZeroToThreeSecondsAfterMovingToZero() throws {
        var project = project()
        let retained = try removeHeadOnVideoLayer(&project)
        try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-3), in: &project)
        let clip = try XCTUnwrap(project.timeline.videoClip(id: retained))
        XCTAssertEqual(clip.sourceRange.start, .zero)
        XCTAssertEqual(clip.sourceRange.duration, try .seconds(12))
        XCTAssertEqual(clip.placement.timelineStart, .zero)
        XCTAssertEqual(clip.placement.duration, try .seconds(12))
        _ = try TimelineEditing.clips(in: project)
    }

    func testVideoLayerHeadRecoveryUsesFreeSpaceWithoutMovingNextClip() throws {
        var project = project()
        let retained = try removeHeadOnVideoLayer(&project)
        let next = try TimelineEditing.split(retained, at: .seconds(6), in: &project)
        try TimelineEditing.insertMove(next, to: .seconds(8), in: &project)
        let nextBefore = project.timeline.videoClip(id: next)
        try TimelineEditing.trimClosingGaps(retained, edge: .left, to: .seconds(-100), in: &project)
        let clip = try XCTUnwrap(project.timeline.videoClip(id: retained))
        XCTAssertEqual(clip.sourceRange.start, try .seconds(1))
        XCTAssertEqual(clip.placement.timelineStart, .zero)
        XCTAssertEqual(clip.placement.duration, try .seconds(8))
        XCTAssertEqual(project.timeline.videoClip(id: next), nextBefore)
        _ = try TimelineEditing.clips(in: project)
    }

    func testTrimHandleLimitsAllowRecoveryBeforeZeroAtTheCorrectSpeed() throws {
        var project = project()
        let original = try XCTUnwrap(project.timeline.firstVideoClip).id
        try TimelineEditing.setSpeed(original, to: 2, in: &project)
        let retained = try removeHead(&project, at: 2)
        let display = project.timeline.items.compactMap(TimelineDisplayClip.init)
        let clip = try XCTUnwrap(display.first { $0.id == retained })
        let limits = TimelineCanvas.trimBounds(for: clip, operation: .trimStart, clips: display,
            tracks: project.timeline.tracks, assets: project.assets, minimumDuration: 1 / 30)
        XCTAssertEqual(limits.lower, -2, accuracy: 0.001)
    }

    func testLivePreviewFollowsTheLeftHandleAndKeepsClipsPacked() throws {
        var project = project()
        let retained = try removeHead(&project)
        let following = try TimelineEditing.split(retained, at: .seconds(3), in: &project)
        let display = project.timeline.items.compactMap(TimelineDisplayClip.init)
        let trackID = try XCTUnwrap(project.timeline.videoClip(id: retained)).placement.trackID
        let preview = TimelineCanvas.rippleTrimPreview(clips: display, trackID: trackID,
            trimmedIDs: [retained], anchorID: retained, operation: .trimStart, delta: -2)
        XCTAssertEqual(preview[retained]?.start, -2)
        XCTAssertEqual(preview[retained]?.end, 3)
        XCTAssertEqual(preview[retained]?.offset, -2)
        XCTAssertEqual(preview[following]?.start, 3)
        XCTAssertEqual(preview[following]?.end, 9)
    }

    func testFilmstripPreviewShowsRecoveredFramesBeforeTheRetainedHead() throws {
        let mapping = TimelineSourceMapping(sourceStart: 2, speed: 2, assetStart: 0,
            assetDuration: 12, map: .constant(speed: 2, sourceDuration: try .seconds(6)),
            trimOffset: -1, clipSourceStart: 4)
        XCTAssertEqual(mapping.fraction(atOffset: 0, pixelsPerSecond: 48), 2 / 12, accuracy: 0.001)
        XCTAssertEqual(mapping.fraction(atOffset: 48, pixelsPerSecond: 48), 4 / 12, accuracy: 0.001)
        let reverse = TimelineSourceMapping(sourceStart: 0, speed: 1, assetStart: 0,
            assetDuration: 12, map: .constant(speed: 1, sourceDuration: try .seconds(9), reverses: true),
            trimOffset: -2, clipSourceStart: 0)
        XCTAssertEqual(reverse.fraction(atOffset: 0, pixelsPerSecond: 48), 11 / 12, accuracy: 0.001)
    }

    @MainActor
    func testModelHeadRecoveryAndUndoRedoUseTheSameGesture() throws {
        var project = project()
        let retained = try removeHead(&project)
        let model = try EditorViewModel(project: project)
        let before = model.project.timeline
        model.editTiming(id: retained, operation: .trimStart, seconds: -2)
        XCTAssertNil(model.editError)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.sourceRange.start, try .seconds(1))
        let after = model.project.timeline
        model.undo()
        XCTAssertEqual(model.project.timeline, before)
        model.redo()
        XCTAssertEqual(model.project.timeline, after)
    }

    @MainActor
    func testGroupHeadRecoveryDoesNotDiscardNegativeTravel() throws {
        var project = project()
        let retained = try removeHead(&project)
        let following = try TimelineEditing.split(retained, at: .seconds(3), in: &project)
        let model = try EditorViewModel(project: project)
        let before = model.project.timeline
        model.trimClips([retained, following], operation: .trimStart, delta: -1)
        XCTAssertNil(model.editError)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.sourceRange.start, try .seconds(2))
        XCTAssertEqual(model.project.timeline.videoClip(id: following)?.sourceRange.start, try .seconds(5))
        XCTAssertEqual(model.project.timeline.videoClip(id: following)?.placement.timelineStart, try .seconds(4))
        model.undo()
        XCTAssertEqual(model.project.timeline, before)
    }
}
