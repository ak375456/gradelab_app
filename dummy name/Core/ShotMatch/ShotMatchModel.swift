import Foundation
import simd

// ---------------------------------------------------------------------------
// Shot Match: the document model
//
// What a match IS, in this app, is a set of ordinary grading values plus the
// grade they were added to. Not a new render stage, not a hidden layer, not a
// baked frame.
//
// That is the single most important decision in the feature and it is worth
// stating plainly. The pipeline runs one `GradeSettings` per clip, so a match
// that produced its own stage would need its own uniforms, its own shader
// branch, its own export path and its own Original-comparison behaviour, and
// would give the user numbers they could look at but not touch. Writing the
// solved values into the controls the app already has means the opposite of
// all of that: Exposure says +0.32 because the match put it there, the slider
// still moves, the curve still has draggable points, and preview, scopes and
// export cannot disagree because there is nothing new for them to disagree
// about.
//
// What makes it non-destructive is `baseGrade`: the clip's grade exactly as it
// was the moment before the match landed. Strength, the component toggles and
// Reset all rebuild from it, so nothing about the original grade is inferred
// back out of the result.
// ---------------------------------------------------------------------------

/// Which workflow produced a match. Mostly a difference of priorities in the
/// solver, and of wording in the panel.
enum ShotMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Match one shot to another: the two are meant to cut together, so
    /// exposure and neutral balance are matched as exactly as the footage
    /// allows.
    case shot
    /// Match a look: a film still, a photograph, an inspiration frame. Tone
    /// shape, palette, the tint of the shadows and highlights and how vivid the
    /// colour is all carry over; exposure deliberately does not, because the
    /// reference is a different scene and relighting the shot to its brightness
    /// is not what anybody means by "make it look like this".
    case look

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shot: String(localized: "Shot")
        case .look: String(localized: "Look")
        }
    }

    var explanation: String {
        switch self {
        case .shot: String(localized: "Matches exposure and white balance as closely as the footage allows. For clips from the same scene or a second camera.")
        case .look: String(localized: "Carries tone, palette and saturation across. Leaves exposure close to where you have it. For a film still or a photograph.")
        }
    }

    /// How much of a measured exposure difference this mode is willing to act
    /// on, and how far it will go.
    var exposureAuthority: (scale: Float, limit: Float) {
        switch self {
        case .shot: (1.0, 2.0)
        case .look: (0.35, 0.6)
        }
    }

    /// How much of the residual tone mapping survives smoothing. A look is a
    /// shape worth carrying; two shots of the same scene should agree through
    /// their own controls rather than through a curve.
    var toneCurveAuthority: Float {
        switch self {
        case .shot: 0.5
        case .look: 0.7
        }
    }
}

/// The parts of the picture the user allows a match to touch.
///
/// An option set rather than a pile of booleans so the whole permission is one
/// value: it persists as one field, it is compared as one value when deciding
/// whether a re-solve is needed, and a component added later cannot be
/// forgotten by a call site that constructs it positionally.
struct ShotMatchComponents: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let exposure        = ShotMatchComponents(rawValue: 1 << 0)
    static let whiteBalance    = ShotMatchComponents(rawValue: 1 << 1)
    static let contrast        = ShotMatchComponents(rawValue: 1 << 2)
    /// Black point, white point and the shoulder and toe between them — the
    /// four tonal-range sliders, as distinct from overall contrast.
    static let tonalRange      = ShotMatchComponents(rawValue: 1 << 3)
    static let saturation      = ShotMatchComponents(rawValue: 1 << 4)
    static let toneCurve       = ShotMatchComponents(rawValue: 1 << 5)
    static let shadowColor     = ShotMatchComponents(rawValue: 1 << 6)
    static let midtoneColor    = ShotMatchComponents(rawValue: 1 << 7)
    static let highlightColor  = ShotMatchComponents(rawValue: 1 << 8)

    /// The three tonal ranges of colour balance, as one switch.
    static let colorBalance: ShotMatchComponents = [.shadowColor, .midtoneColor, .highlightColor]

    static let all: ShotMatchComponents = [
        .exposure, .whiteBalance, .contrast, .tonalRange,
        .saturation, .toneCurve, .colorBalance
    ]

    /// What a fresh match starts with.
    ///
    /// Everything except the residual tone curve. A curve is the one result
    /// that is hard to read at a glance and hard to undo by hand, so it is
    /// offered rather than assumed — the sliders and wheels get a shot within a
    /// stop of the reference on their own, and the curve is there for when that
    /// is not enough.
    static let `default`: ShotMatchComponents = [
        .exposure, .whiteBalance, .contrast, .tonalRange, .saturation, .colorBalance
    ]

    func color(for zone: ShotZone) -> ShotMatchComponents {
        switch zone {
        case .shadows: .shadowColor
        case .midtones: .midtoneColor
        case .highlights: .highlightColor
        }
    }
}

