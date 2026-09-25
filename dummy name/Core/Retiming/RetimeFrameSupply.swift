@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CoreMedia
import Foundation

/// Source frames by source time, in any order, including backwards.
///
/// ## Why this has to exist
///
/// Everything else about retiming is expressed to AVFoundation as an edit list:
/// a run of source, scaled to a run of timeline. A ramp is a staircase of those,
/// a freeze is one frame taking a second, and both are ordinary scales. **A
/// reverse is not.** `scaleTimeRange` maps a range onto a range at a constant
/// positive rate; there is no way to write down a negative one. Inserting the
/// clip frame by frame in reverse order would express it, and would make the
/// decoder seek to a sync sample for every single frame.
///
/// So for a reversed clip the picture stops coming from the composition and
/// comes from here instead. The composition still carries the clip — it is what
/// schedules the instructions, sets the duration and keeps the audio and the
/// rest of the timeline in step — but the frame it hands the compositor is
/// discarded and this one is used.
///
/// ## How reading backwards is made smooth
///
/// A decoder only goes forwards, so backwards means decoding a window forwards
/// and serving it in reverse. Three things make that watchable rather than
/// merely correct, and the first version of this had none of them:
///
///  - **Windows sit on a fixed grid.** A window starting wherever the request
///    happened to land means a scrub two frames away decodes a fresh window
///    overlapping the one already in hand. On a grid the same window is asked
///    for again and is already there.
///  - **The next window is decoded before it is needed.** A reversed clip walks
///    steadily one way, so the direction is known; when the runway left in the
///    current window runs short, the one beyond it is filled in the background.
///    Without this every window boundary is a reader built, a seek and a run
///    from the preceding sync sample, all while the frame it is holding up is
///    due on screen now. That is what a stuttering reverse actually is.
///  - **A window is only served when it genuinely covers the request.** See
///    `lookup`.
///
/// ## Why the blocking path is still synchronous
///
/// A late frame and a wrong frame are not the same kind of failure. For
/// blending or flow, falling back costs sharpness; for reverse, falling back to
/// the frame AVFoundation delivered would play the shot *forwards*. So when the
/// prefetch has not got there first, this blocks. That queue already waits on
/// the GPU for every grade, so waiting is the house style rather than an
/// exception — and export, where it matters most, is not realtime anyway.
final class RetimeFrameSupply {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let range: CMTimeRange
    private let frameDuration: CMTime
    private let outputSettings: [String: Any]

    private struct Frame {
        let time: CMTime
        let buffer: CVPixelBuffer
    }

    /// Which window a decode is filling.
    private enum Target { case current, next }

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// A SECOND reader, for the window being read ahead.
    ///
    /// Not an optimisation — a correctness requirement. With one reader shared
    /// between the two, arming the read-ahead cancelled the reader the playing
    /// window was still reading from, so the next frame could not simply be
    /// read on for and rebuilt the reader instead. Measured: sixty forward
    /// frames took twenty readers with one shared, and two with a reader each.
    private var aheadReader: AVAssetReader?
    private var aheadOutput: AVAssetReaderTrackOutput?
    private var aheadStart: CMTime = .invalid
    /// The window being played, oldest frame first.
    private var ring: [Frame] = []
    /// The window beyond it, decoded ahead of being needed.
    private var nextRing: [Frame] = []
    private var nextWindowStart: CMTime = .invalid
    private var prefetching = false
    private var readerStart: CMTime = .invalid
    /// The window start a decode last came back from with nothing at all. Stops
    /// a request past the end of the media from rebuilding a reader on every
    /// frame.
    private var exhaustedFrom: CMTime = .invalid
    /// The previous request, so the direction of travel is known.
    private var lastRequest: CMTime = .invalid

    /// Serialises every decode. The blocking path enters it synchronously; the
    /// prefetch enters it asynchronously. One queue means the two can never be
    /// inside the reader at the same time.
    private let queue = DispatchQueue(label: "com.lexur.GradeLab.retime-frames", qos: .userInitiated)
    private let lock = NSLock()

    /// Frames held per window.
    ///
    /// Bounded by memory rather than by a frame count, because the same number
    /// is fifty megabytes at 1080p and two hundred at 4K — and being killed by
    /// jetsam is not a smoother reverse. Two windows can be live at once, so the
    /// budget here is half of what the object may hold.
    ///
    /// Eight at the floor: below that the windows are so short that the seek at
    /// every boundary costs more than the frames it yields, and no amount of
    /// reading ahead hides it.
    private let capacity: Int

