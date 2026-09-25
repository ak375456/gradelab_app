import CoreMedia
import Foundation
import simd

enum MaskTrackingDirection: String, CaseIterable, Sendable, Identifiable {
    case backward, forward, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .backward: String(localized: "Track Backward")
        case .forward: String(localized: "Track Forward")
        case .both: String(localized: "Track Both Directions")
        }
    }
}

enum MaskTrackingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct TrackedMaskSample: Sendable {
    let localTime: TimelineTime
    var values: SIMD4<Double> // position X/Y, width/height (freehand: scale X/Y)
    let confidence: Float
}

struct MaskTrackingProgress: Sendable {
    var fraction: Double
    var frames: Int
    var direction: MaskTrackingDirection
    var preparing: Bool = false
}

struct MaskTrackingResult: Sendable {
    var samples: [TrackedMaskSample] = []
    var lostTime: TimelineTime?
    var lastDirection: MaskTrackingDirection = .forward
    var stopped = false
    var message: String?
}

struct MaskTrackingRequest: Sendable {
    let url: URL
    let clip: VideoClip
    let mask: MaskedGradeLayer
    let anchor: TimelineTime
    let sourceAnchor: TimelineTime
    let direction: MaskTrackingDirection

    var anchorValues: SIMD4<Double> {
        let g = mask.geometry
        return SIMD4(g.centerX, g.centerY, g.width, g.height)
    }
    var visibleStart: TimelineTime { clip.animation?.startOffset ?? .zero }
    var visibleEnd: TimelineTime { (try? visibleStart.adding(clip.placement.duration)) ?? visibleStart }
    var requestedRange: ClosedRange<TimelineTime> {
        switch direction {
        case .forward: anchor...visibleEnd
        case .backward: visibleStart...anchor
        case .both: visibleStart...visibleEnd
        }
    }
    /// Where a source frame lands in the clip's own animation coordinates.
    ///
    /// Through the clip's time map, not through a division by one rate: a
    /// tracked mask is keyed to the PICTURE, so on a ramped clip the frame that
    /// was analysed has to come back at the moment it is actually shown. A flat
    /// `1 / speed` was right only while every clip had a single rate.
    func localTime(source: CMTime) throws -> TimelineTime {
        let offset = try clip.localTime(atSource: TimelineTime(source))
        return try visibleStart.adding(offset)
    }
}

/// Analysis postprocessing only. Storage and evaluation remain AnimationTrack's job.
enum MaskTrackingMotion {
    static let properties: [AnimatableProperty] = [
        .localMaskPositionX, .localMaskPositionY, .localMaskWidth, .localMaskHeight
    ]
    static let tolerance = 0.0005

    static func animation(for result: MaskTrackingResult, request: MaskTrackingRequest,
                          original: MaskedGradeLayer) throws -> ClipAnimation {
        var samples = result.samples.sorted { $0.localTime < $1.localTime }
        guard !samples.isEmpty else { return original.animation ?? ClipAnimation() }
        // Never average the authored anchor, first or last successful observation.
        let raw = samples
        let weights = errorWeights(request.mask.geometry)
        if samples.count > 2 {
            for i in 1..<(samples.count - 1) where samples[i].localTime != request.anchor {
                let span = raw[i + 1].localTime.seconds - raw[i - 1].localTime.seconds
                guard span > 0 else { continue }
                let f = (raw[i].localTime.seconds - raw[i - 1].localTime.seconds) / span
                let predicted = raw[i - 1].values + (raw[i + 1].values - raw[i - 1].values) * f
                let delta = (predicted - raw[i].values) * 0.2
                for p in 0..<4 {
                    // At most 0.04% of source size. Sharp turns remain attached.
                    let cap = 0.0004 / weights[p]
                    samples[i].values[p] += min(cap, max(-cap, delta[p]))
                }
            }
        }
        let finished = !result.stopped && result.lostTime == nil && result.message == nil
        let lower = finished && request.direction != .forward ? request.visibleStart : samples.first!.localTime
        let upper = finished && request.direction != .backward ? request.visibleEnd : samples.last!.localTime
        let range = lower...upper
        var animation = original.animation ?? ClipAnimation()
        var tolerance = Self.tolerance
        while true {
            let reduced = simplify(samples, anchor: request.anchor, weights: weights, tolerance: tolerance)
            var replacements: [AnimationTrack] = []
            var fits = true
            for (column, property) in properties.enumerated() {
                let oldTrack = animation.track(property)
                var frames = try outsideFrames(oldTrack, range: range, request: request,
                                               weight: weights[column])
                frames += reduced.map { Keyframe(time: $0.localTime,
                    value: .number(property.clamped($0.values[column])), interpolation: .linear) }
                guard frames.count <= AnimationTrack.keyframeLimit else { fits = false; break }
                replacements.append(AnimationTrack(property: property, keyframes: frames))
            }
            if fits {
                animation.tracks.removeAll { properties.contains($0.property) }
                animation.tracks += replacements
                return animation
            }
            // Bounded relaxation, never unbounded compression or silent truncation.
            guard tolerance < 0.002 else {
                throw MaskTrackingError.message(String(localized: "This range needs more than 2,000 motion keyframes per track. Track a shorter section using Stop, or clear existing geometry animation first. No existing animation was replaced."))
            }
            tolerance *= 2
        }
    }

