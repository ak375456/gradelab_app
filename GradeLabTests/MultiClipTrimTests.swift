import XCTest
@testable import GradeLab

/// Trimming several selected clips at once.
///
/// The handle used to be reserved for a lone selection (`selectedIDs.count == 1`
/// in `operation(at:clip:)`), so selecting a title and the picture under it and
/// dragging an edge did nothing at all.
final class MultiClipTrimRuleTests: XCTestCase {
    private typealias Limits = (lower: Double, upper: Double)

    /// Travel is shared, so clips of different lengths keep their difference
    /// rather than being flattened onto one time.
    func testTheNarrowestClipDecidesHowFarTheGroupTravels() {
        let roomy: (edge: Double, limits: Limits) = (edge: 10, limits: (lower: 0, upper: 100))
        let tight: (edge: Double, limits: Limits) = (edge: 6, limits: (lower: 0, upper: 8))
        // On its own the anchor could give 20; the tight clip has only 2 left.
        XCTAssertEqual(TimelineCanvas.clampedTrimDelta(20, carried: [roomy, tight]), 2)
        XCTAssertEqual(TimelineCanvas.clampedTrimDelta(20, carried: [roomy]), 20)
        // Shrinking is bounded the same way, from the other side.
        let floored: (edge: Double, limits: Limits) = (edge: 6, limits: (lower: 5, upper: 100))
        XCTAssertEqual(TimelineCanvas.clampedTrimDelta(-20, carried: [roomy, floored]), -1)
    }

    func testAnUnconstrainedGroupTravelsTheFullDistance() {
        let a: (edge: Double, limits: Limits) = (edge: 4, limits: (lower: 0, upper: 50))
        let b: (edge: Double, limits: Limits) = (edge: 9, limits: (lower: 0, upper: 50))
        XCTAssertEqual(TimelineCanvas.clampedTrimDelta(3, carried: [a, b]), 3)
        XCTAssertEqual(TimelineCanvas.clampedTrimDelta(0, carried: [a, b]), 0)
    }

    /// An empty carry list is the single-clip trim, which must be left exactly
    /// as it was.
    func testNothingCarriedChangesNothing() {
        XCTAssertEqual(TimelineCanvas.clampedTrimDelta(7.5, carried: []), 7.5)
    }
}

/// The real model, driven the way the timeline drives it.
@MainActor
final class MultiClipTrimTests: XCTestCase {
    private func makeModel() throws -> EditorViewModel {
        let project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/multi-trim.mov"),
                                   displayName: "Trim", metadata: makeVideoMetadata(durationSeconds: 30))
        return try EditorViewModel(project: project)
    }

    /// Built through the model's own API rather than by reaching into the
    /// project, so the setup exercises the same path the editor does.
    @discardableResult
    private func addTitle(_ model: EditorViewModel, start: Double, duration: Double) throws -> UUID {
        model.addText()
        let id = try XCTUnwrap(model.selectedClipID)
        model.editTiming(id: id, operation: .move, seconds: start)
        model.editTiming(id: id, operation: .trimEnd, seconds: start + duration)
        let placement = try XCTUnwrap(model.project.timeline.item(id: id)).placement
        XCTAssertEqual(placement.timelineStart.seconds, start, accuracy: 0.05)
        XCTAssertEqual(placement.duration.seconds, duration, accuracy: 0.05)
        return id
    }

    /// The exact case from the report: a title and a video clip selected
    /// together, one handle dragged, both get longer.
    func testATitleAndAVideoClipGrowTogether() throws {
        let model = try makeModel()
        let video = try XCTUnwrap(model.project.timeline.firstVideoClip)
        // The imported clip arrives using all 30s of its source, so there is
        // nothing to extend into. Give it room first, the way a real edit has.
        model.editTiming(id: video.id, operation: .trimEnd, seconds: 10)
        let title = try addTitle(model, start: 0, duration: 4)

        model.trimClips([video.id, title], operation: .trimEnd, delta: 2)

        XCTAssertEqual(try XCTUnwrap(model.project.timeline.item(id: title)).placement.duration.seconds,
                       6, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(model.project.timeline.videoClip(id: video.id))
                        .placement.range.end.seconds, 12, accuracy: 0.05)
    }

    /// A clip already using all of its source cannot be extended, and it holds
    /// the rest of the selection back rather than being left behind — that is
    /// what `clampedTrimDelta` exists for, checked here end to end.
    func testAClipOutOfSourceHoldsTheWholeGroup() throws {
        let model = try makeModel()
        let video = try XCTUnwrap(model.project.timeline.firstVideoClip)
        let title = try addTitle(model, start: 0, duration: 4)

        let carried = [
            (edge: 30.0, limits: (lower: 0.1, upper: 30.0)),   // video: no source left
            (edge: 4.0, limits: (lower: 0.1, upper: 100.0)),   // title: free to grow
        ]
        XCTAssertEqual(TimelineCanvas.clampedTrimDelta(2, carried: carried), 0,
                       "the exhausted clip pins the group in place")

        // And with that delta the model leaves both exactly as they were.
        let before = model.project.timeline
        model.trimClips([video.id, title], operation: .trimEnd, delta: 0)
        XCTAssertEqual(model.project.timeline, before)
    }

    /// Different lengths stay different: the travel is shared, the durations
    /// are not equalised.
    func testClipsOfDifferentLengthsKeepTheirDifference() throws {
        let model = try makeModel()
        let short = try addTitle(model, start: 0, duration: 3)
        let long = try addTitle(model, start: 0, duration: 8)

        model.trimClips([short, long], operation: .trimEnd, delta: 1.5)

        let a = try XCTUnwrap(model.project.timeline.item(id: short)).placement.duration.seconds
        let b = try XCTUnwrap(model.project.timeline.item(id: long)).placement.duration.seconds
        XCTAssertEqual(a, 4.5, accuracy: 0.05)
        XCTAssertEqual(b, 9.5, accuracy: 0.05)
        XCTAssertEqual(b - a, 5, accuracy: 0.05, "the gap between them must survive the trim")
    }

    /// One undo step, not one per clip — otherwise undoing a multi-trim leaves
    /// the group half-resized.
    func testTheWholeGroupUndoesAsOneAction() throws {
        let model = try makeModel()
        let a = try addTitle(model, start: 0, duration: 3)
        let b = try addTitle(model, start: 0, duration: 3)
        let before = model.project.timeline

        model.trimClips([a, b], operation: .trimEnd, delta: 2)
        XCTAssertNotEqual(model.project.timeline, before)

        model.undo()
        XCTAssertEqual(model.project.timeline, before)
    }

    func testAZeroTravelIsNotAnEdit() throws {
        let model = try makeModel()
        let a = try addTitle(model, start: 0, duration: 3)
        let before = model.project

        model.trimClips([a], operation: .trimEnd, delta: 0)
        XCTAssertEqual(model.project, before)
        model.trimClips([a], operation: .move, delta: 2)
        XCTAssertEqual(model.project, before, "a move is not a trim and must be refused")
    }

    /// Head trims move the start, and a title's animation window rides along —
    /// the same guarantee the single-clip trim already gave.
    func testAHeadTrimMovesEveryStart() throws {
        let model = try makeModel()
        let a = try addTitle(model, start: 2, duration: 6)
        let b = try addTitle(model, start: 5, duration: 6)

        model.trimClips([a, b], operation: .trimStart, delta: 1)

        XCTAssertEqual(try XCTUnwrap(model.project.timeline.item(id: a)).placement.timelineStart.seconds,
                       3, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(model.project.timeline.item(id: b)).placement.timelineStart.seconds,
                       6, accuracy: 0.05)
    }
}

