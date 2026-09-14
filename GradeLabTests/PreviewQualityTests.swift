import AVFoundation
import XCTest
@testable import GradeLab

/// Preview quality reduces playback resolution only. The project, the paused
/// picture and the export are all untouched, and these pin that.
final class PreviewQualityTests: XCTestCase {
    func testReducedSizeOnlyAppliesWhenThePictureIsBiggerThanTheLimit() {
        // 4K down to 1080 and to 960, aspect preserved, dimensions even.
        let medium = SequenceComposition.reducedRenderSize(width: 3840, height: 2160, longEdgeLimit: 1920)
        XCTAssertEqual(medium, CGSize(width: 1920, height: 1080))
        let low = SequenceComposition.reducedRenderSize(width: 3840, height: 2160, longEdgeLimit: 960)
        XCTAssertEqual(low, CGSize(width: 960, height: 540))

        // Already at or below the limit: nothing to do, and saying so is what
        // keeps the player on one composition instead of swapping needlessly.
        XCTAssertNil(SequenceComposition.reducedRenderSize(width: 1920, height: 1080, longEdgeLimit: 1920))
        XCTAssertNil(SequenceComposition.reducedRenderSize(width: 1280, height: 720, longEdgeLimit: 1920))
        XCTAssertNil(SequenceComposition.reducedRenderSize(width: 0, height: 0, longEdgeLimit: 960))
    }

    func testReducedSizesAreEvenForChromaSubsampling() {
        for limit in [960, 1920] {
            let size = SequenceComposition.reducedRenderSize(width: 4_096, height: 2_158, longEdgeLimit: limit)
            let reduced = try? XCTUnwrap(size)
            XCTAssertEqual(Int(reduced?.width ?? 1) % 2, 0)
            XCTAssertEqual(Int(reduced?.height ?? 1) % 2, 0)
        }
    }

    /// Portrait footage is limited on its long edge too, which is its height.
    func testPortraitIsLimitedOnItsLongEdge() {
        XCTAssertEqual(
            SequenceComposition.reducedRenderSize(width: 2160, height: 3840, longEdgeLimit: 1920),
            CGSize(width: 1080, height: 1920)
        )
    }

    func testFullQualityReducesNothing() {
        XCTAssertNil(PreviewQuality.full.longEdgeLimit)
        XCTAssertEqual(PreviewQuality.low.longEdgeLimit, 960)
        XCTAssertEqual(PreviewQuality.medium.longEdgeLimit, 1920)
    }

    /// The reduced copies carry the same instructions and timing as the full
    /// one, differing only in size — a composition that lost an instruction
    /// would render nothing and hold the last frame.
    func testReducedCompositionsKeepTimingAndInstructions() throws {
        let base = AVMutableVideoComposition()
        base.renderSize = CGSize(width: 3840, height: 2160)
        base.frameDuration = CMTime(value: 1, timescale: 60)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
        base.instructions = [instruction]

        let reduced = SequenceComposition.playbackCompositions(base: base, scalingTrack: nil)
        XCTAssertNil(reduced[.full], "Full quality must not produce a copy at all")
        let medium = try XCTUnwrap(reduced[.medium])
        XCTAssertEqual(medium.renderSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(medium.frameDuration, base.frameDuration)
        XCTAssertEqual(medium.instructions.count, base.instructions.count)
        XCTAssertEqual(medium.instructions.first?.timeRange, instruction.timeRange)
        XCTAssertEqual(try XCTUnwrap(reduced[.low]).renderSize, CGSize(width: 960, height: 540))
        // The full-resolution composition is what the paused picture uses, so it
        // must come through untouched.
        XCTAssertEqual(base.renderSize, CGSize(width: 3840, height: 2160))
    }

    /// A 1080p project has nothing to give up, so no copies are made and
    /// playback simply stays on the one composition.
    func testAProjectAlreadyBelowTheLimitGetsNoReducedCopies() {
        let base = AVMutableVideoComposition()
        base.renderSize = CGSize(width: 1920, height: 1080)
        base.frameDuration = CMTime(value: 1, timescale: 30)
        let reduced = SequenceComposition.playbackCompositions(base: base, scalingTrack: nil)
        XCTAssertNil(reduced[.medium])
        XCTAssertNil(reduced[.full])
        XCTAssertEqual(reduced[.low]?.renderSize, CGSize(width: 960, height: 540))
    }

    func testQualityPreferenceRoundTrips() {
        let original = PreviewQuality.load()
        defer { original.save() }
        PreviewQuality.low.save()
        XCTAssertEqual(PreviewQuality.load(), .low)
        PreviewQuality.full.save()
        XCTAssertEqual(PreviewQuality.load(), .full)
    }
}
