@preconcurrency import AVFoundation
@preconcurrency import Vision
import Foundation

struct BackgroundLassoTrackRequest: Sendable {
    let url: URL
    let clip: VideoClip
    let selection: BackgroundLassoSelection
    let direction: MaskTrackingDirection

    var sourceAnchor: TimelineTime { selection.sourceTime ?? clip.sourceRange.start }
    var visibleStart: TimelineTime { clip.animation?.startOffset ?? .zero }
    var visibleEnd: TimelineTime { (try? visibleStart.adding(clip.placement.duration)) ?? visibleStart }

    /// The authored frame in clip-local time, which is what motion is keyed
    /// to. Derived when the outline predates the field, so an older document
    /// still tracks from the frame it was drawn on.
    var anchor: TimelineTime {
        if let local = selection.localTime { return local }
        return (try? localTime(source: sourceAnchor)) ?? visibleStart
    }

    /// Where a source frame lands in the clip's own animation coordinates.
    ///
    /// Through the clip's time map, not through a division by one rate: a
    /// tracked mask is keyed to the PICTURE, so on a ramped clip the frame that
    /// was analysed has to come back at the moment it is actually shown. A flat
    /// `1 / speed` was right only while every clip had a single rate.
    func localTime(source: CMTime) throws -> TimelineTime {
        let offset = try clip.localTime(atSource: TimelineTime(source))
        return try visibleStart.adding(offset)
    }

    func localTime(source: TimelineTime) throws -> TimelineTime {
        try localTime(source: source.cmTime)
    }
}

struct BackgroundLassoTrackResult: Sendable {
    var samples: [BackgroundLassoMotionSample] = []
    var lostLocalTime: TimelineTime?
    var lastDirection: MaskTrackingDirection = .forward
    var frames = 0
    var stopped = false
    var message: String?
}

/// Follows the lassoed object through the clip and reports where it sits on
/// every frame, so one drawn outline covers a whole shot.
///
/// Runs on a detached task: no player, no renderer, no SwiftUI, no document
/// writes. It produces measurements and the view model decides what to do
/// with them.
enum BackgroundLassoTracker {
    /// Frames of dropout tolerated before the object is called lost.
    private static let graceFrames = 8
    /// The most Vision's box may grow or shrink from one frame to the next.
    private static let scaleRate = 1.05
    private static let minimumScale = 0.2
    private static let maximumScale = 5.0

