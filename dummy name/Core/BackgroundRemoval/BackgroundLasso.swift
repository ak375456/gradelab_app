import CoreGraphics
import Foundation

/// One hand-drawn outline, authored on a single frame.
///
/// The polygon *is* the selection: whatever it encloses is kept and everything
/// outside it becomes transparent. `BackgroundRemovalSettings.isInverted`
/// flips that, so "cut out the thing I drew around" costs a toggle rather than
/// a second tool. Nothing here is generated: an outline survives a reopen, an
/// undo and a duplicate exactly as the user drew it.
struct BackgroundLassoSelection: Codable, Equatable, Sendable {
    /// Enough points for a smooth finger-drawn outline, few enough that a
    /// project document stays a document.
    static let maximumPoints = 512

    /// Source-normalized, top-left. Implicitly closed; the closing edge is
    /// never stored, so the first point is not duplicated at the end.
    var points: [MaskPoint] = []
    /// The source frame the outline was drawn on. Tracking begins here.
    var sourceTime: TimelineTime?
    /// That same instant in clip-local time, which is what `motion` is keyed
    /// to, so a head trim or a split moves the tracked outline exactly as it
    /// moves every other clip-local keyframe.
    var localTime: TimelineTime?
    /// Motion measured by the tracker. Empty means the outline is fixed in the
    /// frame, which is what a still and a locked-off shot both want.
    var motion: [BackgroundLassoMotionSample] = []

    var isDrawn: Bool { points.count >= 3 }
    var isTracked: Bool { motion.count > 1 }

    /// The pivot that tracked scale acts around: the centre of the outline as
    /// drawn, which is also the centre of the box handed to Vision.
    var anchorCenter: CGPoint {
        let box = bounds
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// Bounding box of the authored outline, in source-normalized coordinates.
    var bounds: CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The outline as it sits at a clip-local instant, with tracked motion
    /// applied. Outside the tracked span the nearest sample is held rather
    /// than extrapolated: holding is visibly wrong in a predictable place,
    /// while extrapolation slides the cutout somewhere nobody authored.
    func outline(atLocal local: TimelineTime?) -> [CGPoint] {
        let placed = points.map { CGPoint(x: $0.x, y: $0.y) }
        guard let sample = motionSample(atLocal: local) else { return placed }
        let centre = anchorCenter
        return placed.map {
            CGPoint(x: centre.x + sample.offsetX + ($0.x - centre.x) * sample.scaleX,
                    y: centre.y + sample.offsetY + ($0.y - centre.y) * sample.scaleY)
        }
    }

    /// The tracked transform at an instant, linearly interpolated between the
    /// two surrounding samples. Nil when this outline was never tracked.
    func motionSample(atLocal local: TimelineTime?) -> BackgroundLassoMotionSample? {
        guard let local, motion.count > 1 else { return motion.first }
        if local <= motion[0].time { return motion[0] }
        guard let last = motion.last else { return nil }
        if local >= last.time { return last }
        var low = 0, high = motion.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if motion[middle].time <= local { low = middle } else { high = middle }
        }
        let before = motion[low], after = motion[high]
        let span = after.time.seconds - before.time.seconds
        guard span > 0 else { return before }
        let f = (local.seconds - before.time.seconds) / span
        return before.interpolated(towards: after, fraction: f)
    }

    var clamped: BackgroundLassoSelection {
        var value = self
        // A lasso may legitimately run past the frame edge when the subject
        // touches it, so points are bounded generously rather than to 0...1.
        value.points = Array(value.points.prefix(Self.maximumPoints)).map {
            MaskPoint(x: min(max($0.x.isFinite ? $0.x : 0.5, -0.5), 1.5),
                      y: min(max($0.y.isFinite ? $0.y : 0.5, -0.5), 1.5))
        }
        value.motion = Array(value.motion.prefix(BackgroundLassoMotionSample.limit))
            .map(\.clamped).sorted { $0.time < $1.time }
        return value
    }

