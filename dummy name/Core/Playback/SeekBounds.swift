//
//  SeekBounds.swift
//  GradeLab
//

import Foundation

/// Where the playhead is allowed to land when someone seeks.
///
/// `duration` is the end of the final frame rather than its presentation time,
/// so a seek to it lands one frame past the last sample and the compositor has
/// nothing to produce — the picture goes black. Playing to the end never showed
/// this, because AVPlayer holds its last decoded frame on the layer; only an
/// explicit seek exposes it, which is why stepping to the end of a clip went
/// black while watching it end did not.
///
/// Playback is deliberately not bounded by this. `currentTime` has to stay free
/// to reach `duration`, or the end-of-item observers never see the end arrive.
struct SeekBounds: Equatable {
    /// The start of the playable range. A trimmed source begins above zero.
    var minimumTime: Double
    /// The end of the final frame.
    var duration: Double
    /// The composed cadence, or zero while it is still unknown.
    var frameDuration: Double

    /// The cadence to reason with. The fallback covers the window between
    /// opening a project and building its sequence, when nothing has yet said
    /// what the timeline runs at.
    private var step: Double { frameDuration > 0 ? frameDuration : 1.0 / 30 }

    /// Where the final frame begins: the last position that renders a picture.
    var lastFrameTime: Double { max(minimumTime, duration - step) }

    /// How near `duration` still counts as "at the end", for deciding that play
    /// should start over rather than resume where it stands. It has to clear a
    /// whole frame, because a seek can no longer put the playhead any closer to
    /// the end than `lastFrameTime`.
    var endThreshold: Double { max(minimumTime, duration - Swift.max(0.05, step * 1.5)) }

    func clamped(_ seconds: Double) -> Double {
        let value = seconds.isFinite ? seconds : minimumTime
        return min(max(value, minimumTime), lastFrameTime)
    }
}
