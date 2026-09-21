import Foundation

actor AudioBeatStore {
    static let shared = AudioBeatStore()
    private var cache: [UUID: [TimelineTime]] = [:]
    func beats(for media: ProjectMediaAsset) async throws -> [TimelineTime] {
        if let value = cache[media.id] { return value }
        // Detection is tuned to roughly forty bins a second. The envelope is
        // decoded much finer than that for the timeline's benefit, so pool it
        // back down here rather than letting sample-level ripple register as
        // beats. Pooling by maximum over the same window is what decoding at
        // the lower density would have produced.
        let peaks = Self.pooled(try await AudioWaveformStore.shared.load(media),
                                seconds: media.sourceRange.duration.seconds)
        guard peaks.count > 4 else { return [] }
        let threshold = max(0.12, (peaks.reduce(0, +) / Float(peaks.count)) * 1.65)
        var result: [TimelineTime] = []
        for i in 1..<(peaks.count-1) where peaks[i] >= threshold && peaks[i] >= peaks[i-1] && peaks[i] >= peaks[i+1] {
            let time = media.sourceRange.start.seconds + Double(i) / Double(peaks.count) * media.sourceRange.duration.seconds
            if result.last.map({ time - $0.seconds < 0.12 }) != true { result.append(try TimelineTime.seconds(time)) }
        }
        cache[media.id] = result
        return result
    }

    /// The detection density this analysis was written against.
    private static let binsPerSecond = 40.0

    /// Max-pools an envelope down to `binsPerSecond`, or returns it unchanged
    /// when it is already at or below that density.
    static func pooled(_ peaks: [Float], seconds: Double) -> [Float] {
        let target = Int(seconds * binsPerSecond)
        guard seconds > 0, target > 4, peaks.count > target else { return peaks }
        let factor = Double(peaks.count) / Double(target)
        var result = [Float](repeating: 0, count: target)
        for bin in 0..<target {
            let lower = Int(Double(bin) * factor)
            let upper = min(peaks.count, max(lower + 1, Int(Double(bin + 1) * factor)))
            var peak: Float = 0
            for index in lower..<upper { peak = max(peak, peaks[index]) }
            result[bin] = peak
        }
        return result
    }
}
