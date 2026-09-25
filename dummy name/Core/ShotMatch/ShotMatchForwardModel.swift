import Foundation
import simd

// ---------------------------------------------------------------------------
// Shot Match: the forward model
//
// A transcription of `applyGradeCore` in Shaders.metal, restricted to the
// controls Shot Match is allowed to write, and operating on a few thousand
// representative pixels rather than on a frame.
//
// This is what makes the solver honest. Solving each control from a closed-form
// inversion of its own stage, in isolation, is the usual way this feature is
// built and it is why so many of them miss: the stages are not independent. A
// contrast change moves the median the exposure stage just matched; a
// saturation change moves the per-zone chroma the wheels are about to be solved
// from; the tonal masks are read from a luminance that every earlier stage has
// already altered. Predicting the picture after each stage and re-measuring is
// the only way the numbers add up, and it costs a few thousand multiplies.
//
// The correspondence with the shader is not assumed. `ShotMatchModelTests` and
// `Scripts/ValidateShotMatch.swift` run the same colours through this model and
// through the real `applyGrade` on the GPU and require them to agree; if a
// grading stage is ever retuned, that check fails rather than the match quietly
// becoming wrong.
// ---------------------------------------------------------------------------

/// The controls Shot Match solves, in the shader's own normalised units
/// (slider value ÷ 100, except exposure, which is already in stops).
///
/// Deliberately not `GradeSettings`. This is the model's internal currency: it
/// carries only what the solver writes, so a stage cannot accidentally read a
/// control it has no business predicting, and the conversion to and from the
/// app's units happens in exactly one place (`ShotMatchAdjustment`).
struct ShotMatchTransform: Equatable, Sendable {
    var exposure: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var saturation: Float = 0
    /// Shadows, midtones, highlights. Hue in turns, strength and brightness
    /// normalised, exactly as `GradeUniforms` hands them to `wheelGrade`.
    var wheels: [ShotMatchWheel] = Array(repeating: .neutral, count: 3)
    /// The residual tone mapping, sampled on a uniform grid over encoded luma.
    /// Empty means identity.
    var toneCurve: [Float] = []

    static let neutral = ShotMatchTransform()

    /// Every solved value scaled toward neutral.
    ///
    /// This is what Match Strength does, and it is a genuine interpolation of
    /// the transform rather than a fade of the result. Every control here is
    /// either additive in a log domain (exposure in stops, the white-balance
    /// exponents, the contrast slope's exponent, the wheels' exponents) or a
    /// signed delta around zero, so scaling the parameter scales the transform
    /// itself: at 50% the picture is moved exactly half the distance, in the
    /// same space the control operates in. Cross-fading the graded result with
    /// the ungraded one would instead average two pictures, which desaturates
    /// through the middle and is not what half a match looks like.
    func scaled(by strength: Float) -> ShotMatchTransform {
        guard strength != 1 else { return self }
        var scaled = self
        scaled.exposure *= strength
        scaled.temperature *= strength
        scaled.tint *= strength
        scaled.contrast *= strength
        scaled.highlights *= strength
        scaled.shadows *= strength
        scaled.whites *= strength
        scaled.blacks *= strength
        scaled.saturation *= strength
        scaled.wheels = wheels.map { $0.scaled(by: strength) }
        // The curve is stored as absolute outputs, so it interpolates toward
        // the identity it is sampled against rather than toward zero.
        if !toneCurve.isEmpty {
            let last = Float(toneCurve.count - 1)
            scaled.toneCurve = toneCurve.enumerated().map { index, value in
                let identity = Float(index) / max(last, 1)
                return identity + (value - identity) * strength
            }
        }
        return scaled
    }
}

struct ShotMatchWheel: Equatable, Sendable {
    /// Turns of the colour wheel, 0...1.
    var hue: Float = 0
    /// Normalised colour strength, 0...1.
    var strength: Float = 0
    /// Normalised brightness, signed.
    var brightness: Float = 0

    static let neutral = ShotMatchWheel()

    var isNeutral: Bool { strength == 0 && brightness == 0 }

    func scaled(by amount: Float) -> ShotMatchWheel {
        ShotMatchWheel(hue: hue, strength: strength * amount, brightness: brightness * amount)
    }
}

enum ShotMatchForwardModel {
    /// Samples per axis of the residual tone curve. 33 is the same count a
    /// `.cube` look uses per axis and is far more than the smooth, slope-limited
    /// shape the solver produces needs.
    static let toneCurveSamples = 33

