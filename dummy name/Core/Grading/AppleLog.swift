import Foundation
import simd

// ---------------------------------------------------------------------------
// Apple Log
//
// Every constant and both branches of both functions come from Apple's
// "Apple Log Profile White Paper", September 2023, version 1.1 (part
// 028-00768), §"Transfer Function" and §"Color Space". Nothing here is derived
// by eye, fitted, or taken from a secondary source.
//
// Apple Log is *scene-referred*: the decoded value is proportional to scene
// reflectance, where 0.18 is an 18% grey card and 1.0 would be a 100% reflector.
// The encoding runs from R0 (a small negative value, so sensor noise below black
// survives instead of being clipped) up to 12.0 — 1200% reflectance, which is
// where the specular highlights live. Preserving that range is the entire point
// of the format, so nothing in this file clamps it.
// ---------------------------------------------------------------------------

enum AppleLog {
    // MARK: - Published constants (white paper, §Transfer Function)

    /// Lowest scene value the encoding represents. Negative by design.
    static let R0: Float = -0.05641088
    /// Where the parabolic toe hands over to the logarithmic curve.
    static let Rt: Float = 0.01
    static let c: Float = 47.28711236
    static let beta: Float = 0.00964052
    static let gamma: Float = 0.08550479
    static let delta: Float = 0.69336945

    /// The encoded value at the branch point, `c(Rt - R0)²`. Computed rather
    /// than written out, so it can never drift from the constants above.
    static let Pt: Float = c * (Rt - R0) * (Rt - R0)

    /// Scene reflectance of a diffuse white card — 90%, per the white paper's
    /// reference table. Used to normalise into the working space, where diffuse
    /// white sits at 1.0.
    static let diffuseWhiteReflectance: Float = 0.9

    // MARK: - Transfer function

    /// Encoding function `P = f(R)`: linear scene reflectance to Apple Log.
    ///
    /// White paper §"Encoding function". Provided by Apple for information —
    /// the camera does this — but it is needed here to re-encode a graded image
    /// for Apple's own display-rendering LUT.
    static func encode(_ R: Float) -> Float {
        if R < R0 { return 0 }
        if R < Rt { return c * (R - R0) * (R - R0) }
        return gamma * log2(R + beta) + delta
    }

    /// Decoding function `R = f⁻¹(P)`: Apple Log to linear scene reflectance.
    ///
    /// White paper §"Decoding function". This is the transform that makes the
    /// footage gradeable.
    static func decode(_ P: Float) -> Float {
        if P < 0 { return R0 }
        if P < Pt { return sqrt(P / c) + R0 }
        return exp2((P - delta) / gamma) - beta
    }

    // MARK: - Reference values (white paper, §Transfer Function table)

    /// Apple's published table, used to verify the implementation rather than
    /// to define it: scene reflectance, encoded signal, and the 10-bit
    /// full-range code.
    static let referencePoints: [(reflectance: Float, encoded: Float, code10Bit: Int)] = [
        (0.00, 0.150477, 154),
        (0.18, 0.488272, 500),
        (0.90, 0.681686, 697),
        (12.0, 1.000000, 1023)
    ]

    // MARK: - Colour space (white paper, §Color Space)

    /// Apple Log uses the ITU-R BT.2020-2 primaries with a D65 white point.
    /// Listed for the record; the conversions below are what the pipeline uses.
    static let primaries = (
        red: SIMD2<Float>(0.708, 0.292),
        green: SIMD2<Float>(0.170, 0.797),
        blue: SIMD2<Float>(0.131, 0.046),
        white: SIMD2<Float>(0.3127, 0.3290)
    )

    /// Luma coefficients from the white paper's Y′C′BC′R formula. These are the
    /// BT.2020 non-constant-luminance coefficients.
    static let lumaCoefficients = SIMD3<Float>(0.2627, 0.6780, 0.0593)
    /// The chroma denominators from the same formula.
    static let cbScale: Float = 1.8814
    static let crScale: Float = 1.4746

