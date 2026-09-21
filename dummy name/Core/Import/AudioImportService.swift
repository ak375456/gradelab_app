@preconcurrency import AVFoundation
import Foundation

enum AudioImportService {
    static func load(_ url: URL, store: ProjectStore = ProjectStore()) async throws -> ProjectMediaAsset {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc"].contains(ext) else {
            throw TimelineError.invalid(String(localized: "Choose an MP3, M4A, AAC, WAV or AIFF audio file."))
        }
        let destination = try await store.sourceImportURL(fileExtension: ext)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            let asset = AVURLAsset(url: destination)
            guard try await !asset.load(.hasProtectedContent) else { throw TimelineError.invalid(String(localized: "Protected audio cannot be imported.")) }
            let embeddedTracks = try await asset.loadTracks(withMediaType: .audio)
            let tracks = try await AudioTrackSelection.enabledTracks(from: embeddedTracks)
            guard !tracks.isEmpty else { throw TimelineError.invalid(String(localized: "This file contains no audio.")) }
            for track in tracks { _ = try await ExportSourceInspector.inspectAudioTrack(track) }
            let duration = try await TimelineTime(asset.load(.duration))
            guard duration > .zero else { throw TimelineError.invalid(String(localized: "This audio file is empty.")) }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(output) else { throw TimelineError.invalid(String(localized: "This audio format cannot be decoded on this device.")) }
            reader.add(output)
            guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
                throw reader.error ?? TimelineError.invalid(String(localized: "This audio file could not be decoded."))
            }
            reader.cancelReading()
            try Task.checkCancellation()
            return .init(id: UUID(), url: destination, sourceRange: .init(start: .zero, duration: duration),
                videoMetadata: nil, frameDuration: nil, audioName: url.deletingPathExtension().lastPathComponent)
        } catch {
            // Only the new, unreferenced import is removed on failure.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
