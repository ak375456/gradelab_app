import Foundation

// ---------------------------------------------------------------------------
// Relight presets
//
// Starting points, not modes. A preset writes ordinary lights with ordinary
// values into the ordinary model, so the moment it lands every light can be
// dragged, recoloured, softened or deleted like one the user placed by hand —
// and Undo removes the whole preset in one step, because applying it is one
// edit.
//
// Applying a preset replaces the lights and the three scene-wide finishing
// values. It keeps what belongs to the clip rather than to the look: whether
// relight is switched on, which mask it is limited to, and which analysis it
// was set up against.
// ---------------------------------------------------------------------------

struct RelightPreset: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let strength: Double
    let preserveHighlights: Double
    let protectBlacks: Double
    let lights: @Sendable () -> [RelightLight]

    /// `current` with this preset's lighting. New light identities every
    /// time, so applying the same preset twice cannot produce two lights that
    /// share an id.
    func applied(to current: RelightSettings) -> RelightSettings {
        var settings = current
        settings.lights = Array(lights().prefix(RelightSettings.maximumLights))
        settings.strength = strength
        settings.preserveHighlights = preserveHighlights
        settings.protectBlacks = protectBlacks
        settings.isEnabled = true
        // The scene's own animation described the old setup's strength.
        settings.animation = nil
        return settings
    }

    static var all: [RelightPreset] {
        [softKey, warmSunset, coolMoonlight, sideLight, topLight, rimLight, dramatic, softFill]
    }

    private static var key: String { String(localized: "Key Light") }
    private static var fill: String { String(localized: "Fill Light") }
    private static var rim: String { String(localized: "Rim Light") }
    private static var negative: String { String(localized: "Negative Fill") }

    static var softKey: RelightPreset {
        RelightPreset(
            id: "softKey", title: String(localized: "Soft Key"), symbol: "lightbulb",
            summary: String(localized: "A large, gentle key from the front right."),
            strength: 1, preserveHighlights: 0.75, protectBlacks: 0.4,
            lights: {
                [RelightLight(name: key, type: .point, positionX: 0.72, positionY: 0.28,
                              distance: 0.18, intensity: 90, exposure: 0.9,
                              temperature: 5400, softness: 0.85, falloff: 0.35,
                              radius: 1.3, shadowResponse: 0.15)]
            })
    }

    static var warmSunset: RelightPreset {
        RelightPreset(
            id: "warmSunset", title: String(localized: "Warm Sunset"), symbol: "sun.horizon",
            summary: String(localized: "Low, warm sun from the side with a cool sky fill."),
            strength: 1, preserveHighlights: 0.7, protectBlacks: 0.35,
            lights: {
                [RelightLight(name: key, type: .directional, azimuth: 165, elevation: 14,
                              intensity: 110, exposure: 1.1, temperature: 2900, tint: 8,
                              softness: 0.45, shadowResponse: 0.35),
                 RelightLight(name: fill, type: .point, positionX: 0.85, positionY: 0.3,
                              distance: 0.2, intensity: 35, exposure: 0.6,
                              temperature: 8200, softness: 0.9, falloff: 0.3, radius: 1.5)]
            })
    }

    static var coolMoonlight: RelightPreset {
        RelightPreset(
            id: "coolMoonlight", title: String(localized: "Cool Moonlight"), symbol: "moon.stars",
            summary: String(localized: "Cold top light with the far side pulled down."),
            strength: 1, preserveHighlights: 0.8, protectBlacks: 0.2,
            lights: {
                [RelightLight(name: key, type: .directional, azimuth: 62, elevation: 28,
                              intensity: 90, exposure: 0.8, temperature: 9500, tint: -6,
                              softness: 0.4, shadowResponse: 0.5),
                 RelightLight(name: negative, type: .directional, azimuth: 235, elevation: 12,
                              intensity: -45, exposure: 0.8, temperature: 6500,
                              softness: 0.7)]
            })
    }

    static var sideLight: RelightPreset {
        RelightPreset(
            id: "sideLight", title: String(localized: "Side Light"), symbol: "circle.lefthalf.filled",
            summary: String(localized: "Hard light across the subject from the right."),
            strength: 1, preserveHighlights: 0.7, protectBlacks: 0.35,
            lights: {
                [RelightLight(name: key, type: .directional, azimuth: 0, elevation: 6,
                              intensity: 110, exposure: 1.2, temperature: 5600,
                              softness: 0.3, shadowResponse: 0.6)]
            })
    }

    static var topLight: RelightPreset {
        RelightPreset(
            id: "topLight", title: String(localized: "Top Light"), symbol: "arrow.down.to.line",
            summary: String(localized: "Overhead light that models the brow and shoulders."),
            strength: 1, preserveHighlights: 0.7, protectBlacks: 0.35,
            lights: {
                [RelightLight(name: key, type: .directional, azimuth: 90, elevation: 30,
                              intensity: 100, exposure: 1.0, temperature: 5000,
                              softness: 0.35, shadowResponse: 0.45)]
            })
    }

    static var rimLight: RelightPreset {
        RelightPreset(
            id: "rimLight", title: String(localized: "Rim Light"), symbol: "circle.dashed",
            summary: String(localized: "A light behind the subject that outlines its edges."),
            strength: 1, preserveHighlights: 0.75, protectBlacks: 0.5,
            lights: {
                [RelightLight(name: rim, type: .point, positionX: 0.82, positionY: 0.22,
                              distance: 0.92, intensity: 120, exposure: 1.5,
                              temperature: 6000, softness: 0.25, falloff: 0.45,
                              radius: 1.2, lightWrap: 0.35)]
            })
    }

    static var dramatic: RelightPreset {
        RelightPreset(
            id: "dramatic", title: String(localized: "Dramatic"), symbol: "theatermasks",
            summary: String(localized: "A narrow spot from above with the rest of the frame held down."),
            strength: 1, preserveHighlights: 0.8, protectBlacks: 0.25,
            lights: {
                [RelightLight(name: key, type: .spot, positionX: 0.22, positionY: 0.08,
                              distance: 0.15, targetX: 0.5, targetY: 0.42,
                              intensity: 130, exposure: 1.4, temperature: 4500,
                              softness: 0.35, falloff: 0.4, radius: 1.6,
                              coneAngle: 22, feather: 0.55, shadowResponse: 0.7),
                 RelightLight(name: negative, type: .directional, azimuth: 0, elevation: 20,
                              intensity: -60, exposure: 1.0, temperature: 6500,
                              softness: 0.6)]
            })
    }

    static var softFill: RelightPreset {
        RelightPreset(
            id: "softFill", title: String(localized: "Soft Fill"), symbol: "circle.lefthalf.striped.horizontal",
            summary: String(localized: "Gentle frontal light that opens up the shadows."),
            strength: 1, preserveHighlights: 0.8, protectBlacks: 0.45,
            lights: {
                [RelightLight(name: fill, type: .directional, azimuth: 200, elevation: 62,
                              intensity: 60, exposure: 0.6, temperature: 6500,
                              softness: 1, shadowResponse: 0)]
            })
    }
}
