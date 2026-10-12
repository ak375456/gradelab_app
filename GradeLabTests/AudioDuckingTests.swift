@preconcurrency import AVFoundation
import XCTest
@testable import GradeLab

final class AudioDuckingTests: XCTestCase {
    func testEnvelopeTransitionsOverlapAndSilence() {
        let settings = AudioDuckingSettings(reduction: 20, attack: 0.2, release: 0.5)
        let envelope = AudioDuckingEnvelope(intervals: [.init(start: 1, end: 2), .init(start: 2.2, end: 3)], settings: settings)
        XCTAssertEqual(envelope.gain(at: 0), 1)
        XCTAssertEqual(envelope.gain(at: 0.9), 0.55, accuracy: 1e-10)
        XCTAssertEqual(envelope.gain(at: 1.5), 0.1, accuracy: 1e-10)
        XCTAssertLessThan(envelope.gain(at: 2.1), 0.3)
        XCTAssertEqual(envelope.gain(at: 3.25), 0.55, accuracy: 1e-10)
        XCTAssertEqual(envelope.gain(at: 4), 1)
        let activity = AudioActivityEnvelope(start: 0, step: 0.025, peaks: [0, 0, 0.4, 0.3, 0, 0, 0.2, 0])
        XCTAssertEqual(activity.intervals(threshold: -20, level: { _ in 1 }).count, 1, "Short speech pauses are held")
        XCTAssertTrue(activity.intervals(threshold: -20, level: { _ in 0 }).isEmpty)
    }

    func testAnalyzedCompositionDucksMusicAndRecoversInPauses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ducking-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let voiceURL = folder.appendingPathComponent("voice.caf"), musicURL = folder.appendingPathComponent("music.caf")
        try writeAudio(voiceURL, voice: true); try writeAudio(musicURL, voice: false)
        let voiceAsset = AVURLAsset(url: voiceURL), musicAsset = AVURLAsset(url: musicURL)
        let voiceSource = try await voiceAsset.loadTracks(withMediaType: .audio)[0]
        let musicSource = try await musicAsset.loadTracks(withMediaType: .audio)[0]
        let composition = AVMutableComposition()
        let voiceTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 48_000))
        try voiceTrack.insertTimeRange(range, of: voiceSource, at: .zero)
        try musicTrack.insertTimeRange(range, of: musicSource, at: .zero)
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/ducking.mov"), displayName: "Ducking",
                                   metadata: makeVideoMetadata(durationSeconds: 3))
        let voiceMedia = ProjectMediaAsset(id: UUID(), url: voiceURL, sourceRange: .init(start: .zero, duration: try .seconds(3)),
                                          videoMetadata: nil, frameDuration: nil, audioName: "Voice")
        let musicMedia = ProjectMediaAsset(id: UUID(), url: musicURL, sourceRange: voiceMedia.sourceRange,
                                          videoMetadata: nil, frameDuration: nil, audioName: "Music")
        project.addAsset(voiceMedia); project.addAsset(musicMedia)
        let voiceID = UUID(), musicID = UUID(), voiceLayer = UUID(), musicLayer = UUID()
        var voice = AudioClip(placement: .init(id: voiceID, trackID: voiceLayer, timelineStart: .zero, duration: try .seconds(3)),
                              assetID: voiceMedia.id, sourceRange: voiceMedia.sourceRange)
        var music = AudioClip(placement: .init(id: musicID, trackID: musicLayer, timelineStart: .zero, duration: try .seconds(3)),
                              assetID: musicMedia.id, sourceRange: musicMedia.sourceRange, volume: 0.7, fadeIn: 0.2, fadeOut: 0.2,
                              processing: .init(ducking: .init(sourceClipID: voiceID, reduction: 20, attack: 0.1, release: 0.2)))
        project.timeline.tracks += [.init(id: voiceLayer, name: "Voice", kind: .audio, items: [.audio(voice)]),
                                    .init(id: musicLayer, name: "Music", kind: .audio, items: [.audio(music)])]
        var routing = TimelineAudioMix(); routing.clipsByTrack = [voiceTrack.trackID: voiceID, musicTrack.trackID: musicID]
        try await routing.prepareDucking(project, composition: composition)
        let mix = try routing.makeMix(project)
        let normal = try await rms(composition, track: musicTrack, mix: mix, at: 0.4)
        let ducked = try await rms(composition, track: musicTrack, mix: mix, at: 1.0)
        let recovered = try await rms(composition, track: musicTrack, mix: mix, at: 2.5)
        XCTAssertEqual(ducked / normal, 0.1, accuracy: 0.01)
        XCTAssertEqual(recovered / normal, 1, accuracy: 0.01)
        let faded = try await rms(composition, track: musicTrack, mix: mix, at: 0.01)
        XCTAssertLessThan(faded, normal * 0.4)
        voice.isMuted = true; try AudioEditing.replace(voiceID, with: [voice], in: &project)
        let mutedSource = try await rms(composition, track: musicTrack, mix: routing.makeMix(project), at: 1.0)
        XCTAssertEqual(mutedSource / normal, 1, accuracy: 0.01)
        music.processing?.ducking?.sourceClipID = UUID()
        try AudioEditing.replace(musicID, with: [music], in: &project)
        XCTAssertNil(routing.duckingEnvelope(for: musicID, in: project))
        let missingSource = try await rms(composition, track: musicTrack, mix: routing.makeMix(project), at: 1.0)
        XCTAssertEqual(missingSource / normal, 1, accuracy: 0.01)
        voiceTrack.scaleTimeRange(range, toDuration: CMTime(seconds: 1.5, preferredTimescale: 48_000))
        let retimed = try await AudioActivityEnvelope.analyze(asset: composition, tracks: [voiceTrack], start: 0, duration: 1.5)
        let activity = retimed.intervals(threshold: -35, level: { _ in 1 })
        XCTAssertEqual(try XCTUnwrap(activity.first).start, 0.4, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(activity.last).end, 0.65, accuracy: 0.03)
    }

    private func writeAudio(_ url: URL, voice: Bool) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000)!
        buffer.frameLength = 144_000
        for i in 0..<144_000 {
            let time = Double(i) / 48_000
            let value = voice && !(0.8..<1.3).contains(time) ? 0 : Float(0.2 * sin(2 * .pi * 440 * time))
            for channel in 0..<2 { buffer.floatChannelData![channel][i] = value }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
    }

    private func rms(_ asset: AVAsset, track: AVAssetTrack, mix: AVAudioMix, at time: Double) async throws -> Double {
        let reader = try AVAssetReader(asset: asset)

        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix; reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var energy = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer(), let data = CMSampleBufferGetDataBuffer(sample) {
            var values = [Float](repeating: 0, count: CMSampleBufferGetNumSamples(sample) * 2)
            values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for i in values.indices where (time..<(time + 0.1)).contains(start + Double(i / 2) / 48_000) {
                energy += Double(values[i]) * Double(values[i]); count += 1
            }
        }
        if let error = reader.error { throw error }
        XCTAssertGreaterThan(count, 0)
        return sqrt(energy / Double(max(1, count)))
    }
}
