import Foundation

// ---------------------------------------------------------------------------
// Curve editing
//
// Adding, moving and removing control points, plus the three-point hue
// selection the eyedropper and the hue bar both produce. It lives beside the
// model rather than in the view so the rules - which points may be removed,
// how far a point may slide, what happens at the hue seam - are stated once.
// ---------------------------------------------------------------------------

extension AdvancedCurve {
    /// The smallest gap allowed between two points along x. Two points at the
    /// same x would make the segment between them a vertical line.
    static let minimumSpacing: Float = 0.004

    /// Adds a point and returns its id, or nil when there is no room for one.
    ///
    /// A tap close to an existing point moves that point instead of stacking a
    /// second one on top of it, which on a phone is nearly always what was meant.
    mutating func addPoint(x: Float, y: Float) -> UUID? {
        let clampedX = type.isCyclic ? x - x.rounded(.down) : min(max(x, 0), 1)
        let clampedY = clampY(y)
        if let existing = points.first(where: { hueSafeDistance($0.x, clampedX) < Self.minimumSpacing }) {
            movePoint(id: existing.id, x: clampedX, y: clampedY)
            return existing.id
        }
        let point = CurvePoint(x: clampedX, y: clampedY)
        points.append(point)
        points.sort { $0.x < $1.x }
        return point.id
    }

    /// Moves a point, keeping the curve well formed.
    ///
    /// A structural endpoint keeps its x: a tone curve has to be defined at 0
    /// and at 1. Everything else may slide, but not past its neighbours - on a
    /// cyclic curve that means not past them the short way round either, so a
    /// point dragged over the seam cannot turn the curve inside out.
    mutating func movePoint(id: UUID, x: Float, y: Float) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].y = clampY(y)

        let isEndpoint = type.hasFixedEndpoints && (points[index].x <= 0 || points[index].x >= 1)
        guard !isEndpoint else { return }

        if type.isCyclic {
            let wrapped = x - x.rounded(.down)
            let others = points.enumerated().filter { $0.offset != index }.map(\.element.x)
            let tooClose = others.contains { hueSafeDistance($0, wrapped) < Self.minimumSpacing }
            if !tooClose { points[index].x = wrapped }
        } else {
            let sorted = points.sorted { $0.x < $1.x }
            let position = sorted.firstIndex { $0.id == id } ?? 0
            let lower = position > 0 ? sorted[position - 1].x + Self.minimumSpacing : 0
            let upper = position < sorted.count - 1 ? sorted[position + 1].x - Self.minimumSpacing : 1
            points[index].x = min(max(x, min(lower, upper)), max(lower, upper))
        }
        points.sort { $0.x < $1.x }
    }

    @discardableResult
    mutating func removePoint(id: UUID) -> Bool {
        guard canRemovePoint(id: id) else { return false }
        let before = points.count
        points.removeAll { $0.id == id }
        return points.count != before
    }

    /// Builds a selection around one hue: a centre point to drag and two
    /// neighbours holding the surrounding hues at neutral.
    ///
    ///     ○      ●      ○
    ///
    /// Any point already inside the span is cleared first, so tapping a second
    /// colour near the first replaces that selection instead of interleaving
    /// with it. Returns the id of the centre point.
    @discardableResult
    mutating func selectHue(_ hue: Float, halfWidthDegrees: Float = 20) -> UUID? {
        guard type.isCyclic else { return nil }
        let centre = hue - hue.rounded(.down)
        let width = halfWidthDegrees / 360
        // Clear the span the new selection covers, plus any *neutral* point
        // just outside it. Those are the shoulders of a previous selection: they
        // hold nothing the user shaped, and leaving them behind is what would
        // let repeated picks at nearly the same colour silt up the curve with
        // orphaned anchors. A point the user has actually moved is left alone.
        points.removeAll { point in
            let distance = Self.distance(point.x, centre, cyclic: true)
            if distance <= width { return true }
            return distance <= width * 2 && abs(point.y) <= 1e-6
        }
        // Read the remaining curve at the centre so a new selection starts
        // where the curve already is rather than snapping back to neutral.
        let existingValue = CurveEvaluator(self).value(at: centre)
        let left = CurvePoint(x: wrap(centre - width), y: 0)
        let middle = CurvePoint(x: centre, y: existingValue)
        let right = CurvePoint(x: wrap(centre + width), y: 0)
        points.append(contentsOf: [left, middle, right])
        points.sort { $0.x < $1.x }
        return middle.id
    }

    private func wrap(_ x: Float) -> Float { x - x.rounded(.down) }

    /// Distance along x, the short way round for a hue axis. Static so it can
    /// be used from inside a mutation of `points` without aliasing `self`.
    private static func distance(_ a: Float, _ b: Float, cyclic: Bool) -> Float {
        let d = abs(a - b)
        return cyclic ? min(d, 1 - d) : d
    }

    private func hueSafeDistance(_ a: Float, _ b: Float) -> Float {
        Self.distance(a, b, cyclic: type.isCyclic)
    }

    private func clampY(_ y: Float) -> Float {
        type.isMapping ? min(max(y, 0), 1) : min(max(y, -1), 1)
    }
}

