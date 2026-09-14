import XCTest
@testable import GradeLab

final class ProjectStoreTests: XCTestCase {
    func testProjectRoundTripReplacementAndOrdering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradeLabTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)
        let source = root.appendingPathComponent("Source.mov")

        let older = GradeProject(
            sourceURL: source,
            displayName: "Older",
            metadata: makeMetadata(),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        var newer = GradeProject(
            sourceURL: source,
            displayName: "Newer",
            metadata: makeMetadata(),
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40)
        )

        try await store.save(older)
        try await store.save(newer)
        var loaded = try await store.loadProjects()

        XCTAssertEqual(loaded.map(\.displayName), ["Newer", "Older"])

        newer.displayName = "Updated"
        var grade = GradeSettings.neutral
        grade.exposure = 0.75
        newer.timeline.setGrade(grade, for: newer.timeline.firstVideoClip!.id)
        newer.updatedAt = Date(timeIntervalSince1970: 50)
        try await store.save(newer)
        loaded = try await store.loadProjects()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.displayName, "Updated")
        XCTAssertEqual(loaded.first?.timeline.firstVideoClip?.gradeSettings.exposure, 0.75)
    }

    func testGeneratedAssetURLsStayWithinTheStoreRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradeLabTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootURL: root)

        let importURL = try await store.sourceImportURL(fileExtension: "mp4")
        let thumbnailURL = try await store.thumbnailURL(for: UUID())

        XCTAssertTrue(importURL.path.hasPrefix(root.path))
        XCTAssertEqual(importURL.pathExtension, "mp4")
        XCTAssertTrue(thumbnailURL.path.hasPrefix(root.path))
        XCTAssertEqual(thumbnailURL.pathExtension, "jpg")
    }
}
