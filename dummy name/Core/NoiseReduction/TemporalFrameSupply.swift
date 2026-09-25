@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CoreMedia
import Foundation

// ---------------------------------------------------------------------------
// Where the neighbouring frames come from
//
// Temporal noise reduction needs the frames either side of the one being shown,
// and neither of the two places GradeLab gets pictures from will hand those
// over: `AVPlayerItemVideoOutput` produces exactly the frame at the playhead,
// and an export reader produces one frame at a time in order. So there are two
// suppliers here, and they exist for different reasons.
//
//   TemporalExportWindow  is not a decoder. It sits on top of the export
//                         sampler that was already reading the file and holds
//                         a few of its frames back, so a five-frame window
//                         costs one decode per frame rather than five. An
//                         export already reads every frame in order; this only
//                         changes when they are released.
//
//   TemporalFrameCache    does own a reader, and that is unavoidable: there is
//                         no API that will give you the frame after the one the
//                         player is showing. It decodes forward from wherever
//                         the playhead is, keeps a small ring, and is thrown
//                         away the moment temporal reduction is switched off.
//                         Nothing about playback goes through it — the picture
//                         on screen still comes from the player.
//
// Both refuse to cross a cut. Clip boundaries are taken from the timeline,
// which is authoritative and free; within one clip a hard cut in the source is
// caught by comparing coarse luminance signatures, because combining across one
// would mix two unrelated pictures and is the worst artefact this engine could
// produce.
// ---------------------------------------------------------------------------

/// A coarse fingerprint of a frame, for spotting a cut.
///
/// Deliberately tiny — an 8x8 grid of luminance samples read straight off the
/// decoded plane. It costs sixty-four reads, it is immune to noise and to
/// small movements, and it is decisive about the one thing it is asked: are
/// these two frames the same scene at all.
struct SceneSignature: Equatable, Sendable {
    static let side = 8
    private let samples: [Float]

    private init(samples: [Float]) { self.samples = samples }

    /// Reads a signature from a decoded frame, or nil for a layout this does
    /// not know how to sample.
    ///
    /// A nil signature is not a failure: it means cut detection falls back to
    /// the per-pixel rejection in the temporal kernels, which already treats a
    /// frame that matches nowhere as a frame with nothing to contribute.
    static func read(_ pixelBuffer: CVPixelBuffer) -> SceneSignature? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planar: Bool
        let bytesPerSample: Int
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            planar = true; bytesPerSample = 1
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            planar = true; bytesPerSample = 2
        case kCVPixelFormatType_32BGRA:
            planar = false; bytesPerSample = 4
        default:
            return nil
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let stride = planar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = planar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer),
              width >= side, height >= side else { return nil }

        var samples = [Float](repeating: 0, count: side * side)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<side {
            let y = min(height - 1, (row * 2 + 1) * height / (side * 2))
            for column in 0..<side {
                let x = min(width - 1, (column * 2 + 1) * width / (side * 2))
                let offset = y * stride + x * bytesPerSample
                let value: Float
                switch bytesPerSample {
                case 1:
                    value = Float(pointer[offset]) / 255
                case 2:
                    let low = UInt16(pointer[offset]), high = UInt16(pointer[offset + 1])
                    value = Float(low | (high << 8)) / 65535
                default:
                    // BGRA: the green channel carries most of the luminance and
                    // needs no matrix to read.
                    value = Float(pointer[offset + 1]) / 255
                }
                samples[row * side + column] = value
            }
        }
        return SceneSignature(samples: samples)
    }

    /// Mean absolute difference between two signatures, 0…1.
    func distance(to other: SceneSignature) -> Float {
        guard samples.count == other.samples.count, !samples.isEmpty else { return 1 }
        var total: Float = 0
        for index in samples.indices { total += abs(samples[index] - other.samples[index]) }
        return total / Float(samples.count)
    }

    /// Above this, two frames are treated as belonging to different shots.
    ///
    /// Set well clear of what any amount of movement produces. A whip pan or a
    /// flash can move this number a long way, and the cost of a false positive
    /// is only that one frame denoises spatially — while the cost of a false
    /// negative is two shots blended together.
    static let cutThreshold: Float = 0.22

    static func isCut(_ a: SceneSignature?, _ b: SceneSignature?) -> Bool {
        guard let a, let b else { return false }
        return a.distance(to: b) > cutThreshold
    }
}

