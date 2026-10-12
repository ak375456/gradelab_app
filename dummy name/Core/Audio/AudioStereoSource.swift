@preconcurrency import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

/// A track tap receives the source channel count, before the final mixdown.
/// Upmix mono once to lossless stereo so balance works in preview and export.
/// Originals are untouched; disposable source-keyed files live only in Caches.
enum AudioStereoSource {
    static func asset(for track: AVAssetTrack, sourceURL: URL, sampleRate: Double) async throws -> AVURLAsset {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "v1|\(sourceURL.absoluteString)|\(track.trackID)|\(sampleRate)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            .appendingPathComponent("GradeLab/AudioStereo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(key).mov")
        if FileManager.default.fileExists(atPath: destination.path) { return AVURLAsset(url: destination) }
        let temporary = folder.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: sourceURL)
        let reader = try AVAssetReader(asset: asset)
        // Use a track from this retained asset, not an independently owned one.
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let source = tracks.first(where: { $0.trackID == track.trackID }) else { throw failure() }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: source, outputSettings: settings)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard reader.canAdd(output), writer.canAdd(input) else { throw failure() }
        reader.add(output); writer.add(input)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard writer.startWriting() else { throw writer.error ?? failure() }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? failure() }
        var decodedFrames = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? failure() }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.append(sample) else { throw writer.error ?? failure() }
            decodedFrames += frames
        }
        guard reader.status == .completed else { throw reader.error ?? failure() }
        guard decodedFrames > 0 else { throw failure() }
        input.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? failure() }
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { if !FileManager.default.fileExists(atPath: destination.path) { throw error } }
        return AVURLAsset(url: destination)
    }

    private static func failure() -> NSError {
        NSError(domain: "GradeLab.AudioStereo", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not prepare mono audio for stereo editing. Check available storage and try again.")])
    }
}
