import Foundation
import simd

// ---------------------------------------------------------------------------
// Shot Match: the solver
//
// Turns "this picture is not like that one" into grading values.
//
// The method is a forward model with re-measurement, stage by stage, in the
// shader's own order. Each control is solved against the picture as it stands
// after every control before it, and applied before the next one is solved —
// so the answer accounts for the fact that contrast moves the median exposure
// just matched, that the wheels' tonal weights are read from a luminance
// saturation has already changed, and that the four tonal-range sliders share
// one stage and pull on each other's masks.
//
// The alternative — inverting each stage in closed form from summary
// statistics, independently — is quicker to write and is where this kind of
// feature usually goes wrong: every control is individually right about a
// picture that no longer exists by the time it is applied.
//
// Nothing here knows about Metal, the timeline, the editor or SwiftUI. It takes
// two profiles and a set of samples and returns values. That is what lets the
// same solver serve Shot Match, Reference Match and — with no change at all —
// a batch of clips solved against one reference.
// ---------------------------------------------------------------------------

struct ShotMatchSolution: Equatable, Sendable {
    var adjustment: ShotMatchAdjustment
    var confidence: ShotMatchConfidence
    /// How unalike the two pictures were before matching, 0...1. Kept because
    /// it is what damped the result, so a low confidence can be explained.
    var divergence: Float
}

enum MatchSolver {

    /// How many samples the solve runs on.
    ///
    /// Every percentile the solve aims at is backed by at least two hundred of
    /// them — the outermost pair, the 5th and 95th, by exactly that — which is
    /// what keeps a control from chasing sampling noise. Small enough that the
    /// whole solve, which re-grades this set some hundreds of times, is a few
    /// milliseconds rather than a visible pause.
    ///
    /// The 1st and 99th percentiles are measured and kept, but nothing is
    /// solved against them: at any sample count a colorist would wait for, they
    /// are a handful of pixels and a dead one moves them. They report clipping
    /// and dynamic range, which is what they are reliable for.
    static let solveSampleCount = 4096
    /// Bisection steps per control. Sixteen resolves a ±100 slider to better
    /// than a thousandth of its range, which is far finer than the control can
    /// be set by hand.
    static let bisectionSteps = 16
    /// Rounds of the tone loop. The controls in it interact, so they are
    /// re-solved against each other; three rounds is where the values stop
    /// moving in practice.
    static let toneRounds = 3

    // MARK: - Entry point

    static func solve(
        targetSamples: ShotSamples,
        target: ShotProfile,
        reference: ShotProfile,
        components: ShotMatchComponents,
        mode: ShotMatchMode
    ) -> ShotMatchSolution {
        guard target.isUsable, reference.isUsable, !targetSamples.isEmpty else {
            return ShotMatchSolution(adjustment: .neutral, confidence: .low, divergence: 1)
        }

        var working = stratified(targetSamples.linear, count: solveSampleCount)
        let divergence = self.divergence(target: target, reference: reference)
        var transform = ShotMatchTransform.neutral

        // 1. White balance. First, because everything measured after it —
        //    neutral, zone chroma, saturation — is measured on a picture whose
        //    cast has been removed, which is the order the shader uses and the
        //    order a colorist works in.
        if components.contains(.whiteBalance) {
            let current = ShotAnalyzer.profile(linearSamples: working)
            let (temperature, tint) = whiteBalance(current: current, reference: reference)
            transform.temperature = temperature
            transform.tint = tint
            working = working.map {
                simd_max(ShotMatchColor.applyWhiteBalance(
                    $0, temperature: temperature, tint: tint), .zero)
            }
        }

        // 2. Exposure, contrast and the four tonal-range sliders. One loop,
        //    because they are one problem: they share a picture and each one
        //    moves the measurement the others are solved against.
        let tone = solveTone(
            samples: working, reference: reference,
            components: components, mode: mode, divergence: divergence)
        transform.exposure = tone.exposure
        transform.contrast = tone.contrast
        transform.highlights = tone.highlights
        transform.shadows = tone.shadows
        transform.whites = tone.whites
        transform.blacks = tone.blacks
        working = applyTone(tone, to: working)

        // 3. Saturation.
        if components.contains(.saturation) {
            let value = solveMonotonic(
                range: saturationLimits, goal: reference.medianSaturation,
                tolerance: saturationTolerance
            ) { candidate in
                ShotAnalyzer.profile(
                    linearSamples: applySaturation(candidate, to: working)).medianSaturation
            }
            transform.saturation = value
            working = applySaturation(value, to: working)
        }

        // 4. The tint of each tonal range. Measured after everything above, so
        //    what is left is genuinely a colour relationship rather than an
        //    exposure or a saturation difference wearing one.
        let wheels = solveWheels(
            samples: working, reference: reference,
            components: components, divergence: divergence)
        transform.wheels = wheels
        if wheels.contains(where: { !$0.isNeutral }) {
            working = applyWheels(wheels, to: working)
        }

        // 5. Whatever tone is still wrong after the sliders have done their
        //    best, as a smooth, limited curve.
        var curvePoints: [CurvePoint]?
        if components.contains(.toneCurve) {
            let current = ShotAnalyzer.profile(linearSamples: working)
            if let points = solveToneCurve(current: current, reference: reference, mode: mode) {
                curvePoints = points
                transform.toneCurve = denseCurve(points)
                working = applyToneCurve(transform.toneCurve, to: working)
            }
        }

        let residual = ShotAnalyzer.profile(linearSamples: working)
        return ShotMatchSolution(
            adjustment: adjustment(from: transform, curvePoints: curvePoints),
            confidence: confidence(residual: residual, reference: reference, divergence: divergence),
            divergence: divergence)
    }

