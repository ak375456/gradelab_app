import Foundation

// ---------------------------------------------------------------------------
// The Color Warper
//
// Every other hue tool in the app is one-dimensional: Hue vs Hue moves hue as a
// function of hue, Hue vs Sat moves saturation as a function of hue. None of
// them can say "the orange at 70% saturation goes to THAT red at 82%", because
// none of them reads two coordinates of the source colour at once.
//
// This does. A warp point names a place in a two-dimensional colour plane and a
// place to drag it to; the colours around it follow, less the further away they
// are. The plane is either hue x saturation or chroma x luma - the same picture
// from two useful angles.
//
// WHERE THE MATHS HAPPENS. Nothing here is evaluated per pixel. The points are
// sampled into a small two-channel texture on the CPU (see ColorWarpField.swift)
// and the GPU does one filtered fetch, exactly as the curves already work. So
// the cost of a warp on the render thread does not depend on how many points
// were authored.
//
// WHY THE POINTS ARE CONTINUOUS. A point stores its source as a float, not as a
// grid index. `density` decides how many handles the editor OFFERS, and nothing
// else - so changing the mesh resolution after a grade exists cannot move, drop
// or resample a single authored point. That is the whole reason the model is
// shaped this way rather than as a displaced lattice.
// ---------------------------------------------------------------------------

/// Which two-dimensional colour plane a warp point lives in.
///
/// Both planes are live at once. The mode picks which one the editor is showing;
/// points in the other are still applied, because "warm the skin AND deepen the
/// sky" is one grade, not two.
enum ColorWarpMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Angle is hue, distance from the centre is saturation.
    case hueSaturation
    /// x is colour intensity, y is brightness.
    case chromaLuma

    var id: String { rawValue }

    /// The block this mode occupies in the shared field texture. Fixed rather
    /// than derived from `allCases` so reordering the enum cannot silently
    /// re-point the shader at the other plane.
    var block: Int {
        switch self {
        case .hueSaturation: 0
        case .chromaLuma: 1
        }
    }

    /// One bit per mode, handed to the shader so a plane with no points in it
    /// costs no fetch.
    var maskBit: UInt32 { 1 << UInt32(block) }

    /// True when x wraps: hue is a circle, chroma is not.
    var wrapsHorizontally: Bool { self == .hueSaturation }

    var title: String {
        switch self {
        case .hueSaturation: String(localized: "Hue / Sat")
        case .chromaLuma: String(localized: "Chroma / Luma")
        }
    }

    var xLabel: String {
        switch self {
        case .hueSaturation: String(localized: "Hue")
        case .chromaLuma: String(localized: "Chroma")
        }
    }

    var yLabel: String {
        switch self {
        case .hueSaturation: String(localized: "Sat")
        case .chromaLuma: String(localized: "Luma")
        }
    }

    /// Formats a coordinate for the readout. Hue is the only one anybody thinks
    /// about in degrees; the rest are percentages.
    func formattedX(_ value: Float) -> String {
        switch self {
        case .hueSaturation:
            return String(format: "%.0f°", locale: .current, (value - value.rounded(.down)) * 360)
        case .chromaLuma:
            return String(format: "%.0f%%", locale: .current, value * 100)
        }
    }

    func formattedY(_ value: Float) -> String {
        String(format: "%.0f%%", locale: .current, value * 100)
    }
}

/// How many handles the editor offers.
///
/// A display property, deliberately. Lower means broader, smoother moves because
/// the handles sit further apart and start with a wider range; higher means
/// precise isolated ones. It never touches stored points - see the note at the
/// top of this file.
enum ColorWarpDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    /// Divisions along x. On the hue plane this is how many hues get a handle.
    var columns: Int {
        switch self {
        case .low: 6
        case .medium: 12
        case .high: 24
        }
    }

    /// Divisions along y, counting the outer ring but not the neutral centre.
    var rows: Int {
        switch self {
        case .low: 3
        case .medium: 5
        case .high: 8
        }
    }

    /// The range a point gets when it is created at this density: wide enough to
    /// reach its neighbours and overlap them, which is what makes the result a
    /// field rather than a set of islands.
    var defaultRadius: Float {
        min(1, 1.6 / Float(columns))
    }

    var title: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        }
    }
}

