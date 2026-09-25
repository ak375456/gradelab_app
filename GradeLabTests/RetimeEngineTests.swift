import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import GradeLab

/// Freezing a frame.
///
/// A hold is modelled as one frame of source taking a length of timeline, which
/// is what lets it be an ordinary scale rather than a special case. These check
/// that the arithmetic of that actually works out — a freeze that added the
/// wrong length, or consumed the wrong amount of source, would drift every
/// frame after it.
final class FreezeFrameTests: XCTestCase {
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

    func testAFreezeLengthensTheClipByItsOwnDuration() throws {
        var p = project()
        let id = try clip(p).id
        let before = try clip(p).placement.duration.seconds
        _ = try TimelineEditing.freezeFrame(id, atTimeline: try .seconds(4),
                                            duration: try .seconds(2), in: &p)
        let after = try clip(p)
        // Two seconds added, less the one frame of source the hold consumed —
        // which is the whole difference between a hold and an insertion.
        XCTAssertEqual(after.placement.duration.seconds, before + 2 - 1.0 / 30.0, accuracy: 0.02)
        XCTAssertEqual(after.sourceRange.duration.seconds, 10, accuracy: 1e-9,
                       "a freeze does not change which frames the clip covers")
    }

    func testTheHeldFrameIsTheOneUnderThePlayhead() throws {
        var p = project()
        let id = try clip(p).id
        _ = try TimelineEditing.freezeFrame(id, atTimeline: try .seconds(4),
                                            duration: try .seconds(2), in: &p)
        let map = try clip(p).timeMap
        // Anywhere inside the hold, the source stands still.
        let start = map.sourceOffset(atTimelineOffset: try .seconds(4.1))
        let middle = map.sourceOffset(atTimelineOffset: try .seconds(5.0))
        let end = map.sourceOffset(atTimelineOffset: try .seconds(5.8))
        XCTAssertEqual(start.seconds, 4, accuracy: 0.05)
        XCTAssertEqual(middle.seconds, start.seconds, accuracy: 1.0 / 30.0)
        XCTAssertEqual(end.seconds, start.seconds, accuracy: 1.0 / 30.0)
    }

    func testTimeResumesAfterTheHold() throws {
        var p = project()
        let id = try clip(p).id
        _ = try TimelineEditing.freezeFrame(id, atTimeline: try .seconds(4),
                                            duration: try .seconds(2), in: &p)
        let map = try clip(p).timeMap
        // One second past the end of the hold, one second of source has passed.
        XCTAssertEqual(map.sourceOffset(atTimelineOffset: try .seconds(7)).seconds,
                       5, accuracy: 0.05)
    }

    func testAFreezeSurvivesTheEditListConversion() throws {
        var p = project()
        let id = try clip(p).id
        _ = try TimelineEditing.freezeFrame(id, atTimeline: try .seconds(4),
                                            duration: try .seconds(2), in: &p)
        let c = try clip(p)
        let segments = c.timeMap.retimeSegments()
        XCTAssertFalse(segments.isEmpty)
        let timeline = segments.reduce(CMTime.zero) { CMTimeAdd($0, $1.timelineDuration.cmTime) }
        let source = segments.reduce(CMTime.zero) { CMTimeAdd($0, $1.sourceDuration.cmTime) }
        XCTAssertEqual(CMTimeCompare(timeline, c.placement.duration.cmTime), 0,
                       "the pieces must add up to the clip, to the tick")
        XCTAssertEqual(CMTimeCompare(source, c.sourceRange.duration.cmTime), 0)
        // One of them must actually be the hold: a long stretch of timeline over
        // almost no source.
        XCTAssertTrue(segments.contains { $0.rate < 0.1 },
                      "the hold has to survive as its own slow piece")
    }