/// How sure the match is that it did something useful.
///
/// Three words, not a percentage. A number like "82.4%" implies a precision
/// nothing here has: the inputs are two pictures of different things, and the
/// only honest statements are whether they are close enough for the result to
/// be trusted as a starting point, or not.
enum ShotMatchConfidence: String, Codable, Sendable {
    case high, medium, low

    var title: String {
        switch self {
        case .high: String(localized: "High")
        case .medium: String(localized: "Medium")
        case .low: String(localized: "Low")
        }
    }

    /// Shown only when it is worth saying something.
    var advice: String? {
        switch self {
        case .high: nil
        case .medium: String(localized: "The reference differs from this shot. Check the result before moving on.")
        case .low: String(localized: "The reference differs significantly from this shot. The match is a starting point and will need manual refinement.")
        }
    }
}

// ---------------------------------------------------------------------------
// The result
// ---------------------------------------------------------------------------

/// The grading values a match produced, in the app's own units.
///
/// This is the editable result. Every field is a control that exists in the
/// Color tab, so "open Light after matching and see what changed" is not a
/// feature that had to be built — it is what the values are.
struct ShotMatchAdjustment: Codable, Equatable, Sendable {
    var exposure: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var saturation: Float = 0
    /// Shadows, midtones, highlights. Hue in degrees and strength 0...100, as
    /// `GradingWheel` stores them. Brightness is deliberately always zero: how
    /// bright a tonal range is belongs to the tonal-range sliders, and a wheel
    /// that also lifted it would fight them for the same correction.
    var wheels: [GradingWheel] = Array(repeating: GradingWheel(), count: 3)
    /// Control points for the master tone curve, or nil when the match did not
    /// need one. Few enough to drag.
    var toneCurve: [CurvePoint]?

    static let neutral = ShotMatchAdjustment()

    /// Whether this match would change a pixel.
    ///
    /// Compared by meaning rather than by `==`. A wheel at zero strength does
    /// nothing whatever hue it points at, and a curve that lies on the diagonal
    /// does nothing whatever its control points are — so a match scaled to zero
    /// has to read as neutral even though its stored fields still remember
    /// which way it was pointing.
    var isNeutral: Bool {
        exposure == 0 && temperature == 0 && tint == 0 && contrast == 0
            && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
            && saturation == 0
            && wheels.allSatisfy { $0.strength == 0 && $0.brightness == 0 }
            && (toneCurve.map { points in
                points.allSatisfy { abs($0.y - $0.x) <= 1e-6 }
            } ?? true)
    }

