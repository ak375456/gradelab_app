import CoreMedia
import Foundation

/// Playback rate for one clip.
///
/// Speed is stored on the clip and everything else is derived from it, so there
/// is a single source of truth: a clip's timeline duration is always
/// `sourceRange.duration / speed`. Storing both independently would let them
/// disagree, and a clip whose duration does not match its speed would play the
/// wrong content.
enum ClipSpeed {
    /// Deliberately symmetric in log10: 0.1× and 10× are the same distance from
    /// 1× on the slider, which puts normal speed exactly in the middle of the
    /// track. An asymmetric range would leave the centre at some arbitrary rate.
    static let minimum = 0.1
    static let maximum = 10.0
    static let normal = 1.0

    /// Slider position for a speed, and back. log10 rather than a linear ramp:
    /// linearly, everything below 1× would be squeezed into the first tenth of
    /// the track and slow motion would be almost unselectable.
    static func sliderPosition(for speed: Double) -> Double { log10(clamped(speed)) }
    static func speed(atSliderPosition position: Double) -> Double { clamped(pow(10, position)) }
    static var sliderRange: ClosedRange<Double> { log10(minimum)...log10(maximum) }

    static func clamped(_ speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return normal }
        return min(max(speed, minimum), maximum)
    }

    /// The timeline duration a source range occupies at a given speed.
    ///
    /// Rounded to the source's timescale rather than to seconds, so 59.94 fps
    /// content at 2× does not accumulate drift over a long clip.
    static func timelineDuration(
        sourceDuration: TimelineTime,
        speed: Double
    ) throws -> TimelineTime {
        let scaled = CMTimeMultiplyByFloat64(sourceDuration.cmTime, multiplier: 1.0 / clamped(speed))
        return try TimelineTime(CMTimeConvertScale(
            scaled, timescale: sourceDuration.cmTime.timescale, method: .roundHalfAwayFromZero
        ))
    }

    /// The source duration that fills a given timeline duration at this speed.
    static func sourceDuration(
        timelineDuration: TimelineTime,
        speed: Double
    ) throws -> TimelineTime {
        let scaled = CMTimeMultiplyByFloat64(timelineDuration.cmTime, multiplier: clamped(speed))
        return try TimelineTime(CMTimeConvertScale(
            scaled, timescale: timelineDuration.cmTime.timescale, method: .roundHalfAwayFromZero
        ))
    }

    /// How far between two source frames a given moment falls, 0...1.
    ///
    /// This is the blend weight: 0 means sit exactly on frame N, 0.5 means
    /// halfway to N+1. Without it a retimed clip repeats each source frame,
    /// which is the stepping that makes slow motion look juddery on footage
    /// that was not shot at a high frame rate.
    static func framePhase(
        sourceTime: TimelineTime,
        sourceStart: TimelineTime,
        frameDuration: TimelineTime
    ) -> Double {
        let frame = frameDuration.seconds
        guard frame > 0 else { return 0 }
        let elapsed = sourceTime.seconds - sourceStart.seconds
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        let position = elapsed / frame
        return min(max(position - position.rounded(.down), 0), 1)
    }

    /// Presets offered in the UI. 1× is included so returning to normal is one tap.
    static let presets: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10]

    static func label(_ speed: Double) -> String {
        let rounded = (speed * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.0f×", rounded)
        }
        if (rounded * 10).rounded() == rounded * 10 {
            return String(format: "%.1f×", rounded)
        }
        return String(format: "%.2f×", rounded)
    }
}
