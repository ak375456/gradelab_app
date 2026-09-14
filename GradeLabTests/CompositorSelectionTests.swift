import XCTest
@testable import GradeLab

final class CompositorSelectionTests: XCTestCase {

    private func makeProject(
        colorMode: ProjectColorMode,
        duration: Double = 10
    ) -> GradeProject {
        var project = GradeProject(
            sourceURL: URL(fileURLWithPath: "/tmp/log.mov"),
            displayName: "Log",
            metadata: makeMetadata(duration: duration))
        project.colorMode = colorMode
        return project
    }

    /// Adds a second clip, which is the cheapest way to need the compositor.
    private func addingASecondClip(to project: GradeProject) throws -> GradeProject {
        var project = project
        let range = TimelineRange(start: .zero, duration: try TimelineTime.seconds(5))
        let asset = ProjectMediaAsset(id: UUID(), url: URL(fileURLWithPath: "/tmp/b.mov"),
                                      sourceRange: range, videoMetadata: makeMetadata(duration: 5),
                                      frameDuration: project.canvas.frameDuration)
        project.addAsset(asset)
        project.timeline.tracks[0].items.append(.video(VideoClip(
            placement: .init(id: UUID(), trackID: project.timeline.tracks[0].id,
                             timelineStart: project.timeline.duration, duration: range.duration),
            assetID: asset.id, sourceRange: range, embeddedAudio: EmbeddedAudio())))
        try project.validate()
        return project
    }

    /// A remaining non-primary clip must render its own asset. The single-source path
    /// renders the PRIMARY asset, so one remaining clip pointing at some other
    /// asset must keep compositing or it would play the wrong footage.
    func testOneClipOnANonPrimaryAssetStillNeedsTheCompositor() throws {
        var project = try addingASecondClip(to: makeProject(colorMode: .sdr))
        project.timeline.tracks[0].items.removeFirst()   // drop the primary clip
        try project.validate()

        XCTAssertEqual(project.timeline.tracks[0].items.count, 1)
        XCTAssertNotEqual(project.timeline.tracks[0].items[0].assetID, project.primaryAssetID)
        XCTAssertTrue(project.needsLayerCompositor)
    }

    func testDeletingASecondClipDoesNotLeaveTheCompositorEnabledByAnOrphanedAsset() throws {
        var project = try addingASecondClip(to: makeProject(colorMode: .sdr))
        project.timeline.tracks[0].items.removeLast()
        try project.validate()
        XCTAssertEqual(project.assets.count, 2)
        XCTAssertFalse(project.needsLayerCompositor)
    }

    /// An untouched single-clip project must be unaffected by that change — it
    /// is the path every ordinary project takes.
    func testAPlainSingleClipProjectStillAvoidsTheCompositor() {
        XCTAssertFalse(makeProject(colorMode: .sdr).needsLayerCompositor)
    }
}
