import Foundation

/// Soft Film — a subtle, organic look with mild faded character. It is inspired
/// by the general behaviour of photochemical tone reproduction (a lifted toe and
/// a long shoulder); it does not emulate, and is not derived from, any specific
/// film stock or commercial preset.
///
/// Tone: the deepest blacks are gently lifted with a falloff that leaves
/// midtones alone, a softer S-curve than Warm Cinema adds only light contrast,
/// and an exponential shoulder rolls off the highlights. The whole chain is then
/// normalised so pure white still lands on 1 rather than grey — faded, not washed out.
///
/// Colour: saturation is pulled down slightly overall, further in very bright
/// areas and in deep shadow, with warm-neutral midtones over subtly cool shadows.
///
/// Grain, halation, blur and vignette are intentionally absent: a colour LUT
/// cannot express spatial effects, and those are handled elsewhere in the app.
enum SoftFilm {
    static let definition = LUTDefinition(
        name: "Soft Film",
        filename: "Soft_Film.cube",
        category: "Film-inspired",
        summary: "Soft, slightly faded look with lifted blacks, muted colour and smooth highlights.",
        inputColorSpace: "Rec.709 / working SDR",
        type: "creative",
        transform: transform
    )

    private static let tone: @Sendable (Double) -> Double = ToneCurve.normalizedToWhite { x in
        let lifted = ToneCurve.liftedBlacks(x, amount: 0.035, range: 0.22)
        let shaped = ToneCurve.sCurve(lifted, amount: 0.16)
        return ToneCurve.highlightRolloff(shaped, knee: 0.80, strength: 0.45)
    }

    @Sendable static func transform(_ input: RGB) -> RGB {
        var color = input.mapChannels(tone)

        color = ColorOps.splitTone(
            color,
            shadow: RGB(0.000, 0.004, 0.018),
            mid: RGB(0.008, 0.003, -0.004),
            highlight: RGB(0.006, 0.004, 0.002)
        )

        color = ColorOps.saturation(color, 0.90)
        color = ColorOps.selectiveSaturation(color, targetHue: Hue.green, sharpness: 2.0, amount: 0.92)
        color = ColorOps.shadowDesaturation(color, amount: 0.15, end: 0.25)
        color = ColorOps.highlightDesaturation(color, amount: 0.35, start: 0.65)

        return ColorOps.clamped(color)
    }
}
