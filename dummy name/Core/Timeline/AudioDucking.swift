@preconcurrency import AVFoundation
import Foundation

struct AudioActivityEnvelope: Sendable {
    var start: Double
    var step: Double
    var peaks: [Float]

    /// Scheduled composition tracks already reflect trims, source-track
    /// selection and retiming. Decode only selected voice clips, off the UI thread.
    static func analyze(asset: AVAsset, tracks: [AVAssetTrack], start: Double, duration: Double) async throws -> Self {
        guard duration > 0, !tracks.isEmpty else { return .init(start: start, step: 0.025, peaks: []) }
        let count = min(65_536, max(1, Int(ceil(duration * 40))))
        let step = duration / Double(count)
        var peaks = [Float](repeating: 0, count: count)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 60_000))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TimelineError.invalid("Could not analyze the ducking source.") }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(sample) {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            var samples = [Float](repeating: 0, count: frames)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: frames * 4, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            let offset = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
            for i in 0..<frames {
                let index = Int(floor((offset + Double(i) / 8_000) / step))
                if peaks.indices.contains(index), samples[i].isFinite { peaks[index] = max(peaks[index], abs(samples[i])) }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? TimelineError.invalid("Could not analyze the ducking source.") }
        return .init(start: start, step: step, peaks: peaks)
    }

    func intervals(threshold: Double, level: (Double) -> Double) -> [AudioActivityInterval] {
        let minimum = pow(10, threshold / 20)
        var result: [AudioActivityInterval] = []
        for i in peaks.indices where Double(peaks[i]) * level(start + Double(i) * step) >= minimum {
            let time = start + Double(i) * step
            if let last = result.last, time - last.end <= 0.12 {
                result[result.count - 1].end = time + step
            } else { result.append(.init(start: time, end: time + step)) }
        }
        return result
    }
}

struct AudioActivityInterval: Equatable, Sendable {
    var start: Double
    var end: Double
}

struct AudioDuckingEnvelope {
    var intervals: [AudioActivityInterval] = []
    var settings: AudioDuckingSettings
    var boundaries: [Double] {
        intervals.flatMap { [$0.start - settings.attack, $0.start, $0.end, $0.end + settings.release] }
    }
    func gain(at time: Double) -> Double {
        guard settings.isEnabled else { return 1 }
        let low = pow(10, -settings.reduction / 20)
        var gain = 1.0
        var lower = 0, upper = intervals.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if intervals[middle].start <= time { lower = middle + 1 } else { upper = middle }
        }
        // For disjoint activity intervals only the immediately preceding and
        // following interval can produce the strongest attenuation.
        for index in [lower - 1, lower] where intervals.indices.contains(index) {
            let interval = intervals[index]
            guard time >= interval.start - settings.attack && time <= interval.end + settings.release else { continue }
            let candidate: Double
            if time < interval.start {
                candidate = 1 - (1 - low) * (time - interval.start + settings.attack) / settings.attack
            } else if time > interval.end {
                candidate = low + (1 - low) * (time - interval.end) / settings.release
            } else { candidate = low }
            gain = min(gain, candidate)
        }
        return gain
    }
}
