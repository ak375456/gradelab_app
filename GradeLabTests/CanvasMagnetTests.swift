import XCTest
@testable import GradeLab

/// The snapping a drag gets on the canvas.
///
/// A multiple selection used to have none of this: the group drag applied the
/// raw translation, so four titles moved together but lined up with nothing.
/// The magnet now measures the selection's outer bounds exactly as it measures
/// a lone layer's frame.
final class CanvasMagnetTests: XCTestCase {

    private let canvas = CGSize(width: 1920, height: 1080)
    /// The preview scale a drag reports at. Tolerance is 12 screen points, so at
    /// 1:1 that is 12 canvas units.
    private let scale: CGFloat = 1

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testABlockLandsOnANeighboursEdgeWhenItComesClose() {
        let neighbour = rect(700, 100, 300, 100)
        // The block's left edge is 5 units to the left of the neighbour's.
        let moving = rect(695, 400, 200, 80)

        let pull = CanvasMagnet.pull(bounds: moving, canvas: canvas, screenScale: scale, others: [neighbour])

        XCTAssertEqual(pull.dx, 5/1920, accuracy: 1e-9, "it should be pulled the last five units")
        XCTAssertEqual(try XCTUnwrap(pull.xGuide), 700/1920, accuracy: 1e-9)
        XCTAssertEqual(pull.dy, 0, "nothing is near on the other axis")
        XCTAssertNil(pull.yGuide)
    }

    /// Centres line up with centres, not only edges with edges.
    func testCentresLineUpWithCentres() {
        let neighbour = rect(800, 100, 320, 100)   // centre 960
        let moving = rect(854, 600, 200, 80)       // centre 954
        let pull = CanvasMagnet.pull(bounds: moving, canvas: canvas, screenScale: scale, others: [neighbour])
        XCTAssertEqual(pull.dx, 6/1920, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pull.xGuide), 960/1920, accuracy: 1e-9)
    }

    func testNothingWithinReachLeavesTheDragAlone() {
        let pull = CanvasMagnet.pull(bounds: rect(100, 100, 200, 80), canvas: canvas,
                                     screenScale: scale, others: [rect(1500, 900, 200, 80)])
        XCTAssertEqual(pull.dx, 0)
        XCTAssertEqual(pull.dy, 0)
        XCTAssertNil(pull.xGuide)
        XCTAssertNil(pull.yGuide)
    }

    /// The nearest anchor wins when several are in range, so the block does not
    /// jump to whichever layer happens to be first in the list.
    func testTheNearestAnchorWins() {
        let far = rect(690, 0, 100, 100)     // left edge 690, 10 away
        let near = rect(697, 0, 100, 100)    // left edge 697, 3 away
        let moving = rect(700, 500, 200, 80)
        let pull = CanvasMagnet.pull(bounds: moving, canvas: canvas, screenScale: scale, others: [far, near])
        XCTAssertEqual(try XCTUnwrap(pull.xGuide), 697/1920, accuracy: 1e-9)
    }

    /// A magnet tolerance of 12 SCREEN points is more canvas units the smaller
    /// the preview is drawn, so the pull feels the same size under the finger.
    func testToleranceIsMeasuredOnScreenNotOnTheCanvas() {
        let neighbour = rect(700, 0, 100, 100)
        let moving = rect(680, 500, 200, 80)    // 20 canvas units away
        XCTAssertNil(CanvasMagnet.pull(bounds: moving, canvas: canvas, screenScale: 1, others: [neighbour]).xGuide,
                     "20 units is out of reach at 1:1")
        XCTAssertNotNil(CanvasMagnet.pull(bounds: moving, canvas: canvas, screenScale: 0.5, others: [neighbour]).xGuide,
                        "the same 20 units is only 10 screen points at half scale")
    }

    // MARK: - Canvas stops

    /// With nothing else near, the block's CENTRE snaps to the canvas thirds and
    /// middle — a block has no single anchor to snap the way one layer does.
    func testTheBlockCentreSnapsToTheCanvasStops() {
        let stops = CanvasMagnet.positionStops
        let tolerance = CanvasMagnet.positionTolerance
        XCTAssertEqual(CanvasMagnet.snap(0.505, to: stops, tolerance: tolerance).stop, 0.5)
        XCTAssertEqual(CanvasMagnet.snap(0.33, to: stops, tolerance: tolerance).value, 1.0/3, accuracy: 1e-9)
        XCTAssertNil(CanvasMagnet.snap(0.44, to: stops, tolerance: tolerance).stop,
                     "between two stops it stays where it was put")
        XCTAssertEqual(CanvasMagnet.snap(0.44, to: stops, tolerance: tolerance).value, 0.44)
    }

    /// Rotation reuses the same snap with its own stops, so it must not have
    /// been narrowed to positions.
    func testTheSameSnapServesRotation() {
        XCTAssertEqual(CanvasMagnet.snap(46.5, to: [0, 45, 90], tolerance: 4).stop, 45)
        XCTAssertNil(CanvasMagnet.snap(60, to: [0, 45, 90], tolerance: 4).stop)
    }

    /// A zero canvas would divide by zero on the way back to normalized units.
    func testAnEmptyCanvasIsRefusedRatherThanDividedBy() {
        let pull = CanvasMagnet.pull(bounds: rect(0, 0, 10, 10), canvas: .zero,
                                     screenScale: 1, others: [rect(0, 0, 10, 10)])
        XCTAssertEqual(pull.dx, 0)
        XCTAssertNil(pull.xGuide)
    }
}
