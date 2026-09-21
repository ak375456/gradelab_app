@preconcurrency import AVFoundation
@preconcurrency import Vision
import Accelerate
import Foundation

/// Runs on the detached analysis task. No player, renderer, SwiftUI or document writes.
enum MaskTrackingService {
    static func analyze(_ request: MaskTrackingRequest,
                        progress: @escaping @Sendable (MaskTrackingProgress) -> Void) async -> MaskTrackingResult {
        var result = MaskTrackingResult(lastDirection: request.direction == .backward ? .backward : .forward)
        do {
            let asset = AVURLAsset(url: request.url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw MaskTrackingError.message(String(localized: "This source has no video track to analyze."))
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let coordinates = try MaskTrackingCoordinates(encodedSize: size, preferredTransform: transform)
            let initialBox = try coordinates.region(for: request.mask.geometry)
            let converter = TrackingLuminance()
            let sourceStart = request.clip.sourceRange.start.cmTime
            let sourceEnd = try request.clip.sourceRange.end.cmTime
            let anchorTime = request.sourceAnchor.cmTime
            progress(.init(fraction: 0, frames: 0, direction: result.lastDirection, preparing: true))

            // Decode around the chosen instant and retain the frame whose PTS covers it.
            // This matters for VFR and for playhead instants between source samples.
            var anchor: TrackingFrame?
            try TrackingFrameSource.read(asset: asset, track: track,
                     from: CMTimeMaximum(.zero, CMTimeSubtract(anchorTime, CMTime(seconds: 1, preferredTimescale: 600))),
                     to: CMTimeMinimum(sourceEnd, CMTimeAdd(anchorTime, CMTime(seconds: 1, preferredTimescale: 600)))) { sample, time in
                if CMTimeCompare(time, anchorTime) > 0 { return false }
                anchor = try converter.frame(sample, time: time)
                return true
            }
            guard let anchor else { throw MaskTrackingError.message(String(localized: "The source frame at the playhead could not be decoded.")) }
            converter.setReference(anchor)
            result.samples = [.init(localTime: request.anchor, values: request.anchorValues, confidence: 1)]
            let passes: [MaskTrackingDirection] = request.direction == .both ? [.forward, .backward] : [request.direction]
            let forwardSpan = max(0, sourceEnd.seconds - anchorTime.seconds)
            let backwardSpan = max(0, anchorTime.seconds - sourceStart.seconds)
            let totalSpan = max(0.001, request.direction == .both ? forwardSpan + backwardSpan :
                                request.direction == .forward ? forwardSpan : backwardSpan)
            var completedSpan = 0.0
            var frames = 0
            var lastProgress = -1.0

            for direction in passes {
                try Task.checkCancellation()
                result.lastDirection = direction
                // Each direction gets a fresh tracker, initialized with the SAME anchor image.
                let handler = VNSequenceRequestHandler()
                let vision = VNTrackObjectRequest(detectedObjectObservation:
                    VNDetectedObjectObservation(boundingBox: coordinates.visionBox(fromSource: initialBox)))
                vision.trackingLevel = .accurate
                defer { vision.isLastFrame = true }
                try handler.perform([vision], on: converter.pixelBuffer(anchor), orientation: coordinates.orientation)
                guard let seeded = vision.results?.first as? VNDetectedObjectObservation,
                      MaskTrackingCoordinates.isValid(seeded.boundingBox) else {
                    throw MaskTrackingError.message(String(localized: "Vision could not initialize this region. Reposition the mask over visible detail."))
                }
                vision.inputObservation = seeded
                let referenceBox = coordinates.sourceBox(fromVision: seeded.boundingBox)

                func consume(_ frame: TrackingFrame) throws -> Bool {
                    try Task.checkCancellation()
                    let local = try request.localTime(source: frame.time)
                    guard direction == .forward ? local > request.anchor : local < request.anchor else { return true }
                    try handler.perform([vision], on: converter.pixelBuffer(frame), orientation: coordinates.orientation)
                    guard let observation = vision.results?.first as? VNDetectedObjectObservation,
                          observation.confidence.isFinite, observation.confidence >= 0.45,
                          MaskTrackingCoordinates.isValid(observation.boundingBox) else {
                        result.lostTime = local; return false
                    }
                    let box = coordinates.sourceBox(fromVision: observation.boundingBox)
                    let visible = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard MaskTrackingCoordinates.isValid(box), MaskTrackingCoordinates.isValid(visible),
                          visible.width * visible.height >= box.width * box.height * 0.2 else {
                        result.lostTime = local; return false
                    }
                    let sx = box.width / referenceBox.width, sy = box.height / referenceBox.height
                    let g = request.mask.geometry
                    let angle = g.rotationDegrees * .pi / 180
                    // Project the observed X/Y scale onto the existing rotated local axes.
                    // A rectangle cannot represent shear; its authored rotation is retained.
                    let wx = hypot(cos(angle) * sx, sin(angle) * sy)
                    let hy = hypot(sin(angle) * sx, cos(angle) * sy)
                    var values = SIMD4(box.midX + (g.centerX - referenceBox.midX) * sx,
                                       box.midY + (g.centerY - referenceBox.midY) * sy,
                                       g.width * wx, g.height * hy)
                    guard (0..<4).allSatisfy({ values[$0].isFinite }), values.z > 0, values.w > 0 else {
                        result.lostTime = local; return false
                    }
                    for i in 0..<4 { values[i] = MaskTrackingMotion.properties[i].clamped(values[i]) }
                    result.samples.append(.init(localTime: local, values: values, confidence: observation.confidence))
                    vision.inputObservation = observation
                    frames += 1
                    let fraction = min(1, (completedSpan + abs(frame.time.seconds - anchorTime.seconds)) / totalSpan)
                    if fraction - lastProgress >= 0.002 || frames % 12 == 0 {
                        lastProgress = fraction
                        progress(.init(fraction: fraction, frames: frames, direction: direction))
                    }
                    // Bounds sample memory as well as decoder memory on multi-hour inputs.
                    if result.samples.count >= 120_000 {
                        result.message = "Tracking stopped after 120,000 source frames. Continue from the last tracked frame to analyze more."
                        result.stopped = true
                        return false
                    }
                    return true
                }

                if direction == .forward {
                    try TrackingFrameSource.read(asset: asset, track: track, from: anchor.time, to: sourceEnd) { sample, time in
                        guard CMTimeCompare(time, anchor.time) > 0 else { return true }
                        return try consume(converter.frame(sample, time: time))
                    }
                } else {
                    // Reader is forward-only. Spool two seconds of reduced luma at a
                    // time, then visit records backwards. RAM holds only one decoded
                    // source frame and one analysis frame; disk use is one short chunk.
                    let spoolURL = FileManager.default.temporaryDirectory.appendingPathComponent("GradeLab-track-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: spoolURL) }
                    guard FileManager.default.createFile(atPath: spoolURL.path, contents: nil) else {
                        throw MaskTrackingError.message(String(localized: "Could not allocate temporary tracking storage."))
                    }
                    let file = try FileHandle(forUpdating: spoolURL)
                    defer { try? file.close() }
                    var upper = anchor.time
                    while CMTimeCompare(upper, sourceStart) > 0 {
                        try Task.checkCancellation()
                        let lower = CMTimeMaximum(sourceStart, CMTimeSubtract(upper, CMTime(seconds: 2, preferredTimescale: 600)))
                        try file.truncate(atOffset: 0)
                        try file.seek(toOffset: 0)
                        var records: [(offset: UInt64, count: Int, width: Int, height: Int, time: CMTime)] = []
                        progress(.init(fraction: max(0, lastProgress), frames: frames, direction: direction, preparing: true))
                        try TrackingFrameSource.read(asset: asset, track: track, from: lower, to: upper) { sample, time in
                            guard CMTimeCompare(time, lower) >= 0, CMTimeCompare(time, upper) < 0 else { return true }
                            let frame = try converter.frame(sample, time: time)
                            let offset = try file.offset()
                            guard offset + UInt64(frame.luma.count) <= 256 * 1024 * 1024 else {
                                throw MaskTrackingError.message(String(localized: "This source exceeds the temporary tracking buffer limit. Successful motion has been kept."))
                            }
                            try file.write(contentsOf: frame.luma)
                            records.append((offset, frame.luma.count, frame.width, frame.height, time))
                            return true
                        }
                        for entry in records.reversed() {
                            try Task.checkCancellation()
                            try file.seek(toOffset: entry.offset)
                            guard let data = try file.read(upToCount: entry.count), data.count == entry.count else {
                                throw MaskTrackingError.message(String(localized: "Temporary tracking frames could not be read."))
                            }
                            let keepGoing = try autoreleasepool {
                                try consume(.init(luma: data, width: entry.width, height: entry.height, time: entry.time))
                            }
                            if !keepGoing { break }
                        }
                        if result.lostTime != nil || result.stopped { break }
                        upper = lower
                    }
                }
                if result.lostTime != nil || result.stopped { break }
                completedSpan += direction == .forward ? forwardSpan : backwardSpan
            }
            if result.lostTime == nil && !result.stopped {
                progress(.init(fraction: 1, frames: frames, direction: result.lastDirection))
            }
        } catch is CancellationError {
            result.stopped = true
        } catch {
            result.message = error.localizedDescription
        }
        return result
    }
}