    func testTwoHoldsOnTheSameFrameAreRefused() throws {
        var p = project()
        let id = try clip(p).id
        let first = try TimelineEditing.freezeFrame(id, atTimeline: try .seconds(4),
                                                    duration: try .seconds(1), in: &p)
        XCTAssertNotNil(first)
        let lengthAfterFirst = try clip(p).placement.duration
        let second = try TimelineEditing.freezeFrame(id, atTimeline: try .seconds(4),
                                                     duration: try .seconds(1), in: &p)
        XCTAssertNil(second, "a frame that is already held cannot be held again")
        XCTAssertEqual(try clip(p).placement.duration, lengthAfterFirst)
    }

    func testAFreezeRipplesAndValidates() throws {
        var p = project()
        let first = try clip(p).id
        let second = try TimelineEditing.split(first, at: try .seconds(5), in: &p)
        let before = try XCTUnwrap(p.timeline.videoClip(id: second)).placement.timelineStart
        _ = try TimelineEditing.freezeFrame(first, atTimeline: try .seconds(2),
                                            duration: try .seconds(3), in: &p)
        let after = try XCTUnwrap(p.timeline.videoClip(id: second)).placement.timelineStart
        XCTAssertGreaterThan(after.seconds, before.seconds)
        XCTAssertNoThrow(try p.validate())
    }

    func testAFreezeSurvivesSaveAndReload() throws {
        var p = project()
        let id = try clip(p).id
        _ = try TimelineEditing.freezeFrame(id, atTimeline: try .seconds(4),
                                            duration: try .seconds(2), in: &p)
        let data = try JSONEncoder().encode(p)
        let reloaded = try JSONDecoder().decode(VideoProject.self, from: data)
        let c = try XCTUnwrap(reloaded.timeline.videoClip(id: id))
        XCTAssertEqual(c.resolvedRemap.freezes.count, 1)
        XCTAssertEqual(c.resolvedRemap.freezes[0].sourceWidth.seconds, 1.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(c.placement.duration, try clip(p).placement.duration)
    }
}

/// Playing a clip backwards.
final class ReverseClipTests: XCTestCase {
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

    func testReversingDoesNotChangeTheLength() throws {
        var p = project()
        let id = try clip(p).id
        let before = try clip(p).placement.duration
        try TimelineEditing.setReversed(id, true, in: &p)
        XCTAssertEqual(try clip(p).placement.duration, before,
                       "the same frames play, in the other order")
        XCTAssertNoThrow(try p.validate())
    }

    func testTheFirstFrameBecomesTheLast() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setReversed(id, true, in: &p)
        let map = try clip(p).timeMap
        XCTAssertEqual(map.sourceOffset(atTimelineOffset: .zero).seconds, 10, accuracy: 0.02)
        XCTAssertEqual(map.sourceOffset(atTimelineOffset: try .seconds(10)).seconds, 0, accuracy: 0.02)
        XCTAssertEqual(map.sourceOffset(atTimelineOffset: try .seconds(2.5)).seconds, 7.5, accuracy: 0.05)
    }

    /// The ramp stays glued to the picture, not to the direction of travel: a
    /// slow section over a particular bit of the shot stays over that bit.
    func testAReversedRampKeepsItsRatesOnTheSameFrames() throws {
        var p = project()
        let id = try clip(p).id
        var remap = TimeRemap()
        remap.points = [
            SpeedPoint(sourceOffset: .zero, speed: 1, interpolation: .hold),
            SpeedPoint(sourceOffset: try .seconds(5), speed: 4, interpolation: .hold)
        ]
        try TimelineEditing.setTimeRemap(id, to: remap, in: &p)
        let forwardLength = try clip(p).placement.duration.seconds

        remap.reverses = true
        try TimelineEditing.setTimeRemap(id, to: remap, in: &p)
        XCTAssertEqual(try clip(p).placement.duration.seconds, forwardLength, accuracy: 0.05,
                       "reversing plays the same rates over the same frames, so the length is the same")
    }

