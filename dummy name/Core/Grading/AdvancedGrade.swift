import Foundation

struct ToneCurve: Codable, Equatable, Sendable {
    var shadows: Float = 0.25
    var midtones: Float = 0.5
    var highlights: Float = 0.75
    var points: [Float] { [0, shadows, midtones, highlights, 1] }
}

struct HueBand: Codable, Equatable, Sendable {
    var hue: Float = 0
    var saturation: Float = 0
    var luminance: Float = 0
    static let names = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    static let centers: [Float] = [0, 30, 60, 120, 180, 240, 270, 300]
}

struct GradingWheel: Codable, Equatable, Sendable {
    var hue: Float = 0
    var strength: Float = 0
    var brightness: Float = 0
}

/// A soft geometric window that limits a clip's creative grade to one part of
/// the picture. Coordinates and dimensions are percentages of the source frame
/// rather than preview pixels, so preview, scopes and export all agree.
enum GradeMaskShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case ellipse
    case rectangle

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct GradeMask: Codable, Equatable, Sendable {
    var isEnabled = false
    var shape: GradeMaskShape = .ellipse
    var centerX: Float = 50
    var centerY: Float = 50
    var width: Float = 60
    var height: Float = 40
    var rotation: Float = 0
    var feather: Float = 25
    var opacity: Float = 100
    var isInverted = false

    static let disabled = GradeMask()

    /// Keeps hand-edited or future project JSON from sending invalid geometry
    /// to Metal. Authored values are left alone; this is the resolved render
    /// value only.
    var clamped: GradeMask {
        var value = self
        value.centerX = min(max(value.centerX, 0), 100)
        value.centerY = min(max(value.centerY, 0), 100)
        value.width = min(max(value.width, 1), 200)
        value.height = min(max(value.height, 1), 200)
        value.rotation = min(max(value.rotation, -180), 180)
        value.feather = min(max(value.feather, 0), 100)
        value.opacity = min(max(value.opacity, 0), 100)
        return value
    }
}

struct AdvancedGrade: Codable, Equatable, Sendable {
    /// Legacy three-anchor tone curves. Superseded by `advancedCurves`, kept as
    /// a stored property so a project saved against it still decodes and still
    /// renders - `resolvedCurves` converts it exactly.
    var curves = Array(repeating: ToneCurve(), count: 4)
    var hsl = Array(repeating: HueBand(), count: 8)
    var wheels = Array(repeating: GradingWheel(), count: 3)
    var vignette: Float = 0
    var vignetteMidpoint: Float = 50
    var vignetteFeather: Float = 70
    // Both optional so projects saved before looks existed still decode.
    // `lut` holds a LUTAsset identifier; nil means no look is applied.
    var lut: String?
    var lutIntensity: Float?
    /// Optional for the same reason: a project saved before finishing effects
    /// existed decodes with none, and one that has never used them stores none.
    var effects: FilmEffects?
    /// The ten advanced curves. Optional on purpose: a project that has never
    /// opened the panel writes nothing, and one saved before they existed
    /// decodes with none and falls back to `curves`.
    var advancedCurves: AdvancedCurves?
    /// Optional so every project and preset saved before local grading masks
    /// decodes as the unchanged, full-frame grade it originally contained.
    var mask: GradeMask?

    static let neutral = AdvancedGrade()

    /// The curves the pipeline applies.
    ///
    /// With no advanced-curve data the legacy `curves` are converted on the
    /// fly, and that conversion is exact rather than approximate (see
    /// `AdvancedCurves.init(migratingLegacy:)`), so an old grade renders the
    /// picture it always did and the first edit starts from where it left off.
    var resolvedCurves: AdvancedCurves {
        advancedCurves ?? AdvancedCurves(migratingLegacy: curves)
    }

    /// One bit per curve that changes a pixel. Handed to the shader so every
    /// untouched curve costs nothing.
    var curveMask: UInt32 { resolvedCurves.activeMask }

    /// The effects as the shaders need them: never nil, always in range.
    var resolvedEffects: FilmEffects {
        guard var effects else { return .neutral }
        effects.clamp()
        return effects
    }

    /// Applied LUT strength as a 0...100 value. Zero whenever no look is
    /// selected, so the shader can treat it as the single on/off signal.
    var lutStrength: Float {
        lut == nil ? 0 : min(max(lutIntensity ?? 100, 0), 100)
    }

    var resolvedMask: GradeMask { (mask ?? .disabled).clamped }

    func curve(_ index: Int) -> ToneCurve { curves.indices.contains(index) ? curves[index] : ToneCurve() }
    func band(_ index: Int) -> HueBand { hsl.indices.contains(index) ? hsl[index] : HueBand() }
    func wheel(_ index: Int) -> GradingWheel { wheels.indices.contains(index) ? wheels[index] : GradingWheel() }

    mutating func normalizeCollections() {
        curves = (0..<4).map { curve($0) }
        hsl = (0..<8).map { band($0) }
        wheels = (0..<3).map { wheel($0) }
    }
}
