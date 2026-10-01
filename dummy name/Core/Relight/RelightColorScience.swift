import Foundation
import simd

// ---------------------------------------------------------------------------
// The colour of a virtual light
//
// A light's colour is three authored things multiplied together: a colour
// filter (sRGB, picked like any other colour in the document), a colour
// temperature in kelvin, and a green/magenta tint. They resolve here, once, to
// a LINEAR colour with a luminance of one — which is what makes the colour
// independent of the light's strength. Warming a key from 6500 K to 3200 K
// changes its hue, not how many stops it adds; Intensity and Exposure say that.
//
// The working primaries differ by project: linear Rec.709 for SDR, linear
// BT.2020 for HLG and both Apple Log modes. The conversion is done here on the
// CPU, per light, rather than per pixel in the shader.
// ---------------------------------------------------------------------------

enum RelightColorScience {
    static let rec709Luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)
    static let bt2020Luma = SIMD3<Double>(0.2627, 0.6780, 0.0593)

    /// sRGB-encoded component to linear light.
    static func linear(_ value: Double) -> Double {
        let c = min(max(value.isFinite ? value : 0, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Linear light to sRGB-encoded, for drawing a swatch.
    static func encoded(_ value: Double) -> Double {
        let c = min(max(value.isFinite ? value : 0, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// CIE 1931 chromaticity of a Planckian radiator.
    ///
    /// Kim, Kim, Lee and others' cubic-spline approximation of the Planckian
    /// locus (2002), valid from 1667 K to 25000 K, which covers every light
    /// anyone points at a face — candle to overcast sky.
    static func planckianChromaticity(kelvin: Double) -> (x: Double, y: Double) {
        let t = min(max(kelvin.isFinite ? kelvin : 6500, 1667), 25_000)
        let t2 = t * t, t3 = t2 * t
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        }
        let x2 = x * x, x3 = x2 * x
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    /// Linear Rec.709 RGB of a colour temperature, before any normalisation.
    static func rawTemperatureRGB(kelvin: Double) -> SIMD3<Double> {
        let (x, y) = planckianChromaticity(kelvin: kelvin)
        guard y > 1e-6 else { return SIMD3(repeating: 1) }
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        let r = 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
        let g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
        let b = 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
        // Very warm sources fall slightly outside Rec.709 in blue. A small
        // floor keeps the multiplier from switching a channel off entirely.
        return SIMD3(max(r, 0.004), max(g, 0.004), max(b, 0.004))
    }

    /// A colour-temperature multiplier with 6500 K exactly neutral and a
    /// luminance of one.
    ///
    /// Normalised against the locus at 6500 K rather than against D65 itself:
    /// the two are a hair apart, and anchoring to the locus is what makes the
    /// slider's midpoint exactly white rather than very faintly green.
    static func temperatureRGB(kelvin: Double) -> SIMD3<Double> {
        let rgb = rawTemperatureRGB(kelvin: kelvin) / rawTemperatureRGB(kelvin: 6500)
        return normalizedLuminance(rgb)
    }

    /// Green (negative) to magenta (positive), -100...100.
    static func tintRGB(_ tint: Double) -> SIMD3<Double> {
        let t = min(max(tint.isFinite ? tint : 0, -100), 100) / 100
        return normalizedLuminance(SIMD3(exp2(0.35 * t), exp2(-0.5 * t), exp2(0.35 * t)))
    }

    static func normalizedLuminance(_ rgb: SIMD3<Double>, weights: SIMD3<Double> = rec709Luma) -> SIMD3<Double> {
        let luminance = simd_dot(rgb, weights)
        guard luminance > 1e-5, luminance.isFinite else { return .zero }
        return rgb / luminance
    }

    /// The light's colour as linear Rec.709 with a luminance of one, or zero
    /// for a black filter — a light filtered to black adds nothing.
    static func lightColor(color: RGBAColor, temperature: Double, tint: Double) -> SIMD3<Double> {
        let filter = SIMD3(linear(color.red), linear(color.green), linear(color.blue))
        let combined = filter * temperatureRGB(kelvin: temperature) * tintRGB(tint)
        let normalized = normalizedLuminance(combined)
        // A saturated filter normalised to unit luminance can put a lot into
        // one channel. Capped so a pure blue light cannot ask the shader for
        // fourteen stops in one channel.
        return simd_min(normalized, SIMD3(repeating: 4))
    }

    static func lightColor(_ light: RelightLight) -> SIMD3<Double> {
        lightColor(color: light.color, temperature: light.temperature, tint: light.tint)
    }

    /// Linear Rec.709 to linear BT.2020, D65 throughout (ITU-R BT.2087). The
    /// same matrix the shaders call `kRec709ToBT2020`.
    static func rec709ToBT2020(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.627404 * rgb.x + 0.329283 * rgb.y + 0.043313 * rgb.z,
              0.069097 * rgb.x + 0.919540 * rgb.y + 0.011362 * rgb.z,
              0.016391 * rgb.x + 0.088013 * rgb.y + 0.895595 * rgb.z)
    }

    /// The light's colour for a swatch in the UI: sRGB-encoded, brightest
    /// channel at one, so a warm light looks warm rather than dim.
    static func swatch(_ light: RelightLight) -> SIMD3<Double> {
        let rgb = lightColor(light)
        let peak = max(rgb.x, max(rgb.y, rgb.z))
        guard peak > 1e-5 else { return .zero }
        let scaled = rgb / peak
        return SIMD3(encoded(scaled.x), encoded(scaled.y), encoded(scaled.z))
    }

    /// Named temperatures the inspector offers as one-tap starting points.
    /// Shortcuts only: every one of them is an ordinary kelvin value afterwards.
    struct TemperaturePreset: Identifiable, Sendable {
        let id: String
        let title: String
        let kelvin: Double
    }

    static var temperaturePresets: [TemperaturePreset] {
        [
            .init(id: "tungsten", title: String(localized: "Tungsten"), kelvin: 3200),
            .init(id: "warm", title: String(localized: "Warm"), kelvin: 4300),
            .init(id: "daylight", title: String(localized: "Daylight"), kelvin: 5600),
            .init(id: "neutral", title: String(localized: "Neutral"), kelvin: 6500),
            .init(id: "cool", title: String(localized: "Cool"), kelvin: 8500)
        ]
    }
}
