@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// The one conversion between a clip's timeline and its source.
///
/// **Everything goes through this.** The viewer, scrubbing, playback, audio,
/// grading, masks, tracking, keyframes, export, thumbnails and waveforms all
/// ask this the same two questions, so there is exactly one answer about which
/// picture belongs at which moment. A second implementation anywhere is a bug
/// waiting for a ramp to expose it.
///
/// ## Why the curve is indexed by source position
///
/// The speed curve is a function of the **source** offset, and the clip's
/// timeline length is the integral of its reciprocal. Indexing the curve by
/// timeline position instead would be circular — the curve would define its own
/// domain — and it would also mean a speed point slid along the picture every
/// time an earlier point changed. A speed point marks a moment in the shot, so
/// it is stored against that moment.
///
/// ## Why there is a table
///
/// `1/speed` has no closed-form integral once easing and Bezier handles are in
/// it, and both directions are needed on every frame. So the integral is
/// evaluated once, into a monotone table, and both lookups are a binary search
/// plus a linear step inside one cell. The table is built the same way for
/// preview and for export, which is what makes them frame-identical rather than
/// merely similar.
///
/// ## Why the accumulation is integer
///
/// Every cell's contribution is rounded to a whole tick of
/// `TimelineTime.projectTimescale` and added as an `Int64`. Accumulating
/// `Double` seconds instead drifts, and over a long clip the drift is frames.
/// Requirement: a two-hour project stays frame accurate.
struct TimeMap: Equatable, Sendable {
    /// Source and timeline offsets in whole project ticks, both measured from
    /// the clip's own start. `source` is non-decreasing; `timeline` is strictly
    /// increasing except across a freeze, where `source` repeats instead.
    private let source: [Int64]
    private let timeline: [Int64]
    private let reverses: Bool
    /// The clip's whole source span, in ticks.
    private let sourceSpan: Int64

    static let timescale = TimelineTime.projectTimescale

    /// Samples per second of source used to build the table.
    ///
    /// 240 puts at least four samples inside every frame of 60 fps material,
    /// which is finer than any curve a hand can draw. Each cell is integrated
    /// with Simpson's rule on top of that, so the error is in the seventh
    /// decimal place of a second — orders of magnitude below a tick.
    private static let samplesPerSecond = 240.0
    /// Ceiling on table size. At eight bytes a side, this is 256KB for a clip
    /// over an hour long, and the sample spacing only relaxes past that.
    private static let maximumSamples = 16_384

    // MARK: - Construction

    /// The identity map: timeline and source advance together.
    static func identity(sourceDuration: TimelineTime) -> TimeMap {
        let span = ticks(sourceDuration)
        return TimeMap(source: [0, span], timeline: [0, span], reverses: false, sourceSpan: span)
    }

    /// The map for a constant rate, without building a table.
    ///
    /// Two points is the exact answer for a straight line, and constant speed is
    /// overwhelmingly the common case — a clip that has never been ramped must
    /// not pay for a table it would only read a straight line out of.
    static func constant(speed: Double, sourceDuration: TimelineTime, reverses: Bool = false) -> TimeMap {
        let span = ticks(sourceDuration)
        let rate = ClipSpeed.clamped(speed)
        let length = Int64((Double(span) / rate).rounded())
        return TimeMap(source: [0, span], timeline: [0, max(0, length)],
                       reverses: reverses, sourceSpan: span)
    }

