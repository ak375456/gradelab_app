#if !targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
import Foundation

/// Encodes original capture samples on the capture queue. A small bounded FIFO
/// absorbs temporary input backpressure (especially the first interleaved
/// audio/video packets) without dropping a frame or abandoning the take.
final class CameraSampleRecorder {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let frameDuration: CMTime
    private let queue: DispatchQueue
    private let onFailure: @Sendable (String) -> Void
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var retryScheduled = false
    private var finalizing = false
    private var finishDeadline: Date?
    private var completion: (@Sendable (String?) -> Void)?
    private var startTime: CMTime?
    private var videoEnd = CMTime.zero
    private(set) var isFinishing = false

    var duration: Double {
        guard let startTime else { return 0 }
        return max(0, CMTimeSubtract(videoEnd, startTime).seconds)
    }

    init(url: URL, videoSettings: [String: Any], videoFormat: CMFormatDescription,
         audioSettings: [String: Any]?, audioFormat: CMFormatDescription?, fps: Int,
         queue: DispatchQueue, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.queue = queue
        self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        frameDuration = CMTime(value: 1, timescale: Int32(fps))
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw Failure.unsupported }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw Failure.unsupported }
        writer.add(video)
        if let audioSettings, let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Failure.unsupported }
            writer.add(input)
            audio = input
        } else { audio = nil }
        guard writer.startWriting() else { throw writer.error ?? Failure.unsupported }
    }

    /// Returns true for the first accepted video sample (the actual take start).
    func append(_ sample: CMSampleBuffer, isVideo: Bool) throws -> Bool {
        guard !isFinishing else { return false }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric, CMSampleBufferDataIsReady(sample) else { return false }
        var started = false
        if startTime == nil {
            guard isVideo else { return false }
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        guard let startTime, CMTimeCompare(time, startTime) >= 0 else { return false }
        guard isVideo || audio != nil else { return false }
        try drain()
        if isVideo {
            guard pendingVideo.count < 12 else { throw Failure.encoderBusy }
            pendingVideo.append(sample)
        } else {
            guard pendingAudio.count < 64 else { throw Failure.encoderBusy }
            pendingAudio.append(sample)
        }
        try drain()
        return started
    }

    func finish(completion: @escaping @Sendable (String?) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        self.completion = completion
        finishDeadline = Date().addingTimeInterval(3)
        guard startTime != nil else {
            writer.cancelWriting()
            complete(String(localized: "The recording stopped before a frame was captured."))
            return
        }
        do { try drain() }
        catch { complete(error.localizedDescription) }
    }

    private func drain() throws {
        guard !finalizing else { return }
        guard writer.status == .writing else { throw writer.error ?? Failure.encoderBusy }
        while let sample = pendingVideo.first, video.isReadyForMoreMediaData {
            guard video.append(sample) else { throw writer.error ?? Failure.encoderBusy }
            videoEnd = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), frameDuration)
            pendingVideo.removeFirst()
        }
        if let audio {
            while let sample = pendingAudio.first, audio.isReadyForMoreMediaData {
                guard audio.append(sample) else { throw writer.error ?? Failure.encoderBusy }
                pendingAudio.removeFirst()
            }
        }
        guard pendingVideo.isEmpty && pendingAudio.isEmpty else {
            if let finishDeadline, Date() > finishDeadline { throw Failure.encoderBusy }
            scheduleRetry()
            return
        }
        if isFinishing { finalize() }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            do { try self.drain() }
            catch {
                if self.isFinishing { self.complete(error.localizedDescription) }
                else { self.onFailure(error.localizedDescription) }
            }
        }
    }

    private func finalize() {
        guard !finalizing else { return }
        finalizing = true
        video.markAsFinished(); audio?.markAsFinished()
        if writer.status == .writing { writer.endSession(atSourceTime: videoEnd) }
        writer.finishWriting { [weak self, writer] in
            self?.queue.async { [weak self] in
                self?.complete(writer.status == .completed ? nil : writer.error?.localizedDescription ?? Failure.encoderBusy.localizedDescription)
            }
        }
        queue.asyncAfter(deadline: .now() + .seconds(15)) { [weak self] in
            self?.complete(String(localized: "Finishing the recording took too long. Captured footage has been kept for recovery."))
        }
    }

    private func complete(_ error: String?) {
        guard let completion else { return }
        self.completion = nil
        finalizing = true
        pendingVideo.removeAll(); pendingAudio.removeAll()
        completion(error)
    }

    private enum Failure: LocalizedError {
        case unsupported, encoderBusy
        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "The video encoder cannot record this camera format.")
            case .encoderBusy: String(localized: "Recording stopped because the encoder could not keep up. Captured footage has been kept.")
            }
        }
    }
}
#endif
