@preconcurrency import AVFoundation
import XCTest
@testable import GradeLab

final class AudioProcessingExportTests: XCTestCase {
    func testMonoEQAndPanMatchTheProductionAACExport() async throws {
        try await verifyExport(advanced: false)
    }
    func testCompressorDuckingAndCreativeEffectsMatchTheProductionAACExport() async throws {
        try await verifyExport(advanced: true)
    }
    private func verifyExport(advanced: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-export-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let videoURL = folder.appendingPathComponent("source.mov")
        try await writeVideo(videoURL)
        let source = try await VideoMetadataReader().read(from: videoURL)
        var project = VideoProject(sourceURL: videoURL, displayName: "Audio export", metadata: source.metadata)
        let soundURL = folder.appendingPathComponent("voice.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for frame in 0..<48_000 {
            buffer.floatChannelData![0][frame] = Float(0.15 * sin(2 * .pi * 1_000 * Double(frame) / 48_000))
        }
        do {
            let file = try AVAudioFile(forWriting: soundURL, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
            ])
            try file.write(from: buffer)
        }
        let media = ProjectMediaAsset(id: UUID(), url: soundURL,
            sourceRange: .init(start: .zero, duration: try .seconds(1)),
            videoMetadata: nil, frameDuration: nil, audioName: "Voice")
        project.addAsset(media)
        let trackID = UUID()
        let voiceID = UUID()
        let processing = advanced
            ? AudioProcessingSettings(pan: 1, mid: 6, compressor: .init(threshold: -32, ratio: 2),
                ducking: .init(sourceClipID: voiceID, reduction: 6, attack: 0.02, release: 0.1, threshold: -55),
                echo: .init(mix: 0.2, time: 0.08, feedback: 0.2), reverb: .init(mix: 0.15, size: 0.3),
                texture: .init(distortion: 0.05, crush: 0.1))
            : AudioProcessingSettings(pan: 1, mid: 6)
        let audio = AudioClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: .zero,
            duration: try .seconds(1)), assetID: media.id, sourceRange: media.sourceRange,
            volume: 0.5, fadeIn: 0.1, fadeOut: 0.1, processing: processing)
        project.timeline.tracks.append(.init(id: trackID, name: "Voice", kind: .audio, items: [.audio(audio)]))
        if advanced {
            let voiceLayer = UUID()
            let voice = AudioClip(placement: .init(id: voiceID, trackID: voiceLayer, timelineStart: .zero,
                duration: try .seconds(1)), assetID: media.id, sourceRange: media.sourceRange,
                volume: 0.1, processing: .init(pan: -1))
            project.timeline.tracks.append(.init(id: voiceLayer, name: "Voice source", kind: .audio, items: [.audio(voice)]))
        }
        let context = try MetalContext()
        let sequence = try await SequenceComposition.build(project: project, forExport: false, context: context)
        let preview = try await levels(sequence.source.asset, mix: sequence.source.audioMix)
        let exporter = try VideoExporter(context: context)
        let url = try await exporter.export(asset: source, settings: .neutral, configuration: .init(codec: .h264),
                                            project: project, outputURL: folder.appendingPathComponent("result.mov"))
        let exported = try await levels(AVURLAsset(url: url), mix: nil)
        if !advanced {
            XCTAssertLessThan(preview.left, preview.right * 0.001)
            XCTAssertLessThan(exported.left, exported.right * 0.01)
            XCTAssertGreaterThan(exported.right, 0.09, "The +6 dB mid boost must compensate for 50% volume.")
        } else { XCTAssertGreaterThan(exported.right, 0.005) }
        XCTAssertEqual(exported.right / preview.right, 1, accuracy: 0.12)
    }

    private func writeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        CVPixelBufferGetBaseAddress(image)!.initializeMemory(as: UInt8.self, repeating: 80,
            count: CVPixelBufferGetBytesPerRow(image) * 64)
        CVPixelBufferUnlockBaseAddress(image, [])
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard adaptor.append(image, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private func levels(_ asset: AVAsset, mix: AVAudioMix?) async throws -> (left: Double, right: Double) {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)

        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix; reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var left = 0.0, right = 0.0, frames = 0
        while let sample = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(sample) {
            let count = CMSampleBufferGetNumSamples(sample)
            var samples = [Float](repeating: 0, count: count * 2)
            samples.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * 8, destination: $0.baseAddress!)
            }
            let firstTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for frame in 0..<count where (0.4..<0.6).contains(firstTime + Double(frame) / 48_000) {
                left += pow(Double(samples[frame * 2]), 2)
                right += pow(Double(samples[frame * 2 + 1]), 2)
                frames += 1
            }
        }
        if let error = reader.error { throw error }
        XCTAssertGreaterThan(frames, 8_000)
        return (sqrt(left / Double(max(1, frames))), sqrt(right / Double(max(1, frames))))
    }
}
