import AVFoundation
import CoreMedia
import XCTest
@testable import GradeLab

/// The time map: the one conversion between a clip's timeline and its source.
///
/// Every symptom of a broken retime — the wrong frame under the playhead, audio
/// drift, an export a different length from the timeline — is this arithmetic
/// going wrong. So these test the map directly rather than through a clip.
final class TimeMapTests: XCTestCase {
    private func seconds(_ value: Double) throws -> TimelineTime { try .seconds(value) }

    // MARK: - The straight-line cases

    func testAnUnretimedMapIsTheIdentity() throws {
        let map = TimeMap.identity(sourceDuration: try seconds(10))
        XCTAssertTrue(map.isIdentity)
        XCTAssertEqual(map.timelineDuration.seconds, 10, accuracy: 1e-6)
        XCTAssertEqual(map.sourceOffset(atTimelineOffset: try seconds(3)).seconds, 3, accuracy: 1e-6)
    }

    func testAConstantMapMatchesPlainDivision() throws {
        for rate in [0.25, 0.5, 2.0, 4.0] {
            let map = TimeMap.constant(speed: rate, sourceDuration: try seconds(10))
            XCTAssertEqual(map.timelineDuration.seconds, 10 / rate, accuracy: 1e-4, "\(rate)")
            XCTAssertEqual(map.sourceOffset(atTimelineOffset: try seconds(1)).seconds,
                           rate, accuracy: 1e-4, "\(rate)")
        }
    }

    /// The constant path must not go anywhere near the sampled table: it is the
    /// overwhelmingly common case and it has an exact answer.
    func testAConstantRemapTakesTheExactPathRatherThanTheTable() throws {
        var remap = TimeRemap()
        remap.constantSpeed = 2
        let map = TimeMap.cached(remap: remap, sourceDuration: try seconds(600))
        XCTAssertEqual(map.timelineDuration.seconds, 300, accuracy: 1e-9,
                       "ten minutes at 2x must be exactly five, not five-ish")
    }

    // MARK: - Ramps

