import CoreMedia
import Foundation

/// How the speed travels from one speed point to the next.
///
/// The raw values are the stored representation and are **English in every
/// language**, for the same reason `TimelineTrackHeightChoice`'s are: they are
/// written into the document, and a project made in one language must not stop
/// decoding when opened in another. `title` is what anybody reads.
enum SpeedInterpolation: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Constant acceleration: the speed graph is a straight line between the
    /// two points.
    case linear = "Linear"
    case easeIn = "EaseIn"
    case easeOut = "EaseOut"
    case easeInOut = "EaseInOut"
    /// Shaped by the two points' handles.
    case bezier = "Bezier"
    /// No transition at all: the speed stays at the left point's value until
    /// the right point, then jumps. This is what a cut between two constant
    /// speeds looks like.
    case hold = "Hold"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: String(localized: "Linear")
        case .easeIn: String(localized: "Ease In")
        case .easeOut: String(localized: "Ease Out")
        case .easeInOut: String(localized: "Ease In & Out")
        case .bezier: String(localized: "Bezier")
        case .hold: String(localized: "Hold")
        }
    }

    var symbolName: String {
        switch self {
        case .linear: "line.diagonal"
        case .easeIn: "arrow.up.right"
        case .easeOut: "arrow.up.right"
        case .easeInOut: "point.topleft.down.to.point.bottomright.curvepath"
        case .bezier: "point.topleft.down.to.point.bottomright.curvepath"
        case .hold: "rectangle.split.2x1"
        }
    }

    /// Eased position through a segment, both arguments and result 0…1.
    ///
    /// Only `bezier` reads the handles; the named curves are fixed shapes so
    /// that picking one from a menu cannot leave stale handle values showing
    /// through.
    func eased(_ x: Double, outgoing: BezierHandle, incoming: BezierHandle) -> Double {
        let t = min(max(x, 0), 1)
        switch self {
        case .linear: return t
        case .hold: return 0
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t)
        case .bezier:
            return BezierHandle.solve(x: t, outgoing: outgoing, incoming: incoming)
        }
    }
}

/// One side of a Bezier transition, in segment-relative units.
///
/// `dx` is a fraction of the segment's width and `dy` a fraction of its height,
/// so a handle keeps its shape when the points either side of it move. `dx` is
/// clamped below 1 because two handles that cross produce a speed curve that
/// doubles back on itself — which would mean the clip playing two different
/// rates at the same instant.
struct BezierHandle: Codable, Equatable, Sendable {
    var dx: Double
    var dy: Double

    /// The handle a new point gets: a third of the way across, flat. Two of
    /// these produce a smooth S with no overshoot.
    static let neutral = BezierHandle(dx: 1.0 / 3.0, dy: 0)

    static let maximumDX = 0.98

    var clamped: BezierHandle {
        BezierHandle(dx: min(max(dx.isFinite ? dx : Self.neutral.dx, 0.02), Self.maximumDX),
                     dy: min(max(dy.isFinite ? dy : 0, -1.5), 1.5))
    }

    /// Cubic Bezier through (0,0) → (dx₁, dy₁) → (1-dx₂, 1-dy₂) → (1,1),
    /// solved for y at a given x by bisection.
    ///
    /// Bisection rather than Newton: the control points are user-dragged and
    /// can sit anywhere this struct allows, including places where the
    /// derivative is near zero and Newton wanders. Twenty-four halvings put the
    /// answer inside 1e-7, which is far finer than a frame.
    static func solve(x: Double, outgoing: BezierHandle, incoming: BezierHandle) -> Double {
        let out = outgoing.clamped, into = incoming.clamped
        let x1 = out.dx, y1 = out.dy
        let x2 = 1 - into.dx, y2 = 1 - into.dy
        func bezier(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if bezier(x1, x2, mid) < x { low = mid } else { high = mid }
        }
        return bezier(y1, y2, (low + high) / 2)
    }
}