    func testAReversedClipRequiresTheCompositor() throws {
        var p = project()
        let id = try clip(p).id
        XCTAssertFalse(p.needsLayerCompositor)
        try TimelineEditing.setReversed(id, true, in: &p)
        XCTAssertTrue(p.needsLayerCompositor,
                      "an edit list cannot express a negative rate")
    }

    func testReverseSurvivesSaveAndReload() throws {
        var p = project()
        let id = try clip(p).id
        try TimelineEditing.setReversed(id, true, in: &p)
        let data = try JSONEncoder().encode(p)
        let reloaded = try JSONDecoder().decode(VideoProject.self, from: data)
        XCTAssertTrue(try XCTUnwrap(reloaded.timeline.videoClip(id: id)).isReversed)
    }
}

/// The frame supply: source frames by source time, in any order.
///
/// Uses real media, because every failure this has is a timing failure and none
/// of them can be reproduced without a decoder. The numbers that matter are the
/// reader restarts — a supply that restarts per frame produces a correct picture
/// and an unusable one.
final class RetimeFrameSupplyTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("retime_test.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func supply(_ url: URL, seconds: Double = 4) throws -> RetimeFrameSupply {
        try XCTUnwrap(RetimeFrameSupply(
            url: url,
            range: CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600)),
            frameDuration: CMTime(value: 1, timescale: 30),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 1920, height: 1080))
    }

    func testItProducesAFrameGoingForwards() throws {
        let supply = try supply(try fixture())
        XCTAssertNotNil(supply.frame(at: CMTime(seconds: 1, preferredTimescale: 600)))
    }

    func testItProducesFramesGoingBackwards() throws {
        let supply = try supply(try fixture())
        var seen = 0
        for step in stride(from: 60, through: 0, by: -1) {
            let time = CMTime(value: CMTimeValue(step), timescale: 30)
            if supply.frame(at: time) != nil { seen += 1 }
        }
        XCTAssertEqual(seen, 61, "every frame of a backwards walk has to come back with a picture")
    }

    /// The whole reason the ring exists. Backwards is expensive if it is done
    /// naively and cheap if the reader is restarted a window early.
    func testWalkingBackwardsDoesNotRestartTheReaderPerFrame() throws {
        let supply = try supply(try fixture())
        for step in stride(from: 60, through: 0, by: -1) {
            _ = supply.frame(at: CMTime(value: CMTimeValue(step), timescale: 30))
        }
        XCTAssertLessThan(supply.readerStarts, 20,
                          "61 frames backwards must not mean 61 readers")
        XCTAssertGreaterThan(supply.readerStarts, 0)
    }

    func testWalkingForwardsStaysOnAFewReaders() throws {
        let supply = try supply(try fixture())
        for step in 0...60 {
            _ = supply.frame(at: CMTime(value: CMTimeValue(step), timescale: 30))
        }
        XCTAssertLessThan(supply.readerStarts, 12,
                          "forward playback is what a decoder already does")
    }

    /// The bug that froze the picture when scrubbing back through a reversed
    /// clip: a window was answering for times it did not reach, so the newest
    /// frame it happened to hold was returned forever.
    func testAWindowDoesNotAnswerForTimesItDoesNotReach() throws {
        let supply = try supply(try fixture())
        let early = try XCTUnwrap(supply.frame(at: CMTime(value: 2, timescale: 30)))
        let late = try XCTUnwrap(supply.frame(at: CMTime(value: 100, timescale: 30)))
        XCTAssertFalse(early === late,
                       "a request two seconds later must decode, not repeat what was in hand")
    }

    /// Reverse playback is the case this exists for, and a window boundary
    /// every few frames is what made it stutter.
    func testSteadyReversePlaybackKeepsReaderStartsLow() throws {
        let supply = try supply(try fixture())
        for step in stride(from: 110, through: 0, by: -1) {
            _ = supply.frame(at: CMTime(value: CMTimeValue(step), timescale: 30))
        }
        XCTAssertLessThan(supply.readerStarts, 30,
                          "111 frames backwards must not mean a reader every few frames")
    }

    func testAPairComesBackInSourceOrder() throws {
        let supply = try supply(try fixture())
        let pair = try XCTUnwrap(supply.pair(at: CMTime(value: 45, timescale: 60), needsPartner: true))
        XCTAssertNotNil(pair.second, "a moment between two frames has two frames")
        XCTAssertGreaterThan(pair.phase, 0)
        XCTAssertLessThan(pair.phase, 1)
    }
}

