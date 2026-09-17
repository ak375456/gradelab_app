import Foundation

// ---------------------------------------------------------------------------
// Advanced curves
//
// One model covers all ten curves. What differs between them - the domain, the
// meaning of the vertical axis, the neutral shape, whether the horizontal axis
// wraps - is derived from `CurveType` rather than written out per curve, so a
// view or a LUT builder never has to special-case one of them.
//
// Values are always normalised. `x` is 0...1 across the curve's domain and `y`
// is either 0...1 (a mapping curve, neutral is y = x) or -1...1 (an adjustment
// curve, neutral is y = 0). Screen coordinates never reach this file.
// ---------------------------------------------------------------------------

/// One control point, in normalised curve space.
struct CurvePoint: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var x: Float
    var y: Float

    init(id: UUID = UUID(), x: Float, y: Float) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// What a curve reads on its horizontal axis and writes on its vertical one.
enum CurveType: String, Codable, CaseIterable, Identifiable, Sendable {
    case master
    case red
    case green
    case blue
    case hueVsHue
    case hueVsSaturation
    case hueVsLuma
    case lumaVsSaturation
    case saturationVsSaturation
    case saturationVsLuma

    var id: String { rawValue }

    /// Row in the curve LUT texture. Written out rather than taken from
    /// `allCases` so reordering the enum can never silently re-point the shader
    /// at the wrong row.
    var row: Int {
        switch self {
        case .master: 0
        case .red: 1
        case .green: 2
        case .blue: 3
        case .hueVsHue: 4
        case .hueVsSaturation: 5
        case .hueVsLuma: 6
        case .lumaVsSaturation: 7
        case .saturationVsSaturation: 8
        case .saturationVsLuma: 9
        }
    }

    /// Bit this curve occupies in the shader's active mask.
    var maskBit: UInt32 { 1 << UInt32(row) }

    /// True when the horizontal axis is hue, which is a circle: 0 and 1 are the
    /// same place, and everything about interpolation and point editing has to
    /// respect that.
    var isCyclic: Bool {
        switch self {
        case .hueVsHue, .hueVsSaturation, .hueVsLuma: true
        default: false
        }
    }

    /// A mapping curve outputs a value in the same units as its input, and its
    /// neutral shape is the diagonal. An adjustment curve outputs a signed
    /// offset around a neutral of zero.
    var isMapping: Bool {
        switch self {
        case .master, .red, .green, .blue, .saturationVsSaturation: true
        default: false
        }
    }

    /// The vertical value a neutral curve has at `x`.
    func neutralY(at x: Float) -> Float { isMapping ? x : 0 }

    /// Points a freshly reset curve carries.
    ///
    /// Mapping curves need their two endpoints to exist as real, draggable
    /// points. Linear-domain adjustment curves get neutral endpoints so that
    /// adding one point in the middle affects only the middle. Cyclic
    /// adjustment curves start empty: there are no ends to anchor, and the
    /// three-point hue selection supplies its own anchors.
    var defaultPoints: [CurvePoint] {
        if isMapping { return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)] }
        if isCyclic { return [] }
        return [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0)]
    }

    /// Endpoints of a linear-domain curve are structural: the curve has to be
    /// defined at 0 and 1, so they can be dragged vertically but not removed
    /// and not moved along x.
    var hasFixedEndpoints: Bool { !isCyclic }

    /// Hue-shift curves store turns of the colour wheel scaled into -1...1.
    /// ±1 is ±60°, which is the practical working range for hue-vs-hue and
    /// matches the ±30° the HSL panel already offers per band.
    static let hueShiftDegrees: Float = 60

    var shortTitle: String {
        switch self {
        case .master: "Master"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .hueVsHue: "Hue vs Hue"
        case .hueVsSaturation: "Hue vs Sat"
        case .hueVsLuma: "Hue vs Luma"
        case .lumaVsSaturation: "Luma vs Sat"
        case .saturationVsSaturation: "Sat vs Sat"
        case .saturationVsLuma: "Sat vs Luma"
        }
    }

    var title: String {
        switch self {
        case .master: String(localized: "Master")
        case .red: String(localized: "Red")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        default: shortTitle
        }
    }

    /// The four tone curves, in the order the channel picker shows them.
    static let toneCurves: [CurveType] = [.master, .red, .green, .blue]
    /// The six colour curves, in the order the selector shows them.
    static let colorCurves: [CurveType] = [
        .hueVsHue, .hueVsSaturation, .hueVsLuma,
        .lumaVsSaturation, .saturationVsSaturation, .saturationVsLuma
    ]
}