    // MARK: - White balance

    static func whiteBalance(current: ShotProfile, reference: ShotProfile) -> (Float, Float) {
        let coneTarget = ShotMatchColor.toCone(current.neutralBias.simd)
        let coneReference = ShotMatchColor.toCone(reference.neutralBias.simd)
        guard simd_min(coneTarget, coneReference).min() > 1e-5 else { return (0, 0) }
        let gains = coneReference / coneTarget
        var (temperature, tint) = ShotMatchColor.whiteBalance(forConeGains: gains)

        // How much of that to believe. A frame with nothing neutral in it —
        // a sunset, a single-colour wall, a nightclub — gives a grey-world
        // estimate, which is a guess, not a measurement. It is still better
        // than assuming the frame is neutral, so it is used at reduced
        // authority rather than discarded.
        let coverage = min(current.neutralCoverage, reference.neutralCoverage)
        let trust = 0.6 + 0.4 * ShotMatchColor.smoothstep(0.01, 0.10, coverage)
        temperature *= trust
        tint *= trust

        // Normalised units, so the limit is the ±100 the sliders themselves
        // travel expressed as ±1.
        return (min(max(temperature, -1), 1), min(max(tint, -1), 1))
    }

    // MARK: - Tone

    struct ToneValues: Equatable, Sendable {
        var exposure: Float = 0
        var contrast: Float = 0
        var highlights: Float = 0
        var shadows: Float = 0
        var whites: Float = 0
        var blacks: Float = 0
    }