/// One deformation: a place in the plane, a place to drag it to, and how far the
/// pull reaches.
struct ColorWarpPoint: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var mode: ColorWarpMode
    /// Where the point was placed, 0...1 in the mode's own axes. On the hue
    /// plane x is hue in turns and y is saturation.
    var sourceX: Float
    var sourceY: Float
    /// Where it was dragged to, same units.
    var targetX: Float
    var targetY: Float
    /// How much of the surrounding plane comes along, 0...1. The falloff has
    /// compact support, so beyond this distance a colour is untouched.
    var radius: Float
    /// A per-point dial on top of the global strength, 0...1. Reserved for the
    /// editor's fine control and for skin-tone protection later, which is one
    /// more factor multiplied in here.
    var weight: Float

    init(
        id: UUID = UUID(),
        mode: ColorWarpMode,
        sourceX: Float,
        sourceY: Float,
        targetX: Float? = nil,
        targetY: Float? = nil,
        radius: Float = ColorWarpDensity.medium.defaultRadius,
        weight: Float = 1
    ) {
        self.id = id
        self.mode = mode
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.targetX = targetX ?? sourceX
        self.targetY = targetY ?? sourceY
        self.radius = radius
        self.weight = weight
    }

    /// The smallest range a point may have. Below this the Gaussian collapses
    /// into a single texel of the field and the result reads as a hard edge
    /// rather than as a warp.
    static let minimumRadius: Float = 0.02

    /// How far this point moves its own colour. Hue is a circle, so the short
    /// way round is the only sensible reading of "how far".
    var displacement: SIMD2<Float> {
        SIMD2(mode.wrapsHorizontally ? ColorWarpMath.wrappedDelta(from: sourceX, to: targetX)
                                     : targetX - sourceX,
              targetY - sourceY)
    }

    /// True when the point is sitting on its own source and so changes nothing.
    ///
    /// A point in this state is still STORED, deliberately: dragging one back
    /// through its origin mid-gesture must not delete it, and a point placed
    /// with the picker exists to be dragged next.
    var isResting: Bool {
        let d = displacement
        return abs(d.x) <= 1e-6 && abs(d.y) <= 1e-6
    }

    /// Returns the point to where it was placed, keeping its range and id so the
    /// editor's selection survives the reset.
    mutating func resetTarget() {
        targetX = sourceX
        targetY = sourceY
    }

    /// Keeps hand-edited or future project JSON from sending nonsense to the
    /// field builder. Authored values are left alone; this is the resolved
    /// render value only, exactly as `GradeMask.clamped` is.
    var clamped: ColorWarpPoint {
        var value = self
        if mode.wrapsHorizontally {
            value.sourceX = ColorWarpMath.wrap(value.sourceX)
            value.targetX = ColorWarpMath.wrap(value.targetX)
        } else {
            value.sourceX = min(max(value.sourceX, 0), 1)
            value.targetX = min(max(value.targetX, 0), 1)
        }
        value.sourceY = min(max(value.sourceY, 0), 1)
        value.targetY = min(max(value.targetY, 0), 1)
        value.radius = min(max(value.radius, Self.minimumRadius), 1)
        value.weight = min(max(value.weight, 0), 1)
        return value
    }
}

