@preconcurrency import AVFoundation

/// Original mode forwards every timestamp. Explicit FPS mode samples the latest
/// source frame at each output tick, holding/dropping frames without changing speed.
/// Only two decoded samples are retained, even for multi-hour or high-FPS sources.
final class ExportFrameSampler {
    private let output: AVAssetReaderOutput
    private let range: CMTimeRange
    private let fps: Double?
    private var current: CMSampleBuffer?
    private var upcoming: CMSampleBuffer?
    private var started = false
    private var index: Int64 = 0

    init(output: AVAssetReaderOutput, range: CMTimeRange, fps: Double?) {
        self.output = output; self.range = range; self.fps = fps
    }

    func next() throws -> (sample: CMSampleBuffer, time: CMTime)? {
        try Task.checkCancellation()
        guard let fps else {
            guard let sample = try read() else { return nil }
            return (sample, CMSampleBufferGetPresentationTimeStamp(sample))
        }
        let time = CMTimeAdd(range.start, CMTime(value: index, timescale: CMTimeScale(fps)))
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
            throw GradeLabError.exportFailed("The source contains an invalid frame timestamp.")
        }
        return sample
    }
}