/// A speed change the user placed on a clip.
///
/// The position is a **source** offset, measured from the clip's
/// `sourceRange.start`, and that is deliberate. A speed point marks a moment in
/// the picture — "start slowing down when the ball leaves his hand" — and the
/// timeline position of that moment is a consequence of every speed before it.
/// Storing the timeline position instead would make the curve define its own
/// domain, which is circular: the clip's length is the integral of the curve,
/// so the curve cannot also be indexed by that length.
///
/// `TimeMap` converts to and from timeline positions for everything the user
/// touches, so the UI still speaks in timeline time.
struct SpeedPoint: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// Distance into the clip's source range. Never negative, never past the
    /// range's end.
    var sourceOffset: TimelineTime
    /// Playback rate at this point. 1 is normal.
    var speed: Double
    /// How the speed travels from **this** point to the next one.
    var interpolation: SpeedInterpolation
    /// Shapes of the transition leaving this point and arriving at it. Only
    /// read when the governing segment is `.bezier`.
    var outgoingHandle: BezierHandle
    var incomingHandle: BezierHandle

    init(id: UUID = UUID(), sourceOffset: TimelineTime, speed: Double,
         interpolation: SpeedInterpolation = .easeInOut,
         outgoingHandle: BezierHandle = .neutral,
         incomingHandle: BezierHandle = .neutral) {
        self.id = id
        self.sourceOffset = sourceOffset
        self.speed = ClipSpeed.clamped(speed)
        self.interpolation = interpolation
        self.outgoingHandle = outgoingHandle
        self.incomingHandle = incomingHandle
    }
}

/// A held source frame occupying real timeline length.
///
/// Kept apart from the speed curve rather than expressed as a zero-speed point,
/// because zero has no reciprocal: the curve is integrated as 1/speed, and a
/// point at zero would make the clip infinitely long.
///
/// So a freeze is instead **one frame of source stretched over a length of
/// timeline** — `sourceWidth` of picture taking `duration` to play. That is a
/// finite rate, which means the map integrates it like anything else and the
/// edit list can express it with an ordinary scale. It is also what a freeze
/// actually is: one frame, held.
///
/// `sourceWidth` is written when the freeze is made, from the media's own frame
/// duration, rather than being worked out later. The clip does not know its
/// frame rate — only the asset does — and a freeze whose width was guessed
/// would drift the source by that guess every time it was crossed.
struct FreezeSegment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// The source offset that is held.
    var sourceOffset: TimelineTime
    /// How long it is held for, in timeline time.
    var duration: TimelineTime
    /// How much source the hold consumes: one frame of the media it came from.
    var sourceWidth: TimelineTime
    /// Replacement holds must fill an existing slot to the exact project tick.
    /// Nil retains the integration used by previously saved speed edits.
    var integratesExactly: Bool? = nil
    /// A last-frame hold fills time with a picture, without stretching the
    /// frame's audio into a drone. Nil keeps existing authored freezes unchanged.
    var silencesAudio: Bool? = nil

    /// Shortest freeze offered. Below about a sixth of a second a freeze reads
    /// as a stutter rather than as a hold.
    static let minimumDuration = 0.15
    /// Longest offered from the panel. A longer one is still representable —
    /// this only bounds the control.
    static let maximumDuration = 10.0
    static let defaultDuration = 1.0

    init(id: UUID = UUID(), sourceOffset: TimelineTime, duration: TimelineTime,
         sourceWidth: TimelineTime, integratesExactly: Bool? = nil, silencesAudio: Bool? = nil) {
        self.id = id
        self.sourceOffset = sourceOffset
        self.duration = duration
        self.sourceWidth = sourceWidth
        self.integratesExactly = integratesExactly
        self.silencesAudio = silencesAudio
    }

    /// The rate the held stretch plays at: one frame over the whole hold.
    ///
    /// Deliberately **not** put through `ClipSpeed.clamped`. A one-second hold
    /// of a 30 fps frame is 3.3%, far below the slowest rate a user may set,
    /// and clamping it would make the freeze play — slowly — instead of
    /// holding.
    var rate: Double {
        let held = duration.seconds
        guard held > 0 else { return ClipSpeed.normal }
        return max(1e-6, sourceWidth.seconds / held)
    }

    /// The source interval this hold covers.
    var sourceEnd: TimelineTime {
        (try? sourceOffset.adding(sourceWidth)) ?? sourceOffset
    }
}