    /// Exposure, contrast and the tonal-range sliders, solved against each
    /// other.
    ///
    /// Each control is solved by bisection against one order statistic, holding
    /// the others fixed, and the whole set is re-solved a few times. The goals
    /// are percentiles rather than means throughout: a mostly dark scene has a
    /// low mean and a perfectly ordinary median, and matching the mean is
    /// exactly how a night exterior gets lifted into a grey mess because the
    /// reference had a bright sky in the top third.
    static func solveTone(
        samples: [SIMD3<Float>],
        reference: ShotProfile,
        components: ShotMatchComponents,
        mode: ShotMatchMode,
        divergence: Float
    ) -> ToneValues {
        var values = ToneValues()
        let wantsExposure = components.contains(.exposure)
        let wantsContrast = components.contains(.contrast)
        let wantsRange = components.contains(.tonalRange)
        guard wantsExposure || wantsContrast || wantsRange else { return values }

        let original = ShotAnalyzer.profile(linearSamples: samples)

        // Scene-difference protection. Exposure is the control that does the
        // most damage when the reference is simply a different scene — a snowy
        // landscape would have a night interior opened up four stops — so it is
        // the one that yields. Contrast, saturation and the colour of each
        // tonal range describe a STYLE and survive a change of subject, which
        // is why they are not damped here.
        //
        // The damping is applied to the DESTINATION, not to each round's
        // correction. Scaling the correction would only slow the loop down: the
        // residual is re-measured every round, so a damped step just takes more
        // steps to arrive at the same undamped place. Deciding up front how far
        // this match is allowed to travel, and then solving exactly for that,
        // is the only form of damping that survives iteration.
        let (modeScale, modeLimit) = mode.exposureAuthority
        let authority = modeScale * (1 - 0.7 * divergence)
        let limit = min(modeLimit, GradeParameter.exposure.range.upperBound)
        let measuredDifference = exposureCorrection(current: original, reference: reference)
        let exposureGoal = wantsExposure
            ? min(max(measuredDifference * authority, -limit), limit)
            : 0
        // Every control aims at the same place. `goal` is the reference's own
        // tone shape, moved to the brightness this match has decided to go to,
        // so contrast and the tonal-range sliders are not quietly restoring the
        // exposure the damping above just declined to take.
        let goal = reference.scalingExposure(by: exposureGoal - measuredDifference)

        func measured(_ candidate: ToneValues) -> ShotProfile {
            ShotAnalyzer.profile(linearSamples: applyTone(candidate, to: samples))
        }

        for round in 0..<toneRounds {
            if wantsExposure {
                // Solved directly rather than by bisection: exposure is a pure
                // multiply in linear light, so the correction is the log of a
                // ratio of percentiles and one measurement gives it. What the
                // loop handles is that contrast and the tonal-range sliders
                // then move those percentiles again — so what is corrected each
                // round is the gap between where the picture has actually
                // ARRIVED and where this match decided to take it.
                let achieved = exposureCorrection(current: original, reference: measured(values))
                values.exposure = min(max(values.exposure + (exposureGoal - achieved), -limit), limit)
            }
            if wantsContrast {
                // Contrast is solved against the distance between the 10th and
                // 90th percentiles in stops — how much of the range the picture
                // uses — rather than against a slider-shaped idea of "more
                // contrast". That is the measurement that makes a flat Log clip
                // and a finished Rec.709 reference comparable at all.
                values.contrast = solveMonotonic(
                    range: contrastLimits, goal: spread(goal), tolerance: spreadTolerance
                ) { candidate in
                    var trial = values; trial.contrast = candidate
                    return spread(measured(trial))
                }
            }
            // Held at zero for the first round. The tonal-range sliders are trim
            // controls, and trimming a picture whose exposure and contrast have
            // not settled yet just means they spend the rest of the solve
            // undoing a correction that belonged to something else — which is
            // how a match ends up reading Contrast +66, Highlights −40 for a
            // picture that only ever needed a third of a stop.
            if wantsRange, round > 0 {
                // Each slider owns a different part of the range, so no two are
                // solving for the same number: the endpoints set where the
                // picture starts and stops, and the quartiles between them are
                // the toe and the shoulder.
                solveRangeSlider(\.blacks, percentile: ShotPercentile.p5,
                                 goal: goal, values: &values, measured: measured)
                solveRangeSlider(\.whites, percentile: ShotPercentile.p95,
                                 goal: goal, values: &values, measured: measured)
                solveRangeSlider(\.shadows, percentile: ShotPercentile.p25,
                                 goal: goal, values: &values, measured: measured)
                solveRangeSlider(\.highlights, percentile: ShotPercentile.p75,
                                 goal: goal, values: &values, measured: measured)
            }
        }
        return values
    }

    private static func solveRangeSlider(
        _ keyPath: WritableKeyPath<ToneValues, Float>,
        percentile: Int,
        goal: ShotProfile,
        values: inout ToneValues,
        measured: (ToneValues) -> ShotProfile
    ) {
        // The 5th and 95th are backed by a twentieth of the samples where the
        // quartiles have a quarter, so they are allowed to sit further out
        // before anything is done about it.
        let tolerance = (percentile == ShotPercentile.p5 || percentile == ShotPercentile.p95)
            ? tailTolerance : percentileTolerance
        values[keyPath: keyPath] = solveMonotonic(
            range: rangeSliderLimits, goal: goal.percentile(percentile), tolerance: tolerance
        ) { candidate in
            var trial = values
            trial[keyPath: keyPath] = candidate
            return measured(trial).percentile(percentile)
        }
    }