/// Optical flow: the warp, and the judgement about when not to trust it.
///
/// Driven with synthetic frames whose motion is known exactly, on the real GPU,
/// so ghosting and warping are numbers rather than opinions. A picture test
/// would show that something happened; this shows what.
final class OpticalFlowInterpolationTests: XCTestCase {
    private func context() throws -> MetalContext {
        do { return try MetalContext() }
        catch { throw XCTSkip("No Metal device on this machine.") }
    }

    private static let width = 256
    private static let height = 144

    /// A frame holding a bright bar with its left edge at `x`, in 4:2:0 8-bit.
    private func frame(barAt x: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        XCTAssertEqual(CVPixelBufferCreate(nil, Self.width, Self.height,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                           attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                // A textured bar rather than a flat one: a flat block matches
                // itself at every displacement and would tell us nothing about
                // whether the search worked.
                let inside = column >= x && column < x + 40
                let texture = UInt8(((row * 7 + column * 13) % 64) + 16)
                luma[row * stride + column] = inside ? 200 &+ (texture % 40) : texture
            }
        }
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 1))
            .assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixels, 1) {
            for column in 0..<CVPixelBufferGetWidthOfPlane(pixels, 1) {
                chroma[row * chromaStride + column * 2] = 128
                chroma[row * chromaStride + column * 2 + 1] = 128
            }
        }
        return pixels
    }

    /// Mean luma down one column, which is how the bar is located.
    private func column(_ buffer: CVPixelBuffer, _ x: Int) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var total = 0.0
        for row in 0..<Self.height { total += Double(luma[row * stride + x]) }
        return total / Double(Self.height)
    }

    private func allocate(_ width: Int, _ height: Int, _ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format,
                                           attributes as CFDictionary, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    /// The claim optical flow makes, and the one frame blending cannot: at the
    /// halfway point the moving thing is in ONE place, halfway along — not in
    /// two places at once.
    func testTheBarArrivesHalfwayRatherThanInTwoPlaces() throws {
        let metal = try context()
        let interpolator = try XCTUnwrap(RetimeInterpolator(context: metal))
        let a = try frame(barAt: 40), b = try frame(barAt: 80)
        let key = RetimeInterpolator.PairKey(assetID: UUID(), first: .zero,
                                             second: CMTime(value: 1, timescale: 30), divisor: 4)
        let made = try XCTUnwrap(try interpolator.interpolated(
            a, b, phase: 0.5, quality: .high, key: key, allocate: allocate))

        // Where the bar should be at the halfway point: 60…100.
        let middle = column(made, 78)
        // Where each frame had it and the other did not. A cross-dissolve puts
        // roughly half a bar in both of these; flow should leave them dark.
        let onlyInA = column(made, 45)
        let onlyInB = column(made, 115)

        XCTAssertGreaterThan(middle, 150, "the bar has to actually be at the halfway position")
        XCTAssertLessThan(onlyInA, middle * 0.75,
                          "a ghost of the first frame's bar means this is a dissolve, not flow")
        XCTAssertLessThan(onlyInB, middle * 0.75,
                          "a ghost of the second frame's bar means the same")
    }

    func testTheResultTracksThePhase() throws {
        let metal = try context()
        let interpolator = try XCTUnwrap(RetimeInterpolator(context: metal))
        let a = try frame(barAt: 40), b = try frame(barAt: 80)
        let key = RetimeInterpolator.PairKey(assetID: UUID(), first: .zero,
                                             second: CMTime(value: 1, timescale: 30), divisor: 4)
        // A quarter of the way along, the bar should be nearer where it started.
        let quarter = try XCTUnwrap(try interpolator.interpolated(
            a, b, phase: 0.25, quality: .high, key: key, allocate: allocate))
        XCTAssertGreaterThan(column(quarter, 60), column(quarter, 110),
                             "at 25% the bar is still nearer its starting position")
    }

    /// Sitting exactly on a source frame is not something to interpolate — the
    /// frame is already the answer, and making one would only soften it.
    func testAnExactFrameIsNotInterpolated() throws {
        let metal = try context()
        let interpolator = try XCTUnwrap(RetimeInterpolator(context: metal))
        let a = try frame(barAt: 40), b = try frame(barAt: 80)
        let key = RetimeInterpolator.PairKey(assetID: UUID(), first: .zero,
                                             second: CMTime(value: 1, timescale: 30), divisor: 4)
        XCTAssertNil(try interpolator.interpolated(a, b, phase: 0, quality: .preview,
                                                   key: key, allocate: allocate))
        XCTAssertNil(try interpolator.interpolated(a, b, phase: 1, quality: .preview,
                                                   key: key, allocate: allocate))
    }

    /// Identical frames have no motion, so the result must be that frame — not
    /// a warped version of it. This is the test that catches a flow field that
    /// invents displacement out of noise.
    func testTwoIdenticalFramesInterpolateToThemselves() throws {
        let metal = try context()
        let interpolator = try XCTUnwrap(RetimeInterpolator(context: metal))
        let a = try frame(barAt: 40), b = try frame(barAt: 40)
        let key = RetimeInterpolator.PairKey(assetID: UUID(), first: .zero,
                                             second: CMTime(value: 1, timescale: 30), divisor: 4)
        let made = try XCTUnwrap(try interpolator.interpolated(
            a, b, phase: 0.5, quality: .high, key: key, allocate: allocate))
        for x in [20, 50, 70, 120, 200] {
            XCTAssertEqual(column(made, x), column(a, x), accuracy: 6,
                           "nothing moved, so nothing may be warped (column \(x))")
        }
    }

    /// The output has to be a frame the rest of the app can grade, in the
    /// layout it came in. That is the whole reason the interpolation happens
    /// before grading rather than inside it.
    func testTheResultKeepsTheSourceLayout() throws {
        let metal = try context()
        let interpolator = try XCTUnwrap(RetimeInterpolator(context: metal))
        let a = try frame(barAt: 40), b = try frame(barAt: 80)
        let key = RetimeInterpolator.PairKey(assetID: UUID(), first: .zero,
                                             second: CMTime(value: 1, timescale: 30), divisor: 4)
        let made = try XCTUnwrap(try interpolator.interpolated(
            a, b, phase: 0.5, quality: .preview, key: key, allocate: allocate))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(made),
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(CVPixelBufferGetWidth(made), Self.width)
        XCTAssertEqual(CVPixelBufferGetHeight(made), Self.height)
    }

    /// Preview and High differ in the grid the motion is measured on, and both
    /// have to produce a usable picture — Preview is what the timeline runs on.
    func testBothQualitiesProduceAFrame() throws {
        let metal = try context()
        let interpolator = try XCTUnwrap(RetimeInterpolator(context: metal))
        let a = try frame(barAt: 40), b = try frame(barAt: 80)
        for quality in OpticalFlowQuality.allCases {
            let key = RetimeInterpolator.PairKey(
                assetID: UUID(), first: .zero, second: CMTime(value: 1, timescale: 30),
                divisor: RetimeInterpolator.divisor(for: quality))
            let made = try XCTUnwrap(try interpolator.interpolated(
                a, b, phase: 0.5, quality: quality, key: key, allocate: allocate))
            XCTAssertGreaterThan(column(made, 78), 120, "\(quality.title) produced nothing usable")
        }
    }
}