/// How frames that fall between two source frames are produced.
enum FrameInterpolation: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Show the nearest source frame. Fast, and what every clip did before
    /// retiming existed.
    case sampling = "Sampling"
    /// Cross-dissolve the two neighbouring frames.
    case blending = "Blending"
    /// Estimate motion between the two frames and generate the one in between.
    case opticalFlow = "OpticalFlow"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sampling: String(localized: "Frame Sampling")
        case .blending: String(localized: "Frame Blending")
        case .opticalFlow: String(localized: "Optical Flow")
        }
    }

    var detail: String {
        switch self {
        case .sampling:
            String(localized: "Each source frame is held. Fastest, and the only honest choice for fast motion.")
        case .blending:
            String(localized: "Blends the two neighbouring frames. Removes the stepping in slow motion; movement softens rather than gaining detail.")
        case .opticalFlow:
            String(localized: "Estimates the motion between two frames and generates the one in between. Highest quality, and the slowest.")
        }
    }
}

/// How hard the optical flow estimate works.
enum OpticalFlowQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case preview = "Preview"
    case high = "High"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: String(localized: "Preview")
        case .high: String(localized: "High")
        }
    }
}

/// What happens to a retimed clip's audio.
enum RetimedAudioBehaviour: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Follow the time map, keeping pitch where the algorithm can.
    case follow = "Follow"
    /// Follow the map, letting pitch rise and fall with the rate.
    case followWithPitch = "FollowWithPitch"
    /// Silence for the whole retimed clip.
    case mute = "Mute"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .follow: String(localized: "Preserve Pitch")
        case .followWithPitch: String(localized: "Let Pitch Follow Speed")
        case .mute: String(localized: "Mute")
        }
    }
}

/// Everything about one clip's retiming, independent of any platform's UI.
///
/// A clip carries this **or** the older scalar `playbackSpeed`, never both as
/// competing truths: `VideoClip.speed` reads the remap's constant when one is
/// present. Optional on the clip, so every project written before ramping
/// decodes as the unchanged clip it was.
struct TimeRemap: Codable, Equatable, Sendable {
    /// The speed points, in source order. Empty means constant speed at
    /// `constantSpeed`.
    var points: [SpeedPoint] = []
    /// The rate when there are no points. Kept even while points exist, so
    /// switching Ramp off and on again returns to the rate the user had.
    var constantSpeed: Double = ClipSpeed.normal
    /// Play the whole clip backwards. A flag rather than negative speeds,
    /// because that is how the user thinks about it and how they expect to undo
    /// it; `TimeMap` still reads the curve the same way either side of it.
    var reverses: Bool = false
    var freezes: [FreezeSegment] = []
    var frameInterpolation: FrameInterpolation = .sampling
    var opticalFlowQuality: OpticalFlowQuality = .preview
    var audioBehaviour: RetimedAudioBehaviour = .follow

    static let constant = TimeRemap()

    /// True when this describes anything other than ordinary forward playback.
    var isRetimed: Bool {
        reverses || !freezes.isEmpty || !points.isEmpty
            || constantSpeed != ClipSpeed.normal
    }

    /// True when the speed varies within the clip, as opposed to a single rate
    /// applied to all of it. Controls whether the curve editor has anything to
    /// show and whether the timeline draws a "Ramp" badge.
    var isRamped: Bool {
        !freezes.isEmpty || points.count > 1
            || (points.count == 1 && points[0].speed != constantSpeed)
    }

