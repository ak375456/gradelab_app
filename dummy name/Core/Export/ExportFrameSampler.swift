@preconcurrency import AVFoundation

/// Raw original mode forwards every timestamp. A composed timeline or explicit
/// FPS samples the latest frame at every output tick, including empty sections.
/// Only two decoded samples are retained, even for multi-hour or high-FPS sources.
final class ExportFrameSampler {
    private let output: AVAssetReaderOutput
    private let range: CMTimeRange
    private let frameDuration: CMTime?
    private var current: CMSampleBuffer?
    private var upcoming: CMSampleBuffer?
    private var started = false
    private var index: Int64 = 0

    init(output: AVAssetReaderOutput, range: CMTimeRange, fps: Double?, frameDuration: CMTime? = nil) {
        self.output = output; self.range = range
        if let fps {
            self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        } else if let frameDuration, frameDuration.isNumeric, frameDuration > .zero {
            self.frameDuration = frameDuration
        } else {
            self.frameDuration = nil
        }
    }

    func next() throws -> (sample: CMSampleBuffer, time: CMTime)? {
        try Task.checkCancellation()
        guard let frameDuration else {
            guard let sample = try read() else { return nil }
            return (sample, CMSampleBufferGetPresentationTimeStamp(sample))
        }
        let time = CMTimeAdd(range.start,
            CMTime(value: index * frameDuration.value, timescale: frameDuration.timescale))
        guard CMTimeCompare(time, CMTimeRangeGetEnd(range)) < 0 else {
            // Drain trailing source samples so reader status reaches completed.
            while try read() != nil { try Task.checkCancellation() }
            current = nil; upcoming = nil
            return nil
        }
        if !started {
            current = try read(); upcoming = try read(); started = true
        }
        while let next = upcoming, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(next), time) <= 0 {
            current = next; upcoming = try read()
        }
        guard let current else { return nil }
        index += 1
        return (current, time)
    }

    private func read() throws -> CMSampleBuffer? {
        try Task.checkCancellation()
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        guard CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else {
            throw GradeLabError.exportFailed(String(localized: "The source contains an invalid frame timestamp."))
        }
        return sample
    }
}
