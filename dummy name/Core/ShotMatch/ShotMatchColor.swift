import Foundation
import simd

// ---------------------------------------------------------------------------
// Shot Match: the analysis space
//
// Every picture Shot Match measures — a Rec.709 clip, a 10-bit HLG clip, an
// Apple Log clip, an imported JPEG tagged Display P3 — is measured in ONE
// space, because a comparison between two pictures carried in different spaces
// is not a comparison at all. S-Log code values against Rec.709 code values
// would report a wildly flat, desaturated, green-biased "reference" that is
// simply the encoding.
//
// The space is **Rec.709-encoded RGB on Rec.709 primaries, 0...1, diffuse white
// at 1.0** — the picture as a viewer sees it. That choice, rather than the
// grading pipeline's own working space, is deliberate:
//
//   - It is the only space all four source families can be brought into
//     honestly. The SDR path already produces it; the HDR and Log paths reach
//     it through the same display transform the preview uses, so what Shot
//     Match measures is what is on screen.
//   - "These two shots look the same" is a statement about appearance. Matching
//     in scene-linear BT.2020 would match radiometry, and two clips can agree
//     there while looking nothing alike through their display transforms.
//
// Nothing here is ever applied to a rendered frame. This is measurement only:
// the solver's OUTPUT is ordinary GradeLab parameters, which run in whichever
// pipeline the project already uses. So normalising an HDR frame into this
// bounded space for analysis cannot compress a delivered highlight — the
// picture never travels through here. Content above diffuse white is recorded
// as `headroomFraction` instead of being measured as clipping, which is what
// stops the solver from "rescuing" highlights that were never in trouble.
// ---------------------------------------------------------------------------

/// The transfer and primaries the analysis buffer is carried in.
///
/// One case today. It exists as a type rather than as an assumption so the
/// profile can state what it measured: a stored profile that outlives a change
/// of analysis space must be re-analysed rather than silently compared against
/// numbers that mean something else.
enum ShotMatchAnalysisSpace: String, Codable, Sendable {
    /// Rec.709 primaries, Rec.709 OETF, diffuse white at 1.0.
    case rec709Display
}

/// The colour arithmetic the analyser, the forward model and the solver share.
///
/// Every function here is a transcription of the one the shaders use, and the
/// correspondence is asserted against the real GPU in
/// `Scripts/ValidateShotMatch.swift`. That is the whole reason this file is
/// written out rather than approximated: a solver whose model of `contrast`
/// disagrees with the shader's by a few percent produces a match that is
/// visibly wrong and impossible to debug from the outside.
enum ShotMatchColor {
    /// Rec.709 OETF inverse. Matches `rec709ToLinear` in Shaders.metal.
    static func toLinear(_ value: Float) -> Float {
        let v = max(value, 0)
        return v >= 0.081 ? pow((v + 0.099) / 1.099, 1 / 0.45) : v / 4.5
    }

    /// Matches `linearToRec709` in Shaders.metal.
    static func toEncoded(_ value: Float) -> Float {
        let v = max(value, 0)
        return v >= 0.018 ? 1.099 * pow(v, 0.45) - 0.099 : v * 4.5
    }

    static func toLinear(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(toLinear(rgb.x), toLinear(rgb.y), toLinear(rgb.z))
    }

    static func toEncoded(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(toEncoded(rgb.x), toEncoded(rgb.y), toEncoded(rgb.z))
    }

    static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// Matches `luminance709`.
    static func luminance(_ rgb: SIMD3<Float>) -> Float {
        simd_dot(rgb, lumaWeights)
    }

    /// Matches `hueRGB`: the fully saturated RGB for a hue in turns.
    static func hueRGB(_ turns: Float) -> SIMD3<Float> {
        func channel(_ offset: Float) -> Float {
            var v = (turns + offset).truncatingRemainder(dividingBy: 1)
            if v < 0 { v += 1 }
            return min(max(abs(v * 6 - 3) - 1, 0), 1)
        }
        return SIMD3(channel(0), channel(2.0 / 3.0), channel(1.0 / 3.0))
    }

    /// The luminance-neutral tint direction a grading wheel pushes toward.
    /// Matches the first two lines of `wheelGrade`.
    static func wheelTint(_ turns: Float) -> SIMD3<Float> {
        let rgb = hueRGB(turns)
        return rgb - SIMD3(repeating: luminance(rgb))
    }

    /// HSL saturation, exactly as `rgbToHSL` computes it. The input is
    /// Rec.709-**encoded**, which is where the shader's HSL stage works.
    static func saturation(encoded rgb: SIMD3<Float>) -> Float {
        let hi = max(rgb.x, max(rgb.y, rgb.z))
        let lo = min(rgb.x, min(rgb.y, rgb.z))
        let l = (hi + lo) * 0.5
        return (hi - lo) / max(1 - abs(2 * l - 1), 0.00001)
    }

