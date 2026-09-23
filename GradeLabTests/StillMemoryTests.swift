import XCTest
import CoreImage
@testable import GradeLab

/// Why a timeline of image overlays was being killed by the system.
///
/// `stillFrame` decoded every image at up to 4096 on the long edge whatever the
/// canvas was, so a 12-megapixel photograph became a 4032x3024 BGRA surface —
/// 48 MB — even while the preview composited at 1920. Nine overlays wanted nine
/// of those at once, against a cache that held four and emptied itself whenever
/// a fifth arrived.
final class StillDecodeSizeTests: XCTestCase {
    private func bytes(longEdge: Int, aspect: Double = 4.0/3.0) -> Int {
        longEdge * Int(Double(longEdge) / aspect) * 4
    }

    /// The measurement behind the fix, on the reported timeline: a 1920 preview
    /// and nine 12-megapixel overlays.
    func testNineOverlaysNoLongerCostHundredsOfMegabytes() {
        let canvas = CGSize(width: 1920, height: 1080)
        let before = bytes(longEdge: 4032) * 9
        let fitted = LayerCompositor.stillDecodeLongEdge(canvas: canvas, magnification: 1)
        let after = bytes(longEdge: fitted) * 9

        XCTAssertEqual(fitted, 1920, "a fitted image needs exactly the canvas")
        XCTAssertLessThan(after, before / 4, "\(before >> 20)MB -> \(after >> 20)MB")
        XCTAssertLessThan(after, LayerCompositor.stillCacheBudget,
                          "all nine have to fit at once, or the cache thrashes again")
    }

    /// A half-size overlay draws half the canvas, so half the pixels is all it
    /// can show.
    func testASmallOverlayDecodesSmall() {
        let canvas = CGSize(width: 1920, height: 1080)
        var transform = VisualTransform()
        transform.scale = 0.4
        let magnification = LayerCompositor.magnification(transform)
        XCTAssertGreaterThanOrEqual(magnification, 0.4, "never fewer pixels than are drawn")
        XCTAssertEqual(LayerCompositor.stillDecodeLongEdge(canvas: canvas, magnification: magnification), 960)
    }

    /// Blown up past the canvas it genuinely wants more, and gets it.
    func testAnEnlargedOverlayDecodesLarger() {
        let canvas = CGSize(width: 1920, height: 1080)
        var transform = VisualTransform()
        transform.scale = 1.5
        let magnification = LayerCompositor.magnification(transform)
        XCTAssertGreaterThanOrEqual(magnification, 1.5)
        XCTAssertEqual(LayerCompositor.stillDecodeLongEdge(canvas: canvas, magnification: magnification), 3840)
    }

    /// The ladder never asks for less than the frame draws, at any scale, and
    /// only ever answers a handful of distinct values — so an animated scale
    /// cannot re-decode on every frame.
    func testTheLadderAlwaysCoversTheScaleAndHasFewSteps() {
        var seen = Set<CGFloat>()
        for step in 1...400 {
            var transform = VisualTransform()
            transform.scale = Double(step) / 100
            let magnification = LayerCompositor.magnification(transform)
            XCTAssertGreaterThanOrEqual(magnification, min(4, CGFloat(transform.scale)) - 0.0001,
                                        "scale \(transform.scale) would be under-sampled")
            seen.insert(magnification)
        }
        XCTAssertLessThanOrEqual(seen.count, 6, "got \(seen.sorted())")
    }

    func testTheCeilingAndDegenerateCanvasesStillHold() {
        XCTAssertEqual(LayerCompositor.stillDecodeLongEdge(canvas: CGSize(width: 8000, height: 8000),
                                                           magnification: 4),
                       LayerCompositor.maximumStillLongEdge)
        XCTAssertEqual(LayerCompositor.stillDecodeLongEdge(canvas: .zero, magnification: 1),
                       LayerCompositor.maximumStillLongEdge)
        XCTAssertEqual(LayerCompositor.stillDecodeLongEdge(
                        canvas: CGSize(width: CGFloat.nan, height: CGFloat.nan), magnification: 1),
                       LayerCompositor.maximumStillLongEdge)
        XCTAssertEqual(LayerCompositor.magnification(VisualTransform()), 1)
        var broken = VisualTransform(); broken.scale = .nan
        XCTAssertEqual(LayerCompositor.magnification(broken), 1, "a broken transform must not decode at random")
    }
}

/// The promise that makes the change safe: decoding an image smaller does not
/// move it, resize it, or change its shape on the canvas.
///
/// Every caller builds its transform from the size of the buffer it got back
/// and then fits that to the canvas, so the only thing a different decode size
/// changes is sampling density.
final class StillDecodeIsInvisibleTests: XCTestCase {
    private func placed(_ encoded: CGSize, canvas: CGSize, transform t: VisualTransform) -> CGRect {
        CGRect(origin: .zero, size: encoded)
            .applying(LayerCompositor.transform(t, encoded: encoded, preferred: .identity, canvas: canvas))
    }

    func testTheSamePictureLandsIdenticallyAtEveryDecodeSize() {
        let canvas = CGSize(width: 1920, height: 1080)
        var transform = VisualTransform()
        transform.positionX = 0.3
        transform.positionY = 0.7
        transform.scale = 1.4
        transform.rotationDegrees = 12

        let full = placed(CGSize(width: 4032, height: 3024), canvas: canvas, transform: transform)
        for longEdge in [3840, 1920, 960, 480] {
            let reduced = placed(CGSize(width: CGFloat(longEdge), height: CGFloat(longEdge) * 3 / 4),
                                 canvas: canvas, transform: transform)
            XCTAssertEqual(reduced.minX, full.minX, accuracy: 0.001, "\(longEdge)")
            XCTAssertEqual(reduced.minY, full.minY, accuracy: 0.001, "\(longEdge)")
            XCTAssertEqual(reduced.width, full.width, accuracy: 0.001, "\(longEdge)")
            XCTAssertEqual(reduced.height, full.height, accuracy: 0.001, "\(longEdge)")
        }
    }

    /// Non-uniform scale and an off-centre anchor are where a size-dependent
    /// mistake would show up first.
    func testStretchedAndAnchoredLayersAreAlsoUnmoved() {
        let canvas = CGSize(width: 3840, height: 2160)
        var transform = VisualTransform()
        transform.anchorX = 0.2
        transform.anchorY = 0.9
        transform.widthScale = 1.7
        transform.heightScale = 0.6
        transform.scale = 0.8

        let full = placed(CGSize(width: 4032, height: 3024), canvas: canvas, transform: transform)
        let reduced = placed(CGSize(width: 1008, height: 756), canvas: canvas, transform: transform)
        XCTAssertEqual(reduced.minX, full.minX, accuracy: 0.001)
        XCTAssertEqual(reduced.minY, full.minY, accuracy: 0.001)
        XCTAssertEqual(reduced.width, full.width, accuracy: 0.001)
        XCTAssertEqual(reduced.height, full.height, accuracy: 0.001)
    }
}
