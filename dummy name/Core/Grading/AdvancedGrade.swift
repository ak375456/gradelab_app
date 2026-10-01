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
    static var names: [String] {
        [String(localized: "Red"), String(localized: "Orange"), String(localized: "Yellow"),
         String(localized: "Green"), String(localized: "Aqua"), String(localized: "Blue"),
         String(localized: "Purple"), String(localized: "Magenta")]
    }
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
    /// A graduated filter: full effect on one side, fading across its parallel
    /// guide lines to no effect on the other.
    case linear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ellipse: String(localized: "Ellipse")
        case .rectangle: String(localized: "Rectangle")
        case .linear: String(localized: "Gradient")
        }
    }

    var shaderCode: Float {
        switch self {
        case .ellipse: 0
        case .rectangle: 1
        case .linear: 2
        }
    }
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
    /// Shadows, midtones, highlights, offset.
    ///
    /// Four rather than three since the offset wheel. Existing projects decode
    /// with three and read the fourth as neutral through `wheel(_:)`, which is
    /// bounds-checked for exactly this reason.
    var wheels = Array(repeating: GradingWheel(), count: 4)
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
    /// The Color Warper. Optional for the same reason every tool added after
    /// the first release is: a project that has never opened the panel writes
    /// nothing, and one saved before the warper existed decodes with none.
    var colorWarp: ColorWarp?
    /// Noise reduction. Optional for the same reason, and with one consequence
    /// worth naming: every existing project decodes with noise reduction off,
    /// which is what makes this change nothing about any picture anyone has
    /// already graded.
    ///
    /// It lives on the grade rather than on the clip, unlike background removal
    /// and Shot Match, because the question those two answer is "what is this
    /// particular piece of footage" — a drawn cutout, a named reference — while
    /// this one is a set of values that can sensibly be copied to another shot
    /// from the same camera at the same ISO. That also means it inherits
    /// persistence, undo coalescing, copy/paste, presets and the keyframe
    /// engine without a line of code in any of them.
    var noiseReduction: NoiseReduction?
    /// Relight: virtual lights that react to the shot's estimated geometry.
    /// Optional like every tool added after the first release, so a project
    /// saved before Relight existed decodes with none and renders exactly the
    /// picture it always did.
    ///
    /// On the grade rather than the clip for the reason noise reduction is:
    /// the lights are values that can sensibly travel with a copied grade or a
    /// preset. The depth they react to does not travel — it is derived from
    /// each clip's own media and lives in a cache outside the document.
    var relight: RelightSettings?

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

    /// The noise reduction the pipeline applies, or nil when there is nothing
    /// to apply.
    ///
    /// Resolved to nil rather than to a neutral value for the same reason the
    /// warp is: every consumer — the render paths, the neighbour decoding, the
    /// Pro gate — tests one thing and skips the work entirely.
    var resolvedNoiseReduction: NoiseReduction? {
        guard let noiseReduction else { return nil }
        let clamped = noiseReduction.clamped
        return clamped.isActive ? clamped : nil
    }

    /// The warp the pipeline applies, or nil when there is nothing to apply.
    ///
    /// Resolved to nil rather than to a neutral value so every consumer - the
    /// field texture cache, the uniforms, Pro gating - can test one thing and
    /// skip the work entirely.
    var resolvedColorWarp: ColorWarp? {
        guard let colorWarp, !colorWarp.isNeutral else { return nil }
        return colorWarp
    }

    func curve(_ index: Int) -> ToneCurve { curves.indices.contains(index) ? curves[index] : ToneCurve() }
    func band(_ index: Int) -> HueBand { hsl.indices.contains(index) ? hsl[index] : HueBand() }
    func wheel(_ index: Int) -> GradingWheel { wheels.indices.contains(index) ? wheels[index] : GradingWheel() }

    mutating func normalizeCollections() {
        curves = (0..<4).map { curve($0) }
        hsl = (0..<8).map { band($0) }
        wheels = (0..<4).map { wheel($0) }
    }
}
