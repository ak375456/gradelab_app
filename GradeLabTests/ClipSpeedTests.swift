import AVFoundation
import CoreMedia
import XCTest
@testable import GradeLab

/// Clip speed: duration, frame mapping, ripple, keyframes and persistence.
///
/// The invariant these all circle is that a clip's timeline duration is always
/// `sourceRange.duration / speed`. If that ever drifts, the composition plays a
/// different span than the timeline shows, and every downstream symptom — wrong
/// frame under the playhead, audio drift, wrong export length — follows from it.
final class ClipSpeedTests: XCTestCase {
    private func project() -> VideoProject {
        VideoProject(
            sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
            displayName: "a",
            metadata: makeVideoMetadata(durationSeconds: 10, nominalFrameRate: 30,
                                        minimumFrameDurationSeconds: 1.0 / 30.0)
        )
    }

    private func clip(_ project: VideoProject) throws -> VideoClip {
        try XCTUnwrap(TimelineEditing.clips(in: project).first)
    }

    func testDefaultSpeedIsNormalAndUnwritten() throws {
        let c = try clip(project())
        XCTAssertEqual(c.speed, 1)
        XCTAssertFalse(c.isRetimed)
        XCTAssertNil(c.playbackSpeed, "an untouched clip stores no speed")
    }

    func testSpeedIsClampedToAUsableRange() {
        XCTAssertEqual(ClipSpeed.clamped(100), ClipSpeed.maximum)
        XCTAssertEqual(ClipSpeed.clamped(0.001), ClipSpeed.minimum)
        XCTAssertEqual(ClipSpeed.clamped(16), 16, "1600% must be reachable")
        XCTAssertEqual(ClipSpeed.clamped(10), 10, "10x must still be reachable")
        XCTAssertEqual(ClipSpeed.clamped(0), 1, "zero would mean infinite duration")
        XCTAssertEqual(ClipSpeed.clamped(-2), 1)
        XCTAssertEqual(ClipSpeed.clamped(.nan), 1)
        XCTAssertEqual(ClipSpeed.clamped(2), 2)
    }

    /// Doubling the speed must halve the timeline duration, and the source range
    /// must be untouched — the same frames play, over less time.
    func testDoublingSpeedHalvesDurationWithoutTouchingTheSource() throws {
        var p = project()
        let before = try clip(p)
        try TimelineEditing.setSpeed(before.id, to: 2, in: &p)
        let after = try clip(p)

        XCTAssertEqual(after.speed, 2)
        XCTAssertTrue(after.isRetimed)
        XCTAssertEqual(after.sourceRange, before.sourceRange, "speed must not re-trim the clip")
        XCTAssertEqual(after.placement.duration.seconds,
                       before.placement.duration.seconds / 2, accuracy: 0.001)
        XCTAssertEqual(p.timeline.duration.seconds,
                       before.placement.duration.seconds / 2, accuracy: 0.001)
    }

    func testHalvingSpeedDoublesDuration() throws {
        var p = project()
        let before = try clip(p)
        try TimelineEditing.setSpeed(before.id, to: 0.5, in: &p)
        XCTAssertEqual(try clip(p).placement.duration.seconds,
                       before.placement.duration.seconds * 2, accuracy: 0.001)
    }

    func testReturningToNormalRestoresTheOriginalDuration() throws {
        var p = project()
        let original = try clip(p).placement.duration
        try TimelineEditing.setSpeed(try clip(p).id, to: 4, in: &p)
        try TimelineEditing.setSpeed(try clip(p).id, to: 1, in: &p)
        XCTAssertEqual(try clip(p).placement.duration.seconds, original.seconds, accuracy: 0.001)
        XCTAssertFalse(try clip(p).isRetimed)
    }

