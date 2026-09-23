import XCTest
import UIKit
@testable import GradeLab

final class FileMediaImportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testVideoFileCopyPreservesOriginalAndFilename() async throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("Camera original.mov")
        // This service copies bytes; the shared metadata reader validates the movie afterward.
        let bytes = Data(repeating: 0x57, count: 1_048_579)
        try bytes.write(to: original)
        let service = VideoImportService(projectStore: ProjectStore(rootURL: root.appendingPathComponent("Projects")))
        let imported = try await service.importVideo(from: MediaImportSource.file(original))
        XCTAssertEqual(imported.displayName, "Camera original")
        XCTAssertEqual(imported.originalFilename, "Camera original.mov")
        XCTAssertNotEqual(imported.url, original)
        XCTAssertEqual(try Data(contentsOf: imported.url), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(try Data(contentsOf: imported.url), bytes, "Projects must not depend on the external file")
    }

    func testVideoFileRejectsNonMovieWithoutChangingOriginal() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Notes.txt")
        try Data("Keep me".utf8).write(to: source)
        let service = VideoImportService(projectStore: ProjectStore(rootURL: root.appendingPathComponent("Projects")))
        do {
            _ = try await service.importVideo(from: source)
            XCTFail("Text must not be accepted as video")
        } catch {
            XCTAssertEqual(error as? VideoImportError, .unsupportedSelection)
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "Keep me")
    }

    @MainActor
    func testPhotoFileUsesOriginalNameAndDurableCopy() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Studio photo.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        try XCTUnwrap(image.pngData()).write(to: source)
        let imported = try await StillImageImportService.load(.file(source), store: ImageProjectStore(rootURL: root.appendingPathComponent("Projects")))
        XCTAssertEqual(imported.displayName, "Studio photo")
        XCTAssertEqual(imported.asset.metadata.fileName, "Studio photo.png")
        XCTAssertEqual(try Data(contentsOf: imported.asset.url), try Data(contentsOf: source))
        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(ImageDecoder.thumbnail(url: imported.asset.url))
    }
}
