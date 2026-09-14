@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation

/// What `MetalVideoRenderer` needs from whatever is producing pictures.
///
/// It is deliberately three members wide. The renderer holds the decoded frame,
/// the grade uniforms, the look and the curve tables, and it is the one place
/// the grading maths is dispatched from — so anything that can hand it a
/// `CVPixelBuffer` gets the whole pipeline: grading, the spatial finishing
/// effects, the scopes, the eyedropper and the before/after compare, with no
/// second copy of any of it.
///
/// Video supplies frames from `AVPlayerItemVideoOutput`; a still image supplies
/// one buffer that never changes. Neither knows about the other.
protocol PreviewFrameSource: AnyObject, Sendable {
    /// The frame currently on screen, for work that would otherwise decode the
    /// same picture a second time.
    var latestFrame: CVPixelBuffer? { get }

    /// The time the current frame represents. Drives the grain seed, so a still
    /// reports a fixed time and its grain does not crawl.
    var presentationTime: CMTime { get }

    func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer?
}

extension VideoFrameProvider: PreviewFrameSource {}

/// The frame source for a still-image project: one decoded picture, held for as
/// long as the editor is open.
///
/// `presentationTime` is always zero. That is not a placeholder — it is what
/// keeps the grain still. The grain seed is derived from the presentation time,
/// so a moving one would make the pattern crawl under a photograph that is not
/// moving, and the exported file would carry a pattern from whichever instant
/// the export happened to start. A fixed time gives the same grain in the
/// preview, in a preset thumbnail and in the exported file.
final class StillFrameProvider: PreviewFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    init(pixelBuffer: CVPixelBuffer? = nil) {
        buffer = pixelBuffer
    }

    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return buffer
    }

    var presentationTime: CMTime { .zero }

    func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }; return buffer
    }

    /// Replaces the decoded picture — used when a higher-resolution preview
    /// finishes decoding behind the first one.
    func replace(_ pixelBuffer: CVPixelBuffer?) {
        lock.lock(); buffer = pixelBuffer; lock.unlock()
    }
}
