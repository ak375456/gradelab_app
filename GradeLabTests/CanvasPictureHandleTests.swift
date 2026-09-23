import XCTest
@testable import GradeLab

/// The selection outline on a picture overlay has to sit exactly where the
/// compositor draws that picture. The two use different code — the handles go
/// through `VisualTransform.placement`, the render through
/// `LayerCompositor.transform` — so they are compared directly here. An outline
/// that is merely close looks like a bug the moment anything is rotated.
final class CanvasPictureHandleTests: XCTestCase {

    private func corners(_ rect: CGRect, _ t: CGAffineTransform) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { $0.applying(t) }
    }

    private func assertHandlesMatchTheRender(
        _ transform: VisualTransform, source: CGSize, canvas: CGSize,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var clip = VideoClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero,
                                              duration: (try? .seconds(3)) ?? .zero),
                             assetID: UUID(), sourceRange: .init(start: .zero, duration: (try? .seconds(3)) ?? .zero))
        clip.transform = transform

        let rendered = corners(CGRect(origin: .zero, size: source),
                               LayerCompositor.transform(transform, encoded: source,
                                                         preferred: .identity, canvas: canvas))
        let overlay = CanvasOverlay(clip, displaySize: source, canvas: canvas)
        let handles = corners(overlay.anchorBounds, overlay.placement(canvas: canvas))

        for (index, pair) in zip(rendered, handles).enumerated() {
            XCTAssertEqual(pair.0.x, pair.1.x, accuracy: 0.01,
                           "corner \(index) x", file: file, line: line)
            XCTAssertEqual(pair.0.y, pair.1.y, accuracy: 0.01,
                           "corner \(index) y", file: file, line: line)
        }
    }

    private let canvas = CGSize(width: 1920, height: 1080)

    func testAnUntouchedPictureIsOutlinedWhereItIsDrawn() {
        assertHandlesMatchTheRender(VisualTransform(), source: CGSize(width: 1920, height: 1080), canvas: canvas)
    }

    /// A portrait still in a landscape canvas: the fit is driven by height, and
    /// getting that backwards is the easiest way to draw the outline at the
    /// wrong size.
    func testAPortraitStillIsFittedByItsLongEdge() {
        assertHandlesMatchTheRender(VisualTransform(), source: CGSize(width: 3024, height: 4032), canvas: canvas)
    }

    func testAMovedAndScaledPictureStaysOutlined() {
        var t = VisualTransform()
        t.positionX = 0.28; t.positionY = 0.73; t.scale = 0.45
        assertHandlesMatchTheRender(t, source: CGSize(width: 4032, height: 3024), canvas: canvas)
    }

    func testRotationMatches() {
        var t = VisualTransform()
        t.rotationDegrees = 37; t.positionX = 0.4; t.scale = 0.8
        assertHandlesMatchTheRender(t, source: CGSize(width: 1080, height: 1080), canvas: canvas)
    }

    /// A non-centred anchor is what rotation and scale pivot around, so it has
    /// to mean the same thing to both paths.
    func testAnOffCentreAnchorMatches() {
        var t = VisualTransform()
        t.anchorX = 0.15; t.anchorY = 0.85; t.rotationDegrees = -22; t.scale = 1.4
        assertHandlesMatchTheRender(t, source: CGSize(width: 1920, height: 1080), canvas: canvas)
    }

    func testNonUniformScaleMatches() {
        var t = VisualTransform()
        t.widthScale = 1.7; t.heightScale = 0.6; t.positionY = 0.3
        assertHandlesMatchTheRender(t, source: CGSize(width: 1280, height: 720), canvas: canvas)
    }
}