/// One decoded frame with everything needed to judge whether it belongs to the
/// same shot as its neighbours.
struct TemporalFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
    let signature: SceneSignature?
}

// MARK: - Export

/// A sliding window over a sequential frame stream.
///
/// The export reader already walks the whole file in order, so a five-frame
/// window does not need a second pass over the media — it needs the last two
/// frames kept and the next two read early. That is all this is: everything is
/// decoded exactly once, and the buffer never holds more than the window.
final class TemporalExportWindow {
    struct Entry {
        let sample: CMSampleBuffer
        let time: CMTime
        let signature: SceneSignature?
    }

    private let backward: Int
    private let forward: Int
    private var history: [Entry] = []
    private var upcoming: [Entry] = []
    private var exhausted = false

    init(backward: Int, forward: Int) {
        self.backward = max(0, backward)
        self.forward = max(0, forward)
    }

    /// The next frame to render, with the neighbours the engine may use for it.
    ///
    /// - Parameter read: pulls the next decoded frame, or nil at the end.
    func next(read: () throws -> (sample: CMSampleBuffer, time: CMTime)?) throws
        -> (frame: (sample: CMSampleBuffer, time: CMTime), neighbours: [NoiseFrame])?
    {
        while !exhausted && upcoming.count < forward + 1 {
            guard let read = try read() else { exhausted = true; break }
            upcoming.append(Entry(
                sample: read.sample, time: read.time,
                signature: CMSampleBufferGetImageBuffer(read.sample).flatMap(SceneSignature.read)))
        }
        guard !upcoming.isEmpty else { return nil }
        let current = upcoming.removeFirst()
        var neighbours: [NoiseFrame] = []

        // Backwards, nearest first, stopping at the first cut. Stopping rather
        // than skipping is deliberate: past a cut there is nothing further back
        // that could belong to this shot either.
        var previous = current
        for (distance, entry) in history.reversed().enumerated() {
            if SceneSignature.isCut(previous.signature, entry.signature) { break }
            if let buffer = CMSampleBufferGetImageBuffer(entry.sample) {
                neighbours.append(NoiseFrame(pixelBuffer: buffer, offset: -(distance + 1), time: entry.time))
            }
            previous = entry
        }
        previous = current
        for (distance, entry) in upcoming.prefix(forward).enumerated() {
            if SceneSignature.isCut(previous.signature, entry.signature) { break }
            if let buffer = CMSampleBufferGetImageBuffer(entry.sample) {
                neighbours.append(NoiseFrame(pixelBuffer: buffer, offset: distance + 1, time: entry.time))
            }
            previous = entry
        }

        history.append(current)
        if history.count > backward { history.removeFirst(history.count - backward) }
        if backward == 0 { history.removeAll() }
        return ((current.sample, current.time), neighbours)
    }

    func reset() {
        history.removeAll(); upcoming.removeAll(); exhausted = false
    }
}

// MARK: - Preview

