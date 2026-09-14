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
                throw MaskTrackingError.message("This source has no video track to analyze.")
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
            try read(asset: asset, track: track,
                     from: CMTimeMaximum(.zero, CMTimeSubtract(anchorTime, CMTime(seconds: 1, preferredTimescale: 600))),
                     to: CMTimeMinimum(sourceEnd, CMTimeAdd(anchorTime, CMTime(seconds: 1, preferredTimescale: 600)))) { sample, time in
                if CMTimeCompare(time, anchorTime) > 0 { return false }
                anchor = try converter.frame(sample, time: time)
                return true
            }
            guard let anchor else { throw MaskTrackingError.message("The source frame at the playhead could not be decoded.") }
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
                    throw MaskTrackingError.message("Vision could not initialize this region. Reposition the mask over visible detail.")
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
                    try read(asset: asset, track: track, from: anchor.time, to: sourceEnd) { sample, time in
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
                        throw MaskTrackingError.message("Could not allocate temporary tracking storage.")
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
                        try read(asset: asset, track: track, from: lower, to: upper) { sample, time in
                            guard CMTimeCompare(time, lower) >= 0, CMTimeCompare(time, upper) < 0 else { return true }
                            let frame = try converter.frame(sample, time: time)
                            let offset = try file.offset()
                            guard offset + UInt64(frame.luma.count) <= 256 * 1024 * 1024 else {
                                throw MaskTrackingError.message("This source exceeds the temporary tracking buffer limit. Successful motion has been kept.")
                            }
                            try file.write(contentsOf: frame.luma)
                            records.append((offset, frame.luma.count, frame.width, frame.height, time))
                            return true
                        }
                        for entry in records.reversed() {
                            try Task.checkCancellation()
                            try file.seek(toOffset: entry.offset)
                            guard let data = try file.read(upToCount: entry.count), data.count == entry.count else {
                                throw MaskTrackingError.message("Temporary tracking frames could not be read.")
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

    private static func read(asset: AVAsset, track: AVAssetTrack, from start: CMTime, to end: CMTime,
                             visit: (CMSampleBuffer, CMTime) throws -> Bool) throws {
        try Task.checkCancellation()
        guard CMTimeCompare(end, start) > 0 else { return }
        let reader = try AVAssetReader(asset: asset)
        // Decode native nonlinear luminance. SDR, HLG and Apple Log all retain
        // their visible signal detail; no creative grade or HDR-to-SDR clipping.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MaskTrackingError.message("The source cannot be decoded for tracking.") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: start, end: end)
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? MaskTrackingError.message("The source decoder could not start.") }
        let sampler = ExportFrameSampler(output: output, range: reader.timeRange, fps: nil)
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let next = try sampler.next() else { return false }
            return try visit(next.sample, next.time)
        }) {}
        if reader.status == .failed { throw reader.error ?? MaskTrackingError.message("The source decoder stopped unexpectedly.") }
    }
}

private struct TrackingFrame {
    let luma: Data
    let width: Int
    let height: Int
    let time: CMTime
}

/// Fixed anchor-derived contrast mapping avoids pumping between frames and makes
/// flat Log footage usable without requiring a color-managed export conversion.
private final class TrackingLuminance {
    private var lookup = Array(0...255).map { UInt8($0) }

    func setReference(_ frame: TrackingFrame) {
        var histogram = [Int](repeating: 0, count: 256)
        for value in frame.luma { histogram[Int(value)] += 1 }
        var total = 0, low = 0, high = 255
        for i in 0..<256 {
            total += histogram[i]
            if total <= frame.luma.count / 100 { low = i }
            if total < frame.luma.count * 99 / 100 { high = i }
        }
        let gain = min(4, 235 / Double(max(1, high - low)))
        lookup = (0..<256).map { UInt8(min(255, max(0, (Double($0 - low) * gain + 10).rounded()))) }
    }

    func frame(_ sample: CMSampleBuffer, time: CMTime) throws -> TrackingFrame {
        guard let source = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetPlaneCount(source) == 2 else {
            throw MaskTrackingError.message("The decoder did not supply source luminance.")
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(source, 0) else {
            throw MaskTrackingError.message("A source frame could not be read.")
        }
        let sw = CVPixelBufferGetWidthOfPlane(source, 0), sh = CVPixelBufferGetHeightOfPlane(source, 0)
        let factor = min(1, 960 / Double(max(sw, sh)))
        let width = max(1, Int(Double(sw) * factor)), height = max(1, Int(Double(sh) * factor))
        var data = Data(count: width * height)
        let error = data.withUnsafeMutableBytes { bytes -> vImage_Error in
            var input = vImage_Buffer(data: base, height: vImagePixelCount(sh), width: vImagePixelCount(sw),
                                      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 0))
            var output = vImage_Buffer(data: bytes.baseAddress!, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width)
            return vImageScale_Planar8(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        guard error == kvImageNoError else { throw MaskTrackingError.message("The tracking frame could not be resized.") }
        return TrackingFrame(luma: data, width: width, height: height, time: time)
    }

    func pixelBuffer(_ frame: TrackingFrame) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw MaskTrackingError.message("There is not enough memory for a tracking frame.")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        frame.luma.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self)
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let v = lookup[Int(input[y * frame.width + x])]
                    let offset = y * stride + x * 4
                    base[offset] = v; base[offset + 1] = v; base[offset + 2] = v; base[offset + 3] = 255
                }
            }
        }
        return buffer
    }
}