    /// Y′C′BC′R → R′G′B′, inverted from the white paper's forward equations:
    ///
    ///     Y′ = 0.2627R′ + 0.6780G′ + 0.0593B′
    ///     C′B = (B′ − Y′) / 1.8814
    ///     C′R = (R′ − Y′) / 1.4746
    ///
    /// so R′ = Y′ + 1.4746·C′R, B′ = Y′ + 1.8814·C′B, and G′ follows from the
    /// luma equation. Chroma is signed, centred on zero.
    static func rgb(fromYCbCr ycbcr: SIMD3<Float>) -> SIMD3<Float> {
        let y = ycbcr.x, cb = ycbcr.y, cr = ycbcr.z
        let r = y + crScale * cr
        let b = y + cbScale * cb
        let g = (y - lumaCoefficients.x * r - lumaCoefficients.z * b) / lumaCoefficients.y
        return SIMD3<Float>(r, g, b)
    }

    // MARK: - Working space

    /// Scene reflectance normalised so diffuse white is 1.0, which is the
    /// convention the extended-range grading path already works in. An 18% grey
    /// card lands at 0.2 and specular highlights run to about 13.3 — unclamped,
    /// which is what keeps the highlight latitude available to the grade.
    static func workingSpace(fromSceneLinear R: Float) -> Float {
        R / diffuseWhiteReflectance
    }

    static func sceneLinear(fromWorkingSpace w: Float) -> Float {
        w * diffuseWhiteReflectance
    }

    /// The full input transform for one channel: Apple Log code value to
    /// working-space linear.
    static func toWorkingSpace(_ P: Float) -> Float {
        workingSpace(fromSceneLinear: decode(P))
    }
}

// ---------------------------------------------------------------------------
// Display rendering
// ---------------------------------------------------------------------------

/// How a graded Apple Log image is rendered for a Rec.709 display.
///
/// The white paper specifies the encoding, the decoding and the colour space —
/// but no display transform. Rather than invent a tone curve, the graded image
/// is re-encoded to Log (the round trip through `encode`/`decode` is exact) and
/// passed through Apple's own published Apple Log to Rec.709 LUT, so an
/// ungraded frame is rendered exactly as Apple renders it, highlight rolloff
/// included.
enum AppleLogRendering {
    /// Apple's rendering LUT, as distributed with the Apple Log profile
    /// materials. A 65³ cube over a 0…1 domain, which is exactly the range the
    /// encoding function produces.
    static let rec709LUTResourceName = "Apple_Log_To_Rec_709"
}

// ---------------------------------------------------------------------------
// Apple Log 2
//
// Apple Log 2 (`com.apple.apple-wide-gamut.apple-log`, iPhone 17 Pro and later)
// is **the Apple Log transfer function carried on different primaries**. That is
// not an inference from how the footage looks — it is what Apple's Apple Log 2
// white paper (September 2025) specifies, and it is how the Academy Software
// Foundation encodes the format in the ACES OCIO config, where "Apple Log 2"
// reuses the `CURVE - APPLE_LOG_to_LINEAR` builtin and differs from Apple Log
// only by a 3x3 matrix.
//
// So nothing in `AppleLog` above is re-derived, re-fitted or duplicated here.
// The decode, the encode, the branch point and the diffuse-white normalisation
// are shared verbatim; this enum adds the one thing that genuinely differs,
// which is the gamut.
//
// Apple Log   = Apple Log curve + ITU-R BT.2020 primaries
// Apple Log 2 = Apple Log curve + Apple Wide Gamut primaries
// ---------------------------------------------------------------------------

enum AppleLog2 {
    // MARK: - Apple Wide Gamut (white paper, §Color Space)

