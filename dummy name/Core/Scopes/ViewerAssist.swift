import Foundation

/// Monitoring aids drawn only over the preview.
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
    var focusPeaking = false
    var peakingColor: FocusPeakingColor = .cyan
    /// More sensitivity marks lower-contrast edges, including more noise.
    var peakingSensitivity: Double = 50

    static let thresholdRange: ClosedRange<Double> = 50...100

    var isEnabled: Bool { mode != .off || focusPeaking }

    /// `reservedC` as the shader reads it: mode, then the threshold as 0...1.
    var uniform: SIMD4<Float> {
        SIMD4(mode.shaderMode, Float(zebraThreshold / 100),
              focusPeaking ? peakingColor.shaderValue : 0,
              Float(min(100, max(0, peakingSensitivity)) / 100))
    }

    private enum Key {
        static let mode = "viewerAssist.mode"
        static let threshold = "viewerAssist.zebraThreshold"
        static let peaking = "viewerAssist.focusPeaking"
        static let color = "viewerAssist.peakingColor"
        static let sensitivity = "viewerAssist.peakingSensitivity"
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
        settings.focusPeaking = defaults.bool(forKey: Key.peaking)
        if let raw = defaults.string(forKey: Key.color), let color = FocusPeakingColor(rawValue: raw) { settings.peakingColor = color }
        if defaults.object(forKey: Key.sensitivity) != nil {
            settings.peakingSensitivity = min(100, max(0, defaults.double(forKey: Key.sensitivity)))
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(zebraThreshold, forKey: Key.threshold)
        defaults.set(focusPeaking, forKey: Key.peaking)
        defaults.set(peakingColor.rawValue, forKey: Key.color)
        defaults.set(peakingSensitivity, forKey: Key.sensitivity)
    }
}

enum FocusPeakingColor: String, CaseIterable, Identifiable, Sendable {
    case cyan, red, yellow, white
    var id: Self { self }
    var title: String {
        switch self {
        case .cyan: String(localized: "Cyan")
        case .red: String(localized: "Red")
        case .yellow: String(localized: "Yellow")
        case .white: String(localized: "White")
        }
    }
    var shaderValue: Float {
        switch self { case .cyan: 1; case .red: 2; case .yellow: 3; case .white: 4 }
    }
}