    /// The exposure correction, in stops, that best aligns the middle of the
    /// picture with the reference's.
    ///
    /// Three percentiles rather than one, weighted toward the median: a single
    /// median can be dragged by a large flat area, and the quartiles on either
    /// side stabilise it without reaching into the tails, where clipping and
    /// noise live. A percentile whose value is at the very bottom of the range
    /// in either picture is skipped — a ratio of two near-zero numbers is not a
    /// measurement of anything.
    static func exposureCorrection(current: ShotProfile, reference: ShotProfile) -> Float {
        let anchors: [(index: Int, weight: Float)] = [
            (ShotPercentile.p25, 0.25), (ShotPercentile.p50, 0.5), (ShotPercentile.p75, 0.25)
        ]
        var total: Float = 0, weight: Float = 0
        for anchor in anchors {
            let t = current.linearPercentile(anchor.index)
            let r = reference.linearPercentile(anchor.index)
            guard t > 2e-4, r > 2e-4 else { continue }
            total += anchor.weight * log2(r / t)
            weight += anchor.weight
        }
        if weight > 0 { return total / weight }
        // Everything usable was too dark to divide. Fall back to the brightest
        // percentile that exists in both pictures rather than reporting no
        // difference, which would leave a black frame black.
        let t = current.linearPercentile(ShotPercentile.p95)
        let r = reference.linearPercentile(ShotPercentile.p95)
        guard t > 1e-5, r > 1e-5 else { return 0 }
        return log2(r / t)
    }

    /// Distance from the 10th to the 90th percentile, in stops.
    static func spread(_ profile: ShotProfile) -> Float {
        let low = max(profile.linearPercentile(ShotPercentile.p10), 1e-4)
        let high = max(profile.linearPercentile(ShotPercentile.p90), low * 1.0001)
        return log2(high / low)
    }

    // MARK: - Colour of each tonal range

    /// One wheel per tonal range, carrying the tint of that range and nothing
    /// else.
    ///
    /// Each zone's chroma is measured normalised to unit luminance on both
    /// sides, so what is compared is "the shadows lean this way" rather than
    /// "the shadows are this colour" — which is the difference between carrying
    /// a teal shadow relationship across and painting the target's shadows with
    /// the reference's actual shadow colour.
    ///
    /// Brightness is left at zero deliberately. A wheel can lift its range, but
    /// so can the tonal-range sliders, which have already been solved against
    /// measured percentiles; letting both correct the same thing would make the
    /// result depend on which ran last and would double the correction whenever
    /// the two agreed.
    static func solveWheels(
        samples: [SIMD3<Float>],
        reference: ShotProfile,
        components: ShotMatchComponents,
        divergence: Float
    ) -> [ShotMatchWheel] {
        var wheels = [ShotMatchWheel](repeating: .neutral, count: 3)
        let wanted = ShotZone.allCases.filter { components.contains(components.color(for: $0)) }
        guard !wanted.isEmpty else { return wheels }
        let current = ShotAnalyzer.profile(linearSamples: samples)

        for zone in wanted {
            let ratio = ShotAnalyzer.normalizedToUnitLuminance(
                reference.zone(zone) / simd_max(current.zone(zone), SIMD3(repeating: 1e-4)))
            let exponent = SIMD3(log2(max(ratio.x, 1e-4)),
                                 log2(max(ratio.y, 1e-4)),
                                 log2(max(ratio.z, 1e-4)))
            // The wheel's tint direction is luminance-neutral by construction,
            // so the part of the correction that is not is a brightness change
            // and is removed here rather than being smeared into the hue.
            let brightness = ShotMatchColor.luminance(exponent)
            let chroma = exponent - SIMD3(repeating: brightness)
            guard simd_length(chroma) > 1e-4 else { continue }

            // The hue whose tint direction points most nearly along the
            // correction. Swept at one-degree steps: the tint direction is a
            // piecewise-linear function of hue, so there is no closed form
            // worth the trouble, and 360 dot products cost nothing.
            var bestHue: Float = 0, bestProjection: Float = 0, bestNorm: Float = 1
            for degrees in 0..<360 {
                let turns = Float(degrees) / 360
                let tint = ShotMatchColor.wheelTint(turns)
                let norm = simd_length_squared(tint)
                guard norm > 1e-6 else { continue }
                let projection = simd_dot(chroma, tint)
                if projection > bestProjection {
                    bestProjection = projection; bestHue = turns; bestNorm = norm
                }
            }
            guard bestProjection > 0 else { continue }
            // `wheelGrade` scales its tint by 0.8 before exponentiating, so the
            // strength that reproduces the measured correction divides it back
            // out. Capped well below the control's full travel: past this a
            // wheel stops reading as a tonal relationship and starts reading as
            // a colour cast, and the reference almost never means the latter.
            let strength = bestProjection / (bestNorm * 0.8)
            let damped = strength * (1 - 0.35 * divergence)
            guard damped >= wheelStrengthFloor else { continue }
            wheels[zone.rawValue] = ShotMatchWheel(
                hue: bestHue,
                strength: min(damped, wheelStrengthLimit),
                brightness: 0)
        }
        return wheels
    }