    /// Turns a raw drag into a storable outline: duplicate points removed, the
    /// count bounded, then one light smoothing pass. Finger tracking is noisy
    /// at the pixel level and that noise reads as a ragged cutout edge, which
    /// is the one thing a lasso must not have.
    static func authored(_ raw: [MaskPoint]) -> [MaskPoint] {
        var spaced: [MaskPoint] = []
        for point in raw {
            guard let last = spaced.last else { spaced.append(point); continue }
            if hypot(point.x - last.x, point.y - last.y) >= 0.0025 { spaced.append(point) }
        }
        // Drop a closing point that lands back on the start: the polygon is
        // closed by definition and a doubled vertex pinches the smoothing.
        if spaced.count > 3, let first = spaced.first, let last = spaced.last,
           hypot(first.x - last.x, first.y - last.y) < 0.0025 { spaced.removeLast() }
        guard spaced.count >= 3 else { return spaced }
        if spaced.count > maximumPoints {
            let stride = Double(spaced.count) / Double(maximumPoints)
            spaced = (0..<maximumPoints).map { spaced[min(spaced.count - 1, Int(Double($0) * stride))] }
        }
        return smoothed(spaced)
    }

    /// One three-tap pass around the closed ring. Deliberately mild: it takes
    /// the tremor off a traced edge without rounding off a corner the user
    /// drew on purpose.
    private static func smoothed(_ points: [MaskPoint]) -> [MaskPoint] {
        guard points.count >= 5 else { return points }
        return points.indices.map { index in
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            let current = points[index]
            return MaskPoint(x: previous.x * 0.25 + current.x * 0.5 + next.x * 0.25,
                             y: previous.y * 0.25 + current.y * 0.5 + next.y * 0.25)
        }
    }
}

/// Where the tracked object sits at one clip-local instant, relative to the
/// frame the outline was drawn on. The anchor frame is always (0, 0, 1, 1).
///
/// Offset and scale, not a full matrix: Vision reports an axis-aligned box, so
/// claiming rotation or shear would be inventing measurements it never made.
struct BackgroundLassoMotionSample: Codable, Equatable, Sendable {
    /// The same bound `AnimationTrack` uses, for the same reason: a document
    /// must not grow without limit because a long clip was tracked.
    static let limit = 4_000

    var time: TimelineTime
    var offsetX: Double = 0
    var offsetY: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1

    var clamped: BackgroundLassoMotionSample {
        var value = self
        value.offsetX = min(max(offsetX.isFinite ? offsetX : 0, -2), 2)
        value.offsetY = min(max(offsetY.isFinite ? offsetY : 0, -2), 2)
        value.scaleX = min(max(scaleX.isFinite ? scaleX : 1, 0.05), 20)
        value.scaleY = min(max(scaleY.isFinite ? scaleY : 1, 0.05), 20)
        return value
    }

    func interpolated(towards other: BackgroundLassoMotionSample,
                      fraction: Double) -> BackgroundLassoMotionSample {
        let f = min(max(fraction, 0), 1)
        return .init(time: time,
                     offsetX: offsetX + (other.offsetX - offsetX) * f,
                     offsetY: offsetY + (other.offsetY - offsetY) * f,
                     scaleX: scaleX + (other.scaleX - scaleX) * f,
                     scaleY: scaleY + (other.scaleY - scaleY) * f)
    }

    /// One three-tap pass over the interior samples.
    ///
    /// Vision's box jitters by a pixel or two even on a subject that is not
    /// moving, and that jitter reads as the cutout edge vibrating. Both ends
    /// and the anchor are never averaged — the anchor is the frame the user
    /// actually drew on, so it must stay exactly where they put it.
    static func smoothed(_ samples: [BackgroundLassoMotionSample],
                         anchor: TimelineTime?) -> [BackgroundLassoMotionSample] {
        guard samples.count > 4 else { return samples }
        var result = samples
        for index in 1..<(samples.count - 1) where samples[index].time != anchor {
            let previous = samples[index - 1], current = samples[index], next = samples[index + 1]
            result[index].offsetX = previous.offsetX * 0.25 + current.offsetX * 0.5 + next.offsetX * 0.25
            result[index].offsetY = previous.offsetY * 0.25 + current.offsetY * 0.5 + next.offsetY * 0.25
            result[index].scaleX = previous.scaleX * 0.25 + current.scaleX * 0.5 + next.scaleX * 0.25
            result[index].scaleY = previous.scaleY * 0.25 + current.scaleY * 0.5 + next.scaleY * 0.25
        }
        return result
    }

