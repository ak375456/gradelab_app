import SwiftUI
import XCTest
@testable import GradeLab

@MainActor
final class TimelineTransitionControlsTests: XCTestCase {
    private func splitProject(at seconds: Double = 10) throws -> VideoProject {
        var project = VideoProject(sourceURL: URL(filePath: "/tmp/transition-cut.mov"), displayName: "Cuts",
                                   metadata: makeVideoMetadata(durationSeconds: 20))
        let footage = try XCTUnwrap(project.timeline.firstVideoClip)
        _ = try TimelineEditing.split(footage.id, at: .seconds(seconds), in: &project)
        return project
    }

    func testCutButtonTargetsAnExactJoinEvenWithAnotherTransitionAtTheSameTime() throws {
        var project = try splitProject()
        let mainCut = try XCTUnwrap(TimelineTransitionEditing.editableCuts(in: project).first)
        let mainID = try TimelineTransitionEditing.apply(.crossDissolve, at: mainCut, in: &project)
        let overlayID = UUID()
        let items: [TimelineItem] = project.timeline.tracks[0].items.compactMap { item in
            guard case .video(var clip) = item else { return nil }
            clip.placement = ItemPlacement(id: UUID(), trackID: overlayID,
                                           timelineStart: clip.placement.timelineStart, duration: clip.placement.duration)
            return .video(clip)
        }
        project.timeline.tracks.insert(TimelineTrack(id: overlayID, name: "Overlay", kind: .videoOverlay, items: items), at: 0)

        let overlayCut = try XCTUnwrap(TimelineTransitionEditing.editableCuts(in: project).first { $0.trackID == overlayID })
        let overlayTransition = try TimelineTransitionEditing.apply(.dipToBlack, at: overlayCut, in: &project)
        XCTAssertNotEqual(mainID, overlayTransition)
        XCTAssertEqual(project.timeline.transitions.first(where: { $0.id == mainID })?.type, .crossDissolve)
        XCTAssertEqual(project.timeline.transitions.first(where: { $0.id == overlayTransition })?.outgoingClipID, overlayCut.outgoingID)

        project.timeline.tracks[0].isLocked = true
        XCTAssertFalse(TimelineTransitionEditing.editableCuts(in: project).contains(overlayCut))
        XCTAssertThrowsError(try TimelineTransitionEditing.apply(.crossDissolve, at: overlayCut, in: &project))
    }

    func testResizeStopsAtNeighborAndKeepsCutTiming() throws {
        var project = try splitProject()
        let following = try XCTUnwrap(project.timeline.tracks[0].items.last?.id)
        _ = try TimelineEditing.split(following, at: .seconds(11), in: &project)
        let cuts = TimelineTransitionEditing.editableCuts(in: project)
        XCTAssertEqual(cuts.map { $0.time.seconds }, [10, 11])
        let left = try TimelineTransitionEditing.apply(.crossDissolve, at: cuts[0], in: &project)
        _ = try TimelineTransitionEditing.apply(.crossDissolve, at: cuts[1], in: &project)
        let clips = project.timeline.tracks
        try TimelineTransitionEditing.setDuration(left, seconds: 5, in: &project)
        let resized = project.timeline.transitions[0]
        let neighbor = project.timeline.transitions[1]
        XCTAssertEqual(resized.editTime.seconds, 10)
        XCTAssertLessThanOrEqual(try XCTUnwrap(resized.range).end, try XCTUnwrap(neighbor.range).start)
        XCTAssertGreaterThan(resized.duration.seconds, 0.5)
        XCTAssertEqual(project.timeline.tracks, clips)
    }

    func testCutAndResizeHitTargetsOnNarrowAndWideTimeline() throws {
        var project = try splitProject()
        let cut = try XCTUnwrap(TimelineTransitionEditing.editableCuts(in: project).first)
        let id = try TimelineTransitionEditing.apply(.crossDissolve, at: cut, in: &project)
        let transition = try XCTUnwrap(project.timeline.transitions.first)
        let limits = try XCTUnwrap(TimelineTransitionEditing.durationLimits(for: transition, in: project))

        for width in [320.0, 1_024] {
            let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 160))
            canvas.clips = project.timeline.items.compactMap(TimelineDisplayClip.init)
            canvas.tracks = project.timeline.tracks
            canvas.transitionCuts = [cut]
            canvas.layoutSubviews()
            canvas.update(time: cut.time.seconds)