    /// The mapping that decides which frame the preview shows. At 2×, one second
    /// of timeline must consume two seconds of source.
    func testSourceTimeMappingFollowsSpeed() throws {
        var p = project()
        try TimelineEditing.setSpeed(try clip(p).id, to: 2, in: &p)
        let c = try clip(p)
        XCTAssertEqual(try c.sourceTime(at: .zero).seconds, 0, accuracy: 0.001)
        XCTAssertEqual(try c.sourceTime(at: .seconds(1)).seconds, 2, accuracy: 0.01)
        XCTAssertEqual(try c.sourceTime(at: .seconds(2.5)).seconds, 5, accuracy: 0.01)
        // Never past the end of the source, whatever is asked for.
        XCTAssertLessThanOrEqual(try c.sourceTime(at: .seconds(60)).seconds,
                                 try c.sourceRange.end.seconds + 0.001)
    }

    func testSlowMotionMappingFollowsSpeed() throws {
        var p = project()
        try TimelineEditing.setSpeed(try clip(p).id, to: 0.5, in: &p)
        let c = try clip(p)
        XCTAssertEqual(try c.sourceTime(at: .seconds(2)).seconds, 1, accuracy: 0.01)
    }

    func testNormalSpeedMappingIsUnchanged() throws {
        let c = try clip(project())
        XCTAssertEqual(try c.sourceTime(at: .seconds(3)).seconds, 3, accuracy: 0.001)
    }

    /// Later clips must move so nothing is overwritten or left with a gap.
    func testFollowingClipsRippleByTheChangeInLength() throws {
        var p = project()
        let first = try clip(p)
        let secondID = try TimelineEditing.paste(first, at: first.placement.range.end, in: &p)
        let secondStartBefore = try XCTUnwrap(
            TimelineEditing.clips(in: p).first { $0.id == secondID }).placement.timelineStart

        try TimelineEditing.setSpeed(first.id, to: 2, in: &p)

        let updatedFirst = try XCTUnwrap(TimelineEditing.clips(in: p).first { $0.id == first.id })
        let updatedSecond = try XCTUnwrap(TimelineEditing.clips(in: p).first { $0.id == secondID })
        XCTAssertEqual(updatedSecond.placement.timelineStart.seconds,
                       secondStartBefore.seconds / 2, accuracy: 0.001)
        XCTAssertEqual(updatedSecond.placement.timelineStart.seconds,
                       try updatedFirst.placement.range.end.seconds, accuracy: 0.001,
                       "the ripple must leave no gap and no overlap")
    }

    /// Keyframe times are clip-local timeline coordinates, so they scale with the
    /// clip. Without this a 2× clip would push half its animation past its end.
    func testKeyframesScaleWithTheClip() throws {
        var p = project()
        var c = try clip(p)
        c.apply(.toggleKeyframe(.opacity, atLocal: try .seconds(4)))
        c.apply(.setValue(.opacity, .number(0.5), atLocal: try .seconds(4)))
        try TimelineEditing.replace(c.id, with: [c], in: &p)
        let beforeTimes = try XCTUnwrap(try clip(p).animation?.tracks.first?.keyframes.map(\.time.seconds))
        XCTAssertEqual(beforeTimes.count, 1)
        XCTAssertEqual(beforeTimes[0], 4, accuracy: 0.001)

        try TimelineEditing.setSpeed(c.id, to: 2, in: &p)
        let afterTimes = try XCTUnwrap(try clip(p).animation?.tracks.first?.keyframes.map(\.time.seconds))
        XCTAssertEqual(afterTimes.count, 1)
        XCTAssertEqual(afterTimes[0], 2, accuracy: 0.001, "keyframes must stay proportionally placed")
        // And still inside the clip, which is the point.
        XCTAssertLessThanOrEqual(afterTimes[0], try clip(p).placement.duration.seconds + 0.001)
    }

