import XCTest
@testable import GradeLab

/// The rule these guard is a single frame wide and invisible in code review:
/// seeking to `duration` is one frame past the last sample, and the preview
/// goes black there. It only ever showed up by stepping to the end of a clip.
final class SeekBoundsTests: XCTestCase {
    private func bounds(duration: Double, fps: Double, from start: Double = 0) -> SeekBounds {
        SeekBounds(minimumTime: start, duration: duration, frameDuration: 1 / fps)
    }

    func testASeekToTheEndStopsOnTheLastFrameRatherThanPastIt() {
        let bounds = bounds(duration: 15.357, fps: 30)
        XCTAssertEqual(bounds.lastFrameTime, 15.357 - 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(bounds.clamped(bounds.duration), bounds.lastFrameTime, accuracy: 1e-9)
        XCTAssertEqual(bounds.clamped(9_999), bounds.lastFrameTime, accuracy: 1e-9)
        XCTAssertLessThan(bounds.lastFrameTime, bounds.duration)
    }

    func testTheLastFrameFollowsTheRealCadence() {
        for fps in [23.976, 24.0, 25, 29.97, 30, 50, 60, 120] {
            let bounds = bounds(duration: 10, fps: fps)
            XCTAssertEqual(bounds.lastFrameTime, 10 - 1 / fps, accuracy: 1e-9, "at \(fps) fps")
        }
    }

    /// A project that has been opened but whose sequence is not built yet has no
    /// cadence to read. It still must not seek onto the end.
    func testAnUnknownCadenceStillStopsShortOfTheEnd() {
        let bounds = SeekBounds(minimumTime: 0, duration: 10, frameDuration: 0)
        XCTAssertLessThan(bounds.lastFrameTime, bounds.duration)
        XCTAssertEqual(bounds.clamped(10), 10 - 1.0 / 30, accuracy: 1e-9)
    }

    func testSeekingBelowATrimmedStartIsHeldAtIt() {
        let bounds = bounds(duration: 8, fps: 30, from: 2)
        XCTAssertEqual(bounds.clamped(0), 2)
        XCTAssertEqual(bounds.clamped(-5), 2)
        XCTAssertEqual(bounds.clamped(7.9), 7.9, accuracy: 1e-9)
    }

    /// A non-finite seek is a fault upstream rather than a position, so it is
    /// answered with the start of the range in every case — including `+inf`,
    /// which is not treated as a request for the end.
    func testANonFiniteSeekFallsBackToTheStartOfTheRange() {
        let bounds = bounds(duration: 8, fps: 30, from: 2)
        for seconds in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(bounds.clamped(seconds), 2, "\(seconds)")
        }
    }

    /// Degenerate, but the clamp must not invert: a range under one frame long
    /// collapses onto its own start rather than producing a ceiling below the
    /// floor, which would make every seek land outside the range.
    func testARangeShorterThanOneFrameCollapsesOntoItsStart() {
        let bounds = SeekBounds(minimumTime: 2, duration: 2.01, frameDuration: 1.0 / 30)
        XCTAssertEqual(bounds.lastFrameTime, 2)
        XCTAssertGreaterThanOrEqual(bounds.lastFrameTime, bounds.minimumTime)
        XCTAssertEqual(bounds.clamped(2.005), 2)
    }

    /// Sitting on the last frame has to count as being at the end, or pressing
    /// play there would resume on that frame and appear to do nothing instead of
    /// starting the clip over.
    func testTheLastFrameAlwaysCountsAsBeingAtTheEnd() {
        for fps in [10.0, 23.976, 24, 25, 30, 50, 60, 120] {
            let bounds = bounds(duration: 12, fps: fps)
            XCTAssertGreaterThanOrEqual(bounds.lastFrameTime, bounds.endThreshold, "at \(fps) fps")
        }
    }
}