    /// The points as the map should read them: sorted, deduplicated on
    /// position, clamped to the source range and to the supported rates.
    ///
    /// Sorting here rather than trusting the array is what lets the editor drag
    /// a point straight past its neighbour without having to reorder anything
    /// or rewrite ids — the identity of a point follows the point, not its
    /// index.
    func resolvedPoints(sourceDuration: TimelineTime) -> [SpeedPoint] {
        guard !points.isEmpty else { return [] }
        let limit = sourceDuration
        var cleaned: [SpeedPoint] = []
        for var point in points.sorted(by: { $0.sourceOffset < $1.sourceOffset }) {
            point.sourceOffset = min(max(.zero, point.sourceOffset), limit)
            point.speed = ClipSpeed.clamped(point.speed)
            point.outgoingHandle = point.outgoingHandle.clamped
            point.incomingHandle = point.incomingHandle.clamped
            // Two points on the same source frame describe two speeds for one
            // moment. The later one wins, which is what a drag onto a
            // neighbour looks like from the user's side.
            if let last = cleaned.last, last.sourceOffset == point.sourceOffset {
                cleaned.removeLast()
            }
            cleaned.append(point)
        }
        return cleaned
    }

    /// The freezes as the map should read them: sorted, clamped, non-overlapping
    /// and with any zero-length entry dropped.
    ///
    /// Overlaps are resolved by dropping the later hold rather than by merging.
    /// Two holds covering the same frame describe two different lengths for one
    /// moment, and there is no answer to that which is not a guess.
    func resolvedFreezes(sourceDuration: TimelineTime) -> [FreezeSegment] {
        var result: [FreezeSegment] = []
        for freeze in freezes.sorted(by: { $0.sourceOffset < $1.sourceOffset }) {
            guard freeze.duration > .zero, freeze.sourceWidth > .zero else { continue }
            var value = freeze
            value.sourceOffset = min(max(.zero, value.sourceOffset), sourceDuration)
            if let last = result.last, value.sourceOffset < last.sourceEnd { continue }
            guard value.sourceEnd <= sourceDuration else { continue }
            result.append(value)
        }
        return result
    }

    /// The hold covering a source offset, if one does.
    func freeze(atSourceOffset offset: TimelineTime, sourceDuration: TimelineTime) -> FreezeSegment? {
        resolvedFreezes(sourceDuration: sourceDuration).first {
            offset >= $0.sourceOffset && offset < $0.sourceEnd
        }
    }
}

// MARK: - Presets

extension TimeRemap {
    /// A ramp a user can apply and then edit.
    ///
    /// Presets are deliberately **not** special: each one is nothing but a set
    /// of ordinary speed points, so everything about it remains editable and
    /// deletable afterwards. Nothing anywhere records that a preset was used.
    struct Preset: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        /// Speeds at fractions of the source range, 0…1.
        let stops: [(position: Double, speed: Double)]
        var interpolation: SpeedInterpolation = .easeInOut