    func testSpeedSurvivesSaveAndReload() throws {
        var p = project()
        try TimelineEditing.setSpeed(try clip(p).id, to: 1.5, in: &p)
        let reloaded = try JSONDecoder().decode(VideoProject.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(try clip(reloaded).speed, 1.5)
        XCTAssertEqual(try clip(reloaded).placement.duration, try clip(p).placement.duration)
    }

    /// Projects saved before speed existed carry no key and must be unchanged.
    func testProjectsSavedBeforeSpeedDecodeAtNormalSpeed() throws {
        let p = project()
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(p)) as! [String: Any]
        var tracks = json["timeline"] as! [String: Any]
        _ = tracks
        let decoded = try JSONDecoder().decode(
            VideoProject.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(try clip(decoded).speed, 1)
        XCTAssertFalse(try clip(decoded).isRetimed)
    }

    /// A retimed clip cannot take the direct-playback fast path, which bypasses
    /// the composition and would ignore the speed entirely.
    func testARetimedClipRequiresTheComposition() throws {
        var p = project()
        XCTAssertNotNil(p.singleSourceClip, "an untouched clip uses the direct path")
        try TimelineEditing.setSpeed(try clip(p).id, to: 2, in: &p)
        XCTAssertNil(p.singleSourceClip, "a retimed clip must go through the composition")
    }

    func testDurationMathRoundTrips() throws {
        for speed in ClipSpeed.presets {
            let source = try TimelineTime.seconds(10)
            let timeline = try ClipSpeed.timelineDuration(sourceDuration: source, speed: speed)
            XCTAssertEqual(timeline.seconds, 10 / speed, accuracy: 0.001, "speed \(speed)")
            let back = try ClipSpeed.sourceDuration(timelineDuration: timeline, speed: speed)
            XCTAssertEqual(back.seconds, source.seconds, accuracy: 0.01, "speed \(speed)")
        }
    }

    func testLabels() {
        XCTAssertEqual(ClipSpeed.label(1), "1×")
        XCTAssertEqual(ClipSpeed.label(2), "2×")
        XCTAssertEqual(ClipSpeed.label(0.5), "0.5×")
        XCTAssertEqual(ClipSpeed.label(10), "10×")
    }
}

/// The slider's mapping. It is logarithmic so 1× sits in the middle of the
/// track and 0.5×/2× are equidistant from it; a linear slider would compress
/// everything below 1× into the first fifth and make slow motion unusable.
final class SpeedSliderMappingTests: XCTestCase {
    /// Widened from 0.1…10 when ramping arrived, so 1600% is reachable. Kept
    /// symmetric in log10 rather than simply raising the ceiling: an asymmetric
    /// range would move 1× off the centre of the slider.
    func testTheRangeReachesSixteenTimes() {
        XCTAssertEqual(ClipSpeed.maximum, 16)
        XCTAssertEqual(ClipSpeed.minimum, 0.0625)
        XCTAssertEqual(ClipSpeed.clamped(25), 16, "above the range clamps to the maximum")
        XCTAssertEqual(ClipSpeed.clamped(0.01), 0.0625)
    }

    /// Widening must never re-clamp a rate an older project could already hold.
    func testEveryRateAnOlderProjectCouldHoldIsStillExact() {
        for speed in [0.1, 0.25, 0.5, 1, 2, 5, 10] {
            XCTAssertEqual(ClipSpeed.clamped(speed), speed, accuracy: 1e-12, "\(speed)")
        }
    }

