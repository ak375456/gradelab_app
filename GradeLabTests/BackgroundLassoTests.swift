import CoreGraphics
import XCTest
@testable import GradeLab

final class BackgroundLassoTests: XCTestCase {

    // MARK: - Authoring

    func testAuthoringThinsDuplicatePointsAndDropsADoubledClosingVertex() {
        var raw = (0..<200).map { index -> MaskPoint in
            let angle = Double(index) * 2 * .pi / 200
            return MaskPoint(x: 0.5 + cos(angle) * 0.3, y: 0.5 + sin(angle) * 0.3)
        }
        // A finger resting at the end, then landing back on the start.
        raw += Array(repeating: raw[199], count: 30)
        raw.append(raw[0])

        let authored = BackgroundLassoSelection.authored(raw)

        XCTAssertGreaterThan(authored.count, 20)
        XCTAssertLessThanOrEqual(authored.count, BackgroundLassoSelection.maximumPoints)
        let first = authored[0], last = authored[authored.count - 1]
        XCTAssertGreaterThan(hypot(first.x - last.x, first.y - last.y), 0.0025)
    }

    func testAuthoringRejectsATapThatNeverBecameAnOutline() {
        let authored = BackgroundLassoSelection.authored([MaskPoint(x: 0.5, y: 0.5)])
        XCTAssertLessThan(authored.count, 3)
    }

    func testAuthoringNeverExceedsTheStoredPointLimit() {
        let raw = (0..<4_000).map { index -> MaskPoint in
            let angle = Double(index) * 2 * .pi / 4_000
            return MaskPoint(x: 0.5 + cos(angle) * 0.45, y: 0.5 + sin(angle) * 0.45)
        }
        XCTAssertLessThanOrEqual(BackgroundLassoSelection.authored(raw).count,
                                 BackgroundLassoSelection.maximumPoints)
    }

    // MARK: - Rasterizing

    func testTheOutlineKeepsWhatItEnclosesAndRemovesEverythingElse() throws {
        let selection = BackgroundLassoSelection(points: square(from: 0.25, to: 0.75))

        let plane = try XCTUnwrap(BackgroundLassoMatte.plane(
            for: selection, atLocal: nil, aspectWidth: 64, aspectHeight: 64))

        XCTAssertEqual(plane.width, 64)
        XCTAssertEqual(plane.value(x: 32, y: 32), 255)
        XCTAssertEqual(plane.value(x: 4, y: 4), 0)
        XCTAssertEqual(plane.value(x: 60, y: 60), 0)
        XCTAssertEqual(plane.coverage, 0.25, accuracy: 0.02)
    }

    /// Authored points are top-left while Core Graphics draws bottom-left, so
    /// an outline over the top of the frame must land in the plane's first
    /// rows — the same convention the Metal matte sampler reads.
    func testAnOutlineOverTheTopOfTheFrameFillsTheTopOfTheMatte() throws {
        let selection = BackgroundLassoSelection(points: [
            MaskPoint(x: 0.1, y: 0.0), MaskPoint(x: 0.9, y: 0.0),
            MaskPoint(x: 0.9, y: 0.25), MaskPoint(x: 0.1, y: 0.25)
        ])

        let plane = try XCTUnwrap(BackgroundLassoMatte.plane(
            for: selection, atLocal: nil, aspectWidth: 64, aspectHeight: 64))

        XCTAssertEqual(plane.value(x: 32, y: 4), 255)
        XCTAssertEqual(plane.value(x: 32, y: 60), 0)
    }

    func testAnOutlineWithTooFewPointsProducesNoMatteAtAll() {
        let selection = BackgroundLassoSelection(points: [MaskPoint(x: 0.4, y: 0.4),
                                                          MaskPoint(x: 0.6, y: 0.6)])
        XCTAssertNil(BackgroundLassoMatte.plane(for: selection, atLocal: nil,
                                                aspectWidth: 64, aspectHeight: 64))
    }

    // MARK: - Tracked motion