    /// How many readers this supply has started.
    ///
    /// Exposed for the tests, and it earns the line for the same reason the
    /// denoiser's does: starting a reader means seeking and decoding from the
    /// preceding sync sample, and the difference between "one reader per second
    /// of playback" and "one per frame" is invisible in a picture and
    /// unmissable in a number.
    private(set) var readerStarts = 0

    /// The identity of a supply, so one is built per clip source rather than
    /// per frame.
    struct Key: Hashable {
        let assetID: UUID
        let start: CMTime
        let duration: CMTime
        let format: OSType
        let width: Int
        let height: Int
    }

    init?(url: URL, range: CMTimeRange, frameDuration: CMTime,
          pixelFormat: OSType, width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        self.asset = asset
        self.track = track
        self.range = range
        self.frameDuration = frameDuration.isNumeric && frameDuration > .zero
            ? frameDuration
            : CMTime(value: 1, timescale: 30)
        self.outputSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let bytes = max(1, width * height * 3 / 2)
        self.capacity = max(8, min(24, 64_000_000 / bytes))
    }

    // MARK: - Asking for frames

    /// The frames either side of a source time, and how far between them it sits.
    ///
    /// Always returned in **source order**, whichever direction the clip is
    /// playing. Interpolation between two pictures has no direction — the frame
    /// a third of the way from A to B is the same frame however you arrived at
    /// it — so reversing the pair here would only mean the phase had to be
    /// reversed somewhere else to cancel it out.
    ///
    /// - Parameter needsPartner: false when the clip is sampling rather than
    ///   blending or interpolating. The partner sits one frame *ahead* of the
    ///   playhead, which on a reversed clip is the direction already travelled,
    ///   so asking for it when nothing will use it drags the window back and
    ///   forth across its own edge.
    func pair(at sourceTime: CMTime, needsPartner: Bool)
        -> (first: CVPixelBuffer, second: CVPixelBuffer?, phase: Double)? {
        guard let first = frame(at: sourceTime) else { return nil }
        guard needsPartner else { return (first, nil, 0) }
        let elapsed = CMTimeSubtract(sourceTime, range.start).seconds
        let step = frameDuration.seconds
        guard step > 0, elapsed.isFinite else { return (first, nil, 0) }
        let position = elapsed / step
        let phase = min(max(position - position.rounded(.down), 0), 1)
        let next = CMTimeAdd(range.start, CMTimeMultiplyByFloat64(
            frameDuration, multiplier: position.rounded(.down) + 1))
        guard CMTimeCompare(next, CMTimeRangeGetEnd(range)) < 0 else { return (first, nil, 0) }
        return (first, frame(at: next), phase)
    }

    /// The decoded frame covering a source time.
    func frame(at sourceTime: CMTime) -> CVPixelBuffer? {
        let wanted = CMTimeMaximum(range.start,
                                   CMTimeMinimum(sourceTime, CMTimeRangeGetEnd(range)))
        if let hit = served(wanted) {
            readAheadIfRunningOut(after: wanted)
            return hit
        }
        var result: CVPixelBuffer?
        queue.sync { result = fill(to: wanted) }
        readAheadIfRunningOut(after: wanted)
        return result
    }

    // MARK: - Serving

