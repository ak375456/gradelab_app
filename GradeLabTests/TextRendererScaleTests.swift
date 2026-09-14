import CoreGraphics
import XCTest
@testable import GradeLab

final class TextRendererScaleTests: XCTestCase {
    func testExportKeepsEditorTextGeometryProportional() throws {
        let authored = CGSize(width: 800, height: 450)
        let export = CGSize(width: 1_600, height: 900)
        var clip = TextClip(placement: .init(
            id: UUID(), trackID: UUID(), timelineStart: .zero,
            duration: try TimelineTime.seconds(2)
        ))
        clip.text = "Preview matches export"
        clip.style.fontSize = 120
        clip.strokeWidth = 6
        clip.decoration = .init(padding: 18)
        clip.backgroundOpacity = 0.6
        clip.transform.positionX = 0.37
        clip.transform.positionY = 0.62

        let editorImage = try XCTUnwrap(TextRenderer.image(clip, canvas: authored))
        let exportImage = try XCTUnwrap(TextRenderer.image(
            clip, canvas: export, authoredCanvas: authored
        ))

        XCTAssertEqual(
            exportImage.extent.width / export.width,
            editorImage.extent.width / authored.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            exportImage.extent.height / export.height,
            editorImage.extent.height / authored.height,
            accuracy: 0.001
        )
        XCTAssertEqual(
            exportImage.extent.midX / export.width,
            editorImage.extent.midX / authored.width,
            accuracy: 0.001
        )
        XCTAssertEqual(
            exportImage.extent.midY / export.height,
            editorImage.extent.midY / authored.height,
            accuracy: 0.001
        )
    }

    func testFourKProjectsUseTheSameBaseCanvasTheEditorDisplays() {
        XCTAssertEqual(
            SequenceComposition.previewRenderSize(width: 3_840, height: 2_160),
            CGSize(width: 1_920, height: 1_080)
        )
    }
}
