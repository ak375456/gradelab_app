import AudioToolbox
import Foundation
import MediaToolbox
import os

struct AudioLevelReading {
    var peak: Double = 0
    var measuredAt: TimeInterval = 0
    var isSupported = true
    var decibels: Double { peak > 0 ? 20 * log10(peak) : -60 }
}

/// The UI and the audio callback share only this small snapshot. The callback
/// uses try-locks: it never waits for the UI or allocates per audio buffer.
final class AudioTapControl: @unchecked Sendable {
    private struct Snapshot {
        var settings: AudioProcessingSettings
        var level = AudioLevelReading()
    }
    private let storage: OSAllocatedUnfairLock<Snapshot>
    init(settings: AudioProcessingSettings) {
        storage = OSAllocatedUnfairLock(initialState: Snapshot(settings: settings.sanitized))
    }
    func update(_ settings: AudioProcessingSettings) {
        storage.withLock { $0.settings = settings.sanitized }
    }
    func settingsIfAvailable() -> AudioProcessingSettings? {
        storage.withLockIfAvailable { $0.settings }
    }
    func record(peak: Double, supported: Bool) {
        _ = storage.withLockIfAvailable {
            $0.level = AudioLevelReading(peak: peak, measuredAt: Date.timeIntervalSinceReferenceDate, isSupported: supported)
        }
    }
    var level: AudioLevelReading { storage.withLock { $0.level } }
}

enum AudioProcessingTap {
    static func make(control: AudioTapControl) throws -> MTAudioProcessingTap {
        let state = Unmanaged.passRetained(State(control: control))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: nil,
            init: nil, finalize: nil, prepare: nil, unprepare: nil,
            process: { _, _, _, _, frames, _ in frames.pointee = 0 })
        callbacks.version = kMTAudioProcessingTapCallbacksVersion_0
        callbacks.clientInfo = state.toOpaque()
        callbacks.`init` = { _, info, storage in storage.pointee = info }
        callbacks.finalize = { tap in
            Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        }
        callbacks.prepare = { tap, _, format in
            let state = AudioProcessingTap.stateFor(tap)
            state.format = PCMFormat(format.pointee)
            state.dsp.prepare(sampleRate: format.pointee.mSampleRate,
                              channels: Int(format.pointee.mChannelsPerFrame),
                              settings: state.control.settingsIfAvailable() ?? .init())
        }
        callbacks.unprepare = { tap in AudioProcessingTap.stateFor(tap).control.record(peak: 0, supported: true) }
        callbacks.process = { tap, frames, _, buffers, framesOut, flagsOut in
            let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
            guard status == noErr, framesOut.pointee > 0 else {
                framesOut.pointee = 0
                return
            }
            let state = AudioProcessingTap.stateFor(tap)
            if let settings = state.control.settingsIfAvailable(), settings != state.dsp.settings {
                state.dsp.configure(settings)
            }
            if flagsOut.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0 { state.dsp.reset() }
            state.process(buffers, frames: framesOut.pointee)
        }
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            state.release()
            throw NSError(domain: "GradeLab.AudioProcessing", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not prepare the audio effects. Try reopening the project.")])
        }
        return tap
    }

    private static func stateFor(_ tap: MTAudioProcessingTap) -> State {
        Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    private final class State {
        let control: AudioTapControl
        let dsp = AudioDSP()
        var format: PCMFormat?
        init(control: AudioTapControl) { self.control = control }

        func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            guard let format else { control.record(peak: 0, supported: false); return }
            // AudioToolbox's Swift buffer-list overlay is absent in some
            // Catalyst SDKs. Walk the C flexible array using its actual offset.
            let first = UnsafeMutableRawPointer(list)
                .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
                .assumingMemoryBound(to: AudioBuffer.self)
            let buffers = UnsafeMutableBufferPointer(start: first, count: Int(list.pointee.mNumberBuffers))
            var peak = 0.0
            for frame in 0..<frames {
                var inputPeak = 0.0
                if dsp.settings.compressor?.isEnabled == true {
                    for buffer in buffers {
                        let channels = Int(buffer.mNumberChannels), stride = format.bytes * Int(buffer.mNumberChannels)
                        guard let data = buffer.mData, (frame + 1) * stride <= Int(buffer.mDataByteSize) else { continue }
                        for channel in 0..<channels {
                            inputPeak = max(inputPeak, abs(format.read(data.advanced(by: frame * stride + channel * format.bytes))))
                        }
                    }
                }
                dsp.beginFrame(inputPeak: inputPeak)
                var channelOffset = 0
                for buffer in buffers {
                    let channels = Int(buffer.mNumberChannels)
                    guard let data = buffer.mData else { channelOffset += channels; continue }
                    let stride = format.bytes * channels
                    guard (frame + 1) * stride <= Int(buffer.mDataByteSize) else { channelOffset += channels; continue }
                    for channel in 0..<channels {
                        let pointer = data.advanced(by: frame * stride + channel * format.bytes)
                        let input = format.read(pointer)
                        let value = dsp.process(input, channel: channelOffset + channel)
                        format.write(value, to: pointer)
                        peak = max(peak, abs(value))
                    }
                    channelOffset += channels
                }
            }
            control.record(peak: peak, supported: true)
        }
    }
}

/// Decoders normally supply float PCM to taps. Also handle native signed PCM
/// (including packed 24-bit), both byte orders and both buffer layouts.
private struct PCMFormat {
    let bytes: Int
    let bits: Int
    let isFloat: Bool
    let bigEndian: Bool
    let highAligned: Bool
    let signed: Bool

    init?(_ stream: AudioStreamBasicDescription) {
        let channelsPerBuffer = stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : Int(stream.mChannelsPerFrame)
        guard stream.mFormatID == kAudioFormatLinearPCM, channelsPerBuffer > 0 else { return nil }
        bytes = Int(stream.mBytesPerFrame) / channelsPerBuffer
        bits = Int(stream.mBitsPerChannel)
        isFloat = stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
        bigEndian = stream.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        highAligned = stream.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        signed = stream.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        guard isFloat ? ((bits == 32 || bits == 64) && bytes == bits / 8)
                : ((1...4).contains(bytes) && (1...bytes * 8).contains(bits)) else { return nil }
    }

    func read(_ data: UnsafeMutableRawPointer) -> Double {
        var raw: UInt64 = 0
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        for byte in 0..<bytes {
            let shift = (bigEndian ? bytes - 1 - byte : byte) * 8
            raw |= UInt64(pointer[byte]) << shift
        }
        if isFloat { return bits == 32 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw) }
        if highAligned { raw >>= bytes * 8 - bits }
        let scale = Double(UInt64(1) << (bits - 1))
        if signed {
            let shift = 64 - bits
            return Double(Int64(bitPattern: raw << shift) >> shift) / scale
        }
        return (Double(raw) - scale) / scale
    }

    func write(_ value: Double, to data: UnsafeMutableRawPointer) {
        let value = value.isFinite ? value : 0
        var raw: UInt64
        if isFloat {
            raw = bits == 32 ? UInt64(Float(value).bitPattern) : value.bitPattern
        } else {
            let scale = Double(UInt64(1) << (bits - 1))
            let integer = Int64((min(1 - 1 / scale, max(-1, value)) * scale).rounded())
            raw = signed ? UInt64(bitPattern: integer) : UInt64(integer + Int64(scale))
            if highAligned { raw <<= bytes * 8 - bits }
        }
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        for byte in 0..<bytes {
            let shift = (bigEndian ? bytes - 1 - byte : byte) * 8
            pointer[byte] = UInt8(truncatingIfNeeded: raw >> shift)
        }
    }
}