    /// Serves from whichever window covers the time, promoting the one read
    /// ahead when the playhead has walked into it.
    private func served(_ time: CMTime) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        if let hit = Self.lookup(time, in: ring, rangeStart: range.start, step: frameDuration) {
            return hit
        }
        if let hit = Self.lookup(time, in: nextRing, rangeStart: range.start, step: frameDuration) {
            // Promoting rather than copying: the frames it holds are then not
            // decoded a second time on the way through. The reader moves with
            // them, so reading on past the end of the promoted window continues
            // from where it had got to rather than seeking back to its start.
            ring = nextRing
            nextRing = []
            reader?.cancelReading()
            reader = aheadReader
            output = aheadOutput
            readerStart = aheadStart
            aheadReader = nil
            aheadOutput = nil
            aheadStart = .invalid
            nextWindowStart = .invalid
            return hit
        }
        return nil
    }

    /// The frame covering `time`, but only when this window genuinely covers it.
    ///
    /// The frame covering a moment is the last one that began no later than it —
    /// a presentation timestamp is when a frame *starts* being shown, so taking
    /// the nearest would show the next frame for the second half of every
    /// frame's life.
    ///
    /// The coverage test is the part that matters. Answering with the newest
    /// frame at or before the request when there is nothing after it silently
    /// answers "what is at nine seconds" with a frame from four, which is
    /// exactly what a request past the end of a window looks like. Scrubbing
    /// back through a reversed clip froze the picture for that reason.
    private static func lookup(_ time: CMTime, in window: [Frame],
                               rangeStart: CMTime, step: CMTime) -> CVPixelBuffer? {
        guard let earliest = window.first, let latest = window.last else { return nil }
        // Before this window begins. Only answerable when the window starts at
        // the source range's own beginning, where there is nothing earlier.
        if CMTimeCompare(time, earliest.time) < 0 {
            let atStart = CMTimeCompare(earliest.time, CMTimeAdd(rangeStart, step)) <= 0
            return atStart ? earliest.buffer : nil
        }
        // Past where this window reaches. There is no answer here, and the
        // caller has to decode rather than be handed a stale picture.
        guard CMTimeCompare(time, latest.time) <= 0 else { return nil }
        var best: CVPixelBuffer?
        for frame in window {
            if CMTimeCompare(frame.time, time) <= 0 { best = frame.buffer } else { break }
        }
        return best
    }

    // MARK: - Decoding

    /// Fills the window holding `time`. Runs on `queue`.
    private func fill(to time: CMTime) -> CVPixelBuffer? {
        // Another caller may have filled this window while this one waited for
        // the queue, which on a busy compositor is common rather than rare.
        if let hit = served(time) { return hit }

        lock.lock()
        let start = windowStart(for: time)
        let alreadyEmpty = CMTimeCompare(exhaustedFrom, start) == 0
        let fallback = ring.last?.buffer
        // Walking FORWARDS lands here on most frames — the window covers what
        // has been read so far and not yet what is being asked for — and the
        // reader is already sitting exactly where the next frame is. Rebuilding
        // it would seek back to this window's own start and decode everything
        // again, which is what turned sixty forward frames into twenty-two
        // readers. Reading on is the whole of the fix.
        let canReadOn = reader?.status == .reading
            && CMTimeCompare(readerStart, start) == 0
            && !ring.isEmpty
            && CMTimeCompare(time, ring[ring.count - 1].time) > 0
        lock.unlock()
        if alreadyEmpty { return fallback }
        if !canReadOn {
            guard restart(at: start) else { return fallback }
        }

        while true {
            guard let sample = output?.copyNextSampleBuffer() else {
                lock.lock()
                if ring.isEmpty { exhaustedFrom = readerStart }
                lock.unlock()
                break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard sampleTime.isNumeric else { continue }
            lock.lock()
            ring.append(Frame(time: sampleTime, buffer: buffer))
            while ring.count > capacity { ring.removeFirst() }
            lock.unlock()
            if CMTimeCompare(sampleTime, time) > 0 { break }
        }
        return served(time) ?? fallback
    }

    /// Where the window holding `time` begins, on a fixed grid.
    private func windowStart(for time: CMTime) -> CMTime {
        let frames = max(1.0, Double(capacity) - 2)
        let step = frameDuration.seconds * frames
        guard step > 0 else { return range.start }
        let elapsed = CMTimeSubtract(time, range.start).seconds
        guard elapsed.isFinite, elapsed > 0 else { return range.start }
        let index = (elapsed / step).rounded(.down)
        return CMTimeAdd(range.start,
                         CMTimeMultiplyByFloat64(frameDuration, multiplier: index * frames))
    }

    // MARK: - Reading ahead

    /// Decodes the next window in the direction of travel, before it is wanted.
    private func readAheadIfRunningOut(after time: CMTime) {
        lock.lock()
        let previous = lastRequest
        lastRequest = time
        let backwards = previous.isNumeric && CMTimeCompare(time, previous) < 0
        let edge = backwards ? ring.first?.time : ring.last?.time
        let runway = edge.map { abs(CMTimeSubtract(time, $0).seconds) } ?? .infinity
        // Only once the runway is nearly used up. Reading ahead on every frame
        // would keep the decoder permanently busy re-reading a window that has
        // barely been touched.
        let idle = !prefetching && nextRing.isEmpty && !ring.isEmpty
        guard idle, runway <= frameDuration.seconds * 3 else { lock.unlock(); return }
        prefetching = true
        lock.unlock()

        let frames = max(1.0, Double(capacity) - 2)
        let step = CMTimeMultiplyByFloat64(frameDuration, multiplier: frames)
        let target = backwards ? CMTimeSubtract(time, step) : CMTimeAdd(time, step)
        let clamped = CMTimeMaximum(range.start, CMTimeMinimum(target, CMTimeRangeGetEnd(range)))
        queue.async { [weak self] in
            self?.readAhead(covering: clamped)
            guard let self else { return }
            self.lock.lock(); self.prefetching = false; self.lock.unlock()
        }
    }

    /// Decodes a window into `nextRing`, leaving the one being played untouched.
    private func readAhead(covering time: CMTime) {
        let start = windowStart(for: time)
        lock.lock()
        let covered = Self.lookup(time, in: ring, rangeStart: range.start, step: frameDuration) != nil
            || CMTimeCompare(nextWindowStart, start) == 0
            || CMTimeCompare(exhaustedFrom, start) == 0
        lock.unlock()
        guard !covered, restart(at: start, into: .next) else { return }
        let reading = { [weak self] in self?.aheadOutput?.copyNextSampleBuffer() }
        // Fill the WHOLE window, not just as far as the frame that prompted
        // this. A window read only up to its target holds two or three frames,
        // is exhausted immediately, and the boundary it was meant to hide
        // arrives anyway a moment later.
        let frames = max(1.0, Double(capacity) - 2)
        let windowEnd = CMTimeAdd(start, CMTimeMultiplyByFloat64(frameDuration, multiplier: frames))
        while true {
            guard let sample = reading() else { return }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard sampleTime.isNumeric else { continue }
            lock.lock()
            nextRing.append(Frame(time: sampleTime, buffer: buffer))
            let full = nextRing.count >= capacity
            while nextRing.count > capacity { nextRing.removeFirst() }
            lock.unlock()
            if full || CMTimeCompare(sampleTime, windowEnd) >= 0 { return }
        }
    }

    // MARK: - The reader

    @discardableResult
    private func restart(at start: CMTime, into target: Target = .current) -> Bool {
        lock.lock()
        switch target {
        case .current:
            ring.removeAll()
            // The window being played has been thrown away, so anything read
            // ahead of it describes a place the playhead is no longer walking
            // towards.
            nextRing.removeAll()
            nextWindowStart = .invalid
            aheadReader?.cancelReading()
            aheadReader = nil; aheadOutput = nil; aheadStart = .invalid
        case .next:
            nextRing.removeAll()
            nextWindowStart = start
        }
        lock.unlock()
        if target == .current { self.reader?.cancelReading() } else { aheadReader?.cancelReading() }

        guard let reader = try? AVAssetReader(asset: asset) else {
            if target == .current { self.reader = nil; output = nil }
            else { aheadReader = nil; aheadOutput = nil }
            return false
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        // Copies, deliberately, where the rest of the app takes the decoder's
        // own buffers.
        //
        // Everywhere else a decoded frame is used and released within the
        // frame, so borrowing it is free. This holds a ring of them — that is
        // the entire point — and a ring of borrowed buffers starves the
        // decoder's pool, at which point `copyNextSampleBuffer` blocks waiting
        // for one of the buffers THIS object is holding to come back. Measured
        // before the copy was turned on: a sixty-frame backwards walk took over
        // a minute, almost all of it waiting. It is about a millisecond a frame
        // with it on.
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: start, end: CMTimeRangeGetEnd(range))
        guard reader.startReading() else { return false }
        if target == .current {
            self.reader = reader
            self.output = output
            readerStart = start
            lock.lock(); exhaustedFrom = .invalid; lock.unlock()
        } else {
            aheadReader = reader
            aheadOutput = output
            aheadStart = start
        }
        readerStarts += 1
        return true
    }

    func purge() {
        queue.sync {
            reader?.cancelReading()
            aheadReader?.cancelReading()
            reader = nil
            output = nil
            aheadReader = nil
            aheadOutput = nil
            aheadStart = .invalid
            lock.lock()
            ring.removeAll()
            nextRing.removeAll()
            nextWindowStart = .invalid
            readerStart = .invalid
            exhaustedFrom = .invalid
            lastRequest = .invalid
            lock.unlock()
        }
    }

    deinit { reader?.cancelReading(); aheadReader?.cancelReading() }
}