/// Decodes and holds the frames around the playhead, off the render thread.
///
/// Asked for neighbours it does not have, it returns what it has and schedules
/// the rest. That is the whole of the scrubbing behaviour: dragging the
/// playhead produces spatial-only frames immediately rather than a stall, and
/// when the decode catches up the caller is told to repaint and the full
/// temporal result appears. Nothing here ever blocks a draw.
final class TemporalFrameCache: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let outputSettings: [String: Any]
    private let frameDuration: CMTime
    private let queue = DispatchQueue(label: "com.lexur.GradeLab.temporal-frames", qos: .userInitiated)
    private let lock = NSLock()

    private var ring: [TemporalFrame] = []
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var readerStart: CMTime = .invalid
    private var working = false
    private var generation = 0
    /// The playhead position a fill last came back from with nothing at all.
    ///
    /// The general backstop behind the two clamps in `prefetch`. Whatever the
    /// reason a window cannot be satisfied — the tail of a damaged file, a
    /// reader that failed, a track with no frames where the timeline says there
    /// are — asking again from the same place will fail the same way, and this
    /// is asked on every draw. Cleared the moment a frame does land, and the
    /// playhead moving is itself a new question, so this never holds playback
    /// back.
    private var emptyAt: CMTime = .invalid
    /// The last sample time the stream turned out to have, once a read has run
    /// off the end and found out. `.invalid` until then.
    ///
    /// Learned rather than asked for, because what matters is where the frames
    /// actually stop rather than what the container claims, and because a
    /// window that reaches past the last frame must stop being asked for.
    private var streamEnd: CMTime = .invalid
    /// The most frames kept at once: the window, plus a little slack so
    /// ordinary playback never falls out of the ring. Sized from the window
    /// actually asked for rather than fixed, since at 4K every extra frame held
    /// here is about a dozen megabytes of nothing.
    private var capacity = 9

    /// Called on the decode queue when new frames have landed, so the preview
    /// can repaint the frame it drew without them.
    var onFramesReady: (@Sendable () -> Void)?

    /// How many readers this cache has started.
    ///
    /// Exposed for one test, and it earns the line: starting a reader means
    /// seeking and decoding from the preceding sync sample, `prefetch` is called
    /// on every draw, and the difference between "one reader for the whole clip"
    /// and "a reader per frame" is invisible in a picture and unmissable in a
    /// number. `TemporalFrameSupplyTests` holds it to a count.
    private(set) var readerStarts = 0

    /// - Parameter outputSettings: must be the settings the player's own video
    ///   output was built with. A neighbour has to arrive in exactly the layout
    ///   the frame on screen did, so that both go through one preparation path
    ///   and the engine is never comparing an 8-bit copy of a 10-bit frame.
    ///   Passed in rather than derived here so this file does not reach into
    ///   the playback controller for a decision the caller has already made.
    /// The size the frames in this cache arrive at.
    ///
    /// Held so the caller can compare it with the frame it is about to draw
    /// BEFORE any decoding is asked for. The preview renders through a video
    /// composition whose render size drops while playback is running, while
    /// this reader renders the track at its own size — and a neighbour of a
    /// different size is not evidence about this frame, it is a different
    /// picture. See `MetalVideoRenderer.encodeNoiseReduction`.
    let frameSize: (width: Int, height: Int)

    init(asset: AVAsset, track: AVAssetTrack, frameDuration: CMTime,
         frameSize: (width: Int, height: Int),
         outputSettings: [String: Any]) {
        self.asset = asset
        self.track = track
        self.frameSize = frameSize
        self.frameDuration = frameDuration.isNumeric && frameDuration > .zero
            ? frameDuration
            : CMTime(value: 1, timescale: 30)
        self.outputSettings = outputSettings
    }

    /// Whatever is ready for `time`, nearest first.
    ///
    /// - Parameter limit: the active clip's range. Neighbours outside it are
    ///   not offered at all — a timeline boundary is a cut, and it is one the
    ///   document already knows about, so it is never left to be discovered by
    ///   comparing pictures.
    func neighbours(at time: CMTime, backward: Int, forward: Int, limit: CMTimeRange?) -> [NoiseFrame] {
        guard backward > 0 || forward > 0 else { return [] }
        lock.lock(); let frames = ring; lock.unlock()
        guard !frames.isEmpty else { return [] }

        // The frame NEAREST the playhead, not the first one within a tolerance.
        // Both accept the same frame when the ring's spacing and `frameDuration`
        // agree, but where they do not the first match can be the further of
        // two — and this picks the centre of the window, so being off by one
        // shifts every neighbour offset with it.
        let tolerance = CMTimeMultiplyByFloat64(frameDuration, multiplier: 0.5)
        var centreIndex: Int?
        var nearest = CMTime.positiveInfinity
        for (index, frame) in frames.enumerated() {
            let distance = CMTimeAbsoluteValue(CMTimeSubtract(frame.time, time))
            if CMTimeCompare(distance, nearest) < 0 { nearest = distance; centreIndex = index }
        }
        guard let centre = centreIndex, CMTimeCompare(nearest, tolerance) <= 0 else { return [] }

        func allowed(_ frame: TemporalFrame) -> Bool {
            guard let limit else { return true }
            return CMTimeRangeContainsTime(limit, time: frame.time)
        }

        var result: [NoiseFrame] = []
        var previous = frames[centre]
        var offset = 0
        var index = centre - 1
        while index >= 0, offset > -backward {
            let frame = frames[index]
            guard allowed(frame), !SceneSignature.isCut(previous.signature, frame.signature) else { break }
            offset -= 1
            result.append(NoiseFrame(pixelBuffer: frame.pixelBuffer, offset: offset, time: frame.time))
            previous = frame; index -= 1
        }
        previous = frames[centre]
        offset = 0
        index = centre + 1
        while index < frames.count, offset < forward {
            let frame = frames[index]
            guard allowed(frame), !SceneSignature.isCut(previous.signature, frame.signature) else { break }
            offset += 1
            result.append(NoiseFrame(pixelBuffer: frame.pixelBuffer, offset: offset, time: frame.time))
            previous = frame; index += 1
        }
        return result
    }

    /// Makes sure the window around `time` is being filled. Cheap to call on
    /// every draw: it returns immediately when the ring already covers the
    /// window or when a decode is already running.
    func prefetch(at time: CMTime, backward: Int, forward: Int) {
        guard backward > 0 || forward > 0 else { return }
        lock.lock()
        if working { lock.unlock(); return }
        if emptyAt.isNumeric, CMTimeCompare(emptyAt, time) == 0 { lock.unlock(); return }
        capacity = backward + forward + 5
        let frames = ring
        // Both ends are clamped to what the media can actually supply, and that
        // is not tidying. A window reaching before the first frame or past the
        // last one can never be covered, "not covered" is what asks for another
        // decode, and this is called on every draw — so an unclamped window at
        // either end of a clip tore down and rebuilt the reader sixty times a
        // second, each rebuild decoding from the preceding sync sample. The
        // playhead sits at zero when a project opens, which is precisely where
        // that started.
        let start = CMTimeMaximum(
            .zero,
            CMTimeSubtract(time, CMTimeMultiply(frameDuration, multiplier: Int32(backward + 1))))
        let wanted = CMTimeAdd(time, CMTimeMultiply(frameDuration, multiplier: Int32(forward + 1)))
        let end = streamEnd.isNumeric ? CMTimeMinimum(wanted, streamEnd) : wanted
        // Both ends, with the parentheses written out: `??` binds looser than
        // `&&`, so the unbracketed form reads as "covers the past" alone and
        // the window would never be extended forwards.
        let coversPast = (frames.first.map { CMTimeCompare($0.time, start) <= 0 }) ?? false
        let coversFuture = (frames.last.map { CMTimeCompare($0.time, end) >= 0 }) ?? false
        let covered = coversPast && coversFuture
        if covered { lock.unlock(); return }
        // A reader that is still going, and a ring that already reaches back far
        // enough, means the only thing missing is further FORWARD — which is
        // exactly what this reader is already positioned to hand over. Reading
        // on costs one decode per frame; starting again costs a new reader and a
        // decode from the preceding sync sample, and during playback the window
        // needs one more future frame every single frame. Testing the playhead
        // against what had been decoded instead was true only while catching up,
        // so ordinary playback took the restart every time.
        //
        // The distance test is the other half of it: once the playhead has
        // jumped a long way ahead, seeking really is cheaper than decoding
        // everything in between.
        let canContinue = reader?.status == .reading && coversPast
            && frames.last.map {
                CMTimeCompare(CMTimeSubtract(end, $0.time),
                              CMTimeMultiply(frameDuration, multiplier: 48)) < 0
            } ?? false
        working = true
        generation += 1
        let token = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            if !canContinue { self.restart(at: start, token: token) }
            let landed = self.fill(until: end, token: token)
            self.lock.lock()
            self.working = false
            // Only a fill that is still the current one gets to record this. A
            // superseded one stopped early by design — `suspend` or `invalidate`
            // moved the generation on — and reading its empty result as "this
            // position has nothing" would refuse to ever look there again.
            if self.generation == token { self.emptyAt = landed ? .invalid : time }
            self.lock.unlock()
            // Only when something actually arrived. This asks for a repaint, the
            // repaint comes straight back here through the next draw's
            // prefetch, and a fill that added nothing would therefore be a loop
            // rather than a refresh.
            if landed { self.onFramesReady?() }
        }
    }

    /// Drops the held frames and the reader while nothing can use them, and
    /// does nothing at all when there is nothing to drop.
    ///
    /// Called every draw for which the temporal stage cannot run — reduced
    /// playback, most of the time — so the frames are not held across it. At 4K
    /// this ring is over a hundred megabytes, on a phone that is already holding
    /// the engine's own surfaces and the player's decode, and holding it through
    /// the one state that can never read it is how a feature becomes a memory
    /// problem. Refilling afterwards costs one seek, once, when the transport
    /// stops.
    func suspend() {
        lock.lock()
        guard !ring.isEmpty || reader != nil else { lock.unlock(); return }
        generation += 1
        emptyAt = .invalid
        ring.removeAll()
        reader?.cancelReading()
        reader = nil; output = nil; readerStart = .invalid
        lock.unlock()
    }

    /// Drops everything. Called when the clip, the project colour mode or the
    /// temporal settings change, and when noise reduction is switched off.
    func invalidate() {
        lock.lock()
        generation += 1
        emptyAt = .invalid
        ring.removeAll()
        reader?.cancelReading()
        reader = nil; output = nil; readerStart = .invalid
        lock.unlock()
    }

    // MARK: Decoding

    private func restart(at start: CMTime, token: Int) {
        lock.lock()
        reader?.cancelReading()
        reader = nil; output = nil
        ring.removeAll()
        lock.unlock()

        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        // Copied, deliberately. This reader exists to hold a ring of frames, and
        // a ring of buffers the decoder still owns would starve the pool they
        // came from — at which point the next read never returns and the
        // preview quietly stops finding neighbours.
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return }
        reader.add(output)
        let from = CMTimeMaximum(.zero, start)
        reader.timeRange = CMTimeRange(start: from, duration: .positiveInfinity)
        guard reader.startReading() else { return }

        lock.lock()
        guard generation == token else { lock.unlock(); reader.cancelReading(); return }
        self.reader = reader; self.output = output; readerStart = from
        readerStarts += 1
        lock.unlock()
    }

    /// - Returns: true when at least one frame was added, which is the only
    ///   thing that makes a repaint worth asking for.
    private func fill(until end: CMTime, token: Int) -> Bool {
        var landed = false
        while true {
            lock.lock()
            guard generation == token, let output, reader?.status == .reading else { lock.unlock(); return landed }
            let reachedEnd = ring.last.map { CMTimeCompare($0.time, end) >= 0 } ?? false
            lock.unlock()
            if reachedEnd { return landed }
            guard let sample = output.copyNextSampleBuffer() else {
                // Out of frames. Where the stream ended is remembered here
                // because it is the only place it can be found out, and because
                // without it a window reaching past the last frame is asked for
                // again on the next draw, and the next, for as long as the
                // playhead stays near the end of the clip.
                lock.lock()
                if generation == token, reader?.status == .completed, let last = ring.last {
                    streamEnd = last.time
                }
                lock.unlock()
                return landed
            }
            // A sample with no picture, or with a timestamp that cannot be
            // compared, is skipped rather than ending the fill: one odd sample
            // at an edit boundary must not stop the window being filled.
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let frame = TemporalFrame(
                pixelBuffer: buffer, time: time, signature: SceneSignature.read(buffer))
            lock.lock()
            guard generation == token else { lock.unlock(); return landed }
            ring.append(frame)
            landed = true
            // The ring is a window, not a history. Anything older than the
            // frames this window can still reach is released immediately: at 4K
            // each of these is about a dozen megabytes.
            if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
            lock.unlock()
        }
    }
}