    /// Builds the map for one clip's retiming.
    init(remap: TimeRemap, sourceDuration: TimelineTime) {
        let span = Self.ticks(sourceDuration)
        self.sourceSpan = span
        self.reverses = remap.reverses

        let points = remap.resolvedPoints(sourceDuration: sourceDuration)
        let freezes = remap.resolvedFreezes(sourceDuration: sourceDuration)

        guard span > 0 else {
            source = [0, 0]; timeline = [0, 0]; return
        }

        // No curve and no freezes: a straight line, exactly, with no sampling
        // error at all.
        guard !points.isEmpty || !freezes.isEmpty else {
            let rate = ClipSpeed.clamped(remap.constantSpeed)
            source = [0, span]
            timeline = [0, max(0, Int64((Double(span) / rate).rounded()))]
            return
        }

        let seconds = Double(span) / Double(Self.timescale)
        let cells = min(Self.maximumSamples,
                        max(2, Int((seconds * Self.samplesPerSecond).rounded(.up))))

        // Holds, as source intervals with their own rate. A freeze is not a
        // special case in the integration — it is one frame of source taking a
        // second of timeline, which is simply a very low rate over a very short
        // interval, and the rest of this function never learns about it.
        let holds: [(start: Double, end: Double, rate: Double)] = freezes.map { freeze in
            let at = Double(Self.ticks(freeze.sourceOffset))
            let width = Double(Self.ticks(freeze.sourceWidth))
            let start = remap.reverses ? Double(span) - at - width : at
            return (start, start + width, freeze.rate)
        }

        // Speed at a source offset in ticks, reading the curve mirrored when the
        // clip is reversed so the ramp stays glued to the picture rather than to
        // the direction of travel.
        let fallback = ClipSpeed.clamped(remap.constantSpeed)
        func speed(atTick tick: Double) -> Double {
            for hold in holds where tick >= hold.start && tick < hold.end { return hold.rate }
            let position = remap.reverses ? Double(span) - tick : tick
            return Self.speed(atSourceTick: position, points: points, fallback: fallback)
        }

        // Cell boundaries. Uniform across the source, plus a boundary on each
        // edge of every hold: a freeze is a fraction of a frame wide and a
        // uniform grid would sample straight across it, integrating a
        // thirty-times stretch as if it were not there.
        var boundaries: [Double] = (0...cells).map { Double(span) * Double($0) / Double(cells) }
        for hold in holds {
            boundaries.append(min(max(hold.start, 0), Double(span)))
            boundaries.append(min(max(hold.end, 0), Double(span)))
        }
        boundaries.sort()

        var sourceTicks: [Int64] = []
        var timelineTicks: [Int64] = []
        sourceTicks.reserveCapacity(boundaries.count)
        timelineTicks.reserveCapacity(boundaries.count)

        var elapsed: Int64 = 0
        var previousTick = boundaries.first ?? 0
        sourceTicks.append(Int64(previousTick.rounded()))
        timelineTicks.append(0)

        for tick in boundaries.dropFirst() {
            let width = tick - previousTick
            guard width > 0 else { continue }
            // Simpson's rule over 1/speed across the cell. The three samples are
            // the two ends and the middle, which integrates any cubic exactly —
            // and every easing curve here is at most cubic. The midpoint is what
            // is sampled for a hold, since the end of a cell that ends on a
            // hold boundary belongs to whatever is on the other side of it.
            let a = 1 / speed(atTick: previousTick)
            let b = 1 / speed(atTick: (previousTick + tick) / 2)
            let c = 1 / speed(atTick: min(tick, previousTick + width * 0.999999))
            let contribution = width * (a + 4 * b + c) / 6
            elapsed += Int64(contribution.rounded())
            sourceTicks.append(Int64(tick.rounded()))
            timelineTicks.append(elapsed)
            previousTick = tick
        }

        source = sourceTicks
        timeline = timelineTicks
    }

    private init(source: [Int64], timeline: [Int64], reverses: Bool, sourceSpan: Int64) {
        self.source = source
        self.timeline = timeline
        self.reverses = reverses
        self.sourceSpan = sourceSpan
    }

    // MARK: - The two questions

    /// The clip's length on the timeline.
    var timelineDuration: TimelineTime {
        Self.time(timeline.last ?? 0)
    }

    /// The clip's source span.
    var sourceDuration: TimelineTime { Self.time(sourceSpan) }

    /// True when timeline and source advance together and nothing needs remapping.
    var isIdentity: Bool {
        !reverses && source.count == 2 && source == timeline
    }

    /// Source offset shown at a clip-local timeline offset.
    ///
    /// Clamped at both ends: a request outside the clip is answered with its
    /// first or last frame rather than with a position the media does not have.
    func sourceOffset(atTimelineOffset offset: TimelineTime) -> TimelineTime {
        let base = forwardSource(atTimelineTicks: Self.ticks(offset))
        return Self.time(reverses ? sourceSpan - base : base)
    }