    /// This adjustment at a fraction of its measured size.
    ///
    /// See `ShotMatchTransform.scaled(by:)` for why scaling the parameters is
    /// the correct meaning of a strength control and cross-fading the rendered
    /// result is not.
    func scaled(by strength: Float) -> ShotMatchAdjustment {
        guard strength > 0 else { return .neutral }
        guard strength != 1 else { return self }
        var result = self
        result.exposure *= strength
        result.temperature *= strength
        result.tint *= strength
        result.contrast *= strength
        result.highlights *= strength
        result.shadows *= strength
        result.whites *= strength
        result.blacks *= strength
        // Saturation is a percentage change, so it interpolates through its
        // multiplier rather than through zero: half of "×0.80" is "×0.90", not
        // "×0.60".
        result.saturation = (pow(1 + saturation / 100, strength) - 1) * 100
        result.wheels = wheels.map {
            GradingWheel(hue: $0.hue, strength: $0.strength * strength, brightness: $0.brightness * strength)
        }
        result.toneCurve = toneCurve.map { points in
            points.map { CurvePoint(id: $0.id, x: $0.x, y: $0.x + ($0.y - $0.x) * strength) }
        }
        return result
    }

    /// The grade that results from adding this match to `base`.
    ///
    /// The composition rules are chosen so that, wherever the pipeline allows
    /// it, one merged grade is **exactly** the same transform as the base grade
    /// followed by the match — not an approximation of it:
    ///
    /// - Exposure is in stops and the stage is a multiply, so stops add.
    /// - Temperature and tint are exponents on cone-response gains, so they add.
    /// - Contrast is a slope about a fixed pivot, and two slopes about the same
    ///   pivot multiply, which is addition in the control's own log units.
    /// - A wheel's exponent is linear in its tint vector, so two wheels in the
    ///   same tonal range add as vectors — which is why they are composed in
    ///   Cartesian form here and converted back, rather than having their hues
    ///   averaged.
    /// - Saturation is a multiplier on distance from grey, so the multipliers
    ///   multiply.
    ///
    /// The four tonal-range sliders are the exception: their stage is
    /// luminance-dependent, so two applications are not one. They add, which is
    /// the same rule Paste Grade already uses for them, and the solver measures
    /// the picture after the base grade so the sum is solved rather than
    /// assumed.
    func applied(to base: GradeSettings) -> GradeSettings {
        var result = base

        func add(_ keyPath: WritableKeyPath<GradeSettings, Float>, _ delta: Float, _ parameter: GradeParameter) {
            let range = parameter.range
            result[keyPath: keyPath] = min(max(base[keyPath: keyPath] + delta, range.lowerBound), range.upperBound)
        }
        add(\.exposure, exposure, .exposure)
        add(\.temperature, temperature, .temperature)
        add(\.tint, tint, .tint)
        add(\.contrast, contrast, .contrast)
        add(\.highlights, highlights, .highlights)
        add(\.shadows, shadows, .shadows)
        add(\.whites, whites, .whites)
        add(\.blacks, blacks, .blacks)

        let combinedSaturation = ((1 + base.saturation / 100) * (1 + saturation / 100) - 1) * 100
        result.saturation = min(max(combinedSaturation, -100), 100)

        guard wheels.contains(where: { $0 != GradingWheel() }) || toneCurve != nil else {
            return result
        }
        var advanced = result.advanced ?? .neutral
        advanced.normalizeCollections()
        for index in 0..<min(3, wheels.count) where wheels[index] != GradingWheel() {
            advanced.wheels[index] = Self.composed(advanced.wheel(index), with: wheels[index])
        }
        if let toneCurve {
            var curves = advanced.resolvedCurves
            curves[.master] = Self.composedMaster(base: curves[.master], match: toneCurve)
            advanced.advancedCurves = curves.isNeutral ? nil : curves
            // `resolvedCurves` has already folded the legacy array in, so
            // leaving it populated would let two descriptions of the same
            // curves disagree.
            advanced.curves = Array(repeating: ToneCurve(), count: 4)
        }
        result.advanced = advanced == .neutral ? nil : advanced
        return result
    }

