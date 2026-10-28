import XCTest
@testable import GradeLab

final class CameraRecordingStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraStore-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testReceiptRetainsEditableLookAndCompletingNeverDeletesOriginal() throws {
        let store = CameraRecordingStore(root: root)
        var grade = GradeSettings.neutral
        grade.advanced = AdvancedGrade()
        grade.advanced?.lut = "WarmCinema.cube"; grade.advanced?.lutIntensity = 72
        let recording = try store.prepare(grade: grade)
        let bytes = Data("original sensor recording".utf8)
        try bytes.write(to: store.mediaURL(for: recording))
        let pending = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(pending.grade, grade)
        XCTAssertEqual(pending.profile, .sdr)
        XCTAssertEqual(pending.id, recording.id)
        try store.complete(pending)
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(for: pending)), bytes)
        try store.complete(pending) // Recovery after a database commit is idempotent.
    }

    func testFailedPartialRecordingIsKeptForRecovery() throws {
        let store = CameraRecordingStore(root: root)
        let recording = try store.prepare(grade: .neutral)
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: store.mediaURL(for: recording))
        try store.discardEmpty(recording)
        XCTAssertEqual(try store.pending().map(\.id), [recording.id])
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(for: recording)), bytes)
    }

    func testCaptureThatNeverStartedCanBeForgotten() throws {
        let store = CameraRecordingStore(root: root)
        let recording = try store.prepare(grade: .neutral)
        try store.discardEmpty(recording)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testReceiptSurvivesContainerRelocation() throws {
        let store = CameraRecordingStore(root: root)
        let recording = try store.prepare(grade: .neutral)
        try Data([4, 5, 6]).write(to: store.mediaURL(for: recording))
        let relocated = root.appendingPathExtension("relocated")
        defer { try? FileManager.default.removeItem(at: relocated) }
        try FileManager.default.moveItem(at: root, to: relocated)
        let restored = CameraRecordingStore(root: relocated)
        let receipt = try XCTUnwrap(restored.pending().first)
        XCTAssertEqual(try Data(contentsOf: restored.mediaURL(for: receipt)), Data([4, 5, 6]))
    }

    func testExplicitDeletionRemovesOnlyTheSelectedPendingOriginal() throws {
        let store = CameraRecordingStore(root: root)
        let selected = try store.prepare(grade: .neutral), other = try store.prepare(grade: .neutral)
        try Data([1]).write(to: store.mediaURL(for: selected))
        try Data([2]).write(to: store.mediaURL(for: other))
        try store.delete(selected, preserving: [])
        XCTAssertEqual(try store.pending().map(\.id), [other.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(for: selected).path))
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(for: other)), Data([2]))
        try store.delete(selected, preserving: [])
    }

    func testDeletingAStaleReceiptKeepsMediaUsedByASavedProject() throws {
        let store = CameraRecordingStore(root: root)
        let recording = try store.prepare(grade: .neutral)
        let original = Data([1, 2, 3])
        try original.write(to: store.mediaURL(for: recording))
        try store.delete(recording, preserving: [store.mediaURL(for: recording)])
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(for: recording)), original)
        // A stale UI action cannot subsequently delete that saved-project media.
        try store.delete(recording, preserving: [])
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(for: recording)), original)
    }

    func testDeletionFailureKeepsTheReceiptRetryable() throws {
        let store = CameraRecordingStore(root: root)
        let recording = try store.prepare(grade: .neutral)
        // A malformed filename must never escape the managed Imports folder.
        let invalid = CameraRecording(id: recording.id, fileName: "../outside.mov", createdAt: .now, grade: .neutral)
        XCTAssertThrowsError(try store.delete(invalid, preserving: []))
        XCTAssertEqual(try store.pending().map(\.id), [recording.id])
    }
}