/// Edge scrolling while a marquee is open.
///
/// A selection rectangle that stops at the edge of the screen can only ever
/// select what is already on it — the second half of the report. The rule is
/// the same one a clip drag already used, so it is stated once and shared.
final class EdgeScrollTests: XCTestCase {
    private let region = CGRect(x: 60, y: 28, width: 640, height: 300)

    func testTheMiddleOfTheTimelineDoesNotScroll() {
        let delta = TimelineCanvas.edgeScrollDelta(CGPoint(x: 400, y: 180), in: region,
                                                   margin: 56, speed: 9)
        XCTAssertEqual(delta.dx, 0)
        XCTAssertEqual(delta.dy, 0)
    }

    /// "It should go right or left when pushing towards them."
    func testPushingIntoEitherSideTravelsThatWay() {
        let left = TimelineCanvas.edgeScrollDelta(CGPoint(x: region.minX + 10, y: 180),
                                                  in: region, margin: 56, speed: 9)
        XCTAssertLessThan(left.dx, 0, "pushing left has to travel back through the timeline")
        let right = TimelineCanvas.edgeScrollDelta(CGPoint(x: region.maxX - 10, y: 180),
                                                   in: region, margin: 56, speed: 9)
        XCTAssertGreaterThan(right.dx, 0)
        XCTAssertEqual(left.dy, 0)
        XCTAssertEqual(right.dy, 0)
    }

    /// Rows can run off the bottom as easily as clips run off the side.
    func testPushingIntoTopOrBottomTravelsVertically() {
        let up = TimelineCanvas.edgeScrollDelta(CGPoint(x: 400, y: region.minY + 8),
                                                in: region, margin: 56, speed: 9)
        XCTAssertLessThan(up.dy, 0)
        let down = TimelineCanvas.edgeScrollDelta(CGPoint(x: 400, y: region.maxY - 8),
                                                  in: region, margin: 56, speed: 9)
        XCTAssertGreaterThan(down.dy, 0)
    }

    /// A gentle push creeps, a firm one covers ground — and neither exceeds the
    /// speed it was given, or the timeline would bolt away from the finger.
    func testTravelRampsWithDepthAndIsCappedAtTheGivenSpeed() {
        func dx(_ x: CGFloat) -> CGFloat {
            TimelineCanvas.edgeScrollDelta(CGPoint(x: x, y: 180), in: region, margin: 56, speed: 9).dx
        }
        let shallow = abs(dx(region.maxX - 50)), deep = abs(dx(region.maxX - 5))
        XCTAssertGreaterThan(deep, shallow)
        XCTAssertLessThanOrEqual(deep, 9)
        XCTAssertLessThanOrEqual(abs(dx(region.maxX + 500)), 9, "past the edge is still capped")
    }

    /// A corner pushes both ways at once, so a marquee can reach a clip that is
    /// off-screen diagonally.
    func testACornerTravelsOnBothAxes() {
        let corner = TimelineCanvas.edgeScrollDelta(CGPoint(x: region.maxX - 6, y: region.maxY - 6),
                                                    in: region, margin: 56, speed: 9)
        XCTAssertGreaterThan(corner.dx, 0)
        XCTAssertGreaterThan(corner.dy, 0)
    }

    func testADegenerateRegionNeverScrolls() {
        let empty = TimelineCanvas.edgeScrollDelta(CGPoint(x: 5, y: 5), in: .zero, margin: 56, speed: 9)
        XCTAssertEqual(empty.dx, 0)
        XCTAssertEqual(empty.dy, 0)
    }
}
