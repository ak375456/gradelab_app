import XCTest
@testable import GradeLab

final class TimelineRulerScaleTests: XCTestCase {

    func testLabelledIntervalAlwaysLeavesRoomForItsLabel() {
        for zoom in [4.0, 12, 48, 120, 400, 1200, 2400] {
            let scale = TimelineRulerScale(pixelsPerSecond: zoom)
            XCTAssertGreaterThanOrEqual(scale.major * zoom, TimelineRulerScale.targetLabelSpacing,
                                        "labels would collide at \(zoom) px/s")
        }
    }

    func testTicksGetDenserAsTheTimelineZoomsIn() {
        let zooms = [4.0, 12, 48, 120, 400, 1200, 2400]
        let majors = zooms.map { TimelineRulerScale(pixelsPerSecond: $0).major }
        XCTAssertEqual(majors, majors.sorted(by: >), "a closer zoom must never label a coarser interval")
        XCTAssertGreaterThan(majors[0], majors[majors.count - 1])
    }

    func testMinorTicksStayLegibleRatherThanBecomingASmear() {
        for zoom in stride(from: 4.0, through: 2400, by: 7) {
            let scale = TimelineRulerScale(pixelsPerSecond: zoom)
            guard scale.minor != scale.major else { continue }
            XCTAssertGreaterThanOrEqual(scale.minor * zoom, TimelineRulerScale.minimumMinorSpacing,
                                        "minor ticks too close at \(zoom) px/s")
            // A subdivision has to divide its parent, or the ladder reads wrong.
            let pieces = scale.major / scale.minor
            XCTAssertEqual(pieces, pieces.rounded(), accuracy: 1e-9)
        }
    }

    func testFrameTicksOnlyAppearOnceAFrameIsWideEnoughToAimAt() {
        let frameDuration = 1.0 / 30
        XCTAssertNil(TimelineRulerScale(pixelsPerSecond: 48, frameDuration: frameDuration).frame,
                     "a frame is 1.6pt wide at 48 px/s and must not be drawn")
        let zoomedIn = TimelineRulerScale(pixelsPerSecond: 600, frameDuration: frameDuration)
        XCTAssertEqual(try XCTUnwrap(zoomedIn.frame), frameDuration, accuracy: 1e-9)
    }

    func testACoarserLevelNeverHandsTheSamePositionToAFinerOne() {
        let scale = TimelineRulerScale(pixelsPerSecond: 48, frameDuration: 1.0 / 30)
        var majors: [Double] = []
        var minors: [Double] = []
        scale.forEachTick(from: 0, to: 20) { time, kind in
            switch kind {
            case .major: majors.append(time)
            case .minor: minors.append(time)
            case .frame: XCTFail("frames are not resolvable at this zoom")
            }
        }
        XCTAssertFalse(majors.isEmpty)
        XCTAssertFalse(minors.isEmpty)
        for minor in minors {
            XCTAssertFalse(majors.contains { abs($0 - minor) < 1e-6 },
                           "\(minor) was drawn as both a major and a minor tick")
        }
        // Majors land on multiples of the interval and cover the whole span.
        for major in majors {
            let steps = major / scale.major
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-9)
        }
        XCTAssertEqual(majors.first, 0)
        XCTAssertGreaterThanOrEqual(majors.last ?? 0, 20 - scale.major)
    }

    func testLabelsCarryThePrecisionTheZoomResolves() {
        XCTAssertEqual(TimelineRulerScale(pixelsPerSecond: 48).label(for: 62), "01:02")
        XCTAssertEqual(TimelineRulerScale(pixelsPerSecond: 48).label(for: 0), "00:00")
        XCTAssertEqual(TimelineRulerScale(pixelsPerSecond: 4).label(for: 3661), "1:01:01")
        // Sub-second intervals need decimals or consecutive labels would repeat.
        let fine = TimelineRulerScale(pixelsPerSecond: 800)
        XCTAssertLessThan(fine.major, 1)
        XCTAssertNotEqual(fine.label(for: 2.0), fine.label(for: 2.0 + fine.major))
    }

    func testTickWalkTerminatesOnADegenerateRange() {
        let scale = TimelineRulerScale(pixelsPerSecond: 48)
        var count = 0
        scale.forEachTick(from: 5, to: 5) { _, _ in count += 1 }
        XCTAssertLessThanOrEqual(count, 1)
        scale.forEachTick(from: 10, to: 0) { _, _ in XCTFail("a reversed range emits nothing") }
    }
}

final class TimelineZoomScaleTests: XCTestCase {
    func testSliderPositionRoundTripsThroughTheWholeRange() {
        for zoom in [4.0, 10, 48, 200, 900, 2400] {
            let normalized = TimelineZoomScale.normalized(zoom)
            XCTAssertTrue((0...1).contains(normalized))
            XCTAssertEqual(TimelineZoomScale.pixelsPerSecond(normalized), zoom, accuracy: 0.0001)
        }
        XCTAssertEqual(TimelineZoomScale.normalized(TimelineViewport.zoomRange.lowerBound), 0, accuracy: 1e-9)
        XCTAssertEqual(TimelineZoomScale.normalized(TimelineViewport.zoomRange.upperBound), 1, accuracy: 1e-9)
    }

    func testEachSliderHalfCoversTheSameProportionOfZoom() {
        // The point of the log mapping: equal travel is equal ratio, so the
        // low end of the range does not collapse into a few pixels of thumb.
        let low = TimelineZoomScale.pixelsPerSecond(0.25) / TimelineZoomScale.pixelsPerSecond(0)
        let high = TimelineZoomScale.pixelsPerSecond(1) / TimelineZoomScale.pixelsPerSecond(0.75)
        XCTAssertEqual(low, high, accuracy: 0.0001)
    }

    func testSteppingClampsToTheSupportedRange() {
        XCTAssertEqual(TimelineZoomScale.stepped(TimelineViewport.zoomRange.lowerBound, by: 0.1),
                       TimelineViewport.zoomRange.lowerBound)
        XCTAssertEqual(TimelineZoomScale.stepped(TimelineViewport.zoomRange.upperBound, by: 10),
                       TimelineViewport.zoomRange.upperBound)
        XCTAssertEqual(TimelineZoomScale.stepped(48, by: 1.8), 86.4, accuracy: 1e-9)
    }
}
