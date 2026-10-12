@preconcurrency import AVFoundation
import Foundation

/// Exercises the shipping tap through AVAssetReaderAudioMixOutput, the same
/// audio path used by the production timeline exporter. No microphone needed.
@main struct ValidateAudioProcessing {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gradelab-audio-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for channels in [1, 2] {
            let url = folder.appendingPathComponent("\(channels)-channel.caf")
            try writeTone(url, frequency: 1_000, channels: channels)
            let reference = try await read(url)
            let neutral = try await read(url, settings: .init())
            require(zip(reference, neutral).allSatisfy { abs($0 - $1) < 1e-6 }, "neutral tap preserves \(channels)-channel PCM")
            let panned = try await read(url, settings: .init(pan: 1))
            let l = rms(panned, channel: 0), r = rms(panned, channel: 1)
            require(l < r * 0.0001 && r > 0.01, "right pan works for \(channels)-channel source (L \(l), R \(r))")
            let muted = try await read(url, settings: .init(), volume: 0)
            require(rms(muted) < 1e-7, "mute remains silent through tap")
            let faded = try await read(url, settings: .init(), fade: true)
            require(rms(Array(faded.prefix(4_800))) < rms(Array(faded.suffix(4_800))) * 0.2, "volume ramps survive processing")
        }
        for (frequency, settings, minimum, maximum) in [
            (80.0, AudioProcessingSettings(bass: 6), 1.8, 2.2),
            (1_000.0, AudioProcessingSettings(mid: 6), 1.8, 2.2),
            (8_000.0, AudioProcessingSettings(treble: 6), 1.8, 2.2),
            (80.0, AudioProcessingSettings(lowCut: 300), 0.0, 0.12),
            (8_000.0, AudioProcessingSettings(highCut: 1_200), 0.0, 0.1)
        ] {
            let url = folder.appendingPathComponent("tone.caf")
            try writeTone(url, frequency: frequency, channels: 2)
            let plain = try await read(url)
            let processed = try await read(url, settings: settings)
            let ratio = rms(processed) / rms(plain)
            require(ratio > minimum && ratio < maximum, "EQ response at \(Int(frequency)) Hz: ratio \(ratio)")
            var bypass = settings; bypass.isToneEnabled = false
            let bypassed = try await read(url, settings: bypass)
            require(zip(plain, bypassed).allSatisfy { abs($0 - $1) < 1e-6 }, "bypass restores original PCM")
        }
        let effectsURL = folder.appendingPathComponent("effects.caf")
        try writeTone(effectsURL, frequency: 1_000, channels: 2)
        let dry = try await read(effectsURL)
        let compressed = try await read(effectsURL, settings: .init(compressor: .init(threshold: -30, ratio: 4, attack: 5)))
        let compression = rms(compressed) / rms(dry)
        require(compression > 0.15 && compression < 0.45, "compressor attenuates loud input through the native tap: \(compression)")
        let creative = AudioProcessingSettings(echo: .init(mix: 0.3, time: 0.083, feedback: 0.4),
            reverb: .init(mix: 0.25), texture: .init(distortion: 0.15, crush: 0.3))
        let wet = try await read(effectsURL, settings: creative)
        require(wet.count == dry.count && wet.allSatisfy(\.isFinite), "creative effects preserve sample count and remain finite")
        require(zip(wet, dry).contains { abs($0 - $1) > 0.01 }, "creative effects change rendered PCM")
        var bypass = creative
        bypass.echo?.isEnabled = false; bypass.reverb?.isEnabled = false; bypass.texture?.isEnabled = false
        let bypassed = try await read(effectsURL, settings: bypass)
        require(zip(bypassed, dry).allSatisfy { abs($0 - $1) < 1e-6 }, "creative bypass restores original PCM")
        let benchmark = AudioDSP()
        benchmark.prepare(sampleRate: 48_000, channels: 2,
            settings: .init(mid: 3, compressor: .init(), echo: .init(), reverb: .init(), texture: .init(distortion: 0.2, crush: 0.2)))
        let started = Date()
        var checksum = 0.0
        for frame in 0..<48_000 {
            let input = 0.2 * sin(Double(frame) * 0.1)
            benchmark.beginFrame(inputPeak: abs(input))
            checksum += benchmark.process(input, channel: 0) + benchmark.process(input, channel: 1)
        }
        require(checksum.isFinite, "all-effects benchmark output is finite")
        print("INFO one second of stereo DSP, all effects: \(String(format: "%.3f", Date().timeIntervalSince(started))) s on this Mac (optimized build)")
        // State reset makes seeking/replaying deterministic; all presets stay
        // finite at low and high sample rates, including below their cutoffs.
        for rate in [8_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for preset in AudioVoicePreset.allCases {
                let dsp = AudioDSP()
                dsp.prepare(sampleRate: rate, channels: 2, settings: preset.settings)
                var first: [Double] = []
                for frame in 0..<4_096 {
                    dsp.beginFrame()
                    let value = dsp.process(frame == 0 ? 0.2 : 0, channel: 0)
                    require(value.isFinite && abs(value) < 2, "stable \(preset.rawValue) at \(rate)", printPass: false)
                    first.append(value)
                }
                dsp.reset()
                for frame in 0..<4_096 {
                    dsp.beginFrame()
                    require(dsp.process(frame == 0 ? 0.2 : 0, channel: 0) == first[frame], "deterministic seek reset", printPass: false)
                }
            }
        }
        print("PASS all presets stable at 8/44.1/48/96 kHz; seek reset is deterministic")
        print("PASS audio processing validation")
    }

    static func require(_ condition: Bool, _ message: String, printPass: Bool = true) {
        if !condition { print("FAIL \(message)"); fatalError(message) }
        if printPass { print("PASS \(message)") }
    }

    static func writeTone(_ url: URL, frequency: Double, channels: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<channels {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float(0.15 * sin(2 * .pi * frequency * Double(frame) / 48_000))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func read(_ url: URL, settings: AudioProcessingSettings? = nil, volume: Float = 1, fade: Bool = false) async throws -> [Float] {
        var asset = AVURLAsset(url: url)
        var track = try await asset.loadTracks(withMediaType: .audio)[0]
        let descriptions = try await track.load(.formatDescriptions)
        if CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0])!.pointee.mChannelsPerFrame == 1 {
            asset = try await AudioStereoSource.asset(for: track, sourceURL: url, sampleRate: 48_000)
            track = try await asset.loadTracks(withMediaType: .audio)[0]
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(volume, at: .zero)
        if fade { parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48_000))) }
        if let settings {
            parameters.audioTapProcessor = try AudioProcessingTap.make(control: AudioTapControl(settings: settings))
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; output.audioMix = mix
        reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { fatalError("Missing PCM buffer") }
            let count = CMSampleBufferGetNumSamples(sample) * 2
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: $0.baseAddress!)
            }
            require(status == noErr, "read PCM", printPass: false)
            result.append(contentsOf: values)
        }
        guard reader.status == .completed else { throw reader.error! }
        require(result.count >= 90_000, "audio duration preserved", printPass: false)
        return result
    }

    static func rms(_ values: [Float], channel: Int? = nil) -> Double {
        let start = min(9_600, values.count / 4)
        var sum = 0.0, count = 0.0
        for index in start..<values.count where channel == nil || index % 2 == channel {
            sum += Double(values[index]) * Double(values[index]); count += 1
        }
        return sqrt(sum / max(1, count))
    }
}
