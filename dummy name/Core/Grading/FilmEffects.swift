import Foundation

/// The finishing effects: the ones that change how the image is *rendered*
/// rather than how it is toned.
///
/// They divide in two, and the split is not cosmetic — it decides where each one
/// can be computed:
///
/// - **Per-pixel** (`fade`, `grain`) need only the pixel they are on, so they
///   live inside the shared grading functions and reach every render path for
///   free: preview, export, both compositors, and the scopes.
/// - **Spatial** (`sharpness`, `clarity`, `bloom`, `glow`, `halation`) need the
///   pixels around them. Those run in
///   `FilmEffectsStage`, a post-grade pass over the graded frame.
///
/// All amounts are stored as 0…100 and default to zero. The whole struct is
/// optional on `AdvancedGrade` so projects saved before it existed decode
/// unchanged.
struct FilmEffects: Codable, Equatable, Sendable {
    /// Lifts the black point and eases the white point down: the matte,
    /// washed-print look.
    var fade: Float = 0
    /// Unsharp mask against a one-pixel blur of the graded image.
    var sharpness: Float = 0
    /// Highlights bleeding into their surroundings.
    var bloom: Float = 0
    /// A soft diffusion over the whole frame, not only the highlights.
    var glow: Float = 0
    /// The red halo film gets around bright areas, where light scatters off the
    /// back of the base and re-exposes the emulsion. Red-weighted by nature.
    var halation: Float = 0
    /// Monochrome grain, weighted toward the midtones the way film is.
    var grain: Float = 0
    /// Local luminance contrast across a broader area than sharpening.
    var clarity: Float = 0

    static let neutral = FilmEffects()
    static let range: ClosedRange<Float> = 0...100

    /// True when nothing here changes the image, so every path can keep its
    /// existing single-pass behaviour untouched.
    var isNeutral: Bool { self == .neutral }

    /// True when an effect samples a blurred version of the frame.
    var needsBlur: Bool { bloom > 0 || glow > 0 || halation > 0 || clarity > 0 }

    /// True when the post-grade stage has anything to do at all.
    var needsStage: Bool { needsBlur || sharpness > 0 }

    mutating func clamp() {
        func c(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 100) : 0 }
        fade = c(fade); sharpness = c(sharpness); bloom = c(bloom)
        glow = c(glow); halation = c(halation); grain = c(grain)
        clarity = c(clarity)
    }
}

extension FilmEffects {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fade = try values.decode(Float.self, forKey: .fade)
        sharpness = try values.decode(Float.self, forKey: .sharpness)
        bloom = try values.decode(Float.self, forKey: .bloom)
        glow = try values.decode(Float.self, forKey: .glow)
        halation = try values.decode(Float.self, forKey: .halation)
        grain = try values.decode(Float.self, forKey: .grain)
        clarity = try values.decodeIfPresent(Float.self, forKey: .clarity) ?? 0
    }
}

/// One effect as the UI sees it: a name, a slot and a short explanation.
///
/// `id` is the slot's raw value, which is also how `GradeSlot` addresses the
/// effect, so the panel and the keyframe engine cannot drift apart about which
/// slider drives which value.
struct FilmEffectParameter: Identifiable {
    let id: String
    let name: String
    let detail: String
    let keyPath: WritableKeyPath<FilmEffects, Float>

    var slot: FilmEffectSlot? { FilmEffectSlot(rawValue: id) }
    var property: AnimatableProperty? { slot.flatMap { AnimatableProperty.effect($0) } }

    static let all: [FilmEffectParameter] = [
        .init(id: "fade", name: String(localized: "Fade"),
              detail: String(localized: "Lifts the blacks toward a matte, washed-print look."),
              keyPath: \.fade),
        .init(id: "sharpness", name: String(localized: "Sharpen"),
              detail: String(localized: "Local contrast at the edges. Past the middle it starts to show halos."),
              keyPath: \.sharpness),
        .init(id: "clarity", name: String(localized: "Clarity"),
              detail: String(localized: "Adds definition by increasing local contrast in the midtones."),
              keyPath: \.clarity),
        .init(id: "bloom", name: String(localized: "Bloom"),
              detail: String(localized: "Bright areas bleed into what surrounds them."),
              keyPath: \.bloom),
        .init(id: "glow", name: String(localized: "Glow"),
              detail: String(localized: "A soft diffusion across the whole frame, not only the highlights."),
              keyPath: \.glow),
        .init(id: "halation", name: String(localized: "Halation"),
              detail: String(localized: "The red halo film gets around bright areas."),
              keyPath: \.halation),
        .init(id: "grain", name: String(localized: "Grain"),
              detail: String(localized: "Monochrome grain, strongest through the midtones as film is."),
              keyPath: \.grain)
    ]
}