    /// Clip-local timeline offset at which a source offset is shown.
    ///
    /// The inverse of the above, and exact to a tick on the same table, which is
    /// what lets a tracked mask, a thumbnail and the picture agree about which
    /// frame a moment holds.
    func timelineOffset(atSourceOffset offset: TimelineTime) -> TimelineTime {
        let requested = Self.ticks(offset)
        let target = reverses ? sourceSpan - requested : requested
        return Self.time(forwardTimeline(atSourceTicks: target))
    }

    /// Playback rate at a clip-local timeline offset, for readouts and tooltips.
    ///
    /// Measured off the table rather than off the curve, so it reports what the
    /// clip actually does — including zero inside a freeze, which the curve has
    /// no way to say.
    func speed(atTimelineOffset offset: TimelineTime) -> Double {
        let ticks = Self.ticks(offset)
        guard timeline.count > 1 else { return ClipSpeed.normal }
        let index = min(timeline.count - 2, max(0, cell(in: timeline, for: ticks)))
        let timelineWidth = timeline[index + 1] - timeline[index]
        guard timelineWidth > 0 else { return 0 }
        let sourceWidth = source[index + 1] - source[index]
        return Double(sourceWidth) / Double(timelineWidth)
    }

    /// The source distance consumed by the first `duration` of timeline.
    ///
    /// What a right-edge trim and the left half of a split need.
    func sourceDuration(forTimelineDuration duration: TimelineTime) -> TimelineTime {
        let base = forwardSource(atTimelineTicks: Self.ticks(duration))
        // Reversal does not change how MUCH source a span consumes, only which
        // end it is taken from, so this deliberately reads the forward table.
        return Self.time(base)
    }

    /// The timeline length the first `duration` of source occupies.
    func timelineDuration(forSourceDuration duration: TimelineTime) -> TimelineTime {
        Self.time(forwardTimeline(atSourceTicks: Self.ticks(duration)))
    }

    // MARK: - Table lookups

    private func forwardSource(atTimelineTicks ticks: Int64) -> Int64 {
        guard let first = timeline.first, let last = timeline.last else { return 0 }
        if ticks <= first { return source.first ?? 0 }
        if ticks >= last { return source.last ?? sourceSpan }
        let index = cell(in: timeline, for: ticks)
        let width = timeline[index + 1] - timeline[index]
        guard width > 0 else { return source[index] }
        let fraction = Double(ticks - timeline[index]) / Double(width)
        let span = Double(source[index + 1] - source[index])
        return source[index] + Int64((span * fraction).rounded())
    }

    private func forwardTimeline(atSourceTicks ticks: Int64) -> Int64 {
        guard let first = source.first, let last = source.last else { return 0 }
        if ticks <= first { return timeline.first ?? 0 }
        if ticks >= last { return timeline.last ?? 0 }
        let index = cell(in: source, for: ticks)
        let width = source[index + 1] - source[index]
        // A freeze is a pair of entries at the same source position. Landing on
        // one means the frame is held; the LATER timeline position is the right
        // answer, so that the frames after it are not placed inside the hold.
        guard width > 0 else { return timeline[index + 1] }
        let fraction = Double(ticks - source[index]) / Double(width)
        let span = Double(timeline[index + 1] - timeline[index])
        return timeline[index] + Int64((span * fraction).rounded())
    }