    // MARK: - Residual tone curve

    /// The mapping that takes what is left of the tonal difference across,
    /// smoothed and slope-limited.
    ///
    /// Built by percentile matching rather than by equalising histograms: at a
    /// set of anchor levels, the level in the target that holds the same share
    /// of the picture as that level does in the reference. A raw mapping like
    /// that is a faithful description of two different scenes and a terrible
    /// tone curve — it is jagged, it inverts wherever the two pictures disagree
    /// about a narrow band, and it posterises anything it flattens. So it is
    /// then:
    ///
    ///   - blended toward the identity by the mode's own authority,
    ///   - smoothed across its anchors,
    ///   - slope-limited, so no segment can compress detail into a flat patch
    ///     or stretch it into banding,
    ///   - and pinned at both ends, so the black and white points stay the
    ///     business of the controls that were solved for them.
    ///
    /// Returns nil when what survives all that is a straight line, rather than
    /// storing a curve that does nothing.
    static func solveToneCurve(
        current: ShotProfile, reference: ShotProfile, mode: ShotMatchMode
    ) -> [CurvePoint]? {
        let anchors: [Float] = [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1]
        let authority = mode.toneCurveAuthority

        var mapped = anchors.map { x -> Float in
            let share = sample(current.luminanceCDF, at: x)
            let level = level(reference.luminanceCDF, forShare: share)
            return x + (level - x) * authority
        }
        // Ends belong to the black and white point controls.
        mapped[0] = 0
        mapped[mapped.count - 1] = 1

        // Smooth across neighbours. One pass of a small kernel: enough to take
        // the corners off a percentile-matched shape, not enough to flatten a
        // genuine S.
        var smoothed = mapped
        for index in 1..<(mapped.count - 1) {
            smoothed[index] = mapped[index - 1] * 0.25 + mapped[index] * 0.5 + mapped[index + 1] * 0.25
        }

        // Slope limiting, in order, so each segment is legal against the point
        // before it. A slope below the floor crushes a band of the picture into
        // one value; above the ceiling it stretches a few levels across a wide
        // range, which is where banding comes from on an 8-bit source.
        let step = anchors[1] - anchors[0]
        for index in 1..<(smoothed.count - 1) {
            let previous = smoothed[index - 1]
            let low = previous + step * minimumCurveSlope
            let high = previous + step * maximumCurveSlope
            smoothed[index] = min(max(smoothed[index], low), high)
        }
        // The last segment is fixed at 1, so the point before it has to leave a
        // legal slope into the end rather than being clamped after the fact.
        let lastIndex = smoothed.count - 2
        smoothed[lastIndex] = min(max(smoothed[lastIndex], 1 - step * maximumCurveSlope),
                                  1 - step * minimumCurveSlope)

        let deviation = zip(anchors, smoothed).map { abs($1 - $0) }.max() ?? 0
        guard deviation > 0.004 else { return nil }
        return zip(anchors, smoothed).map { CurvePoint(x: $0, y: min(max($1, 0), 1)) }
    }

    // MARK: - Confidence