    /// One pixel through the grading stages Shot Match writes.
    ///
    /// Input and output are **linear** analysis-space RGB. The tone curve is
    /// applied in the encoded domain, which is where the shader's curve stage
    /// lives, so the round trip through the OETF is part of the model rather
    /// than an approximation of it.
    static func apply(_ transform: ShotMatchTransform, to linearRGB: SIMD3<Float>) -> SIMD3<Float> {
        var color = linearRGB

        if transform.temperature != 0 || transform.tint != 0 {
            color = ShotMatchColor.applyWhiteBalance(
                color, temperature: transform.temperature, tint: transform.tint)
            color = simd_max(color, .zero)
        }
        if transform.exposure != 0 {
            color *= exp2(transform.exposure)
        }

        color = applyTonalRange(transform, to: color)

        if transform.contrast != 0 {
            let slope = exp2(transform.contrast * 0.85)
            color = simd_max((color - SIMD3(repeating: 0.18)) * slope + SIMD3(repeating: 0.18), .zero)
        }

        if transform.saturation != 0 {
            let luma = ShotMatchColor.luminance(color)
            let scale = max(0, 1 + transform.saturation)
            color = SIMD3(repeating: luma) + (color - SIMD3(repeating: luma)) * scale
        }

        color = applyWheels(transform, to: color)

        // The shader clamps here on the way into the curve and HSL stages.
        var encoded = simd_min(simd_max(ShotMatchColor.toEncoded(color), .zero), .one)
        if !transform.toneCurve.isEmpty {
            encoded = SIMD3(
                sampleToneCurve(transform.toneCurve, encoded.x),
                sampleToneCurve(transform.toneCurve, encoded.y),
                sampleToneCurve(transform.toneCurve, encoded.z))
        }
        return ShotMatchColor.toLinear(encoded)
    }

    /// The same, for a whole sample set.
    static func apply(_ transform: ShotMatchTransform, to samples: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard transform != .neutral else { return samples }
        return samples.map { apply(transform, to: $0) }
    }

    /// The four tonal-range sliders, which are one stage of the shader sharing
    /// one luminance reading and four overlapping masks.
    ///
    /// Written out as its own function because the solver walks the stages one
    /// at a time and has to apply exactly this much of the grade and no more.
    /// Two copies of these masks would be two chances for the solver to be
    /// solving something the picture does not do.
    static func applyTonalRange(
        _ transform: ShotMatchTransform, to color: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard transform.highlights != 0 || transform.shadows != 0
                || transform.whites != 0 || transform.blacks != 0 else { return color }
        let luma = max(ShotMatchColor.luminance(color), 0)
        let shadowMask = 1 - ShotMatchColor.smoothstep(0.08, 0.50, luma)
        let highlightMask = ShotMatchColor.smoothstep(0.32, 1.0, luma)
        let blackMask = 1 - ShotMatchColor.smoothstep(0.0, 0.18, luma)
        let whiteMask = ShotMatchColor.smoothstep(0.62, 1.0, luma)
        let delta = transform.shadows * shadowMask * max(luma, 0.035) * 0.75
            + transform.highlights * highlightMask * max(luma, 0.08) * 0.65
            + transform.blacks * blackMask * 0.045
            + transform.whites * whiteMask * 0.085
        let adjusted = max(luma + delta, 0)
        // `preserveHueLuminance`: the correction is a change of brightness, so
        // it scales the colour rather than being added to it, and the hue and
        // saturation survive untouched.
        return luma > 0.00001
            ? color * (adjusted / max(luma, 0.00001))
            : SIMD3(repeating: adjusted)
    }

    /// The three tonal wheels.
    ///
    /// All three read their weights from ONE luminance, taken before any of
    /// them has run — which is what makes them commute, and what lets the
    /// solver solve each tonal range from the same starting picture instead of
    /// in a fixed order.
    static func applyWheels(
        _ transform: ShotMatchTransform, to color: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard transform.wheels.contains(where: { !$0.isNeutral }) else { return color }
        let weights = ShotZone.weights(linearLuminance: ShotMatchColor.luminance(color))
        var result = color
        for (index, wheel) in transform.wheels.enumerated() where !wheel.isNeutral {
            guard index < 3 else { break }
            let tint = ShotMatchColor.wheelTint(wheel.hue)
            let exponent = (tint * (wheel.strength * 0.8) + SIMD3(repeating: wheel.brightness))
                * weights[index]
            result *= SIMD3(exp2(exponent.x), exp2(exponent.y), exp2(exponent.z))
        }
        return result
    }

    /// Linear interpolation into a uniformly sampled curve, which is what the
    /// GPU's `filter::linear` fetch from the curve LUT row performs.
    static func sampleToneCurve(_ curve: [Float], _ x: Float) -> Float {
        guard curve.count > 1 else { return x }
        let position = min(max(x, 0), 1) * Float(curve.count - 1)
        let index = Int(position)
        guard index < curve.count - 1 else { return curve[curve.count - 1] }
        let fraction = position - Float(index)
        return curve[index] + (curve[index + 1] - curve[index]) * fraction
    }
}
