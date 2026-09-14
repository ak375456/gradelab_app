@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Pulls decoded frames against the same host-time clock AVPlayer uses for audio.
/// Only the latest frame is retained, allowing paused grades and before/after to redraw instantly.
final class VideoFrameProvider: NSObject, AVPlayerItemOutputPullDelegate, @unchecked Sendable {
    private let output: AVPlayerItemVideoOutput
    private let delegateQueue = DispatchQueue(label: "com.lexur.GradeLab.video-output")
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var latestTime: CMTime = .zero
    var presentationTime: CMTime {
        lock.lock(); defer { lock.unlock() }; return latestTime
    }
    /// The frame currently on screen, for work that would otherwise decode the
    /// same picture a second time.
    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return latestBuffer
    }
    private var mediaDataCallback: (@Sendable () -> Void)?

    init(output: AVPlayerItemVideoOutput) {
        self.output = output
        super.init()
        output.setDelegate(self, queue: delegateQueue)
    }

    deinit {
        output.setDelegate(nil, queue: nil)
    }

    func setMediaDataCallback(_ callback: (@Sendable () -> Void)?) {
        lock.lock()
        mediaDataCallback = callback
        lock.unlock()
    }

    func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        var displayTime = CMTime.invalid
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let newBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
            lock.lock()
            latestBuffer = newBuffer
            latestTime = displayTime.isNumeric ? displayTime : itemTime
            let buffer = latestBuffer
            lock.unlock()
            return buffer
        }

        lock.lock()
        let buffer = latestBuffer
        lock.unlock()
        return buffer
    }

    func clear() {
        // Keep the displayed frame usable for grading until the decoder replaces it.
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
    }

    func reset() {
        lock.lock(); latestBuffer = nil; latestTime = .zero; lock.unlock()
        clear()
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        lock.lock()
        let callback = mediaDataCallback
        lock.unlock()
        callback?()
    }

    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        lock.lock()
        let callback = mediaDataCallback
        lock.unlock()
        callback?()
    }
}