/// Everything the Color Warper holds for one grade.
///
/// Stored on `AdvancedGrade` as an optional, which is what makes project
/// persistence, the grade clipboard, presets and old-file decoding work without
/// a line of code anywhere else: a project that has never opened the panel
/// writes nothing and decodes to nil.
struct ColorWarp: Codable, Equatable, Sendable {
    var points: [ColorWarpPoint] = []
    /// 0...100. Interpolates between the original colour and the warped one.
    var strength: Float = 100
    /// Hold each pixel's brightness while its hue and saturation move. Blue to
    /// purple should not quietly light the shot up.
    var preservesLuminance: Bool = true
    /// Editor only. See the note at the top of this file.
    var density: ColorWarpDensity = .medium

    static let neutral = ColorWarp()

    private enum CodingKeys: String, CodingKey {
        case points, strength, preservesLuminance, density
    }

    init() {}

    /// Every key is optional on decode so a warp written by an older or newer
    /// build still loads as something renderable rather than failing the whole
    /// project.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decodeIfPresent([ColorWarpPoint].self, forKey: .points) ?? []
        strength = try container.decodeIfPresent(Float.self, forKey: .strength) ?? 100
        preservesLuminance = try container.decodeIfPresent(Bool.self, forKey: .preservesLuminance) ?? true
        density = try container.decodeIfPresent(ColorWarpDensity.self, forKey: .density) ?? .medium
    }

    /// The points that actually move a pixel, already clamped, in one mode.
    func activePoints(_ mode: ColorWarpMode) -> [ColorWarpPoint] {
        points.filter { $0.mode == mode && !$0.isResting }.map(\.clamped)
    }

    /// One bit per plane that changes a pixel, handed to the shader so an unused
    /// plane costs no texture fetch.
    var activeMask: UInt32 {
        guard strength > 0 else { return 0 }
        return ColorWarpMode.allCases.reduce(into: UInt32(0)) { mask, mode in
            if !activePoints(mode).isEmpty { mask |= mode.maskBit }
        }
    }

    /// True when the warper cannot change a pixel. Used for the GPU's active
    /// mask, for Pro gating and for the panel's Reset button.
    var isNeutral: Bool { activeMask == 0 }

    /// True when there is anything for the editor to show or reset, including
    /// points that are momentarily resting on their own source.
    var hasPoints: Bool { !points.isEmpty }

    var resolvedStrength: Float { min(max(strength, 0), 100) }

    subscript(id: UUID) -> ColorWarpPoint? {
        get { points.first { $0.id == id } }
        set {
            guard let index = points.firstIndex(where: { $0.id == id }) else {
                if let newValue { points.append(newValue) }
                return
            }
            if let newValue { points[index] = newValue } else { points.remove(at: index) }
        }
    }

    mutating func removePoint(id: UUID) { points.removeAll { $0.id == id } }

    mutating func resetPoint(id: UUID) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].resetTarget()
    }

    /// Clears one plane, leaving the other alone - so "reset the hue wheel" does
    /// not silently throw away a chroma/luma move the user cannot see from here.
    mutating func reset(_ mode: ColorWarpMode) {
        points.removeAll { $0.mode == mode }
    }

    mutating func reset() {
        self = ColorWarp(preserving: self)
    }

    /// A fresh warp that keeps the settings that are preferences rather than
    /// grade: which plane the editor was on is UI state and lives there, but the
    /// density and the luminance choice are how this person works.
    private init(preserving previous: ColorWarp) {
        points = []
        strength = 100
        preservesLuminance = previous.preservesLuminance
        density = previous.density
    }

    /// The nearest point to a place in the plane, within `limit` of it, so a tap
    /// lands on the handle it looks like it landed on.
    func nearestPoint(to x: Float, _ y: Float, mode: ColorWarpMode, within limit: Float) -> ColorWarpPoint? {
        points
            .filter { $0.mode == mode }
            .map { point -> (ColorWarpPoint, Float) in
                let dx = mode.wrapsHorizontally
                    ? ColorWarpMath.wrappedDelta(from: point.sourceX, to: x)
                    : x - point.sourceX
                let dy = y - point.sourceY
                return (point, dx * dx + dy * dy)
            }
            .filter { $0.1 <= limit * limit }
            .min { $0.1 < $1.1 }?.0
    }
}

