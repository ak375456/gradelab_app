import Foundation

/// Callback-owned delay lines. Memory is reserved once during preparation.
/// Reset invalidates the history in constant time, avoiding a large buffer clear
/// on the first render callback after a seek.
final class AudioSpaceDSP {
    private var echo: [Double]
    private var echoIndex = 0, echoWritten = 0
    private var echoDelay = 0.0, targetDelay = 0.0, echoFeedback = 0.0
    private var combs: [AudioDelayLine]
    private var diffusers: [AudioDelayLine]
    private var damping = [Double](repeating: 0, count: 4)
    private var echoMix = 0.0, reverbMix = 0.0, distortion = 0.0, crush = 0.0
    private var targetEcho = 0.0, targetReverb = 0.0, targetDistortion = 0.0, targetCrush = 0.0
    private var roomFeedback = 0.0, roomDamping = 0.0, drive = 1.0, normalization = 1.0, steps = 65_536.0
    private var held = 0.0, holdCount = 0, holdLength = 1
    private let rate: Double
    private let smoothing: Double

    init(rate: Double, channel: Int) {
        self.rate = rate; smoothing = 1 - exp(-1 / (rate * 0.015))
        echo = [Double](repeating: 0, count: Int(rate * 1.5) + 2)
        let offset = Double(channel % 2) * 0.0007
        combs = [0.0297, 0.0371, 0.0411, 0.0437].map { AudioDelayLine(count: Int(rate * ($0 + offset))) }
        diffusers = [0.005, 0.0017].map { AudioDelayLine(count: Int(rate * ($0 + offset))) }
    }

    func configure(_ settings: AudioProcessingSettings) {
        let e = settings.echo ?? .init(isEnabled: false)
        let r = settings.reverb ?? .init(isEnabled: false)
        let t = settings.texture ?? .init(isEnabled: false)
        targetEcho = e.isEnabled ? e.mix : 0; targetReverb = r.isEnabled ? r.mix : 0
        targetDistortion = t.isEnabled ? t.distortion : 0; targetCrush = t.isEnabled ? t.crush : 0
        targetDelay = min(Double(echo.count - 2), e.time * rate); echoFeedback = e.feedback
        roomFeedback = 0.55 + r.size * 0.35; roomDamping = 0.05 + r.damping * 0.85
        drive = 1 + t.distortion * 24; normalization = 1 / tanh(drive)
        steps = pow(2, 16 - t.crush * 12); holdLength = max(1, Int(1 + t.crush * 15))
    }

    func resetHistory() {
        echoIndex = 0; echoWritten = 0
        for line in combs { line.reset() }; for line in diffusers { line.reset() }
        for i in damping.indices { damping[i] = 0 }
        held = 0; holdCount = 0
    }
    func reset() {
        resetHistory()
        echoMix = targetEcho; reverbMix = targetReverb; distortion = targetDistortion; crush = targetCrush
        echoDelay = targetDelay
    }

    func process(_ input: Double) -> Double {
        echoMix += (targetEcho - echoMix) * smoothing; reverbMix += (targetReverb - reverbMix) * smoothing
        distortion += (targetDistortion - distortion) * smoothing; crush += (targetCrush - crush) * smoothing
        var value = input
        if distortion > 0.00001 {
            value += (tanh(value * drive) * normalization - value) * distortion
        }
        if crush > 0.00001 {
            if holdCount <= 0 {
                held = (min(1, max(-1, value)) * steps).rounded() / steps; holdCount = holdLength
            }
            holdCount -= 1; value += (held - value) * crush
        }
        if echoMix > 0.00001 {
            echoDelay += (targetDelay - echoDelay) * smoothing
            let position = Double(echoIndex) - echoDelay + Double(echo.count)
            let first = Int(position) % echo.count, fraction = position - floor(position)
            let a = echoWritten >= Int(ceil(echoDelay)) ? echo[first] : 0
            let b = echoWritten >= Int(floor(echoDelay)) ? echo[(first + 1) % echo.count] : 0
            let delayed = a * (1 - fraction) + b * fraction
            echo[echoIndex] = value + delayed * echoFeedback
            value = value * (1 - echoMix) + delayed * echoMix
        } else { echo[echoIndex] = 0 }
        echoIndex = (echoIndex + 1) % echo.count; echoWritten = min(echo.count, echoWritten + 1)
        if reverbMix > 0.00001 {
            var room = 0.0
            for i in combs.indices {
                let delayed = combs[i].read
                damping[i] = delayed * (1 - roomDamping) + damping[i] * roomDamping
                combs[i].write(value + damping[i] * roomFeedback); room += delayed * 0.25
            }
            for line in diffusers {
                let output = line.read - room * 0.5
                line.write(room + output * 0.5); room = output
            }
            value = value * (1 - reverbMix) + room * reverbMix * 0.5
        } else {
            for line in combs { line.write(0) }; for line in diffusers { line.write(0) }
            for i in damping.indices { damping[i] = 0 }
        }
        return value
    }
}

private final class AudioDelayLine {
    private var samples: [Double]
    private var index = 0, filled = 0
    init(count: Int) { samples = [Double](repeating: 0, count: max(1, count)) }
    var read: Double { filled == samples.count ? samples[index] : 0 }
    func write(_ value: Double) {
        samples[index] = abs(value) < 1e-24 ? 0 : value
        index = (index + 1) % samples.count; filled = min(samples.count, filled + 1)
    }
    func reset() { index = 0; filled = 0 }
}
