import XCTest
@testable import GradeLab

/// The media bin places media the project already holds. Nothing here goes
/// through import, so the invariant under test is that a second use of a source
/// costs a clip and not another copy of the file.
@MainActor
final class MediaBinTests: XCTestCase {

    /// The model owns its document, so a test that needs extra media or a
    /// locked track builds the project first and hands it over.
    private func makeModel(_ configure: (inout GradeProject) throws -> Void = { _ in }) throws -> EditorViewModel {
        var project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
                                   displayName: "Clip", metadata: makeMetadata(duration: 10))
        try configure(&project)
        return try EditorViewModel(project: project)
    }

    private static let stillID = UUID()

    private static func addStill(to project: inout GradeProject) throws {
        project.addAsset(.init(id: stillID, url: URL(fileURLWithPath: "/tmp/still.heic"),
                               sourceRange: .init(start: .zero, duration: try .seconds(3)),
                               videoMetadata: nil, stillImage: .init(width: 400, height: 300)))
    }

    // MARK: - Placing

    func testPlacingOnTheMainTrackAppendsAfterWhatIsAlreadyThere() throws {
        let model = try makeModel()
        let assetID = model.project.primaryAssetID
        let before = try TimelineEditing.clips(in: model.project)
        XCTAssertEqual(before.count, 1)
        let end = try XCTUnwrap(before.first).placement.range

        model.placeAsset(assetID, as: .mainTrack)

        XCTAssertNil(model.editError)
        let after = try TimelineEditing.clips(in: model.project)
        XCTAssertEqual(after.count, 2, "the same source should be placeable a second time")
        let added = try XCTUnwrap(after.last)
        XCTAssertEqual(added.placement.timelineStart, try end.end,
                       "a main-track placement lands after the last clip, not on top of it")
    }

    /// The whole point of a bin: placing does not import, so the asset list is
    /// untouched and no second copy of the file is made.
    func testPlacingDoesNotAddASecondCopyOfTheAsset() throws {
        let model = try makeModel()
        let assets = model.project.assets
        model.placeAsset(model.project.primaryAssetID, as: .mainTrack)
        XCTAssertEqual(model.project.assets, assets)
    }

    func testAnOverlayPlacementStartsWhereItWasDropped() throws {
        let model = try makeModel()
        let tracks = model.project.timeline.tracks.count

        model.placeAsset(model.project.primaryAssetID, as: .overlay(at: 4))

        XCTAssertNil(model.editError)
        XCTAssertEqual(model.project.timeline.tracks.count, tracks + 1, "an overlay gets a layer of its own")
        let overlay = try XCTUnwrap(model.project.timeline.tracks.first)
        XCTAssertEqual(overlay.kind, .videoOverlay)
        let clip = try XCTUnwrap(overlay.items.first)
        XCTAssertEqual(clip.placement.timelineStart.seconds, 4, accuracy: 0.05)
    }

    /// A still has no length of its own, so it takes the same three seconds the
    /// image import gives one rather than a zero-length clip.
    func testAPlacedStillGetsADefaultLength() throws {
        let model = try makeModel { try Self.addStill(to: &$0) }

        model.placeAsset(Self.stillID, as: .overlay(at: 0))

        XCTAssertNil(model.editError)
        let clip = try XCTUnwrap(model.project.timeline.tracks.first?.items.first)
        XCTAssertEqual(clip.placement.duration.seconds, 3, accuracy: 0.05)
    }

    func testPlacingMediaTheProjectNoLongerHoldsReportsItAndChangesNothing() throws {
        let model = try makeModel()
        let timeline = model.project.timeline

        model.placeAsset(UUID(), as: .mainTrack)

        XCTAssertNotNil(model.editError)
        XCTAssertEqual(model.project.timeline, timeline)
    }

    func testPlacingOnALockedMainTrackIsRefused() throws {
        let model = try makeModel { project in
            let index = project.timeline.tracks.firstIndex { $0.kind == .mainVideo }!
            project.timeline.tracks[index].isLocked = true
        }
        let timeline = model.project.timeline

        model.placeAsset(model.project.primaryAssetID, as: .mainTrack)

        XCTAssertNotNil(model.editError)
        XCTAssertEqual(model.project.timeline, timeline)
    }

    // MARK: - What the bin shows

    func testUsageCountsTheClipsThatReferenceAnAsset() throws {
        let model = try makeModel()
        let assetID = model.project.primaryAssetID
        XCTAssertEqual(model.usageCount(of: assetID), 1)

        model.placeAsset(assetID, as: .mainTrack)
        XCTAssertEqual(model.usageCount(of: assetID), 2)

        let other = try makeModel { try Self.addStill(to: &$0) }
        XCTAssertEqual(other.usageCount(of: Self.stillID), 0, "imported but never placed reads as unused")
    }

    func testAnAssetDescribesItselfByKind() throws {
        let model = try makeModel()
        let video = try XCTUnwrap(model.project.assets.first)
        XCTAssertEqual(MediaBinEntry.kind(of: video), String(localized: "Video"))
        XCTAssertEqual(MediaBinEntry.name(of: video), "clip")
        XCTAssertEqual(MediaBinEntry.detail(of: video), "0:10")

        let withStill = try makeModel { try Self.addStill(to: &$0) }
        let still = try XCTUnwrap(withStill.project.assets.first { $0.id == Self.stillID })
        XCTAssertEqual(MediaBinEntry.kind(of: still), String(localized: "Photo"))
        XCTAssertEqual(MediaBinEntry.detail(of: still), "400×300", "a still is measured in pixels, not seconds")
    }

    // MARK: - What one Import button has to sort out

    /// One button and one drop target serve all three kinds, so the file has to
    /// classify itself correctly — including the containers that answer to more
    /// than one type.
    func testAFileIsRoutedByWhatItActuallyIs() {
        func kind(_ name: String) -> EditorViewModel.ImportedMediaKind? {
            EditorViewModel.ImportedMediaKind(URL(fileURLWithPath: "/tmp/\(name)"))
        }
        for name in ["a.mov", "a.mp4", "a.m4v"] {
            XCTAssertEqual(kind(name), .video, name)
        }
        for name in ["a.heic", "a.jpg", "a.jpeg", "a.png", "a.tiff", "a.dng"] {
            XCTAssertEqual(kind(name), .image, name)
        }
        for name in ["a.wav", "a.mp3", "a.m4a", "a.aiff", "a.caf"] {
            XCTAssertEqual(kind(name), .audio, name)
        }
        for name in ["a.txt", "a.pdf", "a.cube", "a", "a.zip"] {
            XCTAssertNil(kind(name), name)
        }
    }

    /// `.mp4` and `.m4a` share a container family, and an `.m4v` reports as
    /// audio-capable too. A movie that also answers to audio is still a movie,
    /// or dropping a rush in would add a soundtrack and no picture.
    func testAMovieThatAlsoReportsAsAudioIsStillAMovie() {
        XCTAssertEqual(EditorViewModel.ImportedMediaKind(URL(fileURLWithPath: "/tmp/take.mp4")), .video)
        XCTAssertEqual(EditorViewModel.ImportedMediaKind(URL(fileURLWithPath: "/tmp/take.m4a")), .audio)
    }

    // MARK: - The drag payload

    /// The timeline accepts plain text, so the payload has to be recognisable.
    /// A file name or a snippet dragged in from anywhere else must not resolve
    /// to an asset.
    func testTheDragPayloadRoundTripsAndRejectsAnythingElse() {
        let id = UUID()
        XCTAssertEqual(MediaBinEntry.assetID(fromDrag: MediaBinEntry.dragIdentifier(id)), id)
        XCTAssertNil(MediaBinEntry.assetID(fromDrag: id.uuidString), "a bare UUID is not the bin's payload")
        XCTAssertNil(MediaBinEntry.assetID(fromDrag: "gradelab.asset:not-a-uuid"))
        XCTAssertNil(MediaBinEntry.assetID(fromDrag: "some dragged text"))
        XCTAssertNil(MediaBinEntry.assetID(fromDrag: ""))
    }
}
