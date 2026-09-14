import XCTest
@testable import GradeLab

final class AudioEditingTests: XCTestCase {
    private func project() -> VideoProject {
        .init(sourceURL: URL(fileURLWithPath: "/tmp/audio-tests.mov"), displayName: "Audio", metadata: makeVideoMetadata(durationSeconds: 10))
    }
    func testSeparationPreservesPictureAndInheritedSoundSettings() throws {
        var p = project()
        var video = p.timeline.firstVideoClip!
        video.embeddedAudio = .init(volume: 0.3, isMuted: true)
        try TimelineEditing.replace(video.id, with: [video], in: &p)
        let id = try AudioEditing.separate(video.id, in: &p)
        let audio = try XCTUnwrap(p.timeline.audioClip(id: id))
        XCTAssertEqual(audio.volume, 0.3); XCTAssertTrue(audio.isMuted)
        XCTAssertEqual(audio.sourceRange, video.sourceRange)
        XCTAssertEqual(audio.placement.timelineStart, video.placement.timelineStart)
        XCTAssertNil(p.timeline.videoClip(id: video.id)?.embeddedAudio)
        let separated = p
        XCTAssertThrowsError(try AudioEditing.separate(video.id, in: &p))
        XCTAssertEqual(p, separated)
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(p)), p)
    }
    func testSplitDeleteMoveDoesNotRippleVideo() throws {
        var p = project()
        let id = try AudioEditing.separate(p.timeline.firstVideoClip!.id, in: &p)
        let picture = p.timeline.firstVideoClip!
        let right = try AudioEditing.split(id, at: .seconds(3), in: &p)
        try AudioEditing.replace(id, with: [], in: &p)
        XCTAssertEqual(p.timeline.audioClip(id: right)?.placement.timelineStart, try .seconds(3))
        try AudioEditing.edit(right, operation: .move, to: .seconds(1), in: &p)
        XCTAssertEqual(p.timeline.audioClip(id: right)?.sourceRange.start, try .seconds(3))
        XCTAssertEqual(p.timeline.firstVideoClip, picture)
    }
    func testTrimClampsToSourceAndLockRejectsAtomically() throws {
        var p = project()
        let id = try AudioEditing.separate(p.timeline.firstVideoClip!.id, in: &p)
        try AudioEditing.edit(id, operation: .trimEnd, to: .seconds(100), clamping: true, in: &p)
        XCTAssertEqual(p.timeline.audioClip(id: id)?.sourceRange.duration, try .seconds(10))
        try AudioEditing.edit(id, operation: .trimStart, to: .seconds(100), clamping: true, in: &p)
        XCTAssertEqual(p.timeline.audioClip(id: id)?.placement.duration, p.canvas.frameDuration)
        p.timeline.tracks[1].isLocked = true
        let before = p
        XCTAssertThrowsError(try AudioEditing.edit(id, operation: .move, to: .zero, in: &p))
        XCTAssertEqual(p, before)
    }
    func testOverlappingPasteUsesNewTrackAndAudioEdgesSnap() throws {
        var p = project()
        let id = try AudioEditing.separate(p.timeline.firstVideoClip!.id, in: &p)
        let audio = p.timeline.audioClip(id: id)!
        let pasted = try AudioEditing.paste(audio, at: .seconds(5), trackID: audio.placement.trackID, in: &p)
        XCTAssertNotEqual(p.timeline.audioClip(id: pasted)?.placement.trackID, audio.placement.trackID)
        let display = p.timeline.items.compactMap(TimelineDisplayClip.init)
        XCTAssertEqual(TimelineEditing.snapPlayhead(14.96, clips: display, markers: [], tolerance: 0.1), 15)
        _ = try TimelineEditing.clips(in: p)
    }
}

