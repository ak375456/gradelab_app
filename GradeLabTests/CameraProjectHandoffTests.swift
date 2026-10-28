import XCTest
@testable import GradeLab

@MainActor
final class CameraProjectHandoffTests: XCTestCase {
    func testDeletingAPendingTakeRefreshesHomeAndPreservesTheOtherTake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraDelete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = CameraRecordingStore(root: root)
        let take = try recordings.prepare(grade: .neutral), other = try recordings.prepare(grade: .neutral)
        try Data([1]).write(to: recordings.mediaURL(for: take))
        try Data([2]).write(to: recordings.mediaURL(for: other))
        let coordinator = AppCoordinator(projectStore: ProjectStore(rootURL: root), cameraRecordingStore: recordings,
            imageProjectStore: ImageProjectStore(rootURL: root))
        await coordinator.deleteCameraRecording(take)
        XCTAssertNil(coordinator.alert)
        XCTAssertEqual(coordinator.pendingCameraRecordings.map(\.id), [other.id])
        XCTAssertTrue(coordinator.deletingCameraRecordings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: recordings.mediaURL(for: other)), Data([2]))
    }

    func testDeletionDoesNotRemoveOriginalsWhenProjectReferencesCannotBeRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraDeleteFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = CameraRecordingStore(root: root)
        let take = try recordings.prepare(grade: .neutral)
        try Data([1]).write(to: recordings.mediaURL(for: take))
        try Data("invalid library".utf8).write(to: root.appendingPathComponent("projects.json"))
        let coordinator = AppCoordinator(projectStore: ProjectStore(rootURL: root), cameraRecordingStore: recordings,
            imageProjectStore: ImageProjectStore(rootURL: root))
        await coordinator.deleteCameraRecording(take)
        XCTAssertNotNil(coordinator.alert)
        XCTAssertEqual(try recordings.pending().map(\.id), [take.id])
        XCTAssertEqual(try Data(contentsOf: recordings.mediaURL(for: take)), Data([1]))
    }

    func testRecordedOriginalOpensWithEditableLookAndRetryKeepsExistingEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraHandoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = CameraRecordingStore(root: root)
        let projects = ProjectStore(rootURL: root)
        var grade = GradeSettings.neutral
        grade.saturation = -24
        grade.vibrance = 35
        grade.advanced = AdvancedGrade()
        grade.advanced?.lut = LUTAsset.bundledCreativeLooks.first?.id
        grade.advanced?.lutIntensity = 65
        let recording = try recordings.prepare(grade: grade)
        let sample = try XCTUnwrap(Bundle.main.url(forResource: "onboarding-1-before", withExtension: "mp4"))
        let original = try Data(contentsOf: sample, options: .mappedIfSafe)
        try original.write(to: recordings.mediaURL(for: recording))
        let coordinator = AppCoordinator(projectStore: projects, cameraRecordingStore: recordings)
        coordinator.openCameraRecording(recording)
        try await waitForHandoff(coordinator)
        XCTAssertEqual(coordinator.screen, .editor, coordinator.alert?.message ?? "Editor did not open")
        let project = try XCTUnwrap(coordinator.activeProject)
        XCTAssertEqual(project.id, recording.id)
        XCTAssertEqual(project.sourceURL, recordings.mediaURL(for: recording))
        XCTAssertEqual(project.timeline.firstVideoClip?.gradeSettings, grade)
        XCTAssertEqual(try Data(contentsOf: project.sourceURL, options: .mappedIfSafe), original)
        XCTAssertTrue(try recordings.pending().isEmpty)
        var edited = project
        edited.displayName = "Edited take"
        try await projects.save(edited)
        coordinator.openCameraRecording(recording)
        try await waitForHandoff(coordinator)
        XCTAssertEqual(coordinator.activeProject?.displayName, "Edited take")
        let saved = try await projects.loadProjects()
        XCTAssertEqual(saved.count, 1)
        coordinator.showHome()
    }

    func testUnreadableTakeKeepsItsBytesAndRecoveryReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = CameraRecordingStore(root: root)
        let record = try recordings.prepare(grade: .neutral)
        let bytes = Data("partial movie".utf8)
        try bytes.write(to: recordings.mediaURL(for: record))
        let coordinator = AppCoordinator(projectStore: ProjectStore(rootURL: root), cameraRecordingStore: recordings)
        coordinator.openCameraRecording(record)
        try await waitForHandoff(coordinator)
        XCTAssertEqual(coordinator.screen, .home)
        XCTAssertNotNil(coordinator.alert)
        XCTAssertEqual(coordinator.pendingCameraRecordings.map(\.id), [record.id])
        XCTAssertEqual(try Data(contentsOf: recordings.mediaURL(for: record)), bytes)
    }

    func testLogReceiptCannotSilentlyOpenAnSDRRecordingAsLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraColor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = CameraRecordingStore(root: root)
        let record = try recordings.prepare(grade: .neutral, profile: .appleLog)
        let sample = try XCTUnwrap(Bundle.main.url(forResource: "onboarding-1-before", withExtension: "mp4"))
        try FileManager.default.copyItem(at: sample, to: recordings.mediaURL(for: record))
        let coordinator = AppCoordinator(projectStore: ProjectStore(rootURL: root), cameraRecordingStore: recordings)
        coordinator.openCameraRecording(record)
        try await waitForHandoff(coordinator)
        XCTAssertEqual(coordinator.screen, .home)
        XCTAssertTrue(coordinator.alert?.message.contains("color tags") == true)
        XCTAssertEqual(try recordings.pending().map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordings.mediaURL(for: record).path))
    }

    private func waitForHandoff(_ coordinator: AppCoordinator) async throws {
        let deadline = Date().addingTimeInterval(20)
        while coordinator.screen == .analyzing && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(coordinator.screen, .analyzing, "Capture handoff timed out")
    }
}