            let rowHeight = TimelineTrackHeightChoice.regular.points(for: .mainVideo)
            let center = CGPoint(x: width / 2, y: TimelineMetrics.rowsTop + rowHeight / 2)
            var tappedCut: TimelineTransitionEditing.Cut?
            canvas.onAddTransition = { tappedCut = $0 }
            canvas.onSelect = { _ in XCTFail("A cut button should open the picker") }
            canvas.handleTap(at: center)
            XCTAssertEqual(tappedCut, cut)

            canvas.transitions = [transition]
            var selected: UUID?
            canvas.onSelectTransition = { selected = $0 }
            canvas.handleTap(at: center)
            XCTAssertEqual(selected, id)
            canvas.selectedTransitionID = id
            canvas.transitionDurationLimits = limits
            canvas.transitionFrameDuration = project.canvas.frameDuration?.seconds
            canvas.applyExternalZoom(4)
            let layout = TimelineTransitionHandleLayout(center: center, duration: transition.duration.seconds, zoom: 4)
            XCTAssertNil(canvas.transitionResizeTarget(at: center))
            let left = try XCTUnwrap(canvas.transitionResizeTarget(at: layout.position(of: .left)))
            let right = try XCTUnwrap(canvas.transitionResizeTarget(at: layout.position(of: .right)))
            XCTAssertEqual(left.duration(at: -2), right.duration(at: 2), accuracy: 0.0001)
            XCTAssertGreaterThan(right.duration(at: 2), transition.duration.seconds)
            XCTAssertEqual(left.duration(at: 100), limits.lowerBound, accuracy: 0.0001)
            XCTAssertEqual(right.duration(at: 100), limits.upperBound, accuracy: 0.0001)
        }
    }

    func testDeleteRemovesTheAttachedTransitionAndMovesOtherTransitionsInOneUndo() throws {
        var project = try splitProject(at: 5)
        let second = try XCTUnwrap(project.timeline.tracks[0].items.last?.id)
        let third = try TimelineEditing.split(second, at: .seconds(10), in: &project)
        _ = try TimelineEditing.split(third, at: .seconds(15), in: &project)
        let cuts = TimelineTransitionEditing.editableCuts(in: project)
        let attached = try TimelineTransitionEditing.apply(.crossDissolve, at: cuts[0], in: &project)
        let survivor = try TimelineTransitionEditing.apply(.crossDissolve, at: cuts[2], in: &project)
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        model.selectClip(id: cuts[0].outgoingID, seek: false)
        let undoCount = model.history.undoEntries.count

        model.deleteClip()
        XCTAssertEqual(model.project.timeline, project.timeline)
        XCTAssertEqual(model.pendingClipDeletion?.transitionCount, 1)
        model.cancelClipDeletion()
        XCTAssertNil(model.pendingClipDeletion)
        XCTAssertEqual(model.project.timeline, project.timeline)

        model.deleteClip()
        model.confirmClipDeletion(try XCTUnwrap(model.pendingClipDeletion))
        XCTAssertNil(model.editError)
        XCTAssertNil(model.project.timeline.item(id: cuts[0].outgoingID))
        XCTAssertFalse(model.project.timeline.transitions.contains { $0.id == attached })
        XCTAssertEqual(model.project.timeline.transitions.first(where: { $0.id == survivor })?.editTime.seconds, 10)
        XCTAssertEqual(model.history.undoEntries.count, undoCount + 1)
        try model.project.validate()

        model.undo()
        XCTAssertEqual(model.project.timeline, project.timeline)
    }

    func testDurationGestureCommitsOneUndoEntryWithoutMovingClips() throws {
        let project = try splitProject()
        let cut = try XCTUnwrap(TimelineTransitionEditing.editableCuts(in: project).first)
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()

        model.prepareTransitionPanel(at: cut)
        model.applyTransition(.crossDissolve)
        let transition = try XCTUnwrap(model.selectedTransition)
        XCTAssertEqual(transition.editTime, cut.time)
        let count = model.history.undoEntries.count
        model.resizeTransition(transition.id, seconds: 2)

        XCTAssertEqual(model.history.undoEntries.count, count + 1)
        let resized = try XCTUnwrap(model.selectedTransition)
        XCTAssertEqual(resized.duration.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(resized.editTime, transition.editTime)
        XCTAssertEqual(model.project.timeline.tracks, project.timeline.tracks)
        model.undo()
        XCTAssertEqual(model.selectedTransition, transition)
    }
}
