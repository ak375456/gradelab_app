import Foundation

/// Teal Orange — a modern commercial teal-and-orange grade, kept deliberately
/// restrained so it stays usable on ordinary footage.
///
/// Tone: light black compression plus a moderate S-curve.
///
/// Colour: shadows are pushed toward teal with the smooth tonal weights;
/// highlights stay neutral-to-slightly-warm. Selective work uses raised-cosine
/// hue lobes scaled by chroma, so greys are untouched and there are no hue
/// boundaries in the cube. Blues go deeper and a little more cyan, greens are
/// desaturated rather than rotated, and warm hues get a mild warmth push instead
/// of a hue rotation — which is what keeps skin from turning unnatural.
enum TealOrange {
    static let definition = LUTDefinition(
        name: "Teal Orange",
        filename: "Teal_Orange.cube",
        category: "Cinematic",
        summary: "Restrained modern teal-shadow / warm-highlight look with controlled greens.",
        inputColorSpace: "Rec.709 / working SDR",
        type: "creative",
        transform: transform
    )

    private static let tone: @Sendable (Double) -> Double = ToneCurve.normalizedToWhite { x in
        let deepened = ToneCurve.blackCompression(x, strength: 0.07, range: 0.20)
        return ToneCurve.sCurve(deepened, amount: 0.28)
    }

    @Sendable static func transform(_ input: RGB) -> RGB {
        var color = input.mapChannels(tone)

        color = ColorOps.splitTone(
            color,
            shadow: RGB(0.000, 0.010, 0.028),
            mid: RGB(0.004, 0.000, -0.004),
            highlight: RGB(0.010, 0.002, -0.014)
        )

        // Blues: deeper and slightly more cyan.
        color = ColorOps.selectiveTint(color, targetHue: Hue.blue, sharpness: 2.5, push: RGB(-0.024, 0.008, 0.004))
        // Warm hues: warmth, not rotation, so skin stays skin.
        color = ColorOps.selectiveTint(color, targetHue: Hue.orange, sharpness: 3.0, push: RGB(0.014, 0.002, -0.012))
        // Greens: held back rather than hue-shifted.
        color = ColorOps.selectiveSaturation(color, targetHue: Hue.green, sharpness: 2.0, amount: 0.78)

        color = ColorOps.saturation(color, 1.08)
        color = ColorOps.shadowDesaturation(color, amount: 0.10, end: 0.20)
        color = ColorOps.highlightDesaturation(color, amount: 0.30, start: 0.72)

        return ColorOps.clamped(color)
    }
}
