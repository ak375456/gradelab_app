@preconcurrency import AVFoundation
import Metal
import Foundation
import CoreImage
import ImageIO

/// Run with Scripts/validate-apple-log-layers.sh [camera-clip.mov]. With a clip,
/// captures the actual frames AVFoundation hands the production compositor and
/// compares their native planes against a direct decode. No appearance-based
/// inference or synthetic file is presented as a camera measurement.
@main
struct ValidateAppleLogLayers {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let device = MTLCreateSystemDefaultDevice()!
        let source = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let effects = try String(contentsOfFile: "dummy name/Metal/EffectShaders.metal", encoding: .utf8)
        let library = try await device.makeLibrary(source: source + "\n" + effects, options: nil)
        let context = try MetalContext(library: library)
        let harness = try AppleLogLayerHarness(context: context)
        let chart = try AppleLogLayerHarness.rawFrame()
        try checkPictures(chart, harness: harness, label: "synthetic reference ramp")
        for point in AppleLog.referencePoints {
            precondition(Int((AppleLog.encode(point.reflectance) * 1023).rounded()) == point.code10Bit)
            let frame = try AppleLogLayerHarness.rawFrame(code: UInt16(point.code10Bit))
            let result = try harness.render(frame)
            let rgb = AppleLog.rgb(fromYCbCr: SIMD3(Float(point.code10Bit) / 1023, 512.0 / 1023 - 0.5, 512.0 / 1023 - 0.5))
            for channel in 0..<3 {
                precondition(abs(result.working[channel] - AppleLog.toWorkingSpace(rgb[channel])) < 0.015)
            }
            print("PASS white-paper code \(point.code10Bit): working R = \(result.working[0])")
        }
        guard CommandLine.arguments.count > 1 else {
            print("NOT RUN: camera decode/tagging and layered preview/export. Supply a real, identified Apple Log clip to measure these.")
            return
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = try await VideoMetadataReader().read(from: url)
        guard asset.metadata.logProfileIdentifier.map(SourceColorProfile.fromLogIdentifier) == .appleLog else {
            throw GradeLabError.unsupportedExport("The supplied clip must identify itself as Apple Log, not Apple Log 2 or untagged footage.")
        }
        let nativeAsset = AVURLAsset(url: url)
        let track = try await nativeAsset.loadTracks(withMediaType: .video)[0]
        let directReader = try AVAssetReader(asset: nativeAsset)
        let directOutput = AVAssetReaderTrackOutput(track: track, outputSettings: ExportMediaSettings.videoReaderSettings(colorMode: .appleLog))
        if let range = asset.sourceRange { directReader.timeRange = range.cmTimeRange }
        directReader.add(directOutput)
        guard directReader.startReading(), let sample = directOutput.copyNextSampleBuffer(),
              let raw = CMSampleBufferGetImageBuffer(sample) else {
            throw directReader.error ?? GradeLabError.rendererInitializationFailed
        }
        try checkPictures(raw, harness: harness, label: "real camera frame")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("AppleLogLayers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var project = VideoProject(sourceURL: url, displayName: "Apple Log validation", metadata: asset.metadata,
                                   sourceRange: .init(start: asset.sourceRange?.start ?? .zero,
                                       duration: try .seconds(min(4, asset.sourceRange?.duration.seconds ?? asset.metadata.durationSeconds))),
                                   frameDuration: asset.frameDuration)
        let preview = try await SequenceComposition.buildLayers(project: project, forExport: false, context: context)
        let composition = preview.source.videoComposition!.mutableCopy() as! AVMutableVideoComposition
        precondition(composition.colorPrimaries == nil && composition.colorTransferFunction == nil && composition.colorYCbCrMatrix == nil,
                     "The capture must test the production tagging policy")
        composition.customVideoCompositorClass = AppleLogCaptureCompositor.self
        let reader = try AVAssetReader(asset: preview.source.asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: preview.source.compositionVideoTracks!,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        reader.add(output)
        guard reader.startReading(), let composedSample = output.copyNextSampleBuffer(),
              let composed = CMSampleBufferGetImageBuffer(composedSample),
              let captured = AppleLogCaptureCompositor.capture.first else {
            throw reader.error ?? GradeLabError.rendererInitializationFailed
        }
        let difference = comparePlanes(raw, captured)
        precondition(difference == 0, "Composition tagging changed camera samples by \(difference) 10-bit codes; stop and investigate tagging before judging the picture")
        print("PASS actual compositor input vs direct decode: worst difference \(difference) codes across both planes")
        try checkPictures(captured, harness: harness, label: "captured compositor frame")
        let previewSize = composition.renderSize
        let transform = LayerCompositor.transform(project.timeline.firstVideoClip!.transform,
                                                   metadata: asset.metadata, canvas: previewSize)
        let expectedPreview = try harness.render(captured, transform: transform, canvasSize: previewSize).display
        let previewDrift = AppleLogLayerHarness.worst(expectedPreview.map { min(max($0, 0), 1) }, bgraPixels(composed))
        precondition(previewDrift <= 1.0 / 255 + 0.002, "The actual AVFoundation compositor changed the picture: \(previewDrift)")
        print("PASS actual compositor output vs shader reference: max/channel \(previewDrift)")
        reader.cancelReading(); directReader.cancelReading()

        // Exercise the actual scheduling and delivery path at a bounded size.
        // This leaves the source file untouched and writes only in a temp folder.
        guard project.timeline.duration.seconds > 2 else {
            throw TimelineError.invalid("Use a clip longer than two seconds for transition validation.")
        }
        let firstID = project.timeline.firstVideoClip!.id
        let edit = try TimelineTime.seconds(min(2, project.timeline.duration.seconds / 2))
        _ = try TimelineTransitionEditing.apply(.crossDissolve, at: edit, preferredTrackID: nil, in: &project)
        project.canvas.width = 320; project.canvas.height = 180
        let duration = min(4, project.timeline.duration.seconds)
        let overlayTrack = UUID()
        var overlay = project.timeline.videoClip(id: firstID)!
        overlay.placement = .init(id: UUID(), trackID: overlayTrack, timelineStart: .zero,
                                  duration: overlay.placement.duration)
        overlay.transform.scale = 0.45; overlay.transform.rotationDegrees = 12; overlay.opacity = 0.6
        overlay.blendMode = .screen
        var mask = LayerMask(); mask.isEnabled = true
        overlay.layerMask = mask
        var animation = ClipAnimation()
        animation.update(.rotation) { track in
            track.set(.number(-12), at: .zero)
            track.set(.number(12), at: overlay.placement.duration)
        }
        overlay.animation = animation
        project.timeline.tracks.insert(.init(id: overlayTrack, name: "Masked overlay", kind: .videoOverlay, items: [.video(overlay)]), at: 0)
        let titleTrack = UUID()
        var title = TextClip(placement: .init(id: UUID(), trackID: titleTrack, timelineStart: .zero, duration: try .seconds(duration)))
        title.text = "Apple Log layers"; title.style.fontSize = 24
        project.timeline.tracks.insert(.init(id: titleTrack, name: "Text", kind: .text, items: [.text(title)]), at: 0)
        let wav = temp.appendingPathComponent("tone.wav")
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let samples = AVAudioFrameCount(duration * 44_100)
        let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: samples)!
        pcm.frameLength = samples
        for i in 0..<Int(samples) { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 330 / 44_100)) * 0.1 }
        do {
            let file = try AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false])
            try file.write(from: pcm)
        }
        let soundRange = TimelineRange(start: .zero, duration: try .seconds(duration))
        let sound = ProjectMediaAsset(id: UUID(), url: wav, sourceRange: soundRange, videoMetadata: nil,
                                     frameDuration: nil, audioName: "Validation tone")
        project.addAsset(sound)
        let audioTrack = UUID()
        let audioClip = AudioClip(placement: .init(id: UUID(), trackID: audioTrack, timelineStart: .zero,
            duration: soundRange.duration), assetID: sound.id, sourceRange: soundRange)
        project.timeline.tracks.append(.init(id: audioTrack, name: "Added audio", kind: .audio, items: [.audio(audioClip)]))

        let png = temp.appendingPathComponent("overlay.png")
        let artwork = CIImage(color: CIColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let cgImage = CIContext().createCGImage(artwork, from: artwork.extent)!
        let imageWriter = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(imageWriter, cgImage, nil)
        precondition(CGImageDestinationFinalize(imageWriter))
        let still = ProjectMediaAsset(id: UUID(), url: png, sourceRange: soundRange,
            videoMetadata: nil, frameDuration: nil, stillImage: .init(width: 32, height: 32))
        project.addAsset(still)
        let imageTrack = UUID()
        var imageClip = VideoClip(placement: .init(id: UUID(), trackID: imageTrack, timelineStart: .zero,
            duration: soundRange.duration), assetID: still.id, sourceRange: soundRange)
        imageClip.transform.scale = 0.2; imageClip.transform.positionX = 0.8
        project.timeline.tracks.insert(.init(id: imageTrack, name: "Image", kind: .videoOverlay, items: [.video(imageClip)]), at: 0)
        try project.validate()
        let layered = try await SequenceComposition.buildLayers(project: project, forExport: false, context: context)
        let playerReader = try AVAssetReader(asset: layered.source.asset)
        let playerOutput = AVAssetReaderVideoCompositionOutput(videoTracks: layered.source.compositionVideoTracks!,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        playerOutput.videoComposition = layered.source.videoComposition
        playerReader.timeRange = CMTimeRange(start: edit.cmTime, duration: CMTime(value: 1, timescale: 30))
        playerReader.add(playerOutput)
        guard playerReader.startReading(), playerOutput.copyNextSampleBuffer() != nil else {
            throw playerReader.error ?? GradeLabError.rendererInitializationFailed
        }
        playerReader.cancelReading()
        let exporter = try VideoExporter(context: context)
        let result = try await exporter.export(asset: asset, settings: .neutral, configuration: .maximumQuality,
            project: project, outputURL: temp.appendingPathComponent("layers.mov"))
        let report = try await ExportOutputInspector.verify(result, expecting: .sdrWide)
        precondition(report.bitDepth == 10)
        let audioTracks = try await AVURLAsset(url: result).loadTracks(withMediaType: .audio)
        precondition(audioTracks.count == 1, "The added audio must survive the mix and export")
        print("PASS two clips, transition, animated masked overlay, image, text and added audio: preview + \(report.summary)")
    }

    static func checkPictures(_ frame: CVPixelBuffer, harness: AppleLogLayerHarness, label: String) throws {
        var grade = GradeSettings.neutral; grade.exposure = -1.3; grade.temperature = 18; grade.saturation = 85
        for settings in [GradeSettings.neutral, grade] {
            let whole = try harness.render(frame, settings: settings)
            let tiles = try harness.render(frame, settings: settings, tile: 127)
            let direct = try harness.direct(frame, settings: settings)
            let drift = AppleLogLayerHarness.worst(whole.display, direct)
            precondition(drift < 0.002, "\(label) direct vs composited drift \(drift)")
            precondition(whole.display == tiles.display && whole.working == tiles.working, "Tiling changed the picture")
            print("PASS \(label), exposure \(settings.exposure): direct vs layers max/channel \(drift); whole vs tiles exact")
        }
    }

    static func bgraPixels(_ buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        return (0..<CVPixelBufferGetHeight(buffer)).flatMap { y in
            (0..<CVPixelBufferGetWidth(buffer)).flatMap { x in
                [2, 1, 0, 3].map { Float(bytes[y * row + x * 4 + $0]) / 255 }
            }
        }
    }

    static func comparePlanes(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Int {
        precondition(CVPixelBufferGetPixelFormatType(first) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
        precondition(CVPixelBufferGetPixelFormatType(second) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(first, .readOnly); CVPixelBufferLockBaseAddress(second, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly); CVPixelBufferUnlockBaseAddress(second, .readOnly) }
        var worst = 0
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidthOfPlane(first, plane), height = CVPixelBufferGetHeightOfPlane(first, plane)
            precondition(width == CVPixelBufferGetWidthOfPlane(second, plane) && height == CVPixelBufferGetHeightOfPlane(second, plane))
            let a = CVPixelBufferGetBaseAddressOfPlane(first, plane)!.assumingMemoryBound(to: UInt16.self)
            let b = CVPixelBufferGetBaseAddressOfPlane(second, plane)!.assumingMemoryBound(to: UInt16.self)
            let strideA = CVPixelBufferGetBytesPerRowOfPlane(first, plane) / 2
            let strideB = CVPixelBufferGetBytesPerRowOfPlane(second, plane) / 2
            for y in 0..<height {
                for x in 0..<(width * (plane == 0 ? 1 : 2)) {
                    worst = max(worst, abs(Int(a[y * strideA + x] >> 6) - Int(b[y * strideB + x] >> 6)))
                }
            }
        }
        return worst
    }
}

final class AppleLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    var first: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return frame }
    func store(_ buffer: CVPixelBuffer) { lock.lock(); defer { lock.unlock() }; if frame == nil { frame = buffer } }
}
final class AppleLogCaptureCompositor: AppleLogLayerCompositor, @unchecked Sendable {
    static let capture = AppleLogCapture()
    override func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        if let id = request.sourceTrackIDs.first, let frame = request.sourceFrame(byTrackID: id.int32Value) {
            Self.capture.store(frame)
        }
        super.startRequest(request)
    }
}