    /// The headline case: 100% to 400% over the clip. The length must be the
    /// integral of 1/speed, which for a linear ramp is the log mean — not the
    /// midpoint, which is what a naive average would give.
    func testALinearRampIntegratesRatherThanAveraging() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .linear),
            SpeedPoint(sourceOffset: try seconds(10), speed: 4, interpolation: .linear)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        // ∫₀¹⁰ du / (1 + 0.3u) = (1/0.3)·ln(4) ≈ 4.6210
        XCTAssertEqual(map.timelineDuration.seconds, log(4.0) / 0.3, accuracy: 0.01)
        // The naive answers, both wrong, both plausible-looking.
        XCTAssertNotEqual(map.timelineDuration.seconds, 10 / 2.5, accuracy: 0.1)
        XCTAssertNotEqual(map.timelineDuration.seconds, 4.0, accuracy: 0.1)
    }

    func testTheSpeedReadAtAMomentFollowsTheCurve() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .linear),
            SpeedPoint(sourceOffset: try seconds(10), speed: 4, interpolation: .linear)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        XCTAssertEqual(map.speed(atTimelineOffset: .zero), 1, accuracy: 0.05)
        XCTAssertEqual(map.speed(atTimelineOffset: map.timelineDuration), 4, accuracy: 0.15)
    }

    /// Both directions have to agree, or a tracked mask and the picture end up
    /// on different frames.
    func testTheMapRoundTripsBothWays() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .easeInOut),
            SpeedPoint(sourceOffset: try seconds(4), speed: 0.25, interpolation: .easeInOut),
            SpeedPoint(sourceOffset: try seconds(7), speed: 3, interpolation: .easeInOut),
            SpeedPoint(sourceOffset: try seconds(10), speed: 1, interpolation: .easeInOut)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            let timeline = try seconds(map.timelineDuration.seconds * step)
            let source = map.sourceOffset(atTimelineOffset: timeline)
            let back = map.timelineOffset(atSourceOffset: source)
            XCTAssertEqual(back.seconds, timeline.seconds, accuracy: 0.01,
                           "round trip at \(step)")
        }
    }

    func testTheCurveIsFlatOutsideTheFirstAndLastPoint() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: try seconds(4), speed: 0.5, interpolation: .linear),
            SpeedPoint(sourceOffset: try seconds(6), speed: 2, interpolation: .linear)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        // Before the first point the rate must be the first point's, not an
        // extrapolation of the ramp that starts there.
        XCTAssertEqual(map.speed(atTimelineOffset: try seconds(0.5)), 0.5, accuracy: 0.05)
    }

    func testAHoldTransitionKeepsTheLeftRateUntilTheNextPoint() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .hold),
            SpeedPoint(sourceOffset: try seconds(5), speed: 4, interpolation: .hold)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        // First five seconds of source at 1x, then five at 4x: 5 + 1.25.
        XCTAssertEqual(map.timelineDuration.seconds, 6.25, accuracy: 0.02)
    }

    // MARK: - Accumulation

    /// The reason the table accumulates whole ticks rather than Double seconds.
    /// A long clip is where float drift turns into visible frames.
    func testALongRampStaysFrameAccurate() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .linear),
            SpeedPoint(sourceOffset: try seconds(3600), speed: 2, interpolation: .linear)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(3600))
        // ∫₀³⁶⁰⁰ du / (1 + u/3600) = 3600·ln(2) ≈ 2495.33
        XCTAssertEqual(map.timelineDuration.seconds, 3600 * log(2.0), accuracy: 0.5)
        // And the two directions still meet, an hour in.
        let source = map.sourceOffset(atTimelineOffset: map.timelineDuration)
        XCTAssertEqual(source.seconds, 3600, accuracy: 0.02)
    }

    // MARK: - Segments

    /// A curve reaches AVFoundation as constant-rate pieces. They must sum to
    /// exactly the clip's length: one tick short leaves the composition's last
    /// instruction uncovered, and AVFoundation answers that by rendering nothing.
    func testSegmentsSumToExactlyTheClipLength() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .easeInOut),
            SpeedPoint(sourceOffset: try seconds(5), speed: 0.25, interpolation: .easeInOut),
            SpeedPoint(sourceOffset: try seconds(10), speed: 4, interpolation: .easeInOut)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        let segments = map.retimeSegments()
        XCTAssertFalse(segments.isEmpty)

        let source = segments.reduce(CMTime.zero) { CMTimeAdd($0, $1.sourceDuration.cmTime) }
        let timeline = segments.reduce(CMTime.zero) { CMTimeAdd($0, $1.timelineDuration.cmTime) }
        XCTAssertEqual(CMTimeCompare(source, map.sourceDuration.cmTime), 0,
                       "segments must account for the whole source range, to the tick")
        XCTAssertEqual(CMTimeCompare(timeline, map.timelineDuration.cmTime), 0,
                       "segments must account for the whole timeline length, to the tick")
    }

    func testSegmentsAreContiguousInSource() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 0.5, interpolation: .linear),
            SpeedPoint(sourceOffset: try seconds(10), speed: 3, interpolation: .linear)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        var cursor = TimelineTime.zero
        for segment in map.retimeSegments() {
            XCTAssertEqual(segment.sourceOffset.seconds, cursor.seconds, accuracy: 0.01)
            cursor = try segment.sourceOffset.adding(segment.sourceDuration)
        }
    }

    /// A flat clip costs one piece, not one per frame. The merge is what keeps a
    /// ramp from turning into hundreds of edit-list entries.
    func testAGentleRampDoesNotExplodeIntoSegments() throws {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .linear),
            SpeedPoint(sourceOffset: try seconds(10), speed: 2, interpolation: .linear)
        ]
        let map = TimeMap(remap: remap, sourceDuration: try seconds(10))
        let count = map.retimeSegments().count
        XCTAssertGreaterThan(count, 3, "a ramp needs enough pieces to read as smooth")
        XCTAssertLessThan(count, 120, "but nowhere near one per frame")
    }
}

/// Ramping through the editing layer: duration, ripple, keyframes, persistence.
final class SpeedRampEditingTests: XCTestCase {
    private func project() -> VideoProject {
        VideoProject(
            sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
            displayName: "a",
            metadata: makeVideoMetadata(durationSeconds: 10, nominalFrameRate: 30,
                                        minimumFrameDurationSeconds: 1.0 / 30.0)
        )
    }

    private func clip(_ p: VideoProject) throws -> VideoClip {
        try XCTUnwrap(TimelineEditing.clips(in: p).first)
    }