    /// Two wheels in the same tonal range, as one wheel.
    ///
    /// Polar values cannot be added: a 10% push toward orange plus a 10% push
    /// toward teal is nothing at all, and averaging their hues would give
    /// yellow-green at full strength. Converting to the Cartesian tint the
    /// shader actually applies, adding there and converting back is the only
    /// composition that produces the picture two wheels in sequence would.
    static func composed(_ base: GradingWheel, with match: GradingWheel) -> GradingWheel {
        func vector(_ wheel: GradingWheel) -> SIMD2<Float> {
            let radians = wheel.hue * .pi / 180
            return SIMD2(cos(radians), sin(radians)) * (wheel.strength / 100)
        }
        let sum = vector(base) + vector(match)
        let length = min(simd_length(sum), 1)
        guard length > 1e-5 else {
            return GradingWheel(hue: base.hue, strength: 0, brightness: base.brightness + match.brightness)
        }
        var degrees = atan2(sum.y, sum.x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return GradingWheel(hue: degrees, strength: length * 100,
                            brightness: base.brightness + match.brightness)
    }

    /// A base master curve followed by the match's, as one curve.
    ///
    /// Function composition, sampled: the merged curve maps x through the base
    /// curve and then through the match's, because that is the order the two
    /// would have run in. Emitted as a handful of control points so what the
    /// user opens is a curve they can drag, not a two-hundred-point trace.
    static func composedMaster(base: AdvancedCurve, match: [CurvePoint]) -> AdvancedCurve {
        let matchCurve = AdvancedCurve(type: .master, points: match)
        guard !base.isFlat else { return matchCurve }
        let baseEvaluator = CurveEvaluator(base)
        let matchEvaluator = CurveEvaluator(matchCurve)
        let anchors: [Float] = [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1]
        let points = anchors.map { x in
            CurvePoint(x: x, y: min(max(matchEvaluator.value(at: baseEvaluator.value(at: x)), 0), 1))
        }
        return AdvancedCurve(type: .master, points: points)
    }
}

/// Everything a match keeps, per clip.
struct ShotMatchSettings: Codable, Equatable, Sendable {
    var reference: ShotMatchReference
    var mode: ShotMatchMode
    var components: ShotMatchComponents
    /// 0...1.
    var strength: Float
    /// The solved values at full strength. What the panel shows, and what
    /// `strength` scales.
    var adjustment: ShotMatchAdjustment
    var confidence: ShotMatchConfidence
    /// The clip's grade the instant before this match landed.
    ///
    /// The whole of what makes a match non-destructive. Reset restores it
    /// exactly; Strength and the component toggles rebuild from it rather than
    /// trying to subtract the previous result out of the current grade, which
    /// would drift a little further from the truth every time it was moved.
    var baseGrade: GradeSettings

    /// The grade this match produces right now.
    var resolvedGrade: GradeSettings {
        adjustment.scaled(by: min(max(strength, 0), 1)).applied(to: baseGrade)
    }

    /// True when the clip's grade is no longer what this match produced,
    /// because the user has been editing since. Not an error: the panel says
    /// so, and moving Strength rebuilds from `baseGrade`, which is the only
    /// definition of "half this match" that stays meaningful.
    func isDetached(from current: GradeSettings) -> Bool { current != resolvedGrade }
}

// ---------------------------------------------------------------------------
// The reference
// ---------------------------------------------------------------------------

/// Where a match's reference picture came from.
///
/// The profile is carried alongside, which is what lets a project reopen with
/// its match intact after the reference image has been moved, renamed or
/// deleted: everything the solver needs was measured at analysis time, and the
/// picture itself is only ever needed again to re-analyse or to draw the
/// thumbnail.
struct ShotMatchReference: Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        /// Another clip on the timeline, at one of its own frames.
        case timelineClip(clipID: UUID, seconds: Double)
        /// A still imported from Files or Photos, stored in the project's own
        /// folder so it survives the original being moved.
        case importedImage(fileName: String)
    }

    var source: Source
    /// What to call it in the panel.
    var displayName: String
    /// Measured once, kept for as long as the match exists.
    var profile: ShotProfile
    /// Whether the profile came from several frames across a shot or from one
    /// frame. Shown in the panel, because it changes what the match means.
    var isClipAverage: Bool

    var thumbnailFileName: String?
}