    func testAnUntrackedOutlineStaysExactlyWhereItWasDrawn() throws {
        let selection = BackgroundLassoSelection(points: square(from: 0.25, to: 0.75))
        let outline = selection.outline(atLocal: try TimelineTime.seconds(5))
        XCTAssertEqual(outline[0].x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(outline[0].y, 0.25, accuracy: 0.0001)
    }

    func testTrackedMotionInterpolatesBetweenSamples() throws {
        var selection = BackgroundLassoSelection(points: square(from: 0.2, to: 0.4))
        selection.motion = [
            .init(time: .zero),
            .init(time: try TimelineTime.seconds(1), offsetX: 0.2, offsetY: -0.1)
        ]

        let outline = selection.outline(atLocal: try TimelineTime.seconds(0.5))

        XCTAssertEqual(outline[0].x, 0.3, accuracy: 0.001)
        XCTAssertEqual(outline[0].y, 0.15, accuracy: 0.001)
    }

    func testTrackedScalePivotsOnTheOutlineItsOwnCentre() throws {
        var selection = BackgroundLassoSelection(points: square(from: 0.4, to: 0.6))
        selection.motion = [.init(time: .zero), .init(time: try TimelineTime.seconds(1),
                                                      scaleX: 2, scaleY: 2)]

        let outline = selection.outline(atLocal: try TimelineTime.seconds(1))

        // Centre 0.5 stays put; the half-extent doubles from 0.1 to 0.2.
        XCTAssertEqual(outline[0].x, 0.3, accuracy: 0.001)
        XCTAssertEqual(outline[2].x, 0.7, accuracy: 0.001)
    }

    /// Past the tracked span the last measurement is held rather than
    /// extrapolated, so a partial track parks the cutout somewhere the user
    /// can see instead of sliding it off the subject.
    func testMotionIsHeldRatherThanExtrapolatedOutsideTheTrackedSpan() throws {
        var selection = BackgroundLassoSelection(points: square(from: 0.2, to: 0.4))
        selection.motion = [
            .init(time: .zero),
            .init(time: try TimelineTime.seconds(1), offsetX: 0.2)
        ]

        let late = selection.outline(atLocal: try TimelineTime.seconds(90))
        let early = selection.outline(atLocal: try TimelineTime.seconds(-90))

        XCTAssertEqual(late[0].x, 0.4, accuracy: 0.001)
        XCTAssertEqual(early[0].x, 0.2, accuracy: 0.001)
    }

    // MARK: - Smoothing

    func testSmoothingLeavesTheAnchorAndBothEndsExactlyWhereTheyWere() throws {
        let anchor = try TimelineTime.seconds(2)
        let samples = try (0...10).map { index in
            BackgroundLassoMotionSample(time: try TimelineTime.seconds(Double(index)),
                                        offsetX: index.isMultiple(of: 2) ? 0.1 : 0.0)
        }

        let smoothed = BackgroundLassoMotionSample.smoothed(samples, anchor: anchor)

        XCTAssertEqual(smoothed[2].offsetX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(smoothed[0].offsetX, samples[0].offsetX, accuracy: 0.0001)
        XCTAssertEqual(smoothed[10].offsetX, samples[10].offsetX, accuracy: 0.0001)
        XCTAssertEqual(smoothed.count, samples.count)
    }

    /// Vision's box jitters by a pixel or two on a subject that is not moving,
    /// and that reads as the cutout edge vibrating.
    func testSmoothingFlattensSingleFrameJitterWithoutLaggingRealMotion() throws {
        let jittery = try (0...10).map { index in
            BackgroundLassoMotionSample(time: try TimelineTime.seconds(Double(index)),
                                        offsetX: index.isMultiple(of: 2) ? 0.02 : -0.02)
        }
        let travelling = try (0...10).map { index in
            BackgroundLassoMotionSample(time: try TimelineTime.seconds(Double(index)),
                                        offsetX: Double(index) * 0.05)
        }

        let calmed = BackgroundLassoMotionSample.smoothed(jittery, anchor: nil)
        let kept = BackgroundLassoMotionSample.smoothed(travelling, anchor: nil)

        // The alternation cancels exactly: 0.25/0.5/0.25 over +x, -x, +x is 0.
        XCTAssertEqual(calmed[5].offsetX, 0, accuracy: 0.0001)
        // A steady slide passes through a three-tap average untouched.
        XCTAssertEqual(kept[5].offsetX, 0.25, accuracy: 0.0001)
    }

    // MARK: - Simplification

    func testASteadySlideCollapsesToItsEndpoints() throws {
        let samples = try (0...120).map { index in
            BackgroundLassoMotionSample(time: try TimelineTime.seconds(Double(index) / 30),
                                        offsetX: Double(index) * 0.002)
        }

        let reduced = BackgroundLassoMotionSample.simplified(samples, anchor: .zero)

        XCTAssertEqual(reduced.count, 2)
        XCTAssertEqual(reduced.last?.offsetX ?? 0, 0.24, accuracy: 0.0001)
    }

    func testASharpChangeOfDirectionSurvivesSimplification() throws {
        let samples = try (0...120).map { index -> BackgroundLassoMotionSample in
            let offset = index <= 60 ? Double(index) * 0.004 : Double(120 - index) * 0.004
            return BackgroundLassoMotionSample(time: try TimelineTime.seconds(Double(index) / 30),
                                               offsetX: offset)
        }

        let reduced = BackgroundLassoMotionSample.simplified(samples, anchor: .zero)

        XCTAssertGreaterThanOrEqual(reduced.count, 3)
        let peak = try XCTUnwrap(reduced.max { $0.offsetX < $1.offsetX })
        XCTAssertEqual(peak.offsetX, 0.24, accuracy: 0.0001)
    }

    func testSimplificationNeverKeepsMoreSamplesThanADocumentAllows() throws {
        // Deliberately erratic: every frame reverses, so nothing interpolates
        // away and the hard cap is the only thing that can bound the result.
        let samples = try (0..<(BackgroundLassoMotionSample.limit + 500)).map { index in
            BackgroundLassoMotionSample(time: try TimelineTime.seconds(Double(index) / 60),
                                        offsetX: index.isMultiple(of: 2) ? 0.3 : -0.3)
        }

        let reduced = BackgroundLassoMotionSample.simplified(samples, anchor: .zero)

        XCTAssertLessThanOrEqual(reduced.count, BackgroundLassoMotionSample.limit)
        XCTAssertEqual(reduced.first?.time, samples.first?.time)
        XCTAssertEqual(reduced.last?.time, samples.last?.time)
    }

    /// A long, smooth track is thinned before the search rather than by it, so
    /// a ten-minute 60fps clip does not spend longer being tidied than it
    /// spent being measured.
    func testAVeryLongSmoothTrackStillCollapsesToItsEndpoints() throws {
        let samples = try (0..<20_000).map { index in
            BackgroundLassoMotionSample(time: try TimelineTime.seconds(Double(index) / 60),
                                        offsetX: Double(index) * 0.00001)
        }

        let reduced = BackgroundLassoMotionSample.simplified(samples, anchor: .zero)

        XCTAssertEqual(reduced.count, 2)
        XCTAssertEqual(reduced.last?.offsetX ?? 0, 0.19999, accuracy: 0.001)
    }

    // MARK: - Settings

    func testAdoptingAnOutlineSwitchesModeWithoutStartingAnAnalysis() {
        var settings = BackgroundRemovalSettings.automatic
        let before = settings.analysisID

        settings.adopt(.init(points: square(from: 0.3, to: 0.6)))

        XCTAssertEqual(settings.mode, .lasso)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.lasso?.points.count, 4)
        XCTAssertEqual(settings.analysisID, before)
    }

    func testAnOutlineSurvivesAnEncodeAndDecodeRoundTrip() throws {
        var settings = BackgroundRemovalSettings.automatic
        var lasso = BackgroundLassoSelection(points: square(from: 0.2, to: 0.7))
        lasso.motion = [.init(time: .zero), .init(time: try TimelineTime.seconds(2), offsetX: 0.1)]
        settings.adopt(lasso)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BackgroundRemovalSettings.self, from: data)

        XCTAssertEqual(decoded.mode, .lasso)
        XCTAssertEqual(decoded.lasso?.points.count, 4)
        XCTAssertEqual(decoded.lasso?.motion.count, 2)
        XCTAssertTrue(decoded.lasso?.isTracked ?? false)
    }

