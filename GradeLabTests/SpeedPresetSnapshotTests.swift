import SwiftUI
import XCTest
@testable import GradeLab

/// The preset tiles, and the curve each one previews.
///
/// The tile IS the control — a name like "Hero" says nothing about a shape, so
/// the picture is what the choice is made from. These check that the picture is
/// the truth and that no two presets draw the same thing.
final class SpeedPresetTests: XCTestCase {

    func testEveryPresetProducesACurveThatActuallyMoves() throws {
        for preset in TimeRemap.presets {
            let speeds = preset.previewSpeeds()
            XCTAssertGreaterThan(speeds.count, 8, "\(preset.title) drew almost nothing")
            let low = try XCTUnwrap(speeds.min()), high = try XCTUnwrap(speeds.max())
            XCTAssertGreaterThan(high / low, 1.5,
                                 "\(preset.title) is nearly flat, so its tile says nothing")
            for speed in speeds {
                XCTAssertGreaterThanOrEqual(speed, ClipSpeed.minimum, "\(preset.title)")
                XCTAssertLessThanOrEqual(speed, ClipSpeed.maximum, "\(preset.title)")
            }
        }
    }

    /// Two tiles that draw the same shape are two tiles the user cannot choose
    /// between.
    func testNoTwoPresetsDrawTheSameShape() throws {
        let shapes = TimeRemap.presets.map { ($0.title, $0.previewSpeeds()) }
        for (indexA, a) in shapes.enumerated() {
            for b in shapes[(indexA + 1)...] {
                let difference = zip(a.1, b.1).map { abs($0 - $1) }.max() ?? 0
                XCTAssertGreaterThan(difference, 0.2, "\(a.0) and \(b.0) look the same")
            }
        }
    }

    /// The tile is sampled from a real `TimeMap`, so it must agree with what
    /// the clip will actually do — not with the authored control points.
    func testTheTileAgreesWithTheClipThePresetMakes() throws {
        var project = VideoProject(
            sourceURL: URL(fileURLWithPath: "/tmp/a.mov"), displayName: "a",
            metadata: makeVideoMetadata(durationSeconds: 10, nominalFrameRate: 30,
                                        minimumFrameDurationSeconds: 1.0 / 30.0))
        let id = try XCTUnwrap(TimelineEditing.clips(in: project).first).id
        for preset in TimeRemap.presets {
            try TimelineEditing.applySpeedPreset(id, preset: preset, in: &project)
            let clip = try XCTUnwrap(project.timeline.videoClip(id: id))
            let map = clip.timeMap
            let drawn = preset.previewSpeeds()
            // The position is taken FROM the drawn array rather than chosen
            // and then converted back into an index. A tenth of the way along
            // is not the same place as sample nine of ninety-six, and on the
            // steep part of a ramp those two places genuinely have different
            // rates — which made this compare the curve against itself half a
            // sample out.
            for index in [10, 30, 48, 67, 86] {
                let step = Double(index) / Double(drawn.count - 1)
                let at = try TimelineTime.seconds(map.timelineDuration.seconds * step)
                let actual = map.speed(atTimelineOffset: at)
                XCTAssertEqual(drawn[index], actual, accuracy: max(0.05, actual * 0.05),
                               "\(preset.title) draws \(drawn[index]) at \(step) but plays \(actual)")
            }
        }
    }

    /// The axis a tile is drawn on is fixed, not fitted to each preset: a gentle
    /// ramp and a violent one have to look different from each other.
    func testTheTileAxisIsSharedRatherThanNormalised() {
        let gentle = SpeedCurveGeometry.fraction(forSpeed: 1.2)
        let violent = SpeedCurveGeometry.fraction(forSpeed: 8)
        XCTAssertGreaterThan(violent - gentle, 0.2)
    }
}