    /// Index of the cell containing `value`, i.e. the largest `i` with
    /// `table[i] <= value`, bounded so `i + 1` is always addressable.
    private func cell(in table: [Int64], for value: Int64) -> Int {
        var low = 0, high = table.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if table[mid] <= value { low = mid } else { high = mid - 1 }
        }
        return min(max(0, low), table.count - 2)
    }

    // MARK: - Curve evaluation

    /// Speed at a source position, from the sorted points.
    static func speed(atSourceTick tick: Double, points: [SpeedPoint], fallback: Double) -> Double {
        guard let first = points.first, let last = points.last else { return fallback }
        let firstTick = Double(ticks(first.sourceOffset))
        let lastTick = Double(ticks(last.sourceOffset))
        // Outside the points the curve is flat. Extrapolating instead would let
        // a ramp near one end invent a rate nobody asked for at the other.
        if tick <= firstTick { return first.speed }
        if tick >= lastTick { return last.speed }
        var index = 0
        for candidate in 0..<(points.count - 1) where Double(ticks(points[candidate].sourceOffset)) <= tick {
            index = candidate
        }
        let left = points[index], right = points[index + 1]
        let leftTick = Double(ticks(left.sourceOffset))
        let width = Double(ticks(right.sourceOffset)) - leftTick
        guard width > 0 else { return right.speed }
        let x = (tick - leftTick) / width
        let eased = left.interpolation.eased(x, outgoing: left.outgoingHandle,
                                             incoming: right.incomingHandle)
        return ClipSpeed.clamped(left.speed + (right.speed - left.speed) * eased)
    }

    // MARK: - Table access for segment building

    /// Number of entries in the table. Cells are the gaps between them.
    fileprivate var sourceCellCount: Int { source.count }
    fileprivate func sourceTick(at index: Int) -> Int64 {
        source[min(max(0, index), source.count - 1)]
    }
    fileprivate func timelineTick(at index: Int) -> Int64 {
        timeline[min(max(0, index), timeline.count - 1)]
    }
    fileprivate static func exposedTime(_ ticks: Int64) -> TimelineTime { time(ticks) }
    fileprivate static func rawTicks(_ value: TimelineTime) -> Int64 { ticks(value) }

    // MARK: - Tick conversion

    private static func ticks(_ time: TimelineTime) -> Int64 {
        let converted = CMTimeConvertScale(time.cmTime, timescale: timescale,
                                           method: .roundHalfAwayFromZero)
        return converted.isNumeric ? converted.value : 0
    }

    private static func time(_ ticks: Int64) -> TimelineTime {
        (try? TimelineTime(value: max(0, ticks), timescale: timescale)) ?? .zero
    }
}

// MARK: - Memoisation

extension TimeMap {
    /// A ramped clip's table is rebuilt for every question that is asked of it,
    /// and the compositor asks one per clip per frame. Building sixteen thousand
    /// cells sixty times a second is not something a phone can do, so the tables
    /// are kept.
    ///
    /// The key is the retiming itself, reduced to integers — not the clip id.
    /// Two clips with the same ramp share one table, a split produces two clips
    /// that each find their own, and changing any part of a curve misses and
    /// rebuilds. Nothing here needs invalidating, because nothing here can go
    /// stale: a different answer has a different key.
    private struct Key: Hashable {
        let sourceTicks: Int64
        let constant: Double
        let reverses: Bool
        let points: [Int64]
        let speeds: [Double]
        let shapes: [String]
        let handles: [Double]
        let freezes: [Int64]
    }

    private final class Store: @unchecked Sendable {
        static let shared = Store()
        private let lock = NSLock()
        private var maps: [Key: TimeMap] = [:]
        private var order: [Key] = []
        /// Enough for every clip in a busy timeline plus the states a drag
        /// passes through, and small enough that the tables themselves stay
        /// well under a megabyte.
        private let limit = 48

        func map(for key: Key, build: () -> TimeMap) -> TimeMap {
            lock.lock()
            if let existing = maps[key] { lock.unlock(); return existing }
            lock.unlock()
            let built = build()
            lock.lock()
            if maps[key] == nil {
                maps[key] = built
                order.append(key)
                while order.count > limit { maps.removeValue(forKey: order.removeFirst()) }
            }
            lock.unlock()
            return built
        }
    }

    /// The map for this retiming, built once and then remembered.
    static func cached(remap: TimeRemap, sourceDuration: TimelineTime) -> TimeMap {
        let points = remap.points
        let freezes = remap.freezes
        // The straight-line cases cost less to build than to look up.
        guard !points.isEmpty || !freezes.isEmpty else {
            return .constant(speed: remap.constantSpeed, sourceDuration: sourceDuration,
                             reverses: remap.reverses)
        }
        let key = Key(
            sourceTicks: CMTimeConvertScale(sourceDuration.cmTime, timescale: timescale,
                                            method: .roundHalfAwayFromZero).value,
            constant: remap.constantSpeed,
            reverses: remap.reverses,
            points: points.map {
                CMTimeConvertScale($0.sourceOffset.cmTime, timescale: timescale,
                                   method: .roundHalfAwayFromZero).value
            },
            speeds: points.map(\.speed),
            shapes: points.map(\.interpolation.rawValue),
            handles: points.flatMap {
                [$0.outgoingHandle.dx, $0.outgoingHandle.dy,
                 $0.incomingHandle.dx, $0.incomingHandle.dy]
            },
            freezes: freezes.flatMap {
                [CMTimeConvertScale($0.sourceOffset.cmTime, timescale: timescale,
                                    method: .roundHalfAwayFromZero).value,
                 CMTimeConvertScale($0.duration.cmTime, timescale: timescale,
                                    method: .roundHalfAwayFromZero).value]
            })
        return Store.shared.map(for: key) {
            TimeMap(remap: remap, sourceDuration: sourceDuration)
        }
    }
}