    /// The reason for log10 rather than a linear ramp: 1× must sit in the middle
    /// of the track. Linearly it would land at 1/10th, and everything below
    /// normal speed would be squeezed into a sliver.
    func testNormalSpeedIsTheCentreOfTheTrack() {
        let range = ClipSpeed.sliderRange
        XCTAssertEqual((range.lowerBound + range.upperBound) / 2, 0, accuracy: 1e-9)
        XCTAssertEqual(ClipSpeed.speed(atSliderPosition: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(ClipSpeed.sliderPosition(for: 1), 0, accuracy: 1e-9)
    }

    func testTheEndsOfTheRangeAreEquidistantFromNormal() {
        XCTAssertEqual(abs(ClipSpeed.sliderPosition(for: ClipSpeed.minimum)),
                       abs(ClipSpeed.sliderPosition(for: ClipSpeed.maximum)), accuracy: 1e-9)
    }

    func testTheSliderEndsMatchTheSupportedRange() {
        XCTAssertEqual(ClipSpeed.speed(atSliderPosition: ClipSpeed.sliderRange.lowerBound),
                       ClipSpeed.minimum, accuracy: 1e-9)
        XCTAssertEqual(ClipSpeed.speed(atSliderPosition: ClipSpeed.sliderRange.upperBound),
                       ClipSpeed.maximum, accuracy: 1e-9)
    }

    func testTheMappingRoundTrips() {
        for speed in [0.0625, 0.1, 0.25, 0.5, 1, 1.5, 2, 5, 7.5, 10, 16] {
            XCTAssertEqual(ClipSpeed.speed(atSliderPosition: ClipSpeed.sliderPosition(for: speed)),
                           speed, accuracy: 1e-9, "\(speed)")
        }
    }

    func testEveryPresetIsReachableOnTheSlider() {
        for preset in ClipSpeed.presets {
            let position = ClipSpeed.sliderPosition(for: preset)
            XCTAssertGreaterThanOrEqual(position, ClipSpeed.sliderRange.lowerBound - 1e-9, "\(preset)")
            XCTAssertLessThanOrEqual(position, ClipSpeed.sliderRange.upperBound + 1e-9, "\(preset)")
        }
    }

    /// Float is what the slider carries, and the preset chip lights up on a
    /// 0.005 tolerance — at 10× a coarse round trip would drift past that and
    /// the chip would flicker off while sitting exactly on the preset.
    func testPresetsSurviveTheFloatRoundTripWithinTheHighlightTolerance() {
        for preset in ClipSpeed.presets {
            let asFloat = Float(ClipSpeed.sliderPosition(for: preset))
            let back = ClipSpeed.speed(atSliderPosition: Double(asFloat))
            XCTAssertEqual(back, preset, accuracy: 0.004, "\(preset) must still light its chip")
        }
    }

    func testLabelsAtTheNewRange() {
        XCTAssertEqual(ClipSpeed.label(16), "16×")
        XCTAssertEqual(ClipSpeed.label(10), "10×")
        XCTAssertEqual(ClipSpeed.label(0.1), "0.1×")
        XCTAssertEqual(ClipSpeed.label(1), "1×")
        XCTAssertEqual(ClipSpeed.label(0.25), "0.25×")
    }
}

/// Splitting a retimed clip.
///
/// Timeline distance is not source distance once a clip is retimed, and the
/// original split maths assumed they were the same — which produced a source
/// range running past the end of the media and refused the edit.
final class RetimedSplitTests: XCTestCase {
    private func project() -> VideoProject {
        VideoProject(
            sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
            displayName: "a",
            metadata: makeVideoMetadata(durationSeconds: 10, nominalFrameRate: 30,
                                        minimumFrameDurationSeconds: 1.0 / 30.0)
        )
    }

    private func clips(_ p: VideoProject) throws -> [VideoClip] {
        try TimelineEditing.clips(in: p)
    }

    func testSplittingASpedUpClipSucceeds() throws {
        var p = project()
        let id = try XCTUnwrap(clips(p).first).id
        try TimelineEditing.setSpeed(id, to: 2, in: &p)
        // The clip is now 0-5s of timeline; split it in the middle.
        _ = try TimelineEditing.split(id, at: .seconds(2.5), in: &p)

        let halves = try clips(p)
        XCTAssertEqual(halves.count, 2)
        for half in halves {
            XCTAssertEqual(half.speed, 2, "both halves keep the speed")
        }
    }

    /// The halves must together account for exactly the original source, with
    /// nothing lost or repeated at the seam.
    func testTheHalvesCoverTheOriginalSourceExactly() throws {
        var p = project()
        let id = try XCTUnwrap(clips(p).first).id
        let originalSource = try XCTUnwrap(clips(p).first).sourceRange
        try TimelineEditing.setSpeed(id, to: 2, in: &p)
        _ = try TimelineEditing.split(id, at: .seconds(2.5), in: &p)

        let halves = try clips(p).sorted { $0.placement.timelineStart < $1.placement.timelineStart }
        XCTAssertEqual(halves[0].sourceRange.start, originalSource.start)
        XCTAssertEqual(try halves[0].sourceRange.end, halves[1].sourceRange.start,
                       "no source is skipped or repeated at the seam")
        XCTAssertEqual(try halves[1].sourceRange.end.seconds, try originalSource.end.seconds, accuracy: 0.001)
        // At 2x, 2.5s of timeline consumes 5s of source.
        XCTAssertEqual(halves[0].sourceRange.duration.seconds, 5, accuracy: 0.01)
    }

    /// And no gap or overlap on the timeline either.
    func testTheHalvesAreContiguousOnTheTimeline() throws {
        var p = project()
        let id = try XCTUnwrap(clips(p).first).id
        try TimelineEditing.setSpeed(id, to: 3, in: &p)
        let total = try XCTUnwrap(clips(p).first).placement.duration
        _ = try TimelineEditing.split(id, at: .seconds(1), in: &p)

        let halves = try clips(p).sorted { $0.placement.timelineStart < $1.placement.timelineStart }
        XCTAssertEqual(try halves[0].placement.range.end, halves[1].placement.timelineStart)
        let combined = try halves[0].placement.duration.adding(halves[1].placement.duration)
        XCTAssertEqual(combined.seconds, total.seconds, accuracy: 0.001)
    }

    func testSplittingSlowMotionSucceeds() throws {
        var p = project()
        let id = try XCTUnwrap(clips(p).first).id
        try TimelineEditing.setSpeed(id, to: 0.5, in: &p)
        // 10s of source at 0.5x is 20s of timeline.
        _ = try TimelineEditing.split(id, at: .seconds(12), in: &p)
        let halves = try clips(p).sorted { $0.placement.timelineStart < $1.placement.timelineStart }
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(halves[0].sourceRange.duration.seconds, 6, accuracy: 0.01,
                       "12s of timeline at 0.5x is 6s of source")
    }

    /// Splitting at normal speed must be exactly what it always was.
    func testSplittingAtNormalSpeedIsUnchanged() throws {
        var p = project()
        let id = try XCTUnwrap(clips(p).first).id
        _ = try TimelineEditing.split(id, at: .seconds(4), in: &p)
        let halves = try clips(p).sorted { $0.placement.timelineStart < $1.placement.timelineStart }
        XCTAssertEqual(halves[0].placement.duration.seconds, 4, accuracy: 0.001)
        XCTAssertEqual(halves[0].sourceRange.duration.seconds, 4, accuracy: 0.001)
        XCTAssertEqual(halves[1].sourceRange.start.seconds, 4, accuracy: 0.001)
    }

    /// A retimed clip must survive a trim as well, which has the same hazard.
    func testTrimmingARetimedClipKeepsTheInvariant() throws {
        var p = project()
        let id = try XCTUnwrap(clips(p).first).id
        try TimelineEditing.setSpeed(id, to: 2, in: &p)
        try TimelineEditing.trim(id, edge: .right, to: .seconds(3), in: &p)
        let clip = try XCTUnwrap(clips(p).first)
        let expected = try ClipSpeed.timelineDuration(
            sourceDuration: clip.sourceRange.duration, speed: clip.speed)
        XCTAssertEqual(clip.placement.duration, expected,
                       "timeline duration must stay source duration over speed")
    }
}

/// Smooth motion: blending adjacent source frames instead of holding each one.
final class SmoothMotionTests: XCTestCase {
    private func project(colorMode: ProjectColorMode = .sdr) -> VideoProject {
        VideoProject(
            sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
            displayName: "a",
            metadata: makeVideoMetadata(durationSeconds: 10, nominalFrameRate: 30,
                                        minimumFrameDurationSeconds: 1.0 / 30.0),
            colorMode: colorMode
        )
    }

    private func clip(_ p: VideoProject) throws -> VideoClip {
        try XCTUnwrap(TimelineEditing.clips(in: p).first)
    }

    func testSmoothingIsOffAndUnwrittenByDefault() throws {
        let c = try clip(project())
        XCTAssertFalse(c.smoothsMotion)
        XCTAssertNil(c.blendsRetimedFrames)
    }

    /// At normal speed every output frame already lands on a source frame, so
    /// there is nothing to blend and the flag must not cost a pass.
    func testSmoothingIsIgnoredAtNormalSpeed() throws {
        var c = try clip(project())
        c.smoothsMotion = true
        XCTAssertEqual(c.speed, 1)
        XCTAssertFalse(c.smoothsMotion, "no blending is needed when nothing is retimed")
    }

    func testSmoothingAppliesOnceRetimed() throws {
        var p = project()
        try TimelineEditing.setSpeed(try clip(p).id, to: 0.5, in: &p)
        var c = try clip(p)
        c.smoothsMotion = true
        XCTAssertTrue(c.smoothsMotion)
    }

    /// Blending needs two source frames at once, which only the compositor can
    /// supply — so the project must stop taking the direct path.
    func testSmoothingForcesTheCompositorPath() throws {
        var p = project()
        try TimelineEditing.setSpeed(try clip(p).id, to: 0.5, in: &p)
        XCTAssertFalse(p.needsLayerCompositor, "a plain retime does not need the compositor")
        var c = try clip(p)
        c.smoothsMotion = true
        try TimelineEditing.replace(c.id, with: [c], in: &p)
        XCTAssertTrue(p.needsLayerCompositor, "blending requires the compositor")
        XCTAssertNil(p.singleSourceClip)
    }

    func testSmoothingSurvivesSaveAndReload() throws {
        var p = project()
        try TimelineEditing.setSpeed(try clip(p).id, to: 0.25, in: &p)
        var c = try clip(p)
        c.smoothsMotion = true
        try TimelineEditing.replace(c.id, with: [c], in: &p)
        let reloaded = try JSONDecoder().decode(VideoProject.self, from: try JSONEncoder().encode(p))
        XCTAssertTrue(try clip(reloaded).smoothsMotion)
    }

    /// The blend weight. 0 sits exactly on a source frame; 0.5 is halfway to the
    /// next one. Getting this wrong is what produces judder or a double image.
    func testFramePhaseWalksBetweenSourceFrames() throws {
        let frame = try TimelineTime.seconds(1.0 / 30.0)
        let start = TimelineTime.zero
        func phase(_ seconds: Double) throws -> Double {
            ClipSpeed.framePhase(sourceTime: try .seconds(seconds), sourceStart: start, frameDuration: frame)
        }
        XCTAssertEqual(try phase(0), 0, accuracy: 0.001, "exactly on a source frame")
        XCTAssertEqual(try phase(1.0 / 60.0), 0.5, accuracy: 0.01, "halfway to the next")
        XCTAssertEqual(try phase(1.0 / 30.0), 0, accuracy: 0.01, "on the next frame")
        XCTAssertEqual(try phase(1.5 / 30.0), 0.5, accuracy: 0.01)
    }

    func testFramePhaseStaysInRange() throws {
        let frame = try TimelineTime.seconds(1.0 / 24.0)
        for step in 0...200 {
            let phase = ClipSpeed.framePhase(
                sourceTime: try .seconds(Double(step) * 0.013),
                sourceStart: .zero, frameDuration: frame)
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1.0001)
        }
    }

    func testFramePhaseIsSafeWithoutAFrameDuration() {
        XCTAssertEqual(ClipSpeed.framePhase(sourceTime: .zero, sourceStart: .zero, frameDuration: .zero), 0)
    }

    /// Slow motion is where the phase actually sweeps: at 0.25× the source
    /// advances a quarter of a frame per output frame, so three of every four
    /// output frames are blends rather than exact source frames.
    func testSlowMotionProducesIntermediatePhases() throws {
        var p = project()
        try TimelineEditing.setSpeed(try clip(p).id, to: 0.25, in: &p)
        let c = try clip(p)
        let frame = try TimelineTime.seconds(1.0 / 30.0)
        var blends = 0
        for step in 0..<8 {
            let time = try TimelineTime.seconds(Double(step) / 30.0)
            let phase = ClipSpeed.framePhase(
                sourceTime: try c.sourceTime(at: time),
                sourceStart: c.sourceRange.start, frameDuration: frame)
            if phase > 0.01 && phase < 0.99 { blends += 1 }
        }
        XCTAssertGreaterThan(blends, 4, "most output frames in slow motion should be blends")
    }
}

/// Retimed compositions, checked against a real file rather than model maths.
///
/// The bug these exist for: AVFoundation validates that a video composition's
/// instructions cover the composition, and enforces it **silently**. When any
/// part of the timeline falls outside every instruction the custom compositor is
/// never invoked at all — not once — so the preview holds whatever frame it last
/// drew while the audio plays on to the end. Nothing throws, no status turns to
/// `.failed`, and the exported file is still correct, because `AVAssetReader`
/// does not apply the same rule. It is only reachable through real media, so a
/// model-level test cannot see it: `GradeLabTests/retime_test.mov` is 145 frames
/// of 30fps Rec.709 H.264 with an AAC track that, like any real recording, does
/// not end on the same tick as the picture.
final class RetimedCompositionTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("retime_test.mov")
    }