    /// How unalike the two pictures are, before anything is matched.
    ///
    /// Four independent signals, because each one is fooled by something
    /// different: two pictures can share a palette and nothing else, or share a
    /// tonal range while one is a face and the other a landscape.
    static func divergence(target: ShotProfile, reference: ShotProfile) -> Float {
        // Histogram intersection over the hue bins. 0 when the two pictures
        // draw on the same colours, 1 when they have none in common.
        let hueOverlap = zip(target.hueDistribution, reference.hueDistribution)
            .reduce(Float(0)) { $0 + min($1.0, $1.1) }
        let hue = 1 - min(max(hueOverlap, 0), 1)

        // How far apart the two sit in overall brightness, in stops.
        let exposureGap = abs(log2(
            max(reference.linearPercentile(ShotPercentile.p50), 1e-4)
                / max(target.linearPercentile(ShotPercentile.p50), 1e-4)))
        let exposure = min(exposureGap / 3, 1)

        // And in how much of the range each uses.
        let rangeGap = abs(reference.dynamicRangeStops - target.dynamicRangeStops)
        let range = min(rangeGap / 6, 1)

        // A picture that is already clipped at either end cannot be measured
        // reliably at that end.
        let clipping = min(max(target.shadowClipping, target.highlightClipping,
                               reference.shadowClipping, reference.highlightClipping) * 4, 1)

        let score = hue * 0.35 + exposure * 0.30 + range * 0.20 + clipping * 0.15
        return min(max(score, 0), 1)
    }

    /// How close the solved picture actually landed, which is a different
    /// question from how alike the two scenes were.
    ///
    /// A very different reference can still produce a confident match — a warm
    /// film still and a cold interior have almost no colours in common and the
    /// match between them can be excellent. So the residual is measured, and
    /// the up-front divergence only pulls the result down when it was large
    /// enough to have damped the solve in the first place.
    static func confidence(
        residual: ShotProfile, reference: ShotProfile, divergence: Float
    ) -> ShotMatchConfidence {
        var error: Float = 0
        // Tone, in stops, at the percentiles the solve aimed at.
        for index in [ShotPercentile.p10, ShotPercentile.p50, ShotPercentile.p90] {
            let a = max(residual.linearPercentile(index), 1e-4)
            let b = max(reference.linearPercentile(index), 1e-4)
            error += min(abs(log2(b / a)) / 1.5, 1) * 0.2
        }
        // Neutral balance, as the remaining cast.
        let cast = simd_length(residual.neutralBias.simd - reference.neutralBias.simd)
        error += min(cast / 0.15, 1) * 0.2
        // Saturation.
        let saturationGap = abs(residual.medianSaturation - reference.medianSaturation)
        error += min(saturationGap / 0.2, 1) * 0.2

        let score = min(max(error + divergence * 0.25, 0), 1)
        if score < 0.28 { return .high }
        if score < 0.55 { return .medium }
        return .low
    }

    // MARK: - Limits
    //
    // Every limit here answers a specific way this feature fails when it is let
    // run free, and each one is deliberately tighter than the control's own
    // range: the match is a starting point, and a starting point that has
    // already used the whole travel of a slider leaves the colorist nowhere to
    // go.

    /// Normalised saturation. A picture can be taken down to 40% of its
    /// colourfulness or up to 1.8×; past the top, skin goes neon long before
    /// the measurement says the match is done.
    static let saturationLimits: ClosedRange<Float> = -0.6...0.8
    /// Normalised contrast, which is ±0.85 stops of slope about middle grey.
    static let contrastLimits: ClosedRange<Float> = -0.85...0.85
    /// Normalised tonal-range sliders. Deliberately short of the full travel:
    /// these are trim controls that shape the toe and shoulder around a tone
    /// exposure and contrast have already set, and a match that spends all of
    /// one of them has misattributed something.
    static let rangeSliderLimits: ClosedRange<Float> = -0.6...0.6
    /// Normalised wheel strength. Half travel: past it a wheel stops reading as
    /// the tint of a tonal range.
    static let wheelStrengthLimit: Float = 0.5
    /// A residual tone curve may not compress a band of the picture below half
    /// its original spacing, nor stretch it beyond double.
    static let minimumCurveSlope: Float = 0.5
    static let maximumCurveSlope: Float = 2.0