/// Audio fades: what actually gets applied, and how they survive editing.
final class AudioFadeTests: XCTestCase {
    func testNoFadeIsStoredByDefault() {
        let clip = AudioClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero,
                                              duration: try! TimelineTime.seconds(10)),
                             assetID: UUID(), sourceRange: .init(start: .zero, duration: try! TimelineTime.seconds(10)))
        XCTAssertNil(clip.fadeIn)
        XCTAssertNil(clip.fadeOut)
        let resolved = AudioFade.resolved(duration: 10, fadeIn: nil, fadeOut: nil)
        XCTAssertEqual(resolved.rise, 0)
        XCTAssertEqual(resolved.fall, 0)
    }

    func testFadesAreClampedToTheClip() {
        let resolved = AudioFade.resolved(duration: 2, fadeIn: 5, fadeOut: 0)
        XCTAssertEqual(resolved.rise, 2, accuracy: 0.0001, "a fade cannot outlast its clip")
    }

    /// Two fades that overlap would each be reading a level the other is still
    /// changing, so they are scaled to meet exactly.
    func testOverlappingFadesAreScaledToMeet() {
        let resolved = AudioFade.resolved(duration: 4, fadeIn: 3, fadeOut: 3)
        XCTAssertEqual(resolved.rise + resolved.fall, 4, accuracy: 0.0001)
        XCTAssertEqual(resolved.rise, 2, accuracy: 0.0001)
        XCTAssertEqual(resolved.fall, 2, accuracy: 0.0001)
    }

    func testNegativeAndNonFiniteFadesAreIgnored() {
        XCTAssertEqual(AudioFade.resolved(duration: 5, fadeIn: -1, fadeOut: .nan).rise, 0)
        XCTAssertEqual(AudioFade.resolved(duration: 5, fadeIn: -1, fadeOut: .nan).fall, 0)
        XCTAssertEqual(AudioFade.resolved(duration: 0, fadeIn: 1, fadeOut: 1).rise, 0,
                       "a zero-length clip has nothing to fade")
    }

    func testFadesAreCappedAtTheOfferedMaximum() {
        let resolved = AudioFade.resolved(duration: 600, fadeIn: 60, fadeOut: 0)
        XCTAssertEqual(resolved.rise, AudioFade.maximum, accuracy: 0.0001)
    }

    func testProjectsSavedBeforeFadesStillDecodeUnfaded() throws {
        let json = """
        {"placement":{"id":"\(UUID().uuidString)","trackID":"\(UUID().uuidString)",
        "timelineStart":{"value":0,"timescale":240000},
        "duration":{"value":240000,"timescale":240000},"isEnabled":true,"isLocked":false},
        "assetID":"\(UUID().uuidString)",
        "sourceRange":{"start":{"value":0,"timescale":240000},
        "duration":{"value":240000,"timescale":240000}},"volume":1,"isMuted":false}
        """
        let clip = try JSONDecoder().decode(AudioClip.self, from: Data(json.utf8))
        XCTAssertNil(clip.fadeIn)
        XCTAssertNil(clip.fadeOut)
    }

    func testAFadeSurvivesSaveAndReload() throws {
        var clip = AudioClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero,
                                              duration: try TimelineTime.seconds(8)),
                             assetID: UUID(), sourceRange: .init(start: .zero, duration: try TimelineTime.seconds(8)))
        clip.fadeIn = 1.5
        clip.fadeOut = 2
        let reloaded = try JSONDecoder().decode(AudioClip.self, from: try JSONEncoder().encode(clip))
        XCTAssertEqual(reloaded.fadeIn, 1.5)
        XCTAssertEqual(reloaded.fadeOut, 2)
    }

    /// A fade belongs to the edge it was drawn on. Copying both onto both halves
    /// would leave a fade-out in the middle of the sound.
    func testSplittingKeepsEachFadeOnItsOwnEdge() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/audio-tests.mov"),
                                   displayName: "Audio", metadata: makeVideoMetadata(durationSeconds: 10))
        let id = try AudioEditing.separate(try XCTUnwrap(project.timeline.firstVideoClip?.id), in: &project)
        var clip = try AudioEditing.editable(id, in: project)
        clip.fadeIn = 0.5
        clip.fadeOut = 0.5
        try AudioEditing.replace(id, with: [clip], in: &project)

        let rightID = try AudioEditing.split(id, at: try TimelineTime.seconds(2), in: &project)
        let left = try AudioEditing.editable(id, in: project)
        let right = try AudioEditing.editable(rightID, in: project)
        XCTAssertEqual(left.fadeIn, 0.5, "the opening fade stays on the first half")
        XCTAssertNil(left.fadeOut, "the closing fade is no longer on an outside edge")
        XCTAssertNil(right.fadeIn)
        XCTAssertEqual(right.fadeOut, 0.5, "the closing fade stays on the second half")
    }
}
