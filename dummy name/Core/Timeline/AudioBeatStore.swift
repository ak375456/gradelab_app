import Foundation

actor AudioBeatStore {
    static let shared = AudioBeatStore()
    private var cache: [UUID: [TimelineTime]] = [:]
    func beats(for media: ProjectMediaAsset) async throws -> [TimelineTime] {
        if let value = cache[media.id] { return value }
        let peaks = try await AudioWaveformStore.shared.load(media)
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
}