        func points(sourceDuration: TimelineTime) -> [SpeedPoint] {
            stops.compactMap { stop in
                guard let offset = try? TimelineTime(CMTimeMultiplyByFloat64(
                    sourceDuration.cmTime, multiplier: min(max(stop.position, 0), 1)))
                else { return nil }
                return SpeedPoint(sourceOffset: offset, speed: stop.speed,
                                  interpolation: interpolation)
            }
        }
    }

    /// The ramps offered as one tap.
    ///
    /// Named for what they are FOR rather than for what they do to the numbers:
    /// someone reaching for a ramp is thinking "this is the hero shot", not
    /// "I would like 300% easing into 20%". The shapes are the six that cover
    /// almost every use — two shapes that dip, one that spikes, two that settle
    /// one way or the other, and one that does both.
    static var presets: [Preset] {
        [
            .init(id: "montage", title: String(localized: "Montage"),
                  detail: String(localized: "Rushes in, drops into slow motion, and settles."),
                  stops: [(0, 1), (0.22, 4), (0.45, 0.35), (0.75, 0.85), (1, 0.85)]),
            .init(id: "hero", title: String(localized: "Hero"),
                  detail: String(localized: "Two rushes around a long held middle — the shot you want people to look at."),
                  stops: [(0, 1), (0.18, 3.5), (0.4, 0.25), (0.6, 0.25), (0.82, 3.5), (1, 1)]),
            .init(id: "bullet", title: String(localized: "Bullet"),
                  detail: String(localized: "Normal speed, one hard drop into very slow motion, and straight back."),
                  stops: [(0, 1), (0.38, 1), (0.46, 0.1), (0.54, 0.1), (0.62, 1), (1, 1)]),
            .init(id: "jump-cut", title: String(localized: "Jump cut"),
                  detail: String(localized: "A short burst of speed that skips the dull part without a cut."),
                  stops: [(0, 1), (0.38, 1), (0.47, 8), (0.53, 8), (0.62, 1), (1, 1)]),
            .init(id: "flash-in", title: String(localized: "Flash in"),
                  detail: String(localized: "Opens fast and eases down to normal."),
                  stops: [(0, 4), (0.45, 4), (1, 1)], interpolation: .easeInOut),
            .init(id: "flash-out", title: String(localized: "Flash out"),
                  detail: String(localized: "Runs at normal speed and accelerates away."),
                  stops: [(0, 1), (0.55, 1), (1, 4)], interpolation: .easeInOut)
        ]
    }

    /// The preset this retiming is, if it is one.
    ///
    /// Derived by comparing the curve rather than recorded when a preset is
    /// applied, and that is deliberate: a preset leaves nothing behind but
    /// ordinary speed points, so a clip that was built by hand into the same
    /// shape is that preset, and one whose points have been nudged since is no
    /// longer it. A stored name would keep claiming "Hero" over a curve that
    /// had been dragged into something else.
    func matchingPreset(sourceDuration: TimelineTime) -> String? {
        let mine = resolvedPoints(sourceDuration: sourceDuration)
        guard !mine.isEmpty else { return nil }
        for preset in Self.presets {
            let theirs = preset.points(sourceDuration: sourceDuration)
            guard theirs.count == mine.count else { continue }
            let total = max(sourceDuration.seconds, 0.0001)
            let matches = zip(mine, theirs).allSatisfy { a, b in
                abs(a.speed - b.speed) < 0.02
                    && abs(a.sourceOffset.seconds - b.sourceOffset.seconds) / total < 0.01
                    && a.interpolation == b.interpolation
            }
            if matches { return preset.id }
        }
        return nil
    }
}

extension TimeRemap.Preset {
    /// The preset as this retiming, for drawing and for applying.
    func remap(sourceDuration: TimelineTime) -> TimeRemap {
        var remap = TimeRemap()
        remap.points = points(sourceDuration: sourceDuration)
        return remap
    }

    /// Speeds across the preset's own length, for the tile that previews it.
    ///
    /// Read off a real `TimeMap` rather than off the control points, so the
    /// thumbnail shows the rate the clip would actually play at — including the
    /// flat runs outside the first and last point, and anything the rate limits
    /// clamped. A curve drawn straight from the stops would promise a ramp the
    /// preset does not have.
    ///
    /// Measured over a nominal one second, which is what lets the six maps be
    /// built once and then found in `TimeMap`'s cache on every later redraw.
    func previewSpeeds(samples: Int = 96) -> [Double] {
        guard let nominal = try? TimelineTime.seconds(1) else { return [] }
        let map = TimeMap.cached(remap: remap(sourceDuration: nominal), sourceDuration: nominal)
        let length = map.timelineDuration
        return (0...max(2, samples)).compactMap { step in
            let fraction = Double(step) / Double(max(2, samples))
            guard let at = try? TimelineTime.seconds(length.seconds * fraction) else { return nil }
            return map.speed(atTimelineOffset: at)
        }
    }
}

// MARK: - Structural edits