    /// Drops samples that linear interpolation already predicts. A locked-off
    /// shot collapses to two samples and a smooth pan to a handful, so the
    /// stored motion is proportional to how much the subject actually moved
    /// rather than to how many frames were read.
    static func simplified(_ samples: [BackgroundLassoMotionSample], anchor: TimelineTime?,
                           tolerance: Double = 0.0004) -> [BackgroundLassoMotionSample] {
        guard samples.count > 2 else { return samples }
        // A very long clip is thinned evenly before the search rather than by
        // it. The search is quadratic in the worst case, and a ten-minute
        // 60fps track would otherwise spend longer being tidied than it spent
        // being measured.
        let bounded = samples.count > limit * 2 ? thinned(samples, to: limit * 2) : samples
        // CMTime to seconds is a function call, and the search below visits
        // each sample many times across several passes, so the clock
        // conversion happens exactly once per sample.
        let times = bounded.map(\.time.seconds)
        let anchorIndex = anchor.flatMap { value in bounded.firstIndex { $0.time == value } }
        let kept = search(bounded, times: times, anchorIndex: anchorIndex, tolerance: tolerance)
            .map { bounded[$0] }
        // One search, then even thinning if motion this erratic still will not
        // fit. Re-running the search at looser and looser tolerances would
        // pick marginally better samples for several times the work, and
        // dropping the tail instead would stop the cutout partway through a
        // shot with nothing on screen to explain why.
        return kept.count > limit ? thinned(kept, to: limit) : kept
    }

    /// Douglas-Peucker over the four tracked channels at once, returning the
    /// indices worth keeping. The first, last and anchor samples are fixed:
    /// the anchor is the frame the user actually drew on.
    private static func search(_ samples: [BackgroundLassoMotionSample], times: [Double],
                               anchorIndex: Int?, tolerance: Double) -> [Int] {
        var keep = Set([0, samples.count - 1])
        if let anchorIndex { keep.insert(anchorIndex) }
        let fixed = keep.sorted()
        var segments = zip(fixed, fixed.dropFirst()).map { ($0, $1) }
        while let (start, end) = segments.popLast() {
            guard end > start + 1 else { continue }
            let span = times[end] - times[start]
            guard span > 0 else { continue }
            let first = samples[start], last = samples[end]
            var worst = tolerance
            var candidate: Int?
            for index in (start + 1)..<end {
                let f = (times[index] - times[start]) / span
                let actual = samples[index]
                // Scale error is halved against offset error so a 1% size
                // change weighs about as much as a 1%-of-frame slide.
                let error = max(
                    abs(actual.offsetX - (first.offsetX + (last.offsetX - first.offsetX) * f)),
                    abs(actual.offsetY - (first.offsetY + (last.offsetY - first.offsetY) * f)),
                    abs(actual.scaleX - (first.scaleX + (last.scaleX - first.scaleX) * f)) * 0.5,
                    abs(actual.scaleY - (first.scaleY + (last.scaleY - first.scaleY) * f)) * 0.5)
                if error > worst { worst = error; candidate = index }
            }
            guard let candidate else { continue }
            keep.insert(candidate)
            segments.append((start, candidate)); segments.append((candidate, end))
        }
        return keep.sorted()
    }

    /// Evenly spaced thinning that always keeps both ends.
    private static func thinned(_ samples: [BackgroundLassoMotionSample],
                                to count: Int) -> [BackgroundLassoMotionSample] {
        guard samples.count > count, count > 1 else { return samples }
        let step = Double(samples.count - 1) / Double(count - 1)
        return (0..<count).map { samples[min(samples.count - 1, Int((Double($0) * step).rounded()))] }
    }
}
