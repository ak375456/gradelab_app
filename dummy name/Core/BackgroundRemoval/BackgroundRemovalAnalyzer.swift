@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
@preconcurrency import Vision

struct BackgroundRemovalAnalysisProgress: Sendable, Equatable {
    var fraction: Double
    var frames: Int
    var preparing = false
    var totalFrames: Int?
    var currentSourceTime: TimelineTime?
}

struct BackgroundRemovalAnalysisSummary: Sendable, Equatable {
    var frames: Int
}

struct BackgroundRemovalAnalysisRequest: Sendable {
    let projectID: UUID
    let clip: VideoClip
    let asset: ProjectMediaAsset
    let settings: BackgroundRemovalSettings
}

enum BackgroundRemovalAnalysisError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

/// On-device Vision analysis for Auto cutouts. Frames are decoded and consumed
/// one at a time; only the previous low-resolution matte is retained for
/// temporal matching.
///
/// Lasso cutouts never come through here. An authored outline is rasterized
/// for the frame being drawn, so it needs no analysis pass and nothing on disk.
enum BackgroundRemovalAnalyzer {
    static func analyze(
        _ input: BackgroundRemovalAnalysisRequest,
        progress: @escaping (BackgroundRemovalAnalysisProgress) -> Void
    ) async throws -> BackgroundRemovalAnalysisSummary {
        guard input.settings.mode == .automatic else { return .init(frames: 0) }
        let asset = AVURLAsset(url: input.asset.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            if input.asset.stillImage != nil {
                return try await analyzeStill(input, progress: progress)
            }
            throw BackgroundRemovalAnalysisError.message("This source has no picture to analyze.")
        }
        let encodedSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let coordinates = try MaskTrackingCoordinates(encodedSize: encodedSize, preferredTransform: preferred)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw BackgroundRemovalAnalysisError.message("This source cannot be decoded for background analysis.")
        }
        reader.add(output)
        let rangeEnd = try input.clip.sourceRange.end
        let analysisStart = min(rangeEnd, input.clip.sourceRange.start)
        reader.timeRange = CMTimeRange(start: analysisStart.cmTime,
                                       end: rangeEnd.cmTime)
        guard reader.startReading() else {
            throw reader.error ?? BackgroundRemovalAnalysisError.message("Background analysis could not start.")
        }
        defer { reader.cancelReading() }
        var engine = Engine(coordinates: coordinates)
        var previous: BackgroundMaskPlane?
        var frames = 0
        var usableFrames = 0
        var lastSourceTime = analysisStart
        let span = max(rangeEnd.seconds - analysisStart.seconds, 0.001)
        let frameSeconds = max(input.asset.frameDuration?.seconds ?? (1.0 / 30.0), 1.0 / 240.0)
        let totalFrames = max(1, Int(ceil(span / frameSeconds)))
        progress(.init(fraction: 0, frames: 0, preparing: true, totalFrames: totalFrames))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let plane = try await engine.mask(pixelBuffer: pixelBuffer)
            if plane.coverage > 0.001, plane.coverage < 0.995 { usableFrames += 1 }
            let stable = plane.temporallyStabilized(with: previous)
            previous = stable
            let sourceTime = try TimelineTime(timestamp)
            lastSourceTime = sourceTime
            let frame = BackgroundMaskFrameIndex.make(
                sourceTime: sourceTime, assetStart: input.asset.sourceRange.start,
                frameDuration: input.asset.frameDuration)
            try BackgroundRemovalMaskStore.shared.write(stable, key: .init(
                projectID: input.projectID, clipID: input.clip.id,
                analysisID: input.settings.analysisID, frame: frame))
            frames += 1
            let fraction = min(1, max(0,
                (timestamp.seconds - analysisStart.seconds) / span))
            progress(.init(fraction: fraction, frames: frames,
                           totalFrames: totalFrames, currentSourceTime: sourceTime))
        }
        if reader.status == .failed {
            throw reader.error ?? BackgroundRemovalAnalysisError.message("Background analysis stopped unexpectedly.")
        }
        guard frames > 0, usableFrames > 0 else {
            throw BackgroundRemovalAnalysisError.message("No clear subject was found. Try the Lasso tool, or refine this cutout by hand.")
        }
        progress(.init(fraction: 1, frames: frames,
                       totalFrames: frames, currentSourceTime: lastSourceTime))
        return .init(frames: frames)
    }

    private static func analyzeStill(
        _ input: BackgroundRemovalAnalysisRequest,
        progress: @escaping (BackgroundRemovalAnalysisProgress) -> Void
    ) async throws -> BackgroundRemovalAnalysisSummary {
        progress(.init(fraction: 0, frames: 0, preparing: true, totalFrames: 1))
        let decoded = try await ImageDecoder.decodeDetached(url: input.asset.url, maximumLongEdge: 2_048)
        let size = CGSize(width: CVPixelBufferGetWidth(decoded.buffer),
                          height: CVPixelBufferGetHeight(decoded.buffer))
        let coordinates = try MaskTrackingCoordinates(encodedSize: size, preferredTransform: .identity)
        var engine = Engine(coordinates: coordinates)
        let plane = try await engine.mask(pixelBuffer: decoded.buffer)
        guard plane.coverage > 0.001 else {
            throw BackgroundRemovalAnalysisError.message("No clear subject was found. Try the Lasso tool, or refine this cutout by hand.")
        }
        try BackgroundRemovalMaskStore.shared.write(plane, key: .init(
            projectID: input.projectID, clipID: input.clip.id,
            analysisID: input.settings.analysisID, frame: 0))
        progress(.init(fraction: 1, frames: 1, totalFrames: 1,
                       currentSourceTime: input.clip.sourceRange.start))
        return .init(frames: 1)
    }

    private struct Engine {
        enum Strategy { case undecided, people, foreground }
        let coordinates: MaskTrackingCoordinates
        var strategy: Strategy = .undecided
        let personRequest: GeneratePersonSegmentationRequest = {
            let request = GeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormatType = kCVPixelFormatType_OneComponent8
            return request
        }()
        let ci = CIContext(options: [.cacheIntermediates: false])

        mutating func mask(pixelBuffer: CVPixelBuffer) async throws -> BackgroundMaskPlane {
            try await automatic(pixelBuffer)
        }

        private mutating func automatic(_ pixelBuffer: CVPixelBuffer) async throws -> BackgroundMaskPlane {
            if strategy != .foreground {
                let observation = try await personRequest.perform(on: pixelBuffer, orientation: coordinates.orientation)
                let raw = try Self.plane(observation.cgImage, coordinates: coordinates)
                let plane = Self.foregroundPolarity(raw)
                if strategy == .people || Self.isMeaningful(plane) {
                    strategy = .people
                    return plane
                }
                strategy = .foreground
            }
            let request = GenerateForegroundInstanceMaskRequest()
            guard let observation = try await request.perform(on: pixelBuffer, orientation: coordinates.orientation) else {
                return Self.empty(coordinates)
            }
            let mask = try observation.generateMask(for: observation.allInstances)
            let raw = try Self.plane(mask, coordinates: coordinates, ci: ci)
            return Self.foregroundPolarity(raw)
        }

        private static func empty(_ coordinates: MaskTrackingCoordinates) -> BackgroundMaskPlane {
            let size = analysisSize(coordinates.encodedSize)
            return .init(width: size.width, height: size.height,
                         values: Data(repeating: 0, count: size.width * size.height))
        }

        private static func plane(_ buffer: CVPixelBuffer, coordinates: MaskTrackingCoordinates,
                                  ci: CIContext) throws -> BackgroundMaskPlane {
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = ci.createCGImage(image, from: image.extent) else {
                throw BackgroundRemovalAnalysisError.message("Vision returned a mask that could not be read.")
            }
            return try plane(cg, coordinates: coordinates)
        }

        private static func plane(_ image: CGImage,
                                  coordinates: MaskTrackingCoordinates) throws -> BackgroundMaskPlane {
            let logicalWidth = image.width, logicalHeight = image.height
            var logical = Data(repeating: 0, count: logicalWidth * logicalHeight)
            let made = logical.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: logicalWidth, height: logicalHeight,
                                              bitsPerComponent: 8, bytesPerRow: logicalWidth,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.translateBy(x: 0, y: CGFloat(logicalHeight))
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight))
                return true
            }
            guard made else {
                throw BackgroundRemovalAnalysisError.message("There is not enough memory for the subject mask.")
            }
            let target = analysisSize(coordinates.encodedSize)
            var encoded = Data(repeating: 0, count: target.width * target.height)
            encoded.withUnsafeMutableBytes { outRaw in
                logical.withUnsafeBytes { inRaw in
                    let output = outRaw.bindMemory(to: UInt8.self)
                    let input = inRaw.bindMemory(to: UInt8.self)
                    for y in 0..<target.height {
                        for x in 0..<target.width {
                            let source = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(target.width),
                                                 y: (CGFloat(y) + 0.5) / CGFloat(target.height))
                            let display = coordinates.sourceToDisplay(source)
                            let ix = min(max(Int(display.x * CGFloat(logicalWidth)), 0), logicalWidth - 1)
                            // Vision locations and masks are lower-left based;
                            // authored/source UVs are top-left based.
                            let iy = min(max(Int((1 - display.y) * CGFloat(logicalHeight)), 0), logicalHeight - 1)
                            output[y * target.width + x] = input[iy * logicalWidth + ix]
                        }
                    }
                }
            }
            return .init(width: target.width, height: target.height, values: encoded)
        }

        private static func analysisSize(_ source: CGSize) -> (width: Int, height: Int) {
            let factor = min(1, 768 / max(source.width, source.height))
            return (max(1, Int((source.width * factor).rounded())),
                    max(1, Int((source.height * factor).rounded())))
        }

        private static func foregroundPolarity(_ plane: BackgroundMaskPlane) -> BackgroundMaskPlane {
            // Background normally owns the image border even when a close-up
            // subject fills most of the frame. Border polarity is therefore a
            // safer discriminator than total area for faces and products.
            return borderCoverage(plane) > 0.62 ? plane.inverted() : plane
        }

        private static func borderCoverage(_ plane: BackgroundMaskPlane) -> Double {
            guard plane.width > 1, plane.height > 1 else { return plane.coverage }
            var total = 0.0, count = 0.0
            let step = max(1, min(plane.width, plane.height) / 128)
            for x in stride(from: 0, to: plane.width, by: step) {
                total += Double(plane.value(x: x, y: 0)) / 255
                total += Double(plane.value(x: x, y: plane.height - 1)) / 255
                count += 2
            }
            for y in stride(from: step, to: max(step, plane.height - step), by: step) {
                total += Double(plane.value(x: 0, y: y)) / 255
                total += Double(plane.value(x: plane.width - 1, y: y)) / 255
                count += 2
            }
            return count > 0 ? total / count : plane.coverage
        }

        private static func isMeaningful(_ plane: BackgroundMaskPlane) -> Bool {
            plane.coverage >= 0.002 && plane.coverage <= 0.995
        }

    }
}
