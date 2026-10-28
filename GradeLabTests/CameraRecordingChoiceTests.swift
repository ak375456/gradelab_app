#if !targetEnvironment(macCatalyst)
import XCTest
@testable import GradeLab

@MainActor
final class CameraRecordingChoiceTests: XCTestCase {
    func testRecordingWarningStaysWithTheDestinationInsteadOfOpeningAnAlert() throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CameraViewModel(recordingStore: store)
        model.receive(.finished(recording, warning: "Encoder stopped early. Footage kept."))
        XCTAssertEqual(model.completedRecording, recording)
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertNotNil(model.recordingWarning)
        XCTAssertNil(model.message, "A warning must not compete with the destination sheet")
        model.receive(.message("Microphone disconnected."))
        XCTAssertEqual(model.recordingWarning, "Microphone disconnected.")
        XCTAssertNil(model.message)
        model.dismissRecordingChoice()
        XCTAssertNil(model.recordingWarning)
        XCTAssertEqual(try store.pending().map(\.id), [recording.id])
    }

    func testCompletedTakeWaitsForADestinationWithoutCreatingAProject() async throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CameraViewModel(recordingStore: store, saveVideo: { _ in XCTFail("Must wait for Save to Photos") })
        model.receive(.finished(recording))
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.completedRecording, recording)
        XCTAssertFalse(model.canRecord)
        let projects = try await ProjectStore(rootURL: root).loadProjects()
        XCTAssertTrue(projects.isEmpty)
        XCTAssertEqual(try store.pending().map(\.id), [recording.id])
        model.receive(.interrupted(false))
        XCTAssertEqual(model.phase, .reviewing, "A late session event must not resume while choosing a destination")
        model.dismissRecordingChoice()
        XCTAssertNil(model.completedRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaURL(for: recording).path))
        XCTAssertEqual(try store.pending().map(\.id), [recording.id])
    }

    func testSuccessfulPhotoSaveRemovesOnlyTheConfirmedLocalTake() async throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try store.prepare(grade: .neutral)
        try Data("another take".utf8).write(to: store.mediaURL(for: other))
        let probe = PhotoSaveProbe()
        let model = CameraViewModel(recordingStore: store, saveVideo: { try await probe.save($0) })
        model.receive(.finished(recording))
        await model.saveCompletedRecordingToPhotos()
        let saved = await probe.urls
        XCTAssertEqual(saved, [store.mediaURL(for: recording)])
        XCTAssertNil(model.completedRecording)
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(model.isSavingToPhotos)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(for: recording).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaURL(for: other).path))
        XCTAssertEqual(try store.pending().map(\.id), [other.id])
        let projects = try await ProjectStore(rootURL: root).loadProjects()
        XCTAssertTrue(projects.isEmpty, "Saving to Photos must not import into the editor")
    }

    func testDeniedPhotoSaveKeepsOriginalAndAllowsRetry() async throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PhotoSaveProbe()
        await probe.deny()
        let model = CameraViewModel(recordingStore: store, saveVideo: { try await probe.save($0) })
        model.receive(.finished(recording))
        await model.saveCompletedRecordingToPhotos()
        XCTAssertEqual(model.completedRecording, recording)
        XCTAssertTrue(model.photosAccessDenied)
        XCTAssertNotNil(model.photosSaveError)
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(for: recording)), Data("original take".utf8))
        XCTAssertEqual(try store.pending().map(\.id), [recording.id])
        await probe.allow()
        await model.saveCompletedRecordingToPhotos()
        XCTAssertNil(model.completedRecording)
        XCTAssertNil(model.photosSaveError)
    }

    func testPhotoSaveCannotBeSubmittedTwice() async throws {
        let (root, store, recording) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PhotoSaveProbe()
        let model = CameraViewModel(recordingStore: store, saveVideo: { try await probe.save($0) })
        model.receive(.finished(recording))
        let first = Task { await model.saveCompletedRecordingToPhotos() }
        while !model.isSavingToPhotos { await Task.yield() }
        model.dismissRecordingChoice()
        XCTAssertNotNil(model.completedRecording, "A saving take cannot be dismissed")
        await model.saveCompletedRecordingToPhotos()
        await first.value
        let count = await probe.urls.count
        XCTAssertEqual(count, 1)
    }

    private func fixture() throws -> (URL, CameraRecordingStore, CameraRecording) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraChoice-\(UUID().uuidString)")
        let store = CameraRecordingStore(root: root)
        let recording = try store.prepare(grade: .neutral)
        try Data("original take".utf8).write(to: store.mediaURL(for: recording))
        return (root, store, recording)
    }
}

private actor PhotoSaveProbe {
    var urls: [URL] = []
    private var denied = false
    func deny() { denied = true }
    func allow() { denied = false }
    func save(_ url: URL) async throws {
        if denied { throw PhotoLibrarySaveError.accessDenied }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        urls.append(url)
        try await Task.sleep(for: .milliseconds(40))
    }
}
#endif