    private func ramp() throws -> TimeRemap {
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .easeInOut),
            SpeedPoint(sourceOffset: try .seconds(10), speed: 4, interpolation: .easeInOut)
        ]
        return remap
    }

    func testAClipWithNoRampStoresNothing() throws {
        let c = try clip(project())
        XCTAssertNil(c.timeRemap, "an untouched clip stores no retiming")
        XCTAssertFalse(c.isRetimed)
        XCTAssertFalse(c.isRamped)
    }

    /// The document invariant, generalised: the clip's length is whatever its
    /// map makes of its source range.
    func testRampingResizesTheClipToTheMap() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setTimeRemap(id, to: try ramp(), in: &p)
        let c = try clip(p)
        XCTAssertTrue(c.isRamped)
        XCTAssertEqual(c.placement.duration.seconds, c.timeMap.timelineDuration.seconds, accuracy: 1e-9)
        XCTAssertEqual(c.sourceRange.duration.seconds, 10, accuracy: 1e-9,
                       "the same frames play, over a different span")
        XCTAssertLessThan(c.placement.duration.seconds, 10, "speeding up shortens the clip")
    }

    func testTheProjectStillValidatesAfterARamp() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setTimeRemap(id, to: try ramp(), in: &p)
        XCTAssertNoThrow(try p.validate())
    }

    func testARampedClipRequiresTheCompositor() throws {
        var p = project()
        let id = try clip(p).id
        XCTAssertFalse(p.needsLayerCompositor)
        try TimelineEditing.setTimeRemap(id, to: try ramp(), in: &p)
        XCTAssertTrue(p.needsLayerCompositor,
                      "a varying rate cannot be expressed on the flat path")
    }

    func testAddingAPointDoesNotChangeThePicture() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setSpeed(id, to: 2, in: &p)
        let before = try clip(p).placement.duration
        _ = try TimelineEditing.addSpeedPoint(id, atTimeline: try .seconds(2), in: &p)
        let after = try clip(p)
        XCTAssertEqual(after.placement.duration.seconds, before.seconds, accuracy: 0.02,
                       "dropping a point carries the speed already in force, so nothing moves")
    }

    func testAPointCarriesTheRateAlreadyInForce() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setSpeed(id, to: 2, in: &p)
        _ = try TimelineEditing.addSpeedPoint(id, atTimeline: try .seconds(2), in: &p)
        let points = try clip(p).resolvedRemap.points
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertEqual(point.speed, 2, accuracy: 0.02)
        }
    }

    func testRampingRipplesTheRestOfTheTrack() throws {
        var p = project()
        let first = try clip(p).id
        let second = try TimelineEditing.split(first, at: try .seconds(5), in: &p)
        let startBefore = try XCTUnwrap(p.timeline.videoClip(id: second)).placement.timelineStart

        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .linear),
            SpeedPoint(sourceOffset: try .seconds(5), speed: 4, interpolation: .linear)
        ]
        try TimelineEditing.setTimeRemap(first, to: remap, in: &p)

        let startAfter = try XCTUnwrap(p.timeline.videoClip(id: second)).placement.timelineStart
        XCTAssertLessThan(startAfter.seconds, startBefore.seconds,
                          "the clip got shorter, so the one after it moves back")
        XCTAssertEqual(startAfter.seconds,
                       try XCTUnwrap(p.timeline.videoClip(id: first)).placement.duration.seconds,
                       accuracy: 1e-9, "and lands exactly where the first one now ends")
    }

    /// Splitting a ramp has to leave both halves playing what the original did.
    func testSplittingARampKeepsBothHalvesPlayingTheSameRates() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setTimeRemap(id, to: try ramp(), in: &p)
        let whole = try clip(p)
        let seam = try whole.placement.timelineStart.adding(
            try .seconds(whole.placement.duration.seconds / 2))
        let rightID = try TimelineEditing.split(id, at: seam, in: &p)

        let left = try XCTUnwrap(p.timeline.videoClip(id: id))
        let right = try XCTUnwrap(p.timeline.videoClip(id: rightID))

        XCTAssertEqual(try left.sourceRange.duration.adding(right.sourceRange.duration).seconds,
                       whole.sourceRange.duration.seconds, accuracy: 1e-6,
                       "the halves cover the original source exactly")
        XCTAssertEqual(try left.placement.range.end.seconds, right.placement.timelineStart.seconds,
                       accuracy: 1e-9, "and are contiguous on the timeline")
        // The rate at the seam is the same from either side, which is the whole
        // point of writing a point there.
        XCTAssertEqual(left.speed(at: try left.placement.range.end),
                       right.speed(at: right.placement.timelineStart), accuracy: 0.2)
    }

    func testKeyframesStayOnTheirOwnPictureAcrossARamp() throws {
        var p = project()
        let id = try clip(p).id
        // A keyframe halfway through the clip, which at 1x is halfway through
        // the source too.
        var c = try clip(p)
        var animation = ClipAnimation()
        animation.update(.opacity) { $0.set(.number(0.5), at: try! .seconds(5)) }
        c.animation = animation
        try TimelineEditing.replace(id, with: [c], in: &p)

        try TimelineEditing.setTimeRemap(id, to: try ramp(), in: &p)

        let after = try clip(p)
        let moved = try XCTUnwrap(after.animation?.track(.opacity)?.keyframes.first)
        let source = after.timeMap.sourceOffset(atTimelineOffset: moved.time)
        XCTAssertEqual(source.seconds, 5, accuracy: 0.05,
                       "the keyframe must still land on the frame it was authored against")
    }

    // MARK: - Persistence

    func testARampSurvivesSaveAndReload() throws {
        var p = project()
        let id = try clip(p).id
        var remap = try ramp()
        remap.frameInterpolation = .opticalFlow
        remap.opticalFlowQuality = .high
        try TimelineEditing.setTimeRemap(id, to: remap, in: &p)

        let data = try JSONEncoder().encode(p)
        let reloaded = try JSONDecoder().decode(VideoProject.self, from: data)
        let c = try XCTUnwrap(reloaded.timeline.videoClip(id: id))

        XCTAssertEqual(c.resolvedRemap.points.count, 2)
        XCTAssertEqual(c.resolvedRemap.frameInterpolation, .opticalFlow)
        XCTAssertEqual(c.resolvedRemap.opticalFlowQuality, .high)
        XCTAssertEqual(c.placement.duration.seconds,
                       try clip(p).placement.duration.seconds, accuracy: 1e-9)
    }

    /// The compatibility guarantee: a project written before ramping existed
    /// opens with no retiming at all, not with a default one.
    func testProjectsSavedBeforeRampingDecodeUnchanged() throws {
        let p = project()
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(p)) as! [String: Any]
        // Strip the key entirely, which is what an older document looks like.
        func strip(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                dictionary.removeValue(forKey: "timeRemap")
                for (key, nested) in dictionary { dictionary[key] = strip(nested) }
                return dictionary
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        json = strip(json) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: json)
        let reloaded = try JSONDecoder().decode(VideoProject.self, from: data)
        let c = try XCTUnwrap(reloaded.timeline.firstVideoClip)
        XCTAssertNil(c.timeRemap)
        XCTAssertEqual(c.speed, 1)
        XCTAssertFalse(c.isRamped)
    }

    /// The old boolean and the new enum describe the same thing for a clip that
    /// has never been ramped, and must not disagree.
    func testTheOldSmoothMotionFlagStillReads() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setSpeed(id, to: 2, in: &p)
        var c = try clip(p)
        c.blendsRetimedFrames = true
        try TimelineEditing.replace(id, with: [c], in: &p)

        let reloaded = try clip(p)
        XCTAssertTrue(reloaded.smoothsMotion)
        XCTAssertEqual(reloaded.frameInterpolation, .blending)
        XCTAssertNil(reloaded.timeRemap, "reading must not rewrite the document")
    }
}