// MARK: - Scheduling a ramp on a composition track

/// One constant-rate piece of a ramp, as an edit list can express it.
struct RetimeSegment: Equatable, Sendable {
    /// Where this piece starts, measured from the clip's source range start.
    var sourceOffset: TimelineTime
    var sourceDuration: TimelineTime
    var timelineDuration: TimelineTime

    var rate: Double {
        let timeline = timelineDuration.seconds
        guard timeline > 0 else { return ClipSpeed.normal }
        return sourceDuration.seconds / timeline
    }
}

extension TimeMap {
    /// The map as a list of constant-rate pieces.
    ///
    /// `AVMutableCompositionTrack.scaleTimeRange` expresses one rate over one
    /// range, so a curve reaches AVFoundation as a staircase. The step height is
    /// what matters, not the step count: cells are merged while the rate stays
    /// within `tolerance` of the piece being built, so a flat stretch costs one
    /// segment and only the bends spend them.
    ///
    /// At the default 1.5% a ramp is smooth well past what anyone can see —
    /// speed changes of that size are below the threshold at which motion reads
    /// as stepping — while a typical ramp lands in the low tens of segments
    /// rather than one per frame.
    ///
    /// The last piece absorbs every rounding remainder, so the pieces always sum
    /// to exactly `timelineDuration`. A clip whose segments summed to one tick
    /// less than its placement would leave the composition's last instruction
    /// uncovered, and AVFoundation answers that by rendering nothing at all.
    func retimeSegments(maximumCount: Int = 320, tolerance: Double = 0.015) -> [RetimeSegment] {
        guard !isIdentity, sourceCellCount > 1 else { return [] }

        var segments: [RetimeSegment] = []
        var startIndex = 0
        var index = 1

        func flush(to end: Int) {
            let sourceStart = sourceTick(at: startIndex), sourceEnd = sourceTick(at: end)
            let timelineStart = timelineTick(at: startIndex), timelineEnd = timelineTick(at: end)
            guard sourceEnd > sourceStart, timelineEnd > timelineStart else { return }
            segments.append(RetimeSegment(
                sourceOffset: Self.exposedTime(sourceStart),
                sourceDuration: Self.exposedTime(sourceEnd - sourceStart),
                timelineDuration: Self.exposedTime(timelineEnd - timelineStart)))
            startIndex = end
        }

        while index < sourceCellCount {
            let runningSource = sourceTick(at: index) - sourceTick(at: startIndex)
            let runningTimeline = timelineTick(at: index) - timelineTick(at: startIndex)
            let cellSource = sourceTick(at: index) - sourceTick(at: index - 1)
            let cellTimeline = timelineTick(at: index) - timelineTick(at: index - 1)
            if runningTimeline > 0, cellTimeline > 0 {
                let running = Double(runningSource) / Double(runningTimeline)
                let cell = Double(cellSource) / Double(cellTimeline)
                if running > 0, abs(cell - running) / running > tolerance {
                    flush(to: index - 1)
                }
            }
            index += 1
        }
        flush(to: sourceCellCount - 1)

        guard !segments.isEmpty else { return [] }

        // Too many pieces is a performance problem rather than a correctness
        // one, so an over-long list is thinned by merging neighbours rather than
        // truncated — truncating would lose the end of the clip.
        while segments.count > maximumCount {
            var merged: [RetimeSegment] = []
            var pending: RetimeSegment?
            for segment in segments {
                if var held = pending {
                    held.sourceDuration = (try? held.sourceDuration.adding(segment.sourceDuration)) ?? held.sourceDuration
                    held.timelineDuration = (try? held.timelineDuration.adding(segment.timelineDuration)) ?? held.timelineDuration
                    merged.append(held)
                    pending = nil
                } else {
                    pending = segment
                }
            }
            if let pending { merged.append(pending) }
            segments = merged
        }

        // Absorb the remainder, both ways, so source and timeline each account
        // for exactly what the clip says they do.
        let sourceSum = segments.reduce(Int64(0)) { $0 + Self.rawTicks($1.sourceDuration) }
        let timelineSum = segments.reduce(Int64(0)) { $0 + Self.rawTicks($1.timelineDuration) }
        let sourceTarget = Self.rawTicks(sourceDuration)
        let timelineTarget = Self.rawTicks(timelineDuration)
        segments[segments.count - 1].sourceDuration =
            Self.exposedTime(Self.rawTicks(segments[segments.count - 1].sourceDuration) + sourceTarget - sourceSum)
        segments[segments.count - 1].timelineDuration =
            Self.exposedTime(Self.rawTicks(segments[segments.count - 1].timelineDuration) + timelineTarget - timelineSum)
        return segments.filter { $0.sourceDuration > .zero && $0.timelineDuration > .zero }
    }
}

