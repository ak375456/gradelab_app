import Foundation

struct GradeSettings: Codable, Equatable, Sendable {
    var exposure: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var whites: Float = 0
    var blacks: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var saturation: Float = 0
    var vibrance: Float = 0
    // Optional for backwards-compatible decoding of existing saved projects.
    var advanced: AdvancedGrade?

    static let neutral = GradeSettings()

    mutating func reset(_ parameter: GradeParameter) {
        self[keyPath: parameter.keyPath] = parameter.neutralValue
    }

    mutating func resetAll() {
        self = .neutral
    }
}

extension GradeSettings {
    /// Whether there is an actual colour change for a local mask to reveal.
    /// The mask itself is intentionally ignored: drawing a window around a
    /// neutral grade cannot change a pixel, and the UI explains that state.
    var hasCreativeChangeIgnoringMask: Bool {
        var copy = self
        if var advanced = copy.advanced {
            advanced.mask = nil
            copy.advanced = advanced == .neutral ? nil : advanced
        }
        return copy != .neutral
    }

    /// The same grade with its look removed, for when the `.cube` it names is
    /// no longer on the device. Everything else is left exactly as it was, and
    /// nothing is substituted for the missing look.
    var withoutLook: GradeSettings {
        var copy = self
        guard var advanced = copy.advanced else { return copy }
        advanced.lut = nil
        advanced.lutIntensity = nil
        copy.advanced = advanced == .neutral ? nil : advanced
        return copy
    }
}

enum GradeParameter: String, CaseIterable, Codable, Identifiable, Sendable {
    case exposure
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case temperature
    case tint
    case saturation
    case vibrance

    var id: String { rawValue }

    static let light: [GradeParameter] = [
        .exposure, .contrast, .highlights, .shadows, .whites, .blacks
    ]

    static let color: [GradeParameter] = [
        .temperature, .tint, .saturation, .vibrance
    ]

    var title: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// UI ranges map to deliberately bounded shader transforms.
    /// Exposure is measured in stops; all other controls use a familiar -100...100 scale.
    var range: ClosedRange<Float> {
        switch self {
        case .exposure: -2...2
        default: -100...100
        }
    }

    var step: Float {
        self == .exposure ? 0.01 : 1
    }

    var neutralValue: Float { 0 }

    var keyPath: WritableKeyPath<GradeSettings, Float> {
        switch self {
        case .exposure: \GradeSettings.exposure
        case .contrast: \GradeSettings.contrast
        case .highlights: \GradeSettings.highlights
        case .shadows: \GradeSettings.shadows
        case .whites: \GradeSettings.whites
        case .blacks: \GradeSettings.blacks
        case .temperature: \GradeSettings.temperature
        case .tint: \GradeSettings.tint
        case .saturation: \GradeSettings.saturation
        case .vibrance: \GradeSettings.vibrance
        }
    }

    func formatted(_ value: Float) -> String {
        if self == .exposure {
            return String(format: "%+.2f", value)
        }
        return String(format: "%+.0f", value)
    }

    var lowerLabel: String {
        self == .exposure ? "-2" : "-100"
    }

    var upperLabel: String {
        self == .exposure ? "+2" : "+100"
    }
}
