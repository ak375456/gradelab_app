import Foundation

/// Scope UI state. Deliberately not part of `VideoProject`: a scope reading is
/// an analysis of the current frame, not something a document should carry.
/// Only the two preferences are persisted, and they go to `UserDefaults`.
struct ScopeSettings: Equatable, Sendable {
    var isEnabled = false
    var type: ScopeType = .histogram
    /// Gain on the density mapping. Waveform and vectorscope traces vary hugely
    /// in density between a flat shot and a detailed one, so this is genuinely
    /// useful rather than a setting for its own sake.
    var intensity: Double = 1

    static let intensityRange: ClosedRange<Double> = 0.4...2.5

    private enum Key {
        static let enabled = "scopes.enabled"
        static let type = "scopes.type"
        static let intensity = "scopes.intensity"
    }

    static func load(from defaults: UserDefaults = .standard) -> ScopeSettings {
        var settings = ScopeSettings()
        settings.isEnabled = defaults.bool(forKey: Key.enabled)
        if let raw = defaults.string(forKey: Key.type), let type = ScopeType(rawValue: raw) {
            settings.type = type
        }
        let stored = defaults.double(forKey: Key.intensity)
        if stored > 0 { settings.intensity = min(max(stored, intensityRange.lowerBound), intensityRange.upperBound) }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(type.rawValue, forKey: Key.type)
        defaults.set(intensity, forKey: Key.intensity)
    }
}
