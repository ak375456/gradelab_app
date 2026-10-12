import XCTest
@testable import GradeLab

final class AudioProcessingTests: XCTestCase {
    @MainActor
    func testPresetUndoRedoAndResetKeepBasicSettings() throws {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/audio-model.mov"), displayName: "Audio",
                                   metadata: makeVideoMetadata(durationSeconds: 10))
        let model = try EditorViewModel(project: project)
        // Document editing is independent of a live decoder. Keep this fixture
        // suspended so undo doesn't try to open the deliberately absent movie.
        model.suspendPreviewForExport()
        model.changeAudio(volume: 0.6, muted: true, fadeIn: 1, fadeOut: 2)
        model.changeAudioProcessing { $0.pan = -0.4 }
        model.flushGradeHistory()
        model.applyAudioPreset(.telephone)
        XCTAssertEqual(model.audioProcessing.preset, .telephone)
        model.undo()
        XCTAssertEqual(model.audioProcessing.preset, .flat)
        XCTAssertEqual(model.audioProcessing.pan, -0.4)
        model.redo()
        XCTAssertEqual(model.audioProcessing.preset, .telephone)
        model.applyAudioPreset(.flat)
        XCTAssertEqual(model.audioProcessing.pan, -0.4)
        XCTAssertEqual(model.audioSettings?.volume, 0.6)
        XCTAssertEqual(model.audioSettings?.isMuted, true)
        XCTAssertEqual(model.audioSettings?.fadeIn, 1)
        XCTAssertEqual(model.audioSettings?.fadeOut, 2)
    }

    func testOldLinkedAudioDecodesWithOriginalTone() throws {
        let original = try JSONDecoder().decode(EmbeddedAudio.self, from: Data(#"{"volume":0.7,"isMuted":false}"#.utf8))
        XCTAssertNil(original.processing)
        XCTAssertEqual(original.volume, 0.7)
    }

    func testPresetsPreservePanAndBecomeCustomAfterAnEdit() {
        let panned = AudioProcessingSettings(pan: -0.6)
        var telephone = panned.applying(.telephone)
        XCTAssertEqual(telephone.pan, -0.6)
        XCTAssertEqual(telephone.preset, .telephone)
        telephone.mid += 1
        XCTAssertNil(telephone.preset)
        telephone.isToneEnabled = false
        XCTAssertTrue(telephone.hasTone)
    }

    func testSettingsSurviveSeparationSplitCopyAndSave() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/audio.mov"), displayName: "Audio",
                                   metadata: makeVideoMetadata(durationSeconds: 10))
        var video = try XCTUnwrap(project.timeline.firstVideoClip)
        let processing = AudioProcessingSettings(pan: 0.4).applying(.warm)
        video.embeddedAudio = .init(volume: 0.6, fadeIn: 1, fadeOut: 2, processing: processing)
        try TimelineEditing.replace(video.id, with: [video], in: &project)
        let id = try AudioEditing.separate(video.id, in: &project)
        XCTAssertEqual(project.timeline.audioClip(id: id)?.processing, processing)
        XCTAssertEqual(project.timeline.audioClip(id: id)?.fadeIn, 1)
        XCTAssertEqual(project.timeline.audioClip(id: id)?.fadeOut, 2)
        let right = try AudioEditing.split(id, at: .seconds(4), in: &project)
        XCTAssertEqual(project.timeline.audioClip(id: right)?.processing, processing)
        XCTAssertEqual(project.timeline.audioClip(id: id)?.processing, processing)
        let copy = try AudioEditing.paste(project.timeline.audioClip(id: right)!, at: .zero, trackID: nil, in: &project)
        XCTAssertEqual(project.timeline.audioClip(id: copy)?.processing, processing)
        try project.validate()
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project)), project)
    }

    func testInvalidAudioSettingsAreRejectedForBothClipTypes() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/audio.mov"), displayName: "Audio",
                                   metadata: makeVideoMetadata(durationSeconds: 10))
        var video = try XCTUnwrap(project.timeline.firstVideoClip)
        video.embeddedAudio?.processing = .init(pan: 4)
        try TimelineEditing.replace(video.id, with: [video], in: &project)
        XCTAssertThrowsError(try project.validate())
        video.embeddedAudio?.processing = .init(bass: .nan)
        try TimelineEditing.replace(video.id, with: [video], in: &project)
        XCTAssertThrowsError(try project.validate())
        video.embeddedAudio?.processing = .init()
        try TimelineEditing.replace(video.id, with: [video], in: &project)
        let id = try AudioEditing.separate(video.id, in: &project)
        var audio = project.timeline.audioClip(id: id)!
        audio.processing = .init(highCut: -10)
        try AudioEditing.replace(id, with: [audio], in: &project)
        XCTAssertThrowsError(try project.validate())
    }

    func testToneBypassKeepsBalanceAndResetClearsFilterHistory() {
        let dsp = AudioDSP()
        var settings = AudioVoicePreset.telephone.settings
        settings.pan = -1; settings.isToneEnabled = false
        dsp.prepare(sampleRate: 48_000, channels: 2, settings: settings)
        dsp.beginFrame()
        XCTAssertEqual(dsp.process(0.2, channel: 0), 0.2, accuracy: 1e-12)
        XCTAssertEqual(dsp.process(0.2, channel: 1), 0, accuracy: 1e-12)
        settings.isToneEnabled = true
        dsp.configure(settings); dsp.reset()
        dsp.beginFrame()
        let first = dsp.process(0.2, channel: 0)
        for _ in 0..<100 { dsp.beginFrame(); _ = dsp.process(0, channel: 0) }
        dsp.reset(); dsp.beginFrame()
        XCTAssertEqual(dsp.process(0.2, channel: 0), first)
    }
}
