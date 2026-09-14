@preconcurrency import AVFoundation
import Metal
import Foundation

/// Runs the production exporter on a supplied camera movie, then decodes every
/// exported audio sample. See validate-camera-audio-export.sh.
@main struct ValidateCameraAudioExport {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass the path to the camera movie to validate.")
        }
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = try await VideoMetadataReader().read(from: sourceURL)
        let shader = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let effects = try String(contentsOfFile: "dummy name/Metal/EffectShaders.metal", encoding: .utf8)
        let device = MTLCreateSystemDefaultDevice()!
        let library = try await device.makeLibrary(source: shader + "\n" + effects, options: nil)
        let context = try MetalContext(library: library)
        let project = VideoProject(sourceURL: sourceURL, displayName: sourceURL.lastPathComponent,
                                   metadata: asset.metadata)
        let exporter = try VideoExporter(context: context)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-audio-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await exporter.export(
            asset: asset, settings: .neutral, configuration: .maximumQuality,
            project: project, outputURL: output
        )
        let exported = AVURLAsset(url: result)
        let tracks = try await exported.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 1, "Expected the enabled stereo camera presentation")
        let description = try await tracks[0].load(.formatDescriptions)[0]
        let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
        precondition(stream.mFormatID == kAudioFormatMPEG4AAC)
        precondition(stream.mChannelsPerFrame == 2 && stream.mSampleRate == 48_000)
        let reader = try AVAssetReader(asset: exported)
        let audio = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: ExportMediaSettings.audioReaderSettings())
        reader.add(audio)
        guard reader.startReading() else { throw reader.error! }
        var frames = 0
        while let sample = audio.copyNextSampleBuffer() {
            frames += CMSampleBufferGetNumSamples(sample)
        }
        precondition(reader.status == .completed, "Exported AAC must decode completely")
        let duration = try await exported.load(.duration).seconds
        guard abs(Double(frames) / stream.mSampleRate - duration) < 0.1 else {
            throw GradeLabError.exportFailed("Audio decoded \(frames) frames for a \(duration)s movie.")
        }
        let video = try await exported.loadTracks(withMediaType: .video)[0]
        let videoDescription = try await video.load(.formatDescriptions)[0]
        precondition(CMFormatDescriptionGetMediaSubType(videoDescription) == kCMVideoCodecType_HEVC)
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoDescription)
        print("PASS production project export: HEVC MOV \(dimensions.width)x\(dimensions.height), \(duration)s; stereo AAC 48kHz decoded \(frames) frames")
    }
}
