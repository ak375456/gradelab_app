import Foundation

/// Warm Cinema — a warm, premium cinematic grade for Rec.709 / working SDR footage.
///
/// Tone: a gentle black compression deepens the toe without crushing it (0 still
/// maps to 0), then a symmetric S-curve adds moderate contrast. The S-curve is
/// built from `smoothstep`, so it carries its own soft highlight shoulder while
/// still mapping pure white to exactly 1 — whites stay clean.
///
/// Colour: warmth is applied with smooth luminance weights so highlights get the
/// most, midtones a little less, and shadows a very small cool counterbalance
/// that keeps the image from reading as a flat orange filter. Saturation is only
/// slightly up overall, and is pulled back in the brightest highlights and the
/// deepest shadows.
enum WarmCinema {
    static let definition = LUTDefinition(
        name: "Warm Cinema",
        filename: "Warm_Cinema.cube",
        category: "Cinematic",
        summary: "Warm, contrasty cinematic look with soft highlights and flattering skin tones.",
        inputColorSpace: "Rec.709 / working SDR",
        type: "creative",
        transform: transform
    )

    private static let tone: @Sendable (Double) -> Double = ToneCurve.normalizedToWhite { x in
        let deepened = ToneCurve.blackCompression(x, strength: 0.09, range: 0.20)
        return ToneCurve.sCurve(deepened, amount: 0.32)
    }

    @Sendable static func transform(_ input: RGB) -> RGB {
        var color = input.mapChannels(tone)

        // Warmth, weighted by tone. Shadows stay near-neutral with a trace of
        // cool so the grade reads as light quality rather than a colour cast.
        color = ColorOps.splitTone(
            color,
            shadow: RGB(0.000, 0.001, 0.010),
            mid: RGB(0.012, 0.004, -0.010),
            highlight: RGB(0.014, 0.004, -0.020)
        )

        color = ColorOps.saturation(color, 1.06)
        // Keep skin lively without pushing it orange.
        color = ColorOps.selectiveSaturation(color, targetHue: Hue.orange, sharpness: 3.0, amount: 1.05)
        color = ColorOps.shadowDesaturation(color, amount: 0.12, end: 0.22)
        color = ColorOps.highlightDesaturation(color, amount: 0.28, start: 0.72)

        return ColorOps.clamped(color)
    }
}
