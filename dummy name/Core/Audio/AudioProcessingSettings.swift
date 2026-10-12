import Foundation

/// Per-clip sound adjustments. Optional on the clip so older projects remain
/// unchanged. Presets are ordinary EQ values, never a second processing stage.
struct AudioProcessingSettings: Codable, Equatable, Sendable {
    var pan: Double = 0
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    var lowCut: Double = 0
    var highCut: Double = 20_000
    var isToneEnabled = true
    var compressor: AudioCompressorSettings? = nil
    var ducking: AudioDuckingSettings? = nil
    var echo: AudioEchoSettings? = nil
    var reverb: AudioReverbSettings? = nil
    var texture: AudioTextureSettings? = nil

    static let gainRange = -12.0...12.0
    static let lowCutRange = 0.0...500.0
    static let highCutRange = 1_000.0...20_000.0

    var isValid: Bool {
        pan.isFinite && (-1...1).contains(pan)
            && [bass, mid, treble].allSatisfy { $0.isFinite && Self.gainRange.contains($0) }
            && lowCut.isFinite && Self.lowCutRange.contains(lowCut)
            && highCut.isFinite && Self.highCutRange.contains(highCut)
            && (compressor?.isValid ?? true) && (ducking?.isValid ?? true)
            && (echo?.isValid ?? true) && (reverb?.isValid ?? true) && (texture?.isValid ?? true)
    }

    var sanitized: Self {
        func bounded(_ value: Double, _ range: ClosedRange<Double>, default fallback: Double = 0) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        var result = self
        result.pan = bounded(pan, -1...1)
        result.bass = bounded(bass, Self.gainRange)
        result.mid = bounded(mid, Self.gainRange)
        result.treble = bounded(treble, Self.gainRange)
        result.lowCut = bounded(lowCut, Self.lowCutRange)
        if result.lowCut < 20 { result.lowCut = 0 }
        result.highCut = bounded(highCut, Self.highCutRange, default: 20_000)
        result.compressor = compressor?.sanitized
        result.ducking = ducking?.sanitized
        result.echo = echo?.sanitized
        result.reverb = reverb?.sanitized
        result.texture = texture?.sanitized
        return result
    }

    var hasTone: Bool { bass != 0 || mid != 0 || treble != 0 || lowCut != 0 || highCut != 20_000 }

    var preset: AudioVoicePreset? {
        AudioVoicePreset.allCases.first { preset in
            var tone = self
            tone.pan = 0
            tone.isToneEnabled = true
            tone.compressor = nil; tone.ducking = nil; tone.echo = nil; tone.reverb = nil; tone.texture = nil
            return tone == preset.settings
        }
    }

    func applying(_ preset: AudioVoicePreset) -> Self {
        var result = preset.settings
        result.pan = pan
        result.compressor = compressor; result.ducking = ducking
        result.echo = echo; result.reverb = reverb; result.texture = texture
        return result
    }
}

private func audioBound(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
private func audioValid(_ value: Double, _ range: ClosedRange<Double>) -> Bool {
    value.isFinite && range.contains(value)
}

protocol AudioEffectSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool { get set }
}

struct AudioCompressorSettings: AudioEffectSettings {
    var isEnabled = true
    var threshold = -21.0
    var ratio = 4.5
    var attack = 15.0 // milliseconds
    var release = 180.0
    var makeup = 0.0 // dB; explicit to avoid surprising loudness jumps
    var amount: Double { min(1, max(0, (-threshold - 6) / 30)) }
    mutating func setAmount(_ value: Double) {
        let amount = audioBound(value, 0...1, 0.5)
        threshold = -6 - 30 * amount; ratio = 1 + 7 * amount
    }
    var isValid: Bool {
        audioValid(threshold, -60...0) && audioValid(ratio, 1...12)
            && audioValid(attack, 1...100) && audioValid(release, 20...1_000) && audioValid(makeup, 0...12)
    }
    var sanitized: Self {
        var s = self
        s.threshold = audioBound(threshold, -60...0, -21); s.ratio = audioBound(ratio, 1...12, 4.5)
        s.attack = audioBound(attack, 1...100, 15); s.release = audioBound(release, 20...1_000, 180)
        s.makeup = audioBound(makeup, 0...12, 0); return s
    }
}