    func testClampingBoundsOutlinePointsAndTrackedScale() {
        var lasso = BackgroundLassoSelection(points: [
            MaskPoint(x: 40, y: -12), MaskPoint(x: 0.5, y: .nan),
            MaskPoint(x: 0.6, y: 0.6), MaskPoint(x: 0.2, y: 0.8)
        ])
        lasso.motion = [.init(time: .zero, offsetX: 900, scaleX: 0, scaleY: .infinity)]

        let clamped = lasso.clamped

        XCTAssertTrue(clamped.points.allSatisfy { $0.x >= -0.5 && $0.x <= 1.5 })
        XCTAssertTrue(clamped.points.allSatisfy { $0.y >= -0.5 && $0.y <= 1.5 })
        XCTAssertEqual(clamped.motion[0].offsetX, 2, accuracy: 0.0001)
        XCTAssertGreaterThan(clamped.motion[0].scaleX, 0)
        XCTAssertTrue(clamped.motion[0].scaleY.isFinite)
    }

    // MARK: - Helpers

    private func square(from low: Double, to high: Double) -> [MaskPoint] {
        [MaskPoint(x: low, y: low), MaskPoint(x: high, y: low),
         MaskPoint(x: high, y: high), MaskPoint(x: low, y: high)]
    }
}
