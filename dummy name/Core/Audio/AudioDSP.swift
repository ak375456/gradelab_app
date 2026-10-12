import Foundation

/// Five small biquads per channel, with no lookahead or added latency. The
/// processing callback owns this state; the UI only publishes settings.
final class AudioDSP {
    private var sampleRate = 48_000.0
    private var states: [ChannelState] = []
    private var filters = FilterBank()
    private var target = FilterBank()
    private var left = 1.0, right = 1.0
    private var targetLeft = 1.0, targetRight = 1.0
    private var smoothing = 0.0
    private var spaces: [AudioSpaceDSP] = []
    private var spaceActive = false, spaceFlushFrames = 0
    private var toneActive = false, toneFlushFrames = 0
    private var envelope = 0.0, compressorGain = 1.0
    private var attack = 0.0, release = 0.0
    private(set) var settings = AudioProcessingSettings()

    func prepare(sampleRate: Double, channels: Int, settings: AudioProcessingSettings) {
        self.sampleRate = max(1, sampleRate)
        states = Array(repeating: ChannelState(), count: max(1, channels))
        spaces = (0..<max(1, channels)).map { AudioSpaceDSP(rate: self.sampleRate, channel: $0) }
        smoothing = 1 - exp(-1 / (self.sampleRate * 0.01))
        configure(settings)
        reset()
    }

    func configure(_ settings: AudioProcessingSettings) {
        self.settings = settings.sanitized
        let tone = self.settings
        let active = (tone.echo?.isEnabled == true && tone.echo!.mix > 0)
            || (tone.reverb?.isEnabled == true && tone.reverb!.mix > 0)
            || (tone.texture?.isEnabled == true && (tone.texture!.distortion > 0 || tone.texture!.crush > 0))
        for space in spaces {
            space.configure(tone)
            if active && !spaceActive && spaceFlushFrames == 0 { space.resetHistory() }
        }
        if spaceActive && !active { spaceFlushFrames = Int(sampleRate * 0.2) }
        spaceActive = active
        let compressor = tone.compressor ?? .init()
        attack = exp(-1 / (sampleRate * compressor.attack / 1_000))
        release = exp(-1 / (sampleRate * compressor.release / 1_000))
        let activeTone = tone.isToneEnabled && tone.hasTone
        if toneActive && !activeTone { toneFlushFrames = Int(sampleRate * 0.2) }
        toneActive = activeTone
        target = tone.isToneEnabled ? FilterBank(
            bass: .shelf(frequency: 200, gain: tone.bass, rate: sampleRate, high: false),
            mid: .peak(frequency: 1_000, gain: tone.mid, rate: sampleRate),
            treble: .shelf(frequency: 4_000, gain: tone.treble, rate: sampleRate, high: true),
            low: tone.lowCut > 0 ? .cut(frequency: tone.lowCut, rate: sampleRate, highPass: true) : .identity,
            high: tone.highCut < 20_000 ? .cut(frequency: tone.highCut, rate: sampleRate, highPass: false) : .identity
        ) : FilterBank()
        // Balance keeps the original stereo image and level at the center.
        targetLeft = tone.pan > 0 ? cos(tone.pan * .pi / 2) : 1
        targetRight = tone.pan < 0 ? cos(-tone.pan * .pi / 2) : 1
    }

    func reset() {
        for index in states.indices { states[index] = ChannelState() }
        filters = target
        left = targetLeft; right = targetRight
        envelope = 0; compressorGain = 1
        spaceFlushFrames = 0; toneFlushFrames = 0
        for space in spaces { space.reset() }
    }

    /// Called once per frame, shared by every channel and buffer. Smooth
    /// coefficient and balance changes to avoid steps while dragging sliders.
    func beginFrame(inputPeak: Double = 0) {
        if !spaceActive && spaceFlushFrames > 0 { spaceFlushFrames -= 1 }
        if !toneActive && toneFlushFrames > 0 { toneFlushFrames -= 1 }
        if toneActive || toneFlushFrames > 0 { filters.approach(target, amount: smoothing) }
        left += (targetLeft - left) * smoothing
        right += (targetRight - right) * smoothing
        var gain = 1.0
        if let c = settings.compressor, c.isEnabled {
            let peak = inputPeak.isFinite ? abs(inputPeak) : 0
            let coefficient = peak > envelope ? attack : release
            envelope = coefficient * envelope + (1 - coefficient) * peak
            let over = 20 * log10(max(1e-12, envelope)) - c.threshold
            // Six-dB soft knee; the linked detector applies the same gain to
            // every channel, preserving stereo balance through loud transients.
            let reduction = over <= -3 ? 0 : over >= 3 ? over * (1 - 1 / c.ratio)
                : pow(over + 3, 2) / 12 * (1 - 1 / c.ratio)
            gain = pow(10, (c.makeup - reduction) / 20)
        }
        compressorGain += (gain - compressorGain) * smoothing
    }

