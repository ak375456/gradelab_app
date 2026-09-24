import Foundation

/// Exposure aids drawn over the preview: false colour and zebras.
///
/// Deliberately not part of `VideoProject`, and deliberately not part of
/// `GradeSettings` either. An assist is how the person is *looking* at the
/// picture, not something the picture carries: it must not travel with a copied
/// grade, a saved preset or a shared project, and it must never reach an
/// exported frame. It is carried to the shader in `GradeUniforms.reservedC`,
/// which the renderer writes after the grade has been built, and it is read
/// only by display fragments — no export path runs one.
enum ViewerAssist: String, CaseIterable, Identifiable, Sendable {
    case off
    /// Exposure as colour zones. Green is 18% grey, pink is average skin,
    /// yellow is approaching clipping and red is clipped.
    case falseColor
    /// Diagonal stripes over everything at or above the threshold.
    case zebras

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .falseColor: String(localized: "False Colour")
        case .zebras: String(localized: "Zebras")
        }
    }

    /// The symbol for the segmented control.
    var symbol: String {
        switch self {
        case .off: "eye.slash"
        case .falseColor: "paintpalette"
        case .zebras: "light.beacon.max"
        }
    }

    /// What the shader switches on. Matches `applyViewerAssist` in Shaders.metal.
    var shaderMode: Float {
        switch self {
        case .off: 0
        case .falseColor: 1
        case .zebras: 2
        }
    }
}

/// Viewer assist state, persisted the way `ScopeSettings` is: a preference, not
/// a document property.
struct ViewerAssistSettings: Equatable, Sendable {
    var mode: ViewerAssist = .off
    /// The luma at or above which zebras are drawn, as a percentage. 90 is the
    /// broadcast convention for "about to clip"; 70 is the other common choice,
    /// used for exposing skin rather than for protecting highlights.
    var zebraThreshold: Double = 90

    static let thresholdRange: ClosedRange<Double> = 50...100

    var isEnabled: Bool { mode != .off }

    /// `reservedC` as the shader reads it: mode, then the threshold as 0...1.
    var uniform: SIMD4<Float> {
        SIMD4(mode.shaderMode, Float(zebraThreshold / 100), 0, 0)
    }

    private enum Key {
        static let mode = "viewerAssist.mode"
        static let threshold = "viewerAssist.zebraThreshold"
    }

    static func load(from defaults: UserDefaults = .standard) -> ViewerAssistSettings {
        var settings = ViewerAssistSettings()
        if let raw = defaults.string(forKey: Key.mode), let mode = ViewerAssist(rawValue: raw) {
            settings.mode = mode
        }
        let stored = defaults.double(forKey: Key.threshold)
        if stored > 0 {
            settings.zebraThreshold = min(max(stored, thresholdRange.lowerBound),
                                          thresholdRange.upperBound)
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(zebraThreshold, forKey: Key.threshold)
    }
}
