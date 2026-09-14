import XCTest
@testable import GradeLab

/// The project library: what happens when it cannot be read, what happens when
/// a project is deleted, and what the card on Home is actually describing.
///
/// All three are promises made to the user about their own files — that a bad
/// database is not silently an empty one, that deleting frees storage without
/// taking media something else is using, and that the numbers on a card are the
/// project's rather than the first clip's.
final class ProjectLibraryTests: XCTestCase {

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradeLabTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A real file on disk, so "was the media removed?" is a question about the
    /// file system rather than about a URL value.
    @discardableResult
    private func makeMediaFile(in root: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try Data("movie".utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Deleting a video project

    /// Video projects had no delete at all, so every imported copy stayed on the
    /// device for good. This is the whole feature in one assertion.
    func testDeletingAVideoProjectRemovesItsDocumentAndItsImportedCopy() async throws {
        let root = makeRoot()
        let store = ProjectStore(rootURL: root)
        let media = try makeMediaFile(in: root, named: "clip.mov")
        let thumbnail = try makeMediaFile(in: root, named: "thumb.jpg")

        var project = GradeProject(sourceURL: media, displayName: "Only", metadata: makeMetadata())
        project.thumbnailFileName = thumbnail.path
        try await store.save(project)

        try await store.delete(project.id, mediaReferencedElsewhere: [])

        let remaining = try await store.loadProjects()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(exists(media))
        XCTAssertFalse(exists(thumbnail))
    }

    /// The reason deletion asks before it removes anything.
    func testDeletingAProjectKeepsMediaAnotherProjectStillReferences() async throws {
        let root = makeRoot()
        let store = ProjectStore(rootURL: root)
        let shared = try makeMediaFile(in: root, named: "shared.mov")

        let doomed = GradeProject(sourceURL: shared, displayName: "Doomed", metadata: makeMetadata())
        let keeper = GradeProject(sourceURL: shared, displayName: "Keeper", metadata: makeMetadata())
        try await store.save(doomed)
        try await store.save(keeper)

        try await store.delete(doomed.id, mediaReferencedElsewhere: [])

        let remaining = try await store.loadProjects()
        XCTAssertEqual(remaining.map(\.displayName), ["Keeper"])
        XCTAssertTrue(exists(shared), "The surviving project still points at this file.")
    }

    /// Video and photo documents live in two databases but import into one
    /// folder, so neither library can decide on its own that a file is unused.
    func testDeletingAPhotoProjectKeepsMediaTheVideoLibraryReferences() async throws {
        let root = makeRoot()
        let videoStore = ProjectStore(rootURL: root)
        let imageStore = ImageProjectStore(rootURL: root)
        let shared = try makeMediaFile(in: root, named: "shared.heic")

        try await videoStore.save(GradeProject(sourceURL: shared, displayName: "Overlay",
                                               metadata: makeMetadata()))
        let photo = ImageProject(
            displayName: "Photo",
            asset: ImageAsset(id: UUID(), url: shared, metadata: makeImageMetadata()))
        try await imageStore.save(photo)

        try await imageStore.delete(
            photo.id, mediaReferencedElsewhere: try await videoStore.referencedMediaURLs())

        let remainingPhotos = try await imageStore.loadProjects()
        XCTAssertTrue(remainingPhotos.isEmpty)
        XCTAssertTrue(exists(shared), "A video project still uses this file.")
    }

    /// When the other library cannot be read its references are unknown, and
    /// unknown has to mean "keep it". An orphaned file wastes storage; a file
    /// deleted out from under a project that needs it breaks that project.
    func testDeletingWithUnknownReferencesRemovesTheDocumentButNoMedia() async throws {
        let root = makeRoot()
        let store = ProjectStore(rootURL: root)
        let media = try makeMediaFile(in: root, named: "clip.mov")
        let project = GradeProject(sourceURL: media, displayName: "Only", metadata: makeMetadata())
        try await store.save(project)

        try await store.delete(project.id, mediaReferencedElsewhere: nil)

        let remaining = try await store.loadProjects()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(exists(media))
    }

    // MARK: - A library that will not load

    /// A corrupt database used to be invisible for photos and, for both kinds,
    /// permanently fatal: every store reads-modifies-writes, so a file that will
    /// not decode also makes every future import fail. Moving it aside is what
    /// gets the app working again — and it is moved, never deleted.
    func testACorruptLibraryIsMovedAsideReportedAndSavingWorksAgain() async throws {
        let root = makeRoot()
        let store = ProjectStore(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("projects.json")
        let original = Data("{ this is not a project library".utf8)
        try original.write(to: databaseURL)

        var recovered: URL?
        do {
            _ = try await store.loadProjects()
            XCTFail("A corrupt library must not read as an empty one.")
        } catch let error as LibraryLoadError {
            guard case .unreadable(let url, _) = error else {
                return XCTFail("Expected an unreadable library, got \(error).")
            }
            recovered = url
            XCTAssertNotNil(error.errorDescription)
        }

        let recoveredURL = try XCTUnwrap(recovered)
        XCTAssertEqual(recoveredURL.deletingLastPathComponent().lastPathComponent, "Recovered")
        XCTAssertEqual(try Data(contentsOf: recoveredURL), original, "The bytes are kept, not discarded.")
        XCTAssertFalse(exists(databaseURL), "The unreadable file is out of the way.")

        // The point of moving it: the library works from here on.
        let project = GradeProject(sourceURL: root.appendingPathComponent("clip.mov"),
                                   displayName: "After", metadata: makeMetadata())
        try await store.save(project)
        let reloaded = try await store.loadProjects()
        XCTAssertEqual(reloaded.map(\.displayName), ["After"])
    }

    /// The opposite case, and the one that would cost the user everything if it
    /// were handled the same way: a document written by a newer build is not
    /// damaged, and an older build must leave it exactly where it is.
    func testALibraryFromANewerBuildIsReportedButNeverMovedAside() async throws {
        let root = makeRoot()
        let store = ProjectStore(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("projects.json")
        let original = Data(#"{"projects":[{"projectVersion":99}]}"#.utf8)
        try original.write(to: databaseURL)

        do {
            _ = try await store.loadProjects()
            XCTFail("A document this build cannot read must not read as an empty library.")
        } catch let error as LibraryLoadError {
            guard case .newerVersion = error else {
                return XCTFail("Expected a newer-version library, got \(error).")
            }
        }

        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertFalse(exists(root.appendingPathComponent("Recovered")))
    }

    /// The photo library gets the same treatment. Its failures used to be
    /// printed in DEBUG and swallowed everywhere else, which looked from Home
    /// exactly like having imported nothing.
    func testTheSameHoldsForThePhotoLibrary() async throws {
        let root = makeRoot()
        let store = ImageProjectStore(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("image-projects.json")

        try Data(#"{"projects":[{"documentVersion":99}]}"#.utf8).write(to: databaseURL)
        do {
            _ = try await store.loadProjects()
            XCTFail("Expected the newer document to be refused.")
        } catch let error as LibraryLoadError {
            guard case .newerVersion = error else { return XCTFail("Got \(error).") }
        }
        XCTAssertTrue(exists(databaseURL))

        try Data("not json at all".utf8).write(to: databaseURL)
        do {
            _ = try await store.loadProjects()
            XCTFail("Expected the corrupt database to be refused.")
        } catch let error as LibraryLoadError {
            guard case .unreadable(let url, _) = error else { return XCTFail("Got \(error).") }
            XCTAssertNotNil(url)
        }
        XCTAssertFalse(exists(databaseURL))
    }

    /// A library that has never been written is empty, not broken, and must not
    /// raise anything at all.
    func testAnAbsentLibraryIsSimplyEmpty() async throws {
        let root = makeRoot()
        let videos = try await ProjectStore(rootURL: root).loadProjects()
        let photos = try await ImageProjectStore(rootURL: root).loadProjects()
        XCTAssertTrue(videos.isEmpty)
        XCTAssertTrue(photos.isEmpty)
    }

    // MARK: - What the card on Home describes

    /// The defect verbatim: two ten-second clips, and the card claimed ten
    /// seconds because it was reading the primary source's duration.
    func testAProjectsDurationIsTheTimelinesNotTheFirstSources() throws {
        let project = try makeTwoClipProject()
        XCTAssertEqual(project.metadata.durationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(project.timeline.duration.seconds, 20, accuracy: 0.001,
                       "The movie is as long as its timeline, not as long as its first clip.")
    }

    /// Trimming shortens the movie. The source file is exactly as long as it was.
    func testTrimmingAClipChangesTheProjectsDurationAndNotTheSources() throws {
        var project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "Trimmed",
                                   metadata: makeMetadata(duration: 10))
        let clip = try XCTUnwrap(project.timeline.firstVideoClip)
        let half = try TimelineTime.seconds(5)
        var trimmed = clip
        trimmed.sourceRange = TimelineRange(start: clip.sourceRange.start, duration: half)
        trimmed.placement.duration = half
        project.timeline.tracks[0].items[0] = .video(trimmed)
        try project.validate()

        XCTAssertEqual(project.timeline.duration.seconds, 5, accuracy: 0.001)
        XCTAssertEqual(project.metadata.durationSeconds, 10, accuracy: 0.001)
    }

    /// The card's dimensions are the canvas, which is what gets exported — not
    /// the frame the footage happened to arrive in.
    func testACanvasResizeChangesWhatTheCardDescribes() throws {
        var project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "Vertical",
                                   metadata: makeMetadata(displayWidth: 3_840, displayHeight: 2_160))
        XCTAssertEqual(project.canvas.resolutionClass, "4K")

        project.canvas.width = 1_080
        project.canvas.height = 1_920
        XCTAssertEqual(project.canvas.resolutionLabel, "1080 × 1920")
        // Classed on the long and short edge, so a portrait canvas is 1080p just
        // as a landscape one is. What matters here is that it moved at all.
        XCTAssertEqual(project.canvas.resolutionClass, "1080p")
        XCTAssertEqual(project.metadata.resolutionClass, "4K", "The source is unchanged.")
        XCTAssertEqual(project.metadata.resolutionLabel, "3840 × 2160")
    }

    /// `frameDuration` is optional so that an unknown rate stays unknown. The
    /// label has to honour that rather than printing a plausible number.
    func testAnUnknownCanvasFrameRateIsNotPrintedAsANumber() throws {
        var project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "Rateless",
                                   metadata: makeMetadata(nominalFrameRate: 30))
        XCTAssertEqual(project.canvas.frameRateLabel, "30 FPS")
        project.canvas.frameDuration = nil
        XCTAssertNil(project.canvas.frameRateLabel)
    }

    /// Broadcast rates keep their two decimals, the same as on the source
    /// screen — the point of the two labels sharing one definition.
    func testFractionalFrameRatesAreSpelledTheSameEverywhere() throws {
        let canvas = ProjectCanvas(width: 1_920, height: 1_080,
                                   frameDuration: try TimelineTime(value: 1_001, timescale: 30_000))
        XCTAssertEqual(canvas.frameRateLabel, "29.97 FPS")
        XCTAssertEqual(VideoMetadata.frameRateLabel(forFrameRate: 30_000.0 / 1_001), "29.97 FPS")
    }

    // MARK: - Fixtures

    private func makeTwoClipProject() throws -> GradeProject {
        var project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "Two Clips",
                                   metadata: makeMetadata(duration: 10))
        let range = TimelineRange(start: .zero, duration: try TimelineTime.seconds(10))
        let second = ProjectMediaAsset(id: UUID(), url: URL(fileURLWithPath: "/tmp/b.mov"),
                                       sourceRange: range, videoMetadata: makeMetadata(duration: 10),
                                       frameDuration: project.canvas.frameDuration)
        project.addAsset(second)
        let clip = VideoClip(
            placement: .init(id: UUID(), trackID: project.timeline.tracks[0].id,
                             timelineStart: project.timeline.duration, duration: range.duration),
            assetID: second.id, sourceRange: range, embeddedAudio: EmbeddedAudio())
        project.timeline.tracks[0].items.append(.video(clip))
        try project.validate()
        return project
    }

    private func makeImageMetadata() -> ImageMetadata {
        ImageMetadata(
            fileName: "IMG_0001.HEIC", pixelWidth: 4_032, pixelHeight: 3_024,
            orientation: 1, typeIdentifier: "public.heic", fileSize: 2_400_000,
            bitsPerComponent: 8, colorModel: "RGB", colorProfileName: "Display P3",
            hasEmbeddedProfile: true, isWideGamut: true, isHDR: false, hasAlpha: false,
            dpi: 72, creationDate: Date(timeIntervalSince1970: 1_700_000_000), isRAW: false,
            hdrGainMap: false)
    }
}
