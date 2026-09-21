@preconcurrency import AVFoundation
import Foundation

/// Small, immutable source envelopes. Trimming/moving only changes the drawing;
/// it never decodes again. Disk cache survives project reopening.
///
/// The envelope is decoded once at a fixed density and never at a zoom: the
/// timeline builds its own mip pyramid over this array (`TimelineWaveform`),
/// so scrolling and zooming never reach the decoder.
actor AudioWaveformStore {
    static let shared = AudioWaveformStore()

    /// Bins per second of source. High enough that a clip stays detailed when
    /// the timeline is zoomed in far enough to trim on a syllable — at 40, the
    /// old density, a bin was six points wide by 260 px/s and the envelope
    /// became a smooth guess between samples.
    static let binsPerSecond = 200.0
    /// Ceiling on one asset's envelope. Long sources fall below the target
    /// density rather than growing without bound: 32k bins is 32KB on disk and
    /// 128KB in memory, and an hour of audio still gets a bin every 110ms.
    static let maximumBins = 32_768

    private var memory: [UUID: [Float]] = [:]
    private let cacheDirectory: URL
    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GradeLab/Waveforms", isDirectory: true)
    }

    func load(_ media: ProjectMediaAsset) async throws -> [Float] {
        if let cached = memory[media.id] { return cached }
        let directory = cacheDirectory
        // v2: raw bytes rather than JSON. At this density a JSON array of
        // floats is an order of magnitude larger than the data in it, and the
        // envelope is quantised anyway. Earlier v1 files are simply never read
        // again and age out with the rest of the caches directory.
        let cache = directory.appendingPathComponent("\(media.id)-v2.bin")
        if let data = try? Data(contentsOf: cache), !data.isEmpty, data.count <= Self.maximumBins {
            let values = data.map { Float($0) / 255 }
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
        guard reader.canAdd(output) else { throw TimelineError.invalid(String(localized: "Waveform unavailable.")) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TimelineError.invalid(String(localized: "Waveform unavailable.")) }
        defer { reader.cancelReading() }
        let duration = media.sourceRange.duration.seconds
        let count = min(Self.maximumBins, max(64, Int(duration * Self.binsPerSecond)))
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
        guard reader.status == .completed else { throw reader.error ?? TimelineError.invalid(String(localized: "Waveform unavailable.")) }
        try Task.checkCancellation()
        // Quantise before returning, not only before writing, so a freshly
        // decoded envelope is bit-identical to the one the cache hands back.
        let bytes = Data(peaks.map { UInt8((min(1, max(0, $0)) * 255).rounded()) })
        let quantised = bytes.map { Float($0) / 255 }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bytes.write(to: cache, options: .atomic)
        remember(quantised, id: media.id)
        return quantised
    }

    private func remember(_ peaks: [Float], id: UUID) {
        if memory.count >= 24, let oldest = memory.keys.first { memory.removeValue(forKey: oldest) }
        memory[id] = peaks
    }
}
