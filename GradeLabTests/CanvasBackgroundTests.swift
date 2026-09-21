import XCTest
@testable import GradeLab

/// The canvas background is part of the exported frame, and the canvas outline
/// is the only thing on screen that says where that frame ends.
final class CanvasBackgroundTests: XCTestCase {

    private func makeProject() -> GradeProject {
        GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
                     displayName: "Clip",
                     metadata: makeMetadata(duration: 10))
    }

    // MARK: - Reaching the renderer at all

    /// The passthrough path writes source frames as they are. A coloured canvas
    /// only exists once something composites onto it, so asking for one has to
    /// move the project off that path or the colour is silently dropped.
    func testAColouredCanvasTakesTheCompositingPath() {
        var project = makeProject()
        XCTAssertFalse(project.needsLayerCompositor, "baseline single clip should use the fast path")

        project.canvas.background = RGBAColor(red: 0.2, green: 0.4, blue: 0.9)
        XCTAssertTrue(project.needsLayerCompositor)
        XCTAssertNil(project.singleSourceClip, "a coloured canvas cannot be flattened to one source clip")
    }

    func testABlackCanvasStillTakesTheFastPath() {
        var project = makeProject()
        project.canvas.background = .black
        XCTAssertFalse(project.needsLayerCompositor)
    }

    // MARK: - Working-space conversion

    /// The HDR and Apple Log canvases carry linear BT.2020 light. Black and
    /// white are the two fixed points of that conversion and must survive it
    /// exactly, or every project gets a lifted or clipped background.
    func testBlackAndWhiteSurviveTheWideWorkingSpaceConversion() {
        let black = RGBAColor.black.linearBT2020ClearColor
        XCTAssertEqual(black.red, 0, accuracy: 1e-9)
        XCTAssertEqual(black.green, 0, accuracy: 1e-9)
        XCTAssertEqual(black.blue, 0, accuracy: 1e-9)
        XCTAssertEqual(black.alpha, 1, accuracy: 1e-9)

        let white = RGBAColor.white.linearBT2020ClearColor
        XCTAssertEqual(white.red, 1, accuracy: 1e-3)
        XCTAssertEqual(white.green, 1, accuracy: 1e-3)
        XCTAssertEqual(white.blue, 1, accuracy: 1e-3)
    }

    /// A mid grey is the case that exposes handing sRGB numbers to a linear
    /// surface: 0.5 encoded is 0.21 of the light, and skipping the transfer
    /// function would put the background more than twice as bright as picked.
    func testAMidGreyIsLinearisedRatherThanPassedThrough() {
        let grey = RGBAColor(red: 0.5, green: 0.5, blue: 0.5).linearBT2020ClearColor
        XCTAssertEqual(grey.red, 0.2140, accuracy: 0.001)
        XCTAssertEqual(grey.green, 0.2140, accuracy: 0.001)
        XCTAssertEqual(grey.blue, 0.2140, accuracy: 0.001)
    }

    /// A background is a fill, never a hole: whatever alpha was authored, the
    /// canvas is cleared opaque.
    func testTheClearColourIsAlwaysOpaque() {
        let translucent = RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.2)
        XCTAssertEqual(translucent.linearBT2020ClearColor.alpha, 1, accuracy: 1e-9)
    }

    // MARK: - The outline

    /// The outline is derived from the canvas aspect rather than read back from
    /// the renderer, so it has to land on exactly the rectangle
    /// `MetalVideoRenderer.displayedVideoRect` reports — the two disagreeing by
    /// even a point would draw the frame boundary in the wrong place.
    func testTheOutlineMatchesTheRendererAspectFit() {
        let view = CGSize(width: 1_000, height: 600)
        for (width, height) in [(1_080, 1_920), (1_920, 1_080), (1_080, 1_080), (600, 1_000)] {
            let canvas = ProjectCanvas(width: width, height: height, frameDuration: nil)
            let drawn = CanvasEdgeOverlay.fitted(canvas, in: view)
            let expected = rendererRect(canvas: CGSize(width: width, height: height), view: view)
            XCTAssertEqual(drawn.minX, expected.minX * view.width, accuracy: 0.001, "\(width)x\(height)")
            XCTAssertEqual(drawn.minY, expected.minY * view.height, accuracy: 0.001, "\(width)x\(height)")
            XCTAssertEqual(drawn.width, expected.width * view.width, accuracy: 0.001, "\(width)x\(height)")
            XCTAssertEqual(drawn.height, expected.height * view.height, accuracy: 0.001, "\(width)x\(height)")
        }
    }

    func testTheOutlineIsCentredAndKeepsTheCanvasAspect() {
        let view = CGSize(width: 800, height: 800)
        let rect = CanvasEdgeOverlay.fitted(
            ProjectCanvas(width: 1_080, height: 1_920, frameDuration: nil), in: view)
        XCTAssertEqual(rect.midX, 400, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 400, accuracy: 0.001)
        XCTAssertEqual(rect.height, 800, accuracy: 0.001, "the tall canvas should fill the height")
        XCTAssertEqual(rect.width / rect.height, 1_080.0 / 1_920.0, accuracy: 0.001)
    }

    /// A canvas with no size yet must not produce a NaN rectangle for SwiftUI
    /// to lay out.
    func testAnEmptyCanvasFallsBackToTheWholeView() {
        let view = CGSize(width: 320, height: 200)
        let rect = CanvasEdgeOverlay.fitted(ProjectCanvas(width: 0, height: 0, frameDuration: nil), in: view)
        XCTAssertEqual(rect, CGRect(origin: .zero, size: view))
    }

    /// `MetalVideoRenderer.displayedVideoRect`, written out as the oracle.
    private func rendererRect(canvas: CGSize, view: CGSize) -> CGRect {
        let viewAspect = view.width / view.height
        let videoAspect = canvas.width / canvas.height
        let width = videoAspect > viewAspect ? 1 : videoAspect / viewAspect
        let height = videoAspect > viewAspect ? viewAspect / videoAspect : 1
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}
