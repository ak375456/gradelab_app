import XCTest
@testable import GradeLab

@MainActor
final class TimelineLayerCleanupTests: XCTestCase {
    private func fixture(image: Bool = false) throws -> (VideoProject, UUID, UUID) {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/layer-cleanup.mov"),
                                   displayName: "Layer cleanup", metadata: makeVideoMetadata(durationSeconds: 9))
        let row = UUID()
        var overlay = try XCTUnwrap(project.timeline.firstVideoClip)
        overlay.placement = .init(id: UUID(), trackID: row, timelineStart: try .seconds(3),
                                  duration: try .seconds(3))
        overlay.sourceRange.duration = try .seconds(3)
        if image {
            let still = ProjectMediaAsset(id: UUID(), url: URL(fileURLWithPath: "/tmp/layer-cleanup.png"),
                sourceRange: overlay.sourceRange, stillImage: .init(width: 400, height: 300))
            project.addAsset(still)
            overlay.assetID = still.id
            overlay.embeddedAudio = nil
        }
        project.timeline.tracks.insert(.init(id: row, name: "My overlay", kind: .videoOverlay,
                                             items: [.video(overlay)]), at: 0)
        return (project, overlay.id, row)
    }

    func testDeletingOrCuttingLastVideoOrImageRemovesOnlyItsRowAndUndoesOnce() throws {
        for image in [false, true] {
            for cutting in [false, true] {
                var (project, clipID, rowID) = try fixture(image: image)
                let placeholder = TimelineTrack(id: UUID(), name: "Ready for media", kind: .videoOverlay)
                project.timeline.tracks.insert(placeholder, at: 0)
                let main = try XCTUnwrap(project.timeline.tracks.first { $0.kind == .mainVideo })
                let model = try EditorViewModel(project: project)
                model.suspendPreviewForExport()
                model.selectClip(id: clipID, seek: false)

                model.deleteClip(cutting: cutting)

                XCTAssertNil(model.editError)
                XCTAssertNil(model.project.timeline.tracks.first { $0.id == rowID })
                XCTAssertNil(model.project.timeline.item(id: clipID))
                XCTAssertEqual(model.project.timeline.tracks.first { $0.id == main.id }, main)
                XCTAssertEqual(model.project.timeline.tracks.first { $0.id == placeholder.id }, placeholder,
                               "Intentionally empty tracks unrelated to the deletion remain available.")
                XCTAssertEqual(model.history.undoEntries.count, 1)
                let deleted = model.project.timeline
                model.undo()
                XCTAssertEqual(model.project.timeline, project.timeline)
                model.redo()
                XCTAssertEqual(model.project.timeline, deleted)
                let reopened = try JSONDecoder().decode(VideoProject.self,
                    from: JSONEncoder().encode(model.project))
                XCTAssertEqual(reopened.timeline, deleted)
            }
        }
    }

    func testSharedOverlayRowRemainsUntilItsLastClipIsDeleted() throws {
        var (project, firstID, rowID) = try fixture()
        var next = try XCTUnwrap(project.timeline.videoClip(id: firstID))
        next.placement = .init(id: UUID(), trackID: rowID, timelineStart: try .seconds(6),
                               duration: next.placement.duration)
        project.timeline.tracks[0].items.append(.video(next))
        try TimelineEditing.deleteClosingGaps(firstID, in: &project)
        XCTAssertEqual(project.timeline.tracks.first { $0.id == rowID }?.items, [.video(next)])
        try TimelineEditing.deleteClosingGaps(next.id, in: &project)
        XCTAssertNil(project.timeline.tracks.first { $0.id == rowID })
        _ = try TimelineEditing.clips(in: project)
    }

    func testDeletingLastMainClipKeepsMainRow() throws {
        var project = try fixture().0
        let main = try XCTUnwrap(project.timeline.tracks.first { $0.kind == .mainVideo })
        try TimelineEditing.deleteClosingGaps(try XCTUnwrap(main.items.first).id, in: &project)
        XCTAssertEqual(project.timeline.tracks.first { $0.id == main.id }?.items, [])
    }

    func testLockedLayerRefusesDeletionWithoutRemovingItsRow() throws {
        var (project, clipID, rowID) = try fixture()
        project.timeline.tracks[0].isLocked = true
        let before = project
        XCTAssertThrowsError(try TimelineEditing.deleteClosingGaps(clipID, in: &project))
        XCTAssertEqual(project, before)
        XCTAssertNotNil(project.timeline.tracks.first { $0.id == rowID })
    }
}
