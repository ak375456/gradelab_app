import XCTest
@testable import GradeLab

final class CanvasExportSettingsTests: XCTestCase {
    func testOlderCanvasDocumentsDefaultToFollowingCanvas() throws {
        let oldDocument = Data(#"{"width":1920,"height":1080,"frameDuration":{"value":1,"timescale":30},"background":{"red":0,"green":0,"blue":0,"alpha":1}}"#.utf8)
        let canvas = try JSONDecoder().decode(ProjectCanvas.self, from: oldDocument)
        XCTAssertTrue(canvas.usesCanvasExportSettings)
    }

    func testExportPreferenceAndFrameRateSurviveProjectSave() throws {
        var canvas = ProjectCanvas(width: 1920, height: 1080,
                                   frameDuration: try TimelineTime(value: 1, timescale: 30))
        canvas.usesCanvasExportSettings = false
        let restored = try JSONDecoder().decode(ProjectCanvas.self, from: JSONEncoder().encode(canvas))
        XCTAssertFalse(restored.usesCanvasExportSettings)
        XCTAssertEqual(restored.frameRate, 30)
        XCTAssertEqual(restored.width, 1920)
        XCTAssertEqual(restored.height, 1080)
    }

    @MainActor
    func testFollowingCanvasResetsIndependentExportOverrides() throws {
        var project = GradeProject(
            sourceURL: URL(fileURLWithPath: "/tmp/4k60.mov"),
            displayName: "4K source",
            metadata: makeMetadata(nominalFrameRate: 60, minimumFrameDuration: 1.0 / 60))
        project.canvas.width = 1920
        project.canvas.height = 1080
        project.canvas.frameDuration = try TimelineTime(value: 1, timescale: 30)
        project.canvas.usesCanvasExportSettings = false

        let model = ExportViewModel(project: project, settings: .neutral)
        XCTAssertFalse(model.followsCanvas)
        model.configuration.resolution = .ultraHD
        model.configuration.frameRate = .fps60
        model.followsCanvas = true

        XCTAssertEqual(model.configuration.resolution, .original)
        XCTAssertEqual(model.configuration.frameRate, .original)
        let output = model.configuration.dimensions(width: project.canvas.width, height: project.canvas.height)
        XCTAssertEqual(output.width, 1920)
        XCTAssertEqual(output.height, 1080)
        XCTAssertEqual(model.project.canvas.frameRate, 30)
    }
}