    // Deadbands: how close is close enough.
    //
    // Sized from what the measurement can actually resolve at
    // `solveSampleCount`, so that a control only moves when there is a real
    // difference behind it. They are also, not by coincidence, roughly the
    // smallest differences a person can see: a quarter of a code value in the
    // midtones, a twentieth of a stop of range.

    /// A quartile, in encoded units. Around 1.5 code values of 255.
    static let percentileTolerance: Float = 0.006
    /// The 5th and 95th, which sit on a twentieth of the samples.
    static let tailTolerance: Float = 0.010
    /// The 10th-to-90th distance, in stops. Larger than it looks: it is a
    /// difference of two noisy percentiles, so it carries both of their errors.
    static let spreadTolerance: Float = 0.07
    /// Median HSL saturation.
    static let saturationTolerance: Float = 0.01
    /// How far a tonal range's tint must be off before a wheel is worth writing
    /// — below this the wheel would be a number in the panel with no visible
    /// effect on the picture.
    static let wheelStrengthFloor: Float = 0.03

    // MARK: - Stage appliers
    //
    // Each of these is one stage of `applyGradeCore`, applied to a sample set.
    // They exist separately from `ShotMatchForwardModel.apply` because the
    // solver walks the stages in order and keeps the intermediate picture: a
    // control is solved against what the controls before it produced, not
    // against a fresh run from the source.

    static func applyTone(_ values: ToneValues, to samples: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var transform = ShotMatchTransform.neutral
        transform.exposure = values.exposure
        transform.contrast = values.contrast
        transform.highlights = values.highlights
        transform.shadows = values.shadows
        transform.whites = values.whites
        transform.blacks = values.blacks
        guard transform != .neutral else { return samples }
        return samples.map { sample in
            var color = sample
            if transform.exposure != 0 { color *= exp2(transform.exposure) }
            color = ShotMatchForwardModel.applyTonalRange(transform, to: color)
            if transform.contrast != 0 {
                let slope = exp2(transform.contrast * 0.85)
                color = simd_max((color - SIMD3(repeating: 0.18)) * slope + SIMD3(repeating: 0.18), .zero)
            }
            return color
        }
    }

    static func applySaturation(_ value: Float, to samples: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard value != 0 else { return samples }
        let scale = max(0, 1 + value)
        return samples.map { sample in
            let luma = SIMD3(repeating: ShotMatchColor.luminance(sample))
            return luma + (sample - luma) * scale
        }
    }

    static func applyWheels(_ wheels: [ShotMatchWheel], to samples: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var transform = ShotMatchTransform.neutral
        transform.wheels = wheels
        return samples.map { ShotMatchForwardModel.applyWheels(transform, to: $0) }
    }

    static func applyToneCurve(_ curve: [Float], to samples: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard !curve.isEmpty else { return samples }
        return samples.map { sample in
            let encoded = simd_clamp(ShotMatchColor.toEncoded(sample), .zero, .one)
            return ShotMatchColor.toLinear(SIMD3(
                ShotMatchForwardModel.sampleToneCurve(curve, encoded.x),
                ShotMatchForwardModel.sampleToneCurve(curve, encoded.y),
                ShotMatchForwardModel.sampleToneCurve(curve, encoded.z)))
        }
    }

    // MARK: - Utilities