    private func project() async throws -> VideoProject {
        let asset = try await VideoMetadataReader().read(from: fixtureURL)
        // 145 frames at 30fps stated on a 600 grid: the exact shape an iPhone
        // recording arrives in, and the one whose retime arithmetic rounds
        // badly. Taking the range back out of the container instead would leave
        // the test at the mercy of whatever media timescale the muxer chose.
        let range = try TimelineRange(start: .zero,
                                      duration: TimelineTime(CMTime(value: 2900, timescale: 600)))
        return VideoProject(sourceURL: asset.url, displayName: "retime",
                            metadata: asset.metadata, sourceRange: range)
    }

    private func retimed(_ speed: Double, smooth: Bool = false) async throws -> VideoProject {
        var project = try await self.project()
        let id = try XCTUnwrap(project.timeline.firstVideoClip?.id)
        try TimelineEditing.setSpeed(id, to: speed, in: &project)
        if smooth {
            var clip = try TimelineEditing.editable(id, in: project)
            clip.smoothsMotion = true
            try TimelineEditing.replace(id, with: [clip], in: &project)
        }
        return project
    }

    /// The regression itself. Every speed the slider can reach must produce a
    /// composition whose instructions run to its very last tick.
    func testInstructionsCoverTheWholeCompositionAtEverySpeed() async throws {
        for (speed, smooth) in [(0.1, false), (0.2, false), (0.25, false), (0.5, false), (1.0, false),
                                (2.0, false), (5.0, false), (10.0, false),
                                (0.1, true), (0.2, true), (0.5, true), (2.0, true), (5.0, true), (10.0, true)] {
            // Both render paths: a plain retime goes direct, smoothing goes
            // through the layer compositor, and each builds its own instructions.
            let project = try await retimed(speed, smooth: smooth)
            let sequence = try await SequenceComposition.build(project: project, forExport: false)
            let composition = try XCTUnwrap(sequence.source.asset as? AVComposition)
            let instructions = try XCTUnwrap(sequence.source.videoComposition?.instructions)
            let end = try XCTUnwrap(instructions.last?.timeRange.end)
            XCTAssertFalse(instructions.isEmpty, "\(speed)x produced no instructions")
            XCTAssertTrue(CMTimeCompare(end, composition.duration) >= 0,
                """
                At \(speed)x (smoothing \(smooth)) the instructions stop at \(end.seconds) but \
                the composition runs to \(composition.duration.seconds). AVFoundation refuses a \
                composition with an uncovered tail by never calling the compositor, so the \
                preview freezes on one frame while the audio keeps playing.
                """)
        }
    }