    func process(_ sample: Double, channel: Int) -> Double {
        guard states.indices.contains(channel) else { return sample }
        var value = sample.isFinite ? sample : 0
        value *= compressorGain
        if toneActive || toneFlushFrames > 0 { value = states[channel].process(value, filters: filters) }
        if spaceActive || spaceFlushFrames > 0 { value = spaces[channel].process(value) }
        if states.count >= 2 {
            if channel == 0 { value *= left }
            if channel == 1 { value *= right }
        }
        return value.isFinite ? value : 0
    }
}

private struct FilterBank {
    var bass = Biquad.identity, mid = Biquad.identity, treble = Biquad.identity
    var low = Biquad.identity, high = Biquad.identity
    mutating func approach(_ target: Self, amount: Double) {
        bass.approach(target.bass, amount); mid.approach(target.mid, amount)
        treble.approach(target.treble, amount); low.approach(target.low, amount)
        high.approach(target.high, amount)
    }
}

private struct ChannelState {
    var bass = BiquadState(), mid = BiquadState(), treble = BiquadState()
    var low = BiquadState(), high = BiquadState()
    mutating func process(_ value: Double, filters: FilterBank) -> Double {
        let a = low.process(value, filters.low)
        let b = bass.process(a, filters.bass)
        let c = mid.process(b, filters.mid)
        let d = treble.process(c, filters.treble)
        return high.process(d, filters.high)
    }
}

private struct BiquadState {
    var z1 = 0.0, z2 = 0.0
    mutating func process(_ input: Double, _ c: Biquad) -> Double {
        let output = c.b0 * input + z1
        z1 = c.b1 * input - c.a1 * output + z2
        z2 = c.b2 * input - c.a2 * output
        // Flush denormals during silence, avoiding a CPU penalty after tails.
        if abs(z1) < 1e-24 { z1 = 0 }
        if abs(z2) < 1e-24 { z2 = 0 }
        return output
    }
}

/// RBJ cookbook coefficients, normalized by a0. Frequencies are bounded below
/// Nyquist so the same preset is stable at different source sample rates.
private struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    static let identity = Self(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
    init(b0: Double, b1: Double, b2: Double, a0: Double = 1, a1: Double, a2: Double) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }
    mutating func approach(_ target: Self, _ amount: Double) {
        b0 += (target.b0 - b0) * amount; b1 += (target.b1 - b1) * amount
        b2 += (target.b2 - b2) * amount; a1 += (target.a1 - a1) * amount
        a2 += (target.a2 - a2) * amount
    }
    private static func angle(_ frequency: Double, _ rate: Double) -> Double {
        2 * .pi * min(frequency, rate * 0.45) / rate
    }
    static func peak(frequency: Double, gain: Double, rate: Double) -> Self {
        guard gain != 0 else { return .identity }
        let w = angle(frequency, rate), a = pow(10, gain / 40)
        let alpha = sin(w) / (2 * 0.8), c = cos(w)
        return Self(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a,
                    a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }
    static func cut(frequency: Double, rate: Double, highPass: Bool) -> Self {
        let w = angle(frequency, rate), c = cos(w), alpha = sin(w) / sqrt(2)
        let b = highPass ? (1 + c) / 2 : (1 - c) / 2
        return Self(b0: b, b1: highPass ? -2 * b : 2 * b, b2: b,
                    a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }
    static func shelf(frequency: Double, gain: Double, rate: Double, high: Bool) -> Self {
        guard gain != 0 else { return .identity }
        let w = angle(frequency, rate), a = pow(10, gain / 40), c = cos(w)
        let beta = sqrt(2 * a) * sin(w), p = a + 1, m = a - 1
        if high {
            return Self(b0: a * (p + m * c + beta), b1: -2 * a * (m + p * c), b2: a * (p + m * c - beta),
                        a0: p - m * c + beta, a1: 2 * (m - p * c), a2: p - m * c - beta)
        }
        return Self(b0: a * (p - m * c + beta), b1: 2 * a * (m - p * c), b2: a * (p - m * c - beta),
                    a0: p + m * c + beta, a1: -2 * (m + p * c), a2: p + m * c - beta)
    }
}