struct AudioDuckingSettings: AudioEffectSettings {
    var isEnabled = true
    var sourceClipID: UUID? = nil
    var reduction = 12.0 // dB below the clip's normal level
    var attack = 0.15 // seconds, anticipates the voice
    var release = 0.6
    var threshold = -35.0 // dBFS activity threshold
    var isValid: Bool {
        audioValid(reduction, 0...30) && audioValid(attack, 0.02...1)
            && audioValid(release, 0.1...3) && audioValid(threshold, -55 ... -10)
    }
    var sanitized: Self {
        var s = self
        s.reduction = audioBound(reduction, 0...30, 12); s.attack = audioBound(attack, 0.02...1, 0.15)
        s.release = audioBound(release, 0.1...3, 0.6); s.threshold = audioBound(threshold, -55 ... -10, -35)
        return s
    }
}

struct AudioEchoSettings: AudioEffectSettings {
    var isEnabled = true
    var mix = 0.25
    var time = 0.3
    var feedback = 0.35
    var isValid: Bool { audioValid(mix, 0...0.8) && audioValid(time, 0.04...1.5) && audioValid(feedback, 0...0.8) }
    var sanitized: Self {
        var s = self; s.mix = audioBound(mix, 0...0.8, 0.25)
        s.time = audioBound(time, 0.04...1.5, 0.3); s.feedback = audioBound(feedback, 0...0.8, 0.35); return s
    }
}

struct AudioReverbSettings: AudioEffectSettings {
    var isEnabled = true
    var mix = 0.2
    var size = 0.5
    var damping = 0.5
    var isValid: Bool { audioValid(mix, 0...0.8) && audioValid(size, 0...1) && audioValid(damping, 0...1) }
    var sanitized: Self {
        var s = self; s.mix = audioBound(mix, 0...0.8, 0.2)
        s.size = audioBound(size, 0...1, 0.5); s.damping = audioBound(damping, 0...1, 0.5); return s
    }
}

struct AudioTextureSettings: AudioEffectSettings {
    var isEnabled = true
    var distortion = 0.0
    var crush = 0.0
    var isValid: Bool { audioValid(distortion, 0...1) && audioValid(crush, 0...1) }
    var sanitized: Self {
        var s = self; s.distortion = audioBound(distortion, 0...1, 0)
        s.crush = audioBound(crush, 0...1, 0); return s
    }
}

enum AudioVoicePreset: String, CaseIterable, Identifiable, Sendable {
    case flat, warm, telephone, muffled, bright
    var id: String { rawValue }
    var name: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .warm: String(localized: "Warm Voice")
        case .telephone: String(localized: "Telephone")
        case .muffled: String(localized: "Muffled")
        case .bright: String(localized: "Bright Voice")
        }
    }
    var icon: String {
        switch self {
        case .flat: "slider.horizontal.3"
        case .warm: "waveform"
        case .telephone: "phone"
        case .muffled: "speaker.wave.1"
        case .bright: "sparkles"
        }
    }
    var detail: String {
        switch self {
        case .flat: String(localized: "Original tone. Choose a preset or adjust the EQ below.")
        case .warm: String(localized: "Fuller lows and softer highs for a warmer voice.")
        case .telephone: String(localized: "A narrow frequency range, like a telephone call.")
        case .muffled: String(localized: "Softened detail, as if the sound is behind a wall.")
        case .bright: String(localized: "More presence and high-frequency detail for speech.")
        }
    }
    var settings: AudioProcessingSettings {
        switch self {
        case .flat: .init()
        case .warm: .init(bass: 3, mid: -1, treble: -2, lowCut: 80, highCut: 16_000)
        case .telephone: .init(bass: -3, mid: 3, treble: -5, lowCut: 300, highCut: 3_400)
        case .muffled: .init(bass: 1, mid: -2, treble: -8, highCut: 1_200)
        case .bright: .init(bass: -2, mid: 2, treble: 4, lowCut: 100, highCut: 18_000)
        }
    }
}