    /// Apple Wide Gamut primaries with a D65 white point.
    ///
    /// The blue primary's negative `y` is not a typo and not a bad transcription.
    /// Apple Wide Gamut is a *virtual* gamut in the same sense as ARRI Wide Gamut:
    /// its primaries sit outside the spectral locus so the encoding can carry
    /// colours a physically realisable primary set could not. Clamping them to
    /// something that "looks reasonable" would silently shrink the gamut.
    static let primaries = (
        red: SIMD2<Float>(0.725, 0.301),
        green: SIMD2<Float>(0.221, 0.814),
        blue: SIMD2<Float>(0.068, -0.076),
        white: SIMD2<Float>(0.3127, 0.3290)
    )

    // MARK: - Gamut conversion

    /// Linear Apple Wide Gamut to linear ITU-R BT.2020, row-major.
    ///
    /// Derived from the primaries above by the standard normalised-primary-matrix
    /// construction: `inverse(NPM(BT.2020, D65)) * NPM(AppleWideGamut, D65)`.
    /// **Both spaces are D65, so no chromatic adaptation is involved** — there is
    /// no choice of CAT to get wrong here, which is the one ambiguity Apple's
    /// paper leaves open for conversions to other white points.
    ///
    /// Verified rather than asserted. The same primaries, adapted to ACES with
    /// Bradford, reproduce the Apple Wide Gamut to ACES2065-1 matrix published by
    /// the Academy Software Foundation to 3.1e-15 — floating-point agreement with
    /// an independently derived source. `AppleLog2Tests` re-runs that check, and
    /// also asserts the property that matters visually: every row sums to 1, so a
    /// neutral stays exactly neutral through the conversion.
    static let wideGamutToBT2020 = simd_float3x3(rows: [
        SIMD3<Float>( 1.0281009382,  0.0989788177, -0.1270797558),
        SIMD3<Float>( 0.0025203419,  1.1708496433, -0.1733699853),
        SIMD3<Float>(-0.0220875732, -0.0640503834,  1.0861379567)
    ])

    /// BT.2020 back to Apple Wide Gamut. Not used by the render path — which only
    /// ever converts inwards — but kept with its forward matrix so the round trip
    /// is testable.
    static let bt2020ToWideGamut = simd_float3x3(rows: [
        SIMD3<Float>( 0.9750428995, -0.0768564900,  0.1018135904),
        SIMD3<Float>( 0.0008445448,  0.8615375131,  0.1376179421),
        SIMD3<Float>( 0.0198781607,  0.0492425795,  0.9308792597)
    ])

    // MARK: - Working space

    /// The full input transform for one pixel: Apple Log 2 code values to the
    /// same working space Apple Log already produces.
    ///
    /// The order is deliberate. The curve is undone *first*, because a gamut
    /// matrix is only meaningful in linear light; applying it to log-encoded
    /// values would be a category error that happens to produce a plausible
    /// picture. Only then are the primaries converted.
    ///
    /// The result is indistinguishable in kind from Apple Log's working space —
    /// scene-referred, BT.2020, diffuse white at 1.0 — which is what lets every
    /// stage after this point be *shared* with Apple Log rather than duplicated:
    /// the grading tools, the look stage, the scopes, and Apple's own published
    /// Apple Log to Rec.709 display rendering.
    static func toWorkingSpace(_ P: SIMD3<Float>) -> SIMD3<Float> {
        let scene = SIMD3<Float>(AppleLog.decode(P.x),
                                 AppleLog.decode(P.y),
                                 AppleLog.decode(P.z))
        return (wideGamutToBT2020 * scene) / AppleLog.diffuseWhiteReflectance
    }

    /// Apple Wide Gamut is wider than BT.2020, so saturated colour can land
    /// outside BT.2020 and arrive here with a negative channel.
    ///
    /// Those values are carried, not clipped: the working space is unclamped
    /// float and the grade runs in it, so the extra gamut stays available to be
    /// pulled back into range by a grade. It is the *display* encode at the very
    /// end of the chain that clamps, exactly as it already does for Apple Log.
    /// No gamut compression is applied on the way in, because Apple publishes
    /// none and a hand-rolled one would change the colours of footage that was
    /// already in range.
    static func isOutsideBT2020(_ working: SIMD3<Float>) -> Bool {
        working.min() < 0
    }
}