// ---------------------------------------------------------------------------
// Readouts
// ---------------------------------------------------------------------------

extension CurveType {
    /// What the horizontal axis measures, for the selected-point readout.
    var inputLabel: String {
        switch self {
        case .master, .red, .green, .blue: "In"
        case .hueVsHue, .hueVsSaturation, .hueVsLuma: "Hue"
        case .lumaVsSaturation: "Luma"
        case .saturationVsSaturation, .saturationVsLuma: "Sat"
        }
    }

    var outputLabel: String {
        switch self {
        case .master, .red, .green, .blue, .saturationVsSaturation: "Out"
        case .hueVsHue: "Shift"
        case .hueVsSaturation, .lumaVsSaturation: "Sat"
        case .hueVsLuma, .saturationVsLuma: "Luma"
        }
    }

    func formattedInput(_ x: Float) -> String {
        guard isCyclic else { return "\(Int((x * 100).rounded()))" }
        // 360 and 0 are the same hue, and a reading of "360°" looks like a
        // value that has run off the end of the scale.
        return "\(Int((x * 360).rounded()) % 360)°"
    }

    func formattedOutput(_ y: Float) -> String {
        switch self {
        case .master, .red, .green, .blue, .saturationVsSaturation:
            "\(Int((y * 100).rounded()))"
        case .hueVsHue:
            String(format: "%+d°", Int((y * CurveType.hueShiftDegrees).rounded()))
        default:
            String(format: "%+d", Int((y * 100).rounded()))
        }
    }

    /// A one-line description of what this curve does, shown under the graph.
    var help: String {
        switch self {
        case .master: String(localized: "Overall tone. Lift a point to brighten that range; lower it to darken. Pull shadows down and highlights up for contrast.")
        case .red: String(localized: "Red channel. Raising adds red; lowering leans cyan.")
        case .green: String(localized: "Green channel. Raising adds green; lowering leans magenta.")
        case .blue: String(localized: "Blue channel. Raising adds blue; lowering leans yellow.")
        case .hueVsHue: String(localized: "Turn one color into another. Pick a hue, then drag its point up or down to rotate it. Neighbouring hues follow smoothly.")
        case .hueVsSaturation: String(localized: "Saturation of one color. Pick a hue, then drag down to mute it or up to strengthen it.")
        case .hueVsLuma: String(localized: "Brightness of one color. Pick a hue, then drag down to darken it — a deeper sky, for instance.")
        case .lumaVsSaturation: String(localized: "Saturation by brightness. Pulling the left down mutes color in the shadows; the right does the same for highlights.")
        case .saturationVsSaturation: String(localized: "Remaps saturation. Lowering the right compresses colors that are already strong; lifting the left brings up quiet ones.")
        case .saturationVsLuma: String(localized: "Brightness by saturation. Lowering the right darkens the most colorful areas and leaves neutrals alone.")
        }
    }
}

/// Turning a colour sampled off the picture into a hue for the cyclic curves.
///
/// Shared by both editors so the eyedropper behaves identically on a video frame
/// and on a photograph — including its refusal to select a hue that is not
/// really there.
enum CurveHuePicker {
    /// Below this much chroma a pixel has no hue worth selecting, and picking
    /// one would just report whichever channel happened to win.
    static let minimumChroma: Float = 0.02

    static let neutralMessage =
        "That area has almost no color, so there is no hue to select. Try a more colorful part of the picture."

    /// The sampled colour's hue as 0...1, or nil when it is effectively neutral.
    static func hue(of colour: SIMD3<Float>) -> Float? {
        let hi = max(colour.x, max(colour.y, colour.z))
        let lo = min(colour.x, min(colour.y, colour.z))
        let delta = hi - lo
        guard delta > minimumChroma else { return nil }
        var hue: Float
        if hi == colour.x { hue = (colour.y - colour.z) / delta }
        else if hi == colour.y { hue = 2 + (colour.z - colour.x) / delta }
        else { hue = 4 + (colour.x - colour.y) / delta }
        return (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
    }
}
