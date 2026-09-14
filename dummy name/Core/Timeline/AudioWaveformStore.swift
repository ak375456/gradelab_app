@preconcurrency import AVFoundation
import Foundation

/// Small, immutable source envelopes. Trimming/moving only changes the drawing;
/// it never decodes again. Disk cache survives project reopening.
actor AudioWaveformStore {
    static let shared = AudioWaveformStore()
    private var memory: [UUID: [Float]] = [:]
    private let cacheDirectory: URL
    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GradeLab/Waveforms", isDirectory: true)
    }
    func load(_ media: ProjectMediaAsset) async throws -> [Float] {
        if let cached = memory[media.id] { return cached }
        let directory = cacheDirectory
        let cache = directory.appendingPathComponent("\(media.id)-v1.json")
        if let data = try? Data(contentsOf: cache), let values = try? JSONDecoder().decode([Float].self, from: data),
           !values.isEmpty, values.count <= 4096, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) {
            remember(values, id: media.id); return values
        }
        let asset = AVURLAsset(url: media.url)
        let embeddedTracks = try await asset.loadTracks(withMediaType: .audio)
        let tracks = try await AudioTrackSelection.enabledTracks(from: embeddedTracks)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 8_000.0
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TimelineError.invalid("Waveform unavailable.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TimelineError.invalid("Waveform unavailable.") }
        defer { reader.cancelReading() }
        let duration = media.sourceRange.duration.seconds
        let count = min(4096, max(64, Int(min(4096, duration * 40))))
        var peaks = [Float](repeating: 0, count: count)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds - media.sourceRange.start.seconds
            pointer.withMemoryRebound(to: Float.self, capacity: length/4) { samples in
                for i in 0..<(length/4) {
                    let time = start + Double(i)/rate
                    guard time >= 0, time < duration else { continue }
                    let bin = min(count-1, Int(time/duration*Double(count)))
                    let value = abs(samples[i])
                    if value.isFinite { peaks[bin] = max(peaks[bin], min(1, value)) }
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? TimelineError.invalid("Waveform unavailable.") }
        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(peaks) { try? data.write(to: cache, options: .atomic) }
        remember(peaks, id: media.id)
        return peaks
    }
    private func remember(_ peaks: [Float], id: UUID) {
        if memory.count >= 24, let oldest = memory.keys.first { memory.removeValue(forKey: oldest) }
        memory[id] = peaks
    }
}