    /// The instructions must also be contiguous from zero: a hole in the middle
    /// is refused exactly as an uncovered tail is.
    func testInstructionsAreContiguousFromZero() async throws {
        for speed in [0.2, 2.0] {
            let project = try await retimed(speed)
            let sequence = try await SequenceComposition.build(project: project, forExport: false)
            let instructions = try XCTUnwrap(sequence.source.videoComposition?.instructions)
            var cursor = CMTime.zero
            for instruction in instructions {
                XCTAssertEqual(instruction.timeRange.start, cursor,
                               "gap or overlap before \(instruction.timeRange.start.seconds)s at \(speed)x")
                cursor = instruction.timeRange.end
            }
        }
    }

    /// Smooth motion adds a second copy of the source, shifted one frame on. It
    /// must land on exactly the same timeline end as the picture it accompanies:
    /// a partner track that outlives the last instruction takes the whole video
    /// composition down with it, which is how holding the final frame to fill
    /// the missing tail broke preview for every smoothed clip.
    func testTheBlendTrackNeverOutlivesThePicture() async throws {
        for speed in [0.1, 0.2, 0.5, 2.0] {
            let project = try await retimed(speed, smooth: true)
            XCTAssertTrue(project.needsLayerCompositor, "smoothing must take the compositor path")
            let sequence = try await SequenceComposition.build(project: project, forExport: false)
            let composition = try XCTUnwrap(sequence.source.asset as? AVComposition)
            let video = composition.tracks(withMediaType: .video)
            XCTAssertEqual(video.count, 2, "smoothing needs the source and its shifted partner")
            let mains = sequence.source.compositionVideoTracks?.map(\.trackID) ?? []
            let picture = try XCTUnwrap(video.first { mains.contains($0.trackID) })
            let partner = try XCTUnwrap(video.first { !mains.contains($0.trackID) })
            XCTAssertTrue(CMTimeCompare(partner.timeRange.end, picture.timeRange.end) <= 0,
                          "at \(speed)x the partner runs to \(partner.timeRange.end.seconds), past a picture ending at \(picture.timeRange.end.seconds); anything beyond the last instruction invalidates the whole video composition")
            // Being a frame short at the tail is expected and harmless: with no
            // partner frame the compositor uses the source frame unblended.
            let shortfall = CMTimeSubtract(picture.timeRange.end, partner.timeRange.end).seconds
            XCTAssertLessThanOrEqual(shortfall, 1.0 / 30.0 / speed + 0.001,
                                     "the partner is \(shortfall)s short at \(speed)x, more than one retimed frame")
            for track in video {
                XCTAssertEqual(track.segments.count, 1,
                               "a second segment scales to its own end and desynchronises the track")
            }
            let instructions = try XCTUnwrap(sequence.source.videoComposition?.instructions)
            let end = try XCTUnwrap(instructions.last?.timeRange.end)
            XCTAssertTrue(CMTimeCompare(end, composition.duration) >= 0,
                          "smoothed \(speed)x left \(composition.duration.seconds - end.seconds)s uncovered")
        }
    }