    /// Finds the input that produces `goal`, assuming the function is monotonic
    /// over the range.
    ///
    /// Bisection rather than Newton: every function here is a measurement of a
    /// re-graded sample set, so it has no derivative worth computing and is
    /// mildly noisy at the resolution of the sample count. Bisection does not
    /// care about either, and sixteen steps is exact enough for a control the
    /// user will nudge by hand anyway.
    ///
    /// `tolerance` is the whole reason the results are usable rather than
    /// merely correct. Two guards use it, and without them a control that
    /// barely influences the number it is aimed at will travel its entire range
    /// chasing sampling noise:
    ///
    ///   - **Deadband.** If leaving the control alone already lands inside the
    ///     tolerance, it is left alone. Nothing here is worth a number in a
    ///     panel that the user cannot see the effect of.
    ///   - **Sensitivity.** If moving the control from one end of its range to
    ///     the other moves the measurement by less than the tolerance, the
    ///     measurement cannot resolve the control at all. Bisection would
    ///     still converge — on whichever end the noise happened to favour —
    ///     which is how Whites lands at +60 and Highlights at −60 on a picture
    ///     that needed neither.
    static func solveMonotonic(
        range: ClosedRange<Float>,
        goal: Float,
        tolerance: Float = 0,
        steps: Int = bisectionSteps,
        _ f: (Float) -> Float
    ) -> Float {
        let atNeutral = f(0)
        guard atNeutral.isFinite else { return 0 }
        if abs(atNeutral - goal) <= tolerance { return 0 }

        var low = range.lowerBound, high = range.upperBound
        let atLow = f(low), atHigh = f(high)
        guard atLow.isFinite, atHigh.isFinite else { return 0 }
        guard abs(atHigh - atLow) > max(tolerance, 1e-6) else { return 0 }

        let increasing = atHigh > atLow
        if (increasing && goal <= atLow) || (!increasing && goal >= atLow) { return low }
        if (increasing && goal >= atHigh) || (!increasing && goal <= atHigh) { return high }
        for _ in 0..<steps {
            let middle = (low + high) / 2
            if (f(middle) < goal) == increasing { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// An evenly spread subset, taken by stride rather than at random.
    ///
    /// The samples arrive already scattered over the frame by the analysis
    /// pass, so a stride keeps that spread and makes the solve deterministic —
    /// the same frame and the same reference always produce the same numbers,
    /// which matters because a colorist who runs a match twice and gets two
    /// answers stops trusting it.
    static func stratified(_ samples: [SIMD3<Float>], count: Int) -> [SIMD3<Float>] {
        guard samples.count > count, count > 0 else { return samples }
        let step = Double(samples.count) / Double(count)
        return (0..<count).map { samples[min(samples.count - 1, Int(Double($0) * step))] }
    }

    /// A 33-point dense curve from the control points, evaluated exactly the
    /// way the app will evaluate them.
    ///
    /// The forward model has to predict the curve the user ends up with, not an
    /// idealised version of it, so this runs the real `CurveEvaluator` over the
    /// real control points rather than re-interpolating them here.
    static func denseCurve(_ points: [CurvePoint]) -> [Float] {
        let evaluator = CurveEvaluator(AdvancedCurve(type: .master, points: points))
        let last = Float(ShotMatchForwardModel.toneCurveSamples - 1)
        return (0..<ShotMatchForwardModel.toneCurveSamples).map {
            min(max(evaluator.value(at: Float($0) / last), 0), 1)
        }
    }

    static func sample(_ cdf: [Float], at x: Float) -> Float {
        ShotMatchForwardModel.sampleToneCurve(cdf, x)
    }

    /// The level at which a CDF reaches `share` — the inverse of `sample`.
    static func level(_ cdf: [Float], forShare share: Float) -> Float {
        guard cdf.count > 1 else { return share }
        let last = cdf.count - 1
        if share <= cdf[0] { return 0 }
        for index in 1...last where cdf[index] >= share {
            let previous = cdf[index - 1]
            let span = cdf[index] - previous
            let fraction = span > 1e-6 ? (share - previous) / span : 0
            return (Float(index - 1) + fraction) / Float(last)
        }
        return 1
    }

    /// The solved transform, in the app's own units.
    static func adjustment(
        from transform: ShotMatchTransform, curvePoints: [CurvePoint]?
    ) -> ShotMatchAdjustment {
        var adjustment = ShotMatchAdjustment()
        adjustment.exposure = transform.exposure
        adjustment.temperature = transform.temperature * 100
        adjustment.tint = transform.tint * 100
        adjustment.contrast = transform.contrast * 100
        adjustment.highlights = transform.highlights * 100
        adjustment.shadows = transform.shadows * 100
        adjustment.whites = transform.whites * 100
        adjustment.blacks = transform.blacks * 100
        adjustment.saturation = transform.saturation * 100
        adjustment.wheels = transform.wheels.map {
            GradingWheel(hue: $0.hue * 360, strength: $0.strength * 100, brightness: $0.brightness * 100)
        }
        adjustment.toneCurve = curvePoints
        return adjustment
    }
}
