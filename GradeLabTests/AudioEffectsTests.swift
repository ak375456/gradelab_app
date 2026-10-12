import XCTest
@testable import GradeLab

final class AudioEffectsTests: XCTestCase {
    func testOlderToneSettingsDecodeAndPresetsPreserveNewEffects() throws {
        let data = Data(#"{"pan":0.2,"bass":0,"mid":0,"treble":0,"lowCut":0,"highCut":20000,"isToneEnabled":true}"#.utf8)
        var settings = try JSONDecoder().decode(AudioProcessingSettings.self, from: data)
        XCTAssertNil(settings.compressor); XCTAssertNil(settings.ducking); XCTAssertNil(settings.echo)
        settings.compressor = .init(); settings.ducking = .init(sourceClipID: UUID())
        settings.echo = .init(); settings.reverb = .init(); settings.texture = .init(distortion: 0.2, crush: 0.3)
        let warm = settings.applying(.warm)
        XCTAssertEqual(warm.preset, .warm)
        XCTAssertEqual(warm.compressor, settings.compressor); XCTAssertEqual(warm.ducking, settings.ducking)
        XCTAssertEqual(warm.echo, settings.echo); XCTAssertEqual(warm.reverb, settings.reverb)
        XCTAssertEqual(warm.texture, settings.texture); XCTAssertEqual(warm.pan, 0.2)
        XCTAssertEqual(try JSONDecoder().decode(AudioProcessingSettings.self, from: JSONEncoder().encode(warm)), warm)
    }

    func testEffectBoundsRejectInvalidDocumentsAndSanitizeLiveValues() {
        let settings = AudioProcessingSettings(compressor: .init(ratio: .infinity), ducking: .init(attack: -1),
            echo: .init(feedback: 1.5), reverb: .init(size: .nan), texture: .init(crush: 4))
        XCTAssertFalse(settings.isValid)
        XCTAssertTrue(settings.sanitized.isValid)
        XCTAssertEqual(settings.sanitized.echo?.feedback, 0.8)
    }

    func testCompressorReducesLoudPeaksAndLinksStereoWithoutRaisingQuietAudio() {
        let settings = AudioProcessingSettings(compressor: .init(threshold: -20, ratio: 4, attack: 5, release: 100))
        let dsp = AudioDSP(); dsp.prepare(sampleRate: 48_000, channels: 2, settings: settings)
        var loud = 0.0, right = 0.0
        for _ in 0..<48_000 {
            dsp.beginFrame(inputPeak: 0.8)
            loud = dsp.process(0.8, channel: 0); right = dsp.process(0.2, channel: 1)
        }
        XCTAssertEqual(loud, pow(10, (-20 + (20 * log10(0.8) + 20) / 4) / 20), accuracy: 0.001)
        XCTAssertEqual(right / loud, 0.25, accuracy: 1e-9)
        var quiet = 0.0
        for _ in 0..<96_000 { dsp.beginFrame(inputPeak: 0.02); quiet = dsp.process(0.02, channel: 0) }
        XCTAssertEqual(quiet, 0.02, accuracy: 0.0001)
    }

    func testEchoTimingFeedbackAndReverbTailReset() {
        let dsp = AudioDSP()
        dsp.prepare(sampleRate: 48_000, channels: 1, settings: .init(echo: .init(mix: 0.4, time: 0.1, feedback: 0.5)))
        var values: [Double] = []
        for frame in 0..<14_401 { dsp.beginFrame(); values.append(dsp.process(frame == 0 ? 1 : 0, channel: 0)) }
        XCTAssertEqual(values[0], 0.6, accuracy: 1e-10)
        XCTAssertEqual(values[4_800], 0.4, accuracy: 1e-10)
        XCTAssertEqual(values[9_600], 0.2, accuracy: 1e-10)
        XCTAssertEqual(values[14_400], 0.1, accuracy: 1e-10)
        dsp.prepare(sampleRate: 48_000, channels: 1, settings: .init(reverb: .init(mix: 0.5, size: 0.8)))
        var first: [Double] = []
        for frame in 0..<24_000 { dsp.beginFrame(); first.append(dsp.process(frame == 0 ? 1 : 0, channel: 0)) }
        XCTAssertGreaterThan(first.dropFirst(1_000).reduce(0) { $0 + $1 * $1 }, 0.001)
        dsp.reset()
        for frame in 0..<24_000 { dsp.beginFrame(); XCTAssertEqual(dsp.process(frame == 0 ? 1 : 0, channel: 0), first[frame]) }
    }

    func testCreativeEffectsBypassExactlyAndRemainStableAtSupportedRates() {
        for rate in [8_000.0, 44_100, 48_000, 96_000] {
            let dsp = AudioDSP()
            let settings = AudioProcessingSettings(compressor: .init(), echo: .init(mix: 0.8, time: 0.04, feedback: 0.8),
                reverb: .init(mix: 0.8, size: 1), texture: .init(distortion: 1, crush: 1))
            dsp.prepare(sampleRate: rate, channels: 2, settings: settings)
            for frame in 0..<Int(rate) {
                let input = frame < 200 ? 0.8 * sin(Double(frame)) : 0
                dsp.beginFrame(inputPeak: abs(input))
                for channel in 0..<2 {
                    let output = dsp.process(input, channel: channel)
                    XCTAssertTrue(output.isFinite); XCTAssertLessThan(abs(output), 4)
                }
            }
            var bypass = settings
            bypass.compressor?.isEnabled = false; bypass.echo?.isEnabled = false
            bypass.reverb?.isEnabled = false; bypass.texture?.isEnabled = false
            dsp.configure(bypass); dsp.reset(); dsp.beginFrame(inputPeak: 0.2)
            XCTAssertEqual(dsp.process(0.2, channel: 0), 0.2, accuracy: 1e-12)
        }
    }

    @MainActor
    func testEffectsUndoRedoAndSurviveSplitSave() throws {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/audio-effects.mov"), displayName: "Effects",
                                   metadata: makeVideoMetadata(durationSeconds: 10))
        let model = try EditorViewModel(project: project); model.suspendPreviewForExport()
        model.changeAudioProcessing { $0.compressor = .init(); $0.echo = .init(); $0.reverb = .init(); $0.texture = .init(crush: 0.5) }
        model.flushGradeHistory()
        let effects = model.audioProcessing
        model.undo(); XCTAssertNil(model.audioProcessing.echo)
        model.redo(); XCTAssertEqual(model.audioProcessing, effects)
        model.applyAudioPreset(.telephone); XCTAssertEqual(model.audioProcessing.echo, effects.echo)
        var edited = model.project
        let id = try AudioEditing.separate(edited.timeline.firstVideoClip!.id, in: &edited)
        let second = try AudioEditing.split(id, at: .seconds(4), in: &edited)
        XCTAssertEqual(edited.timeline.audioClip(id: second)?.processing?.texture, effects.texture)
        try edited.validate()
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(edited)), edited)
    }
}