/// How the points between control points are joined.
enum CurveInterpolation: String, Codable, Sendable {
    /// Monotone cubic Hermite with Fritsch-Carlson tangent limiting. Smooth,
    /// and provably free of overshoot: between two control points the curve
    /// never leaves the interval they bound, so a tone curve cannot ring,
    /// invert, or produce a negative value.
    case monotoneCubic
    /// Straight segments. Only used to carry projects saved against the old
    /// three-slider `ToneCurve`, whose shader evaluated exactly this - keeping
    /// those grades pixel-identical instead of nearly so.
    case linear
}

/// One curve: its points, and how to read between them.
struct AdvancedCurve: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var type: CurveType
    var points: [CurvePoint]
    var interpolation: CurveInterpolation

    init(
        id: UUID = UUID(),
        type: CurveType,
        points: [CurvePoint]? = nil,
        interpolation: CurveInterpolation = .monotoneCubic
    ) {
        self.id = id
        self.type = type
        self.points = points ?? type.defaultPoints
        self.interpolation = interpolation
    }

    static func neutral(_ type: CurveType) -> AdvancedCurve { AdvancedCurve(type: type) }

    /// Points in ascending x. Everything that evaluates or draws the curve goes
    /// through this, so a drag that crosses another point cannot corrupt it.
    var sortedPoints: [CurvePoint] { points.sorted { $0.x < $1.x } }

    /// True when the curve does nothing: every point sits on its neutral line.
    /// Used for the GPU's active mask, so an untouched curve costs no work.
    var isFlat: Bool {
        points.allSatisfy { abs($0.y - type.neutralY(at: $0.x)) <= 1e-6 }
    }

    /// True when the curve is flat *and* shaped like a fresh one. A curve the
    /// user has added points to stays stored even while it is momentarily flat,
    /// so dragging a point through neutral does not delete it mid-gesture.
    var isNeutral: Bool { isFlat && points.count == type.defaultPoints.count }

    /// Whether removing this point is allowed. Structural endpoints are not.
    func canRemovePoint(id: UUID) -> Bool {
        guard type.hasFixedEndpoints else { return true }
        guard let point = points.first(where: { $0.id == id }) else { return false }
        return point.x > 0 && point.x < 1
    }

    mutating func reset() {
        points = type.defaultPoints
        interpolation = .monotoneCubic
    }
}

// ---------------------------------------------------------------------------
// The set of curves attached to one grade
// ---------------------------------------------------------------------------

/// The ten curves, stored sparsely: a curve that is doing nothing is simply
/// absent, so a project that has never opened the panel adds nothing to its
/// file and nothing to the GPU's work.
struct AdvancedCurves: Codable, Equatable, Sendable {
    /// Keyed by `CurveType.rawValue` so the JSON is self-describing and a curve
    /// type added later decodes old files without a migration.
    private var stored: [String: AdvancedCurve]

    init() { stored = [:] }

    subscript(type: CurveType) -> AdvancedCurve {
        get { stored[type.rawValue] ?? .neutral(type) }
        set {
            var value = newValue
            value.type = type
            stored[type.rawValue] = value.isNeutral ? nil : value
        }
    }

    var isNeutral: Bool { stored.isEmpty }

    /// Curves that actually change a pixel.
    var active: [AdvancedCurve] {
        CurveType.allCases.compactMap { type in
            guard let curve = stored[type.rawValue], !curve.isFlat else { return nil }
            return curve
        }
    }

    /// One bit per curve that changes a pixel, handed to the shader so it can
    /// skip every curve the user has not touched.
    var activeMask: UInt32 {
        active.reduce(into: UInt32(0)) { $0 |= $1.type.maskBit }
    }

    mutating func reset(_ type: CurveType) { self[type] = .neutral(type) }

    mutating func resetTone() { CurveType.toneCurves.forEach { reset($0) } }
    mutating func resetColor() { CurveType.colorCurves.forEach { reset($0) } }

    static let neutral = AdvancedCurves()
}

// ---------------------------------------------------------------------------
// Legacy migration
// ---------------------------------------------------------------------------

extension AdvancedCurves {
    /// Rebuilds the old three-slider `ToneCurve` set as advanced curves.
    ///
    /// The old shader evaluated a piecewise-linear ramp through five anchors at
    /// x = 0, ¼, ½, ¾, 1. Reproducing that as five control points with linear
    /// interpolation is exact rather than approximate, so opening a project
    /// saved before this work shows the same picture it did - a monotone cubic
    /// through the same anchors would not.
    init(migratingLegacy curves: [ToneCurve]) {
        self.init()
        let anchors: [Float] = [0, 0.25, 0.5, 0.75, 1]
        for (index, type) in CurveType.toneCurves.enumerated() {
            let legacy = index < curves.count ? curves[index] : ToneCurve()
            guard legacy != ToneCurve() else { continue }
            self[type] = AdvancedCurve(
                type: type,
                points: zip(anchors, legacy.points).map { CurvePoint(x: $0, y: $1) },
                interpolation: .linear
            )
        }
    }
}