// ---------------------------------------------------------------------------
// Shared maths
//
// Here rather than in the field builder because the editor needs the same
// answers: a handle dragged across the red boundary has to travel the short way
// round on screen for the same reason the field does.
// ---------------------------------------------------------------------------

enum ColorWarpMath {
    /// Brings a hue back into 0..<1.
    static func wrap(_ value: Float) -> Float {
        let fraction = value - value.rounded(.down)
        return fraction < 0 ? fraction + 1 : fraction
    }

    /// Signed distance around the circle, -0.5...0.5. Going from 0.95 to 0.05 is
    /// +0.1, not -0.9.
    static func wrappedDelta(from: Float, to: Float) -> Float {
        var delta = wrap(to) - wrap(from)
        if delta > 0.5 { delta -= 1 }
        if delta < -0.5 { delta += 1 }
        return delta
    }

    /// The Hermite `smoothstep`, matching the shader's, so a falloff sampled on
    /// the CPU and a guard applied on the GPU agree on their shape.
    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// ---------------------------------------------------------------------------
// Turning a colour sampled off the picture into warper coordinates
//
// Shared by both editors so the eyedropper behaves identically on a video frame
// and on a photograph, and deliberately using the SAME hue and saturation the
// shader measures - see `rgbToHSL` in Shaders.metal. If these two ever disagreed
// the picker would highlight one place on the mesh while the warp acted on
// another, which is the one thing this tool cannot afford.
// ---------------------------------------------------------------------------

enum ColorWarpPicker {
    /// Below this much chroma a pixel has no hue worth selecting on the hue
    /// plane. The same threshold `CurveHuePicker` uses, for the same reason.
    static let minimumChroma: Float = 0.02

    static var neutralMessage: String {
        String(localized: "That area has almost no color, so there is nothing for the hue mesh to hold on to. Try a more colorful part of the picture, or use Chroma / Luma.")
    }

    /// Where a sampled colour sits in each plane.
    ///
    /// The sample is clamped first. On an HDR or Log project the readback is in
    /// extended-range working space and a specular highlight can be well above
    /// 1.0; the warper's planes are bounded, and the shader reaches them through
    /// the same clamp.
    static func coordinates(of colour: SIMD3<Float>) -> (hue: Float, saturation: Float, luma: Float) {
        let r = min(max(colour.x, 0), 1)
        let g = min(max(colour.y, 0), 1)
        let b = min(max(colour.z, 0), 1)
        let hi = max(r, max(g, b))
        let lo = min(r, min(g, b))
        let delta = hi - lo
        let lightness = (hi + lo) * 0.5
        var hue: Float = 0
        if delta > 0.00001 {
            if hi == r { hue = (g - b) / delta }
            else if hi == g { hue = 2 + (b - r) / delta }
            else { hue = 4 + (r - g) / delta }
            hue = ColorWarpMath.wrap(hue / 6)
        }
        let saturation = delta / max(1 - abs(2 * lightness - 1), 0.00001)
        return (hue, min(max(saturation, 0), 1), 0.2126 * r + 0.7152 * g + 0.0722 * b)
    }

    /// Where the sample lands in one plane's own axes.
    static func position(of colour: SIMD3<Float>, in mode: ColorWarpMode) -> SIMD2<Float>? {
        let sample = coordinates(of: colour)
        switch mode {
        case .hueSaturation:
            guard sample.saturation > minimumChroma else { return nil }
            return SIMD2(sample.hue, sample.saturation)
        case .chromaLuma:
            // No chroma floor here: "take the colour out of the highlights" is a
            // move onto near-neutral pixels, and refusing it would be wrong.
            return SIMD2(sample.saturation, min(max(sample.luma, 0), 1))
        }
    }
}
