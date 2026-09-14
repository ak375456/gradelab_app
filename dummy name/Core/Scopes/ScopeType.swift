import Foundation

/// The four scopes, in the order they appear in the selector.
enum ScopeType: String, CaseIterable, Identifiable, Sendable {
    case histogram
    case waveform
    case rgbParade
    case vectorscope

    var id: String { rawValue }

    /// Short enough for a segmented control on a phone.
    var title: String {
        switch self {
        case .histogram: "Histogram"
        case .waveform: "Waveform"
        case .rgbParade: "Parade"
        case .vectorscope: "Vector"
        }
    }

    /// What the scope measures, for the accessibility label.
    var summary: String {
        switch self {
        case .histogram: "Distribution of red, green and blue levels"
        case .waveform: "Luminance against horizontal image position"
        case .rgbParade: "Red, green and blue levels against horizontal image position"
        case .vectorscope: "Hue as angle and saturation as distance from centre"
        }
    }
}

/// The colour space the analysis texture is in, which decides the luma
/// coefficients and what the panel is honest about calling the axis.
///
/// The grading pipeline hands scopes whatever the display receives: Rec.709
/// encoded RGB for SDR projects, the HLG signal for HDR ones. Neither is linear
/// light, which is correct — a scope reads code values, the same as the picture.
enum ScopeColorSpace: Sendable {
    case rec709
    case hlgBT2020

    init(_ mode: ProjectColorMode) {
        self = mode.isHDR ? .hlgBT2020 : .rec709
    }

    /// Luma coefficients. Rec.709 for SDR (BT.709 Table 3), BT.2020 for HLG
    /// (BT.2100 Table 5) — applying 709 coefficients to a BT.2020 signal would
    /// weight the channels wrongly and misreport exposure.
    var lumaCoefficients: (r: Float, g: Float, b: Float) {
        switch self {
        case .rec709: (0.2126, 0.7152, 0.0722)
        case .hlgBT2020: (0.2627, 0.6780, 0.0593)
        }
    }

    /// Chroma denominators for the non-constant-luminance Y'CbCr difference
    /// signals: Cb = (B-Y)/(2(1-kB)), Cr = (R-Y)/(2(1-kR)).
    var chromaDenominators: (cb: Double, cr: Double) {
        let k = lumaCoefficients
        return (2 * (1 - Double(k.b)), 2 * (1 - Double(k.r)))
    }

    /// Where a fully saturated primary lands in the Cb/Cr plane. Used to scale
    /// the vectorscope so the outer circle means "as saturated as this colour
    /// space goes", rather than a number chosen by eye.
    var fullSaturationRadius: Double {
        [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1),
         SIMD3<Double>(0, 1, 1), SIMD3<Double>(1, 0, 1), SIMD3<Double>(1, 1, 0)]
            .map { chroma($0) }
            .map { ($0.cb * $0.cb + $0.cr * $0.cr).squareRoot() }
            .max() ?? 0.5
    }

    /// RGB to the Cb/Cr pair the vectorscope plots. The shader does the same
    /// arithmetic; this is what draws the graticule, so the targets land exactly
    /// where the trace does.
    func chroma(_ rgb: SIMD3<Double>) -> (cb: Double, cr: Double) {
        let k = lumaCoefficients
        let y = rgb.x * Double(k.r) + rgb.y * Double(k.g) + rgb.z * Double(k.b)
        let d = chromaDenominators
        return ((rgb.z - y) / d.cb, (rgb.x - y) / d.cr)
    }

    /// Normalised scope coordinates, +x right and +y up, for the graticule.
    func scopePoint(_ rgb: SIMD3<Double>) -> CGPoint {
        let c = chroma(rgb)
        let scale = 1 / fullSaturationRadius
        return CGPoint(x: c.cb * scale, y: c.cr * scale)
    }

    var axisLabel: String {
        switch self {
        case .rec709: "Rec.709"
        case .hlgBT2020: "HLG signal"
        }
    }
}