    static func track(_ request: BackgroundLassoTrackRequest,
                      progress: @escaping @Sendable (MaskTrackingProgress) -> Void) async -> BackgroundLassoTrackResult {
        var result = BackgroundLassoTrackResult(
            lastDirection: request.direction == .backward ? .backward : .forward)
        do {
            let selection = request.selection.clamped
            guard selection.isDrawn else {
                throw MaskTrackingError.message(String(localized: "Draw a lasso around the object before tracking it."))
            }
            let asset = AVURLAsset(url: request.url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw MaskTrackingError.message(String(localized: "This source has no video track to analyze."))
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let coordinates = try MaskTrackingCoordinates(encodedSize: size, preferredTransform: transform)
            let initialBox = selection.bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard MaskTrackingCoordinates.isValid(initialBox),
                  initialBox.width * size.width >= 8, initialBox.height * size.height >= 8 else {
                throw MaskTrackingError.message(String(localized: "Draw the lasso around a larger part of the picture before tracking."))
            }
            // Scale pivots on the outline's own centre, so the offset below is
            // solved for that pivot rather than assuming it matches the box
            // Vision settled on.
            let pivot = selection.anchorCenter
            let converter = TrackingLuminance()
            let sourceStart = request.clip.sourceRange.start.cmTime
            let sourceEnd = try request.clip.sourceRange.end.cmTime
            let anchorTime = request.sourceAnchor.cmTime
            progress(.init(fraction: 0, frames: 0, direction: result.lastDirection, preparing: true))

            // Decode around the authored instant and keep the frame whose PTS
            // covers it, which is what makes this correct on VFR sources and
            // when the playhead sits between two source samples.
            var anchorFrame: TrackingFrame?
            try TrackingFrameSource.read(
                asset: asset, track: track,
                from: CMTimeMaximum(.zero, CMTimeSubtract(anchorTime, CMTime(seconds: 1, preferredTimescale: 600))),
                to: CMTimeMinimum(sourceEnd, CMTimeAdd(anchorTime, CMTime(seconds: 1, preferredTimescale: 600)))) { sample, time in
                if CMTimeCompare(time, anchorTime) > 0 { return false }
                anchorFrame = try converter.frame(sample, time: time)
                return true
            }
            guard let anchorFrame else {
                throw MaskTrackingError.message(String(localized: "The source frame the lasso was drawn on could not be decoded."))
            }
            converter.setReference(anchorFrame)
            result.samples = [.init(time: request.anchor)]

            let passes: [MaskTrackingDirection] = request.direction == .both
                ? [.forward, .backward] : [request.direction]
            let forwardSpan = max(0, sourceEnd.seconds - anchorTime.seconds)
            let backwardSpan = max(0, anchorTime.seconds - sourceStart.seconds)
            let totalSpan = max(0.001, request.direction == .both ? forwardSpan + backwardSpan
                                : request.direction == .forward ? forwardSpan : backwardSpan)
            var completedSpan = 0.0
            var frames = 0
            var lastProgress = -1.0

            for direction in passes {
                try Task.checkCancellation()
                result.lastDirection = direction
                // Each pass gets its own tracker seeded from the SAME anchor
                // image, so tracking backwards is not a replay of forwards.
                let handler = VNSequenceRequestHandler()
                let vision = VNTrackObjectRequest(detectedObjectObservation:
                    VNDetectedObjectObservation(boundingBox: coordinates.visionBox(fromSource: initialBox)))
                vision.trackingLevel = .accurate
                defer { vision.isLastFrame = true }
                try handler.perform([vision], on: converter.pixelBuffer(anchorFrame),
                                    orientation: coordinates.orientation)
                guard let seeded = vision.results?.first as? VNDetectedObjectObservation,
                      MaskTrackingCoordinates.isValid(seeded.boundingBox) else {
                    throw MaskTrackingError.message(String(localized: "Tracking could not lock onto this outline. Draw it around an object with visible detail, or around more of the subject."))
                }
                vision.inputObservation = seeded
                let referenceBox = coordinates.sourceBox(fromVision: seeded.boundingBox)
                // Coasting state for this pass. A brief occlusion, a motion
                // blurred frame or a hand crossing the subject must not end a
                // whole track: the last good box is held for a few frames and
                // tracking resumes if the object comes back.
                var lastGood = seeded
                // Seeded with the anchor's identity transform so a dropout on
                // the very first frame coasts from where the user drew, and so
                // the rate limit below applies from the first measurement too.
                var lastAccepted: BackgroundLassoMotionSample? = .init(time: request.anchor)
                var misses = 0

                func sample(for box: CGRect, at local: TimelineTime) -> BackgroundLassoMotionSample? {
                    var sx = box.width / referenceBox.width, sy = box.height / referenceBox.height
                    if let previous = lastAccepted {
                        // Vision's box is free to breathe a little per frame but
                        // not to run away. Unchecked, it inflates until the
                        // outline swallows the frame, which is the failure that
                        // reads as "tracking is unreliable" more than any drift.
                        sx = min(max(sx, previous.scaleX / Self.scaleRate), previous.scaleX * Self.scaleRate)
                        sy = min(max(sy, previous.scaleY / Self.scaleRate), previous.scaleY * Self.scaleRate)
                    }
                    sx = min(max(sx, Self.minimumScale), Self.maximumScale)
                    sy = min(max(sy, Self.minimumScale), Self.maximumScale)
                    // Solve the offset that carries the reference box centre
                    // onto the observed one under a scale about `pivot`.
                    let value = BackgroundLassoMotionSample(
                        time: local,
                        offsetX: box.midX - pivot.x - (referenceBox.midX - pivot.x) * sx,
                        offsetY: box.midY - pivot.y - (referenceBox.midY - pivot.y) * sy,
                        scaleX: sx, scaleY: sy)
                    guard [value.offsetX, value.offsetY, sx, sy].allSatisfy(\.isFinite) else { return nil }
                    return value.clamped
                }

                /// Records the last accepted position again at this instant, so
                /// a short dropout holds the cutout still instead of ending the
                /// track or snapping the outline somewhere nobody authored.
                func coast(at local: TimelineTime) -> Bool {
                    misses += 1
                    guard misses <= Self.graceFrames, var held = lastAccepted else {
                        result.lostLocalTime = local
                        return false
                    }
                    held.time = local
                    result.samples.append(held)
                    vision.inputObservation = lastGood
                    return true
                }

                func consume(_ frame: TrackingFrame) throws -> Bool {
                    try Task.checkCancellation()
                    let local = try request.localTime(source: frame.time)
                    guard direction == .forward ? local > request.anchor : local < request.anchor else { return true }
                    try handler.perform([vision], on: converter.pixelBuffer(frame),
                                        orientation: coordinates.orientation)
                    guard let observation = vision.results?.first as? VNDetectedObjectObservation,
                          observation.confidence.isFinite, observation.confidence >= 0.35,
                          MaskTrackingCoordinates.isValid(observation.boundingBox) else {
                        return coast(at: local)
                    }
                    let box = coordinates.sourceBox(fromVision: observation.boundingBox)
                    let visible = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard MaskTrackingCoordinates.isValid(box), MaskTrackingCoordinates.isValid(visible),
                          visible.width * visible.height >= box.width * box.height * 0.2,
                          let measured = sample(for: box, at: local) else {
                        return coast(at: local)
                    }
                    misses = 0
                    lastGood = observation
                    lastAccepted = measured
                    result.samples.append(measured)
                    vision.inputObservation = observation
                    frames += 1
                    let fraction = min(1, (completedSpan + abs(frame.time.seconds - anchorTime.seconds)) / totalSpan)
                    if fraction - lastProgress >= 0.002 || frames % 12 == 0 {
                        lastProgress = fraction
                        progress(.init(fraction: fraction, frames: frames, direction: direction))
                    }
                    // Bounds decoder and sample memory on multi-hour inputs.
                    if result.samples.count >= 120_000 {
                        result.message = String(localized: "Tracking stopped after 120,000 frames. Draw the lasso again later in the clip to continue.")
                        result.stopped = true
                        return false
                    }
                    return true
                }

                if direction == .forward {
                    try TrackingFrameSource.read(asset: asset, track: track,
                                                 from: anchorFrame.time, to: sourceEnd) { sample, time in
                        guard CMTimeCompare(time, anchorFrame.time) > 0 else { return true }
                        return try consume(converter.frame(sample, time: time))
                    }
                } else {
                    try readBackwards(asset: asset, track: track, converter: converter,
                                      from: sourceStart, to: anchorFrame.time,
                                      progress: { progress(.init(fraction: max(0, lastProgress), frames: frames,
                                                                 direction: direction, preparing: true)) },
                                      consume: consume)
                }
                if result.lostLocalTime != nil || result.stopped { break }
                completedSpan += direction == .forward ? forwardSpan : backwardSpan
            }
            result.frames = frames
            result.samples = BackgroundLassoMotionSample.simplified(
                BackgroundLassoMotionSample.smoothed(
                    result.samples.sorted { $0.time < $1.time }, anchor: request.anchor),
                anchor: request.anchor)
            if result.lostLocalTime == nil && !result.stopped {
                progress(.init(fraction: 1, frames: frames, direction: result.lastDirection))
            }
        } catch is CancellationError {
            result.stopped = true
        } catch {
            result.message = error.localizedDescription
        }
        return result
    }

    /// An asset reader only moves forwards, so backwards tracking spools two
    /// seconds of reduced luma to a temporary file and visits those records in
    /// reverse. Memory holds one decoded frame at a time; disk holds one short
    /// chunk, which is what keeps this usable on a long clip.
    private static func readBackwards(
        asset: AVAsset, track: AVAssetTrack, converter: TrackingLuminance,
        from sourceStart: CMTime, to anchorTime: CMTime,
        progress: () -> Void,
        consume: (TrackingFrame) throws -> Bool
    ) throws {
        let spoolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradeLab-lasso-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spoolURL) }
        guard FileManager.default.createFile(atPath: spoolURL.path, contents: nil) else {
            throw MaskTrackingError.message(String(localized: "Could not allocate temporary tracking storage."))
        }
        let file = try FileHandle(forUpdating: spoolURL)
        defer { try? file.close() }
        var upper = anchorTime
        while CMTimeCompare(upper, sourceStart) > 0 {
            try Task.checkCancellation()
            let lower = CMTimeMaximum(sourceStart, CMTimeSubtract(upper, CMTime(seconds: 2, preferredTimescale: 600)))
            try file.truncate(atOffset: 0)
            try file.seek(toOffset: 0)
            var records: [(offset: UInt64, count: Int, width: Int, height: Int, time: CMTime)] = []
            progress()
            try TrackingFrameSource.read(asset: asset, track: track, from: lower, to: upper) { sample, time in
                guard CMTimeCompare(time, lower) >= 0, CMTimeCompare(time, upper) < 0 else { return true }
                let frame = try converter.frame(sample, time: time)
                let offset = try file.offset()
                guard offset + UInt64(frame.luma.count) <= 256 * 1024 * 1024 else {
                    throw MaskTrackingError.message(String(localized: "This source exceeds the temporary tracking buffer limit. Tracking already measured has been kept."))
                }
                try file.write(contentsOf: frame.luma)
                records.append((offset, frame.luma.count, frame.width, frame.height, time))
                return true
            }
            var stop = false
            for entry in records.reversed() {
                try Task.checkCancellation()
                try file.seek(toOffset: entry.offset)
                guard let data = try file.read(upToCount: entry.count), data.count == entry.count else {
                    throw MaskTrackingError.message(String(localized: "Temporary tracking frames could not be read."))
                }
                let keepGoing = try autoreleasepool {
                    try consume(.init(luma: data, width: entry.width, height: entry.height, time: entry.time))
                }
                if !keepGoing { stop = true; break }
            }
            if stop { break }
            upper = lower
        }
    }
}
