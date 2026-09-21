import Foundation

/// The authored, lightweight description of a clip cutout. Generated Vision
/// masks deliberately live outside the project document.
enum BackgroundRemovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case lasso
    case colorKey

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: String(localized: "Auto")
        case .lasso: String(localized: "Lasso")
        case .colorKey: String(localized: "Color")
        }
    }
}

enum BackgroundRemovalBrush: String, Codable, Sendable {
    case add
    case remove
}

/// A whole drag is one value and therefore one undo operation. Points and
/// radius are source-normalized, so a correction authored on a phone preview
/// remains smooth when the same project exports at 4K.
struct BackgroundRemovalStroke: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: BackgroundRemovalBrush
    var points: [MaskPoint]
    var radius: Double = 0.04
    var softness: Double = 0.65
    var opacity: Double = 1
    /// Nil for stills. Video refinements are honest about being time-local.
    var localTime: TimelineTime?

    var clamped: BackgroundRemovalStroke {
        var value = self
        value.points = Array(value.points.prefix(2_048)).map(\.clamped)
        value.radius = min(max(value.radius.isFinite ? value.radius : 0.04, 0.002), 0.5)
        value.softness = min(max(value.softness.isFinite ? value.softness : 0.65, 0), 1)
        value.opacity = min(max(value.opacity.isFinite ? value.opacity : 1, 0.01), 1)
        return value
    }
}

struct BackgroundColorKeySettings: Codable, Equatable, Sendable {
    var color = RGBAColor(red: 0.08, green: 0.78, blue: 0.18)
    /// Chroma radius and transition width, both presented as 0...100.
    var similarity: Double = 38
    var smoothness: Double = 18
    var spill: Double = 35

    var clamped: BackgroundColorKeySettings {
        var value = self
        value.color.red = min(max(value.color.red, 0), 1)
        value.color.green = min(max(value.color.green, 0), 1)
        value.color.blue = min(max(value.color.blue, 0), 1)
        value.color.alpha = 1
        value.similarity = min(max(value.similarity, 0), 100)
        value.smoothness = min(max(value.smoothness, 0), 100)
        value.spill = min(max(value.spill, 0), 100)
        return value
    }
}

struct BackgroundRemovalSettings: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version = Self.currentVersion
    var isEnabled = true
    var mode: BackgroundRemovalMode = .automatic
    /// The hand-drawn outline, present only in `.lasso` mode.
    var lasso: BackgroundLassoSelection?
    var colorKey = BackgroundColorKeySettings()
    var strokes: [BackgroundRemovalStroke] = []
    /// 0...100 UI values. Edge shift is signed: negative contracts.
    var feather: Double = 0
    var edgeShift: Double = 0
    var isInverted = false
    /// Authored token naming rebuildable generated data. A duplicate may share
    /// this immutable cache safely; changing the analysis creates a new token.
    var analysisID = UUID()

    static let automatic = BackgroundRemovalSettings()

    var addStrokes: [BackgroundRemovalStroke] { strokes.filter { $0.kind == .add } }
    var removeStrokes: [BackgroundRemovalStroke] { strokes.filter { $0.kind == .remove } }

    mutating func beginAnalysis(mode: BackgroundRemovalMode) {
        self.mode = mode
        isEnabled = true
        analysisID = UUID()
    }

    /// Adopting an outline is authoring, not analysis: there is nothing to
    /// generate and nothing cached to invalidate, so the preview is correct on
    /// the very next frame the renderer draws.
    mutating func adopt(_ lasso: BackgroundLassoSelection) {
        mode = .lasso
        self.lasso = lasso.clamped
        isEnabled = true
    }

    mutating func resetRefinement() { strokes.removeAll() }

    var clamped: BackgroundRemovalSettings {
        var value = self
        value.version = Self.currentVersion
        value.colorKey = value.colorKey.clamped
        value.feather = min(max(value.feather.isFinite ? value.feather : 0, 0), 100)
        value.edgeShift = min(max(value.edgeShift.isFinite ? value.edgeShift : 0, -100), 100)
        value.strokes = Array(value.strokes.prefix(1_024)).map(\.clamped)
        value.lasso = value.lasso?.clamped
        return value
    }
}
