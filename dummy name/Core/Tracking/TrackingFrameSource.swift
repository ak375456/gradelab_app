@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import Foundation

/// Shared source-frame decoding for every tracker in the app.
///
/// Both the power-window tracker and the background lasso tracker need the
/// same thing: native luminance, decoded once, normalized against the anchor
/// frame so flat Log footage is usable without a creative grade in the way.
/// Keeping one copy means a fix to Log handling or to VFR reading reaches
/// both rather than only whichever one was being worked on.
enum TrackingFrameSource {
    static func read(asset: AVAsset, track: AVAssetTrack, from start: CMTime, to end: CMTime,
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
        guard reader.canAdd(output) else { throw MaskTrackingError.message(String(localized: "The source cannot be decoded for tracking.")) }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: start, end: end)
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? MaskTrackingError.message(String(localized: "The source decoder could not start.")) }
        let sampler = ExportFrameSampler(output: output, range: reader.timeRange, fps: nil)
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let next = try sampler.next() else { return false }
            return try visit(next.sample, next.time)
        }) {}
        if reader.status == .failed { throw reader.error ?? MaskTrackingError.message(String(localized: "The source decoder stopped unexpectedly.")) }
    }
}

struct TrackingFrame {
    let luma: Data
    let width: Int
    let height: Int
    let time: CMTime
}

/// Fixed anchor-derived contrast mapping avoids pumping between frames and makes
/// flat Log footage usable without requiring a color-managed export conversion.
final class TrackingLuminance {
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
            throw MaskTrackingError.message(String(localized: "The decoder did not supply source luminance."))
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(source, 0) else {
            throw MaskTrackingError.message(String(localized: "A source frame could not be read."))
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
        guard error == kvImageNoError else { throw MaskTrackingError.message(String(localized: "The tracking frame could not be resized.")) }
        return TrackingFrame(luma: data, width: width, height: height, time: time)
    }

    func pixelBuffer(_ frame: TrackingFrame) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw MaskTrackingError.message(String(localized: "There is not enough memory for a tracking frame."))
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