// MARK: - Applying a ramp to a track

extension TimeMap {
    /// The segments covering one window of the clip's source, with the pieces
    /// at either end cut proportionally.
    ///
    /// Audio is inserted as the intersection of the clip's source range with the
    /// track's, which is often but not always the whole clip. Cutting the end
    /// pieces rather than dropping them keeps the audio the same length as the
    /// picture over the same span — a whole piece either way would put the two
    /// out of step by up to a segment.
    func retimeSegments(clippedToSource window: CMTimeRange) -> [RetimeSegment] {
        let all = retimeSegments()
        guard !all.isEmpty else { return [] }
        let start = window.start, end = CMTimeRangeGetEnd(window)
        var result: [RetimeSegment] = []
        for segment in all {
            let segmentStart = segment.sourceOffset.cmTime
            let segmentEnd = CMTimeAdd(segmentStart, segment.sourceDuration.cmTime)
            let lower = CMTimeMaximum(segmentStart, start)
            let upper = CMTimeMinimum(segmentEnd, end)
            guard CMTimeCompare(upper, lower) > 0 else { continue }
            let whole = segment.sourceDuration.seconds
            let kept = CMTimeSubtract(upper, lower)
            guard whole > 0 else { continue }
            let fraction = kept.seconds / whole
            guard let source = try? TimelineTime(kept),
                  let offset = try? TimelineTime(lower),
                  let timeline = try? TimelineTime(CMTimeMultiplyByFloat64(
                      segment.timelineDuration.cmTime, multiplier: min(1, max(0, fraction))))
            else { continue }
            result.append(RetimeSegment(sourceOffset: offset, sourceDuration: source,
                                        timelineDuration: timeline))
        }
        return result
    }

    /// Scales an already-inserted run of source into a ramp.
    ///
    /// The pieces are applied **back to front**, and that is not a style choice:
    /// scaling a range rewrites where everything after it sits, so working
    /// forwards would move each piece out from under the position computed for
    /// the next one. Going backwards, every piece still yet to be scaled is
    /// exactly where it was inserted.
    ///
    /// - Parameter start: where the run was inserted, on the composition's clock.
    /// - Returns: the timeline length the run now occupies.
    @discardableResult
    static func applySegments(_ segments: [RetimeSegment],
                              to track: AVMutableCompositionTrack,
                              startingAt start: CMTime) -> CMTime {
        guard !segments.isEmpty else { return .zero }
        // Where each piece sits BEFORE anything is scaled: source lengths laid
        // end to end from the insertion point.
        var offsets: [CMTime] = []
        var cursor = start
        for segment in segments {
            offsets.append(cursor)
            cursor = CMTimeAdd(cursor, segment.sourceDuration.cmTime)
        }
        for index in stride(from: segments.count - 1, through: 0, by: -1) {
            let segment = segments[index]
            guard segment.sourceDuration > .zero, segment.timelineDuration > .zero,
                  segment.sourceDuration.cmTime != segment.timelineDuration.cmTime else { continue }
            track.scaleTimeRange(
                CMTimeRange(start: offsets[index], duration: segment.sourceDuration.cmTime),
                toDuration: segment.timelineDuration.cmTime)
        }
        return segments.reduce(CMTime.zero) { CMTimeAdd($0, $1.timelineDuration.cmTime) }
    }
}