    /// Retimed sound has to be scaled by the same conversion as the picture.
    /// `CMTimeMultiplyByFloat64` alone lands on a nanosecond timescale and can
    /// round a fraction of a nanosecond PAST the video it was cut from — which is
    /// all it takes.
    func testRetimedAudioDoesNotOutrunThePicture() async throws {
        for (speed, smooth) in [(0.1, false), (0.2, false), (0.5, false), (2.0, false), (5.0, false),
                                (10.0, false), (0.2, true), (0.5, true), (2.0, true), (5.0, true)] {
            // Both render paths: a plain retime goes direct, smoothing goes
            // through the layer compositor, and they scale sound separately.
            let project = try await retimed(speed, smooth: smooth)
            let sequence = try await SequenceComposition.build(project: project, forExport: false)
            let composition = try XCTUnwrap(sequence.source.asset as? AVComposition)
            let picture = try XCTUnwrap(composition.tracks(withMediaType: .video).first).timeRange.end
            for sound in composition.tracks(withMediaType: .audio) {
                XCTAssertTrue(CMTimeCompare(sound.timeRange.end, picture) <= 0,
                    """
                    At \(speed)x (smoothing \(smooth)) sound runs to \(sound.timeRange.end.seconds) \
                    past a picture ending at \(picture.seconds).
                    """)
            }
        }
    }

    /// Why the rational conversion is required, without needing a file. These are
    /// the user's own numbers: 4.8333s of source at 2x.
    func testTheFloatRetimeRoundsPastTheRationalOne() throws {
        let source = CMTime(value: 2900, timescale: 600)
        let float = CMTimeMultiplyByFloat64(source, multiplier: 0.5)
        let exact = try ClipSpeed.timelineDuration(sourceDuration: try TimelineTime(source), speed: 2)
        XCTAssertEqual(exact.cmTime.timescale, source.timescale, "the exact form stays on the source's grid")
        XCTAssertTrue(CMTimeCompare(float, exact.cmTime) > 0,
                      "the float form is expected to overshoot; if it no longer does, this test has gone stale")
        XCTAssertLessThan(float.seconds - exact.cmTime.seconds, 1e-8, "the overshoot is sub-nanosecond")
        XCTAssertEqual(exact.cmTime.value, 1450, "half of 2900 ticks, exactly")
    }
}