extension TimeRemap {
    /// The retiming split at a source offset, for a blade cut.
    ///
    /// Both halves keep the curve they were actually playing: a point is added
    /// at the seam carrying the exact speed in force there, so the two halves
    /// played back to back are indistinguishable from the original. Without
    /// that point the left half would end at the previous point's rate and the
    /// right would start at the next one's, and the cut would be visible as a
    /// jump in speed.
    func split(atSourceOffset offset: TimelineTime, sourceDuration: TimelineTime)
        -> (leading: TimeRemap, trailing: TimeRemap) {
        let points = resolvedPoints(sourceDuration: sourceDuration)
        guard !points.isEmpty || !freezes.isEmpty else { return (self, self) }

        let seamSpeed = TimeMap.speed(
            atSourceTick: Double(CMTimeConvertScale(
                offset.cmTime, timescale: TimeMap.timescale, method: .roundHalfAwayFromZero).value),
            points: points, fallback: constantSpeed)

        var leading = self, trailing = self
        leading.points = points.filter { $0.sourceOffset < offset }
        trailing.points = points.filter { $0.sourceOffset > offset }.compactMap { point in
            var moved = point
            guard let rebased = try? point.sourceOffset.subtracting(offset) else { return nil }
            moved.sourceOffset = rebased
            return moved
        }
        // The seam point, on both sides, so neither half has to extrapolate.
        leading.points.append(SpeedPoint(sourceOffset: offset, speed: seamSpeed,
                                         interpolation: .hold))
        trailing.points.insert(SpeedPoint(sourceOffset: .zero, speed: seamSpeed,
                                          interpolation: points.last?.interpolation ?? .linear),
                               at: 0)

        leading.freezes = freezes.filter { $0.sourceOffset < offset }
        trailing.freezes = freezes.filter { $0.sourceOffset >= offset }.compactMap { freeze in
            var moved = freeze
            guard let rebased = try? freeze.sourceOffset.subtracting(offset) else { return nil }
            moved.sourceOffset = rebased
            return moved
        }
        return (leading, trailing)
    }

    /// The retiming after `consumed` of source is hidden off the front.
    ///
    /// A head trim moves the clip's origin, and the curve is measured from that
    /// origin, so every point moves with it. Points that fall off the front are
    /// replaced by a single one holding the speed that was in force at the new
    /// first frame — the same reason the split adds a seam point.
    func trimmedHead(bySource consumed: TimelineTime, sourceDuration: TimelineTime) -> TimeRemap {
        guard consumed > .zero else { return self }
        let (_, trailing) = split(atSourceOffset: consumed, sourceDuration: sourceDuration)
        return trailing
    }

    /// The retiming with everything past `duration` of source discarded.
    func trimmedTail(toSource duration: TimelineTime, sourceDuration: TimelineTime) -> TimeRemap {
        let (leading, _) = split(atSourceOffset: duration, sourceDuration: sourceDuration)
        return leading
    }

    /// Adds a point, or moves the one already on that frame.
    mutating func setPoint(atSourceOffset offset: TimelineTime, speed: Double,
                           interpolation: SpeedInterpolation? = nil) {
        if let index = points.firstIndex(where: { $0.sourceOffset == offset }) {
            points[index].speed = ClipSpeed.clamped(speed)
            if let interpolation { points[index].interpolation = interpolation }
            return
        }
        points.append(SpeedPoint(sourceOffset: offset, speed: speed,
                                 interpolation: interpolation ?? .easeInOut))
        points.sort { $0.sourceOffset < $1.sourceOffset }
    }

    /// Removes a point. The curve then runs straight through where it was,
    /// which is what "remove this ramp" should mean.
    mutating func removePoint(_ id: UUID) {
        points.removeAll { $0.id == id }
    }

    /// Collapses the ramp back to a single rate, keeping frame interpolation,
    /// reverse and freezes alone. Resetting the curve is not the same as
    /// resetting the clip.
    mutating func resetCurve() {
        points.removeAll()
    }
}