    /// Keep every authored key outside the replacement span. If a boundary
    /// cuts an eased segment, merely inserting a key would reparameterize that
    /// entire segment. Sample only those two boundary segments through the
    /// existing evaluator, retaining their motion within 0.005% of source size.
    private static func outsideFrames(_ track: AnimationTrack?, range: ClosedRange<TimelineTime>,
                                      request: MaskTrackingRequest, weight: Double) throws -> [Keyframe] {
        guard let track else { return [] }
        var frames = track.keyframes.filter { !range.contains($0.time) }
        let tick = try TimelineTime(value: 1, timescale: TimelineTime.projectTimescale)
        for (boundary, before) in [(try range.lowerBound.subtracting(tick), true),
                                   (try range.upperBound.adding(tick), false)] {
            guard boundary >= request.visibleStart, boundary < request.visibleEnd,
                  !frames.contains(where: { $0.time == boundary }),
                  let value = track.value(at: boundary) else { continue }
            let originalMode = track.previous(before: boundary)?.interpolation ?? .linear
            let guardKey = Keyframe(time: boundary, value: value,
                                   interpolation: originalMode == .hold ? .hold : .linear)
            frames.append(guardKey)
            let pair: (Keyframe, Keyframe)?
            if before, let previous = track.previous(before: boundary) { pair = (previous, guardKey) }
            else if !before, let next = track.next(after: boundary) { pair = (guardKey, next) }
            else { pair = nil }
            guard let pair else { continue }
            var segments = [pair]
            while let (left, right) = segments.popLast() {
                let span = right.time.seconds - left.time.seconds
                guard span > tick.seconds * 2, let a = left.value.number, let b = right.value.number else { continue }
                var needsSplit = false
                for f in [0.25, 0.5, 0.75] {
                    let time = try TimelineTime.seconds(left.time.seconds + span * f)
                    let predicted = left.interpolation == .hold ? a : a + (b - a) * left.interpolation.eased(f)
                    if let expected = track.value(at: time)?.number,
                       abs(expected - predicted) * weight > 0.00005 { needsSplit = true }
                }
                guard needsSplit else { continue }
                let time = try TimelineTime.seconds(left.time.seconds + span / 2)
                guard let value = track.value(at: time), time > left.time, time < right.time else { continue }
                let middle = Keyframe(time: time, value: value, interpolation: .linear)
                frames.append(middle)
                guard frames.count <= AnimationTrack.keyframeLimit else {
                    throw MaskTrackingError.message(String(localized: "Preserving the existing motion would exceed 2,000 keyframes. Choose an existing keyframe as the tracking anchor or clear geometry animation first. No animation was replaced."))
                }
                segments.append((left, middle)); segments.append((middle, right))
            }
        }
        return frames
    }

    private static func errorWeights(_ g: MaskGeometry) -> SIMD4<Double> {
        guard g.shape == .freehand, let first = g.points.first else { return SIMD4(repeating: 1) }
        let xs = g.points.map(\.x), ys = g.points.map(\.y)
        return SIMD4(1, 1, max(0.01, (xs.max() ?? first.x) - (xs.min() ?? first.x)),
                     max(0.01, (ys.max() ?? first.y) - (ys.min() ?? first.y)))
    }

    private static func simplify(_ values: [TrackedMaskSample], anchor: TimelineTime,
                                 weights: SIMD4<Double>, tolerance: Double) -> [TrackedMaskSample] {
        guard values.count > 2 else { return values }
        var keep = Set([0, values.count - 1])
        if let i = values.firstIndex(where: { $0.localTime == anchor }) { keep.insert(i) }
        let fixed = keep.sorted()
        var segments = zip(fixed, fixed.dropFirst()).map { ($0, $1) }
        while let (start, end) = segments.popLast() {
            guard end > start + 1 else { continue }
            let span = values[end].localTime.seconds - values[start].localTime.seconds
            guard span > 0 else { continue }
            var largest = tolerance, candidate: Int?
            for i in (start + 1)..<end {
                let f = (values[i].localTime.seconds - values[start].localTime.seconds) / span
                let predicted = values[start].values + (values[end].values - values[start].values) * f
                let difference = (values[i].values - predicted) * weights
                let error = (0..<4).map { abs(difference[$0]) }.max() ?? 0
                if error > largest { largest = error; candidate = i }
            }
            if let i = candidate { keep.insert(i); segments.append((start, i)); segments.append((i, end)) }
        }
        return keep.sorted().map { values[$0] }
    }
}