/// The graph's own maths, which decides where a point lands and what a drag means.
final class SpeedCurveGeometryTests: XCTestCase {
    func testNormalSpeedSitsWhereTheKneeSaysItDoes() {
        // 1x must be inside the fine-grained lower region, not at the top.
        let fraction = SpeedCurveGeometry.fraction(forSpeed: 1)
        XCTAssertGreaterThan(fraction, 0.4)
        XCTAssertLessThan(fraction, SpeedCurveGeometry.kneeFraction)
    }

    /// The reason for the knee: the slow half has to stay draggable even though
    /// 1600% is representable.
    func testTheSlowHalfGetsMostOfTheHeight() {
        let toKnee = SpeedCurveGeometry.fraction(forSpeed: SpeedCurveGeometry.knee)
        XCTAssertEqual(toKnee, SpeedCurveGeometry.kneeFraction, accuracy: 1e-9)
        XCTAssertGreaterThan(toKnee, 0.6, "0.0625x-4x must own the majority of the axis")
    }

    func testTheAxisRoundTrips() {
        for speed in [0.0625, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16] {
            let back = SpeedCurveGeometry.speed(forFraction: SpeedCurveGeometry.fraction(forSpeed: speed))
            XCTAssertEqual(back, speed, accuracy: 1e-6, "\(speed)")
        }
    }

    func testTheEndsOfTheAxisAreTheEndsOfTheRange() {
        XCTAssertEqual(SpeedCurveGeometry.speed(forFraction: 0), ClipSpeed.minimum, accuracy: 1e-9)
        XCTAssertEqual(SpeedCurveGeometry.speed(forFraction: 1), ClipSpeed.maximum, accuracy: 1e-9)
    }

    /// A finger needs a far bigger target than the dot it is aiming at, and a
    /// pointer does not. Both have to work on the same graph.
    func testAFingerGetsABiggerTargetThanAPointer() {
        XCTAssertGreaterThan(SpeedCurveGeometry.hitRadius(forPointer: false),
                             SpeedCurveGeometry.hitRadius(forPointer: true))
        XCTAssertGreaterThanOrEqual(SpeedCurveGeometry.hitRadius(forPointer: false) * 2, 40,
                                    "a touch target under 40pt is not one")
        XCTAssertGreaterThan(SpeedCurveGeometry.hitRadius(forPointer: false),
                             SpeedCurveGeometry.pointRadius * 3,
                             "the visible dot stays small; only the reach is large")
    }
}
