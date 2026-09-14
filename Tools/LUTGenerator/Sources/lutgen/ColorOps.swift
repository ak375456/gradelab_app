import Foundation

/// A display-referred RGB triple in the app's working SDR (Rec.709) space.
///
/// Every operation in this file is a pure function of colour only. Nothing here
/// is spatial: no grain, vignette, glow, halation or blur, because a 3D `.cube`
/// LUT can only express a per-pixel colour mapping.
struct RGB: Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(all value: Double) {
        self.init(value, value, value)
    }

    /// Applies a scalar tone curve independently to each channel.
    func mapChannels(_ transform: (Double) -> Double) -> RGB {
        RGB(transform(r), transform(g), transform(b))
    }

    static func + (lhs: RGB, rhs: RGB) -> RGB { RGB(lhs.r + rhs.r, lhs.g + rhs.g, lhs.b + rhs.b) }
    static func - (lhs: RGB, rhs: RGB) -> RGB { RGB(lhs.r - rhs.r, lhs.g - rhs.g, lhs.b - rhs.b) }
    static func * (lhs: RGB, rhs: Double) -> RGB { RGB(lhs.r * rhs, lhs.g * rhs, lhs.b * rhs) }
    static func * (lhs: RGB, rhs: RGB) -> RGB { RGB(lhs.r * rhs.r, lhs.g * rhs.g, lhs.b * rhs.b) }
}

// MARK: - Scalar helpers

enum ColorMath {
    static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        min(max(value, lower), upper)
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(mix(a.r, b.r, t), mix(a.g, b.g, t), mix(a.b, b.b, t))
    }

    /// Hermite interpolation between two edges; C1-continuous, so it never
    /// introduces a visible boundary in the LUT.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = clamp((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    /// Rec.709 relative luminance weights, matching the app's SDR working space.
    /// A flat `(r + g + b) / 3` average would misjudge how bright saturated
    /// reds and blues actually appear and skew every luminance-weighted step.
    static func luma709(_ color: RGB) -> Double {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
    }
}

// MARK: - Tone curves (scalar, applied per channel or to luminance)

enum ToneCurve {
    /// Linear contrast around `pivot`. Deliberately allowed to overshoot: a
    /// shoulder or soft clip is expected downstream to bring highlights back.
    static func contrast(_ x: Double, amount: Double, pivot: Double = 0.5) -> Double {
        pivot + (x - pivot) * (1 + amount)
    }

    /// Symmetric S-curve with fixed points at 0 and 1. `amount` blends between
    /// the identity and a full Hermite S.
    static func sCurve(_ x: Double, amount: Double) -> Double {
        let s = ColorMath.smoothstep(0, 1, ColorMath.clamp(x))
        return ColorMath.mix(x, s, amount)
    }

    /// Exponential highlight shoulder. Slope is exactly 1 at `knee`, so the
    /// curve stays C1-continuous there, and the output approaches 1 without
    /// ever reaching or exceeding it — no clipped, detail-free highlights.
    static func highlightRolloff(_ x: Double, knee: Double, strength: Double) -> Double {
        guard x > knee else { return x }
        let headroom = 1 - knee
        let t = (x - knee) / headroom
        return knee + headroom * (1 - exp(-strength * t)) / strength
    }

    /// Darkens the toe without crushing: 0 maps to 0, the curve stays strictly
    /// increasing for `strength < 1`, and the effect decays away by the midtones.
    static func blackCompression(_ x: Double, strength: Double, range: Double = 0.22) -> Double {
        x - strength * x * exp(-x / range)
    }

    /// Raises the deepest blacks only. 1 stays at 1 and the lift fades out with
    /// `range`, so midtones and highlights are left alone.
    static func liftedBlacks(_ x: Double, amount: Double, range: Double = 0.25) -> Double {
        x + amount * exp(-x / range) * (1 - x)
    }

    /// Rescales a curve so pure white maps back to exactly 1. Used after a
    /// shoulder so the LUT keeps a clean white point instead of a grey one.
    static func normalizedToWhite(_ curve: @escaping @Sendable (Double) -> Double) -> @Sendable (Double) -> Double {
        let white = curve(1)
        guard white > 0.0001 else { return curve }
        return { curve($0) / white }
    }

    /// Asymptotic soft clip above `knee`; slope 1 at the knee, limit 1 at infinity.
    static func softClip(_ x: Double, knee: Double) -> Double {
        guard x > knee else { return x }
        let headroom = 1 - knee
        return knee + headroom * tanh((x - knee) / headroom)
    }
}

// MARK: - Colour operations