    /// Hue in turns, or nil for a pixel with no meaningful hue. Matches
    /// `rgbToHSL`'s hue branch, including its 1e-5 guard.
    static func hue(encoded rgb: SIMD3<Float>) -> Float? {
        let hi = max(rgb.x, max(rgb.y, rgb.z))
        let lo = min(rgb.x, min(rgb.y, rgb.z))
        let d = hi - lo
        guard d > 0.00001 else { return nil }
        var h: Float
        if hi == rgb.x { h = (rgb.y - rgb.z) / d }
        else if hi == rgb.y { h = 2 + (rgb.z - rgb.x) / d }
        else { h = 4 + (rgb.x - rgb.y) / d }
        h = (h / 6 + 1).truncatingRemainder(dividingBy: 1)
        return h < 0 ? h + 1 : h
    }

    /// Matches `smoothstep` in MSL.
    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Bradford chromatic adaptation

    // The same matrices `applyWhiteBalance` uses. Written column-major to match
    // the MSL `float3x3(col0, col1, col2)` constructors they were copied from,
    // so the two can be compared line by line.

    static let rgbToXYZ = simd_float3x3(
        SIMD3(0.4123908, 0.2126390, 0.0193308),
        SIMD3(0.3575843, 0.7151687, 0.1191948),
        SIMD3(0.1804808, 0.0721923, 0.9505322))

    static let xyzToRGB = simd_float3x3(
        SIMD3( 3.2409699, -0.9692436,  0.0556301),
        SIMD3(-1.5373832,  1.8759675, -0.2039770),
        SIMD3(-0.4986108,  0.0415551,  1.0569715))

    static let xyzToBradford = simd_float3x3(
        SIMD3( 0.8951, -0.7502,  0.0389),
        SIMD3( 0.2664,  1.7135, -0.0685),
        SIMD3(-0.1614,  0.0367,  1.0296))

    static let bradfordToXYZ = simd_float3x3(
        SIMD3( 0.9869929,  0.4323053, -0.0085287),
        SIMD3(-0.1470543,  0.5183603,  0.0400428),
        SIMD3( 0.1599627,  0.0492912,  0.9684867))

    /// Linear Rec.709 to Bradford cone response.
    static func toCone(_ linearRGB: SIMD3<Float>) -> SIMD3<Float> {
        xyzToBradford * (rgbToXYZ * linearRGB)
    }

    /// The exact transform `applyWhiteBalance` performs, given the shader's
    /// normalised parameters (slider value / 100).
    ///
    /// The SDR shader clamps the result at zero and the HDR one does not; the
    /// clamp is left out here because the analysis space has no out-of-gamut
    /// coordinates to protect, and applying it would bias the model against the
    /// HDR path it also has to predict.
    static func applyWhiteBalance(
        _ linearRGB: SIMD3<Float>, temperature: Float, tint: Float
    ) -> SIMD3<Float> {
        let gains = coneGains(temperature: temperature, tint: tint)
        return xyzToRGB * (bradfordToXYZ * (toCone(linearRGB) * gains))
    }

    /// The cone-response gains a given temperature/tint pair produces.
    static func coneGains(temperature: Float, tint: Float) -> SIMD3<Float> {
        SIMD3(
            exp2(temperature * 0.18 - tint * 0.035),
            exp2(tint * 0.14),
            exp2(-temperature * 0.18 - tint * 0.035))
    }

    /// The inverse: the temperature and tint that come closest to producing
    /// `gains` in cone-response space.
    ///
    /// Exact rather than fitted. Writing the shader's own definition out in
    /// logs,
    ///
    ///     log2(gain.L) =  T·0.18 − t·0.035
    ///     log2(gain.M) =           t·0.14
    ///     log2(gain.S) = −T·0.18 − t·0.035
    ///
    /// leaves tint alone on the M row and temperature alone in the L−S
    /// difference, where the two tint terms cancel. What the pair cannot
    /// express is a common gain on all three cones — that is an exposure
    /// change wearing a white-balance costume, and it is deliberately dropped
    /// here so the exposure stage can measure and own it.
    ///
    /// Returned in the shader's normalised units, the same ones
    /// `applyWhiteBalance` takes — a slider value divided by a hundred.
    static func whiteBalance(forConeGains gains: SIMD3<Float>) -> (temperature: Float, tint: Float) {
        let safe = SIMD3(max(gains.x, 1e-6), max(gains.y, 1e-6), max(gains.z, 1e-6))
        let l = log2(safe.x), m = log2(safe.y), s = log2(safe.z)
        return (temperature: (l - s) / 0.36, tint: m / 0.14)
    }
}