enum ColorOps {
    /// Luminance-preserving saturation: the Rec.709 luma of the result matches
    /// the input, so saturation changes never shift exposure.
    static func saturation(_ color: RGB, _ amount: Double) -> RGB {
        let y = ColorMath.luma709(color)
        return RGB(all: y) + (color - RGB(all: y)) * amount
    }

    /// Pulls saturation out of the brightest region only, which is what keeps
    /// speculars and skies from turning into flat blocks of colour.
    static func highlightDesaturation(_ color: RGB, amount: Double, start: Double = 0.7) -> RGB {
        let weight = ColorMath.smoothstep(start, 1, ColorMath.luma709(color))
        return saturation(color, 1 - amount * weight)
    }

    /// Same idea at the other end: very dark areas hold less chroma, which
    /// removes the electric-blue look digital shadows often have.
    static func shadowDesaturation(_ color: RGB, amount: Double, end: Double = 0.25) -> RGB {
        let weight = 1 - ColorMath.smoothstep(0, end, ColorMath.luma709(color))
        return saturation(color, 1 - amount * weight)
    }

    /// Smooth shadow / midtone / highlight weights that sum to 1 at every
    /// luminance. Built from `smoothstep`, so there are no tonal seams.
    static func toneWeights(_ luma: Double) -> (shadow: Double, mid: Double, highlight: Double) {
        let shadow = 1 - ColorMath.smoothstep(0.0, 0.5, luma)
        let highlight = ColorMath.smoothstep(0.5, 1.0, luma)
        return (shadow, max(0, 1 - shadow - highlight), highlight)
    }

    /// Fades a tint out at both ends of the range, so pure black stays exactly
    /// black and pure white stays exactly white. Without this, a tint that
    /// pushes a channel past an endpoint gets clamped, and everything near that
    /// endpoint flattens into the same value — visible as clipped highlights or
    /// blocked-up shadows.
    static func endpointTaper(_ luma: Double) -> Double {
        ColorMath.smoothstep(0, 0.05, luma) * (1 - ColorMath.smoothstep(0.93, 1, luma))
    }

    /// Additive split toning. Tints are small signed RGB offsets applied with
    /// the smooth tonal weights above, faded out at the endpoints so the tint
    /// can never drive a channel out of range.
    static func splitTone(_ color: RGB, shadow: RGB, mid: RGB, highlight: RGB) -> RGB {
        let luma = ColorMath.luma709(color)
        let w = toneWeights(luma)
        let taper = endpointTaper(luma)
        return color + (shadow * w.shadow + mid * w.mid + highlight * w.highlight) * taper
    }

    /// Chroma magnitude, 0 for neutral greys.
    static func chroma(_ color: RGB) -> Double {
        max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b))
    }

    /// Hue angle in radians. Undefined for greys, which is why every selective
    /// operation below multiplies its weight by `chroma`.
    static func hueAngle(_ color: RGB) -> Double {
        atan2(sqrt(3) * (color.g - color.b), 2 * color.r - color.g - color.b)
    }

    /// A smooth cosine lobe centred on `targetHue`, scaled by chroma so greys
    /// are never touched. `sharpness` controls how tight the selection is.
    /// Because the lobe is a raised cosine it has no hard edges, and therefore
    /// introduces no hue discontinuities in the sampled LUT.
    static func hueWeight(_ color: RGB, targetHue: Double, sharpness: Double) -> Double {
        let c = chroma(color)
        guard c > 0 else { return 0 }
        let delta = hueAngle(color) - targetHue
        let lobe = (cos(delta) + 1) / 2
        return pow(lobe, sharpness) * min(1, c * 3)
    }

    /// Applies a signed RGB push to colours near a hue, weighted as above.
    static func selectiveTint(_ color: RGB, targetHue: Double, sharpness: Double, push: RGB) -> RGB {
        color + push * hueWeight(color, targetHue: targetHue, sharpness: sharpness)
    }

    /// Scales saturation for colours near a hue without touching the rest.
    static func selectiveSaturation(_ color: RGB, targetHue: Double, sharpness: Double, amount: Double) -> RGB {
        let w = hueWeight(color, targetHue: targetHue, sharpness: sharpness)
        return ColorMath.mix(color, saturation(color, amount), w)
    }

    static func clamped(_ color: RGB) -> RGB {
        RGB(ColorMath.clamp(color.r), ColorMath.clamp(color.g), ColorMath.clamp(color.b))
    }
}

/// Hue reference angles for `hueAngle`, in radians.
enum Hue {
    static let red = 0.0
    static let orange = 30.0 * .pi / 180
    static let yellow = 60.0 * .pi / 180
    static let green = 120.0 * .pi / 180
    static let cyan = 180.0 * .pi / 180
    static let blue = 240.0 * .pi / 180
    static let magenta = 300.0 * .pi / 180
}
