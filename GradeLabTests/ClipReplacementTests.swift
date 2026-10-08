import AVFoundation
import CoreMedia
import XCTest
@testable import GradeLab

final class ClipReplacementTests: XCTestCase {
    private func sequence() throws -> (VideoProject, UUID, UUID) {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/original.mov"),
            displayName: "Replacement", metadata: makeVideoMetadata(durationSeconds: 15))
        let first = project.timeline.firstVideoClip!.id
        let middle = try TimelineEditing.split(first, at: .seconds(5), in: &project)
        let last = try TimelineEditing.split(middle, at: .seconds(10), in: &project)
        return (project, middle, last)
    }

    private func asset(_ duration: Double = 10, start: Double = 0, audio: Bool = true) throws -> ProjectMediaAsset {
        .init(id: UUID(), url: URL(fileURLWithPath: "/tmp/replacement.mov"),
              sourceRange: try .init(start: .seconds(start), duration: .seconds(duration)),
              videoMetadata: makeVideoMetadata(durationSeconds: duration, hasAudio: audio),
              frameDuration: try .seconds(1.0 / 30))
    }

    func testTenSecondSourceKeepsFiveSecondSlotAndEdits() throws {
        var (project, middle, last) = try sequence()
        var edited = project.timeline.videoClip(id: middle)!
        edited.gradeSettings.exposure = 0.4
        edited.transform.scale = 1.3
        edited.opacity = 0.8
        edited.layerMask = LayerMask(isEnabled: true)
        edited.animation = .init(tracks: [.init(property: .scale, keyframes: [
            .init(time: try .seconds(2), value: .number(1.6))])])
        edited.embeddedAudio?.volume = 0.45
        try TimelineEditing.replace(middle, with: [edited], in: &project)
        let replacement = try asset()
        let plan = try ClipReplacement.prepare(clipID: middle, asset: replacement, timing: .keepDuration, in: project)

        XCTAssertEqual(plan.clip.id, middle)
        XCTAssertEqual(plan.clip.assetID, replacement.id)
        XCTAssertEqual(plan.clip.placement, edited.placement)
        XCTAssertEqual(plan.clip.sourceRange, .init(start: .zero, duration: try .seconds(5)))
        XCTAssertEqual(plan.clip.gradeSettings, edited.gradeSettings)
        XCTAssertEqual(plan.clip.transform, edited.transform)
        XCTAssertEqual(plan.clip.layerMask, edited.layerMask)
        XCTAssertEqual(plan.clip.opacity, edited.opacity)
        XCTAssertEqual(plan.clip.animation, edited.animation)
        XCTAssertEqual(plan.clip.embeddedAudio?.volume, 0.45)
        XCTAssertEqual(plan.project.timeline.videoClip(id: last), project.timeline.videoClip(id: last))
        XCTAssertEqual(plan.durationChange, .zero)
        XCTAssertEqual(project.assets.count, 1, "Preparation must not mutate the original document.")
    }

    func testFullTenSecondsPushesFollowingClipFiveSecondsLater() throws {
        let (project, middle, last) = try sequence()
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .useFullClip, in: project)
        XCTAssertEqual(plan.clip.placement.timelineStart, try .seconds(5))
        XCTAssertEqual(plan.clip.placement.duration, try .seconds(10))
        XCTAssertEqual(plan.project.timeline.videoClip(id: last)?.placement.timelineStart, try .seconds(15))
        XCTAssertEqual(plan.project.timeline.duration, try .seconds(20))
        XCTAssertEqual(plan.durationChange, try .seconds(5))
        XCTAssertEqual(plan.project.timeline.videoClip(id: last)?.embeddedAudio,
                       project.timeline.videoClip(id: last)?.embeddedAudio)
    }

    func testStartingFrameUsesRealSourceRangeOrigin() throws {
        let (project, middle, _) = try sequence()
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(10, start: 2),
            timing: .keepDuration, sourceStart: .seconds(6), in: project)
        XCTAssertEqual(plan.clip.sourceRange.start, try .seconds(6))
        XCTAssertEqual(plan.clip.sourceRange.duration, try .seconds(5))
        XCTAssertEqual(try plan.clip.sourceTime(at: .seconds(5)), try .seconds(6))
    }

    func testShortVideoHoldsLastFrameWithoutMovingNeighbors() throws {
        let (project, middle, last) = try sequence()
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(3), timing: .keepDuration, in: project)
        XCTAssertTrue(plan.holdsLastFrame)
        XCTAssertEqual(plan.clip.placement.duration, try .seconds(5))
        XCTAssertEqual(plan.clip.timeMap.timelineDuration, try .seconds(5))
        XCTAssertEqual(plan.project.timeline.videoClip(id: last)?.placement.timelineStart, try .seconds(10))
        let frame = try plan.clip.sourceTime(at: .seconds(9.5))
        XCTAssertGreaterThanOrEqual(frame.seconds, 3 - 1.0 / 30)
        XCTAssertLessThan(frame.seconds, 3)
        try plan.project.validate()
    }

    func testLastFrameHoldSilencesAudioOnlyDuringTheHold() throws {
        let (project, middle, _) = try sequence()
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(3), timing: .keepDuration, in: project)
        let mix = TimelineAudioMix(clipsByTrack: [1: middle]).makeMix(plan.project)
        let parameter = try XCTUnwrap(mix.inputParameters.first)
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange.invalid
        XCTAssertTrue(parameter.getVolumeRamp(for: CMTime(seconds: 6, preferredTimescale: 600),
            startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 1)
        XCTAssertTrue(parameter.getVolumeRamp(for: CMTime(seconds: 9, preferredTimescale: 600),
            startVolume: &start, endVolume: &end, timeRange: &range))
        XCTAssertEqual(start, 0)
        let decoded = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(plan.project))
        XCTAssertEqual(decoded.timeline.videoClip(id: middle)?.timeRemap?.freezes.last?.silencesAudio, true)
        try decoded.validate()
    }

    func testFullShortVideoClosesGapAndRetimesAnimation() throws {
        var (project, middle, last) = try sequence()
        var clip = project.timeline.videoClip(id: middle)!
        clip.animation = .init(tracks: [.init(property: .opacity, keyframes: [
            .init(time: try .seconds(4), value: .number(0.5))])])
        try TimelineEditing.replace(middle, with: [clip], in: &project)
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(3), timing: .useFullClip, in: project)
        XCTAssertEqual(plan.clip.placement.duration, try .seconds(3))
        XCTAssertEqual(plan.project.timeline.videoClip(id: last)?.placement.timelineStart, try .seconds(8))
        XCTAssertEqual(plan.clip.animation?.tracks.first?.keyframes.first?.time.seconds ?? -1, 2.4, accuracy: 0.0001)
    }

    func testRippleMovesLaterVisualLayersAndMarkersButKeepsMusic() throws {
        var (project, middle, _) = try sequence()
        let textTrack = UUID(), shapeTrack = UUID(), audioTrack = UUID()
        let title = TextClip(placement: .init(id: UUID(), trackID: textTrack,
            timelineStart: try .seconds(11), duration: try .seconds(2)), text: "Next shot")
        let shape = ShapeClip(placement: .init(id: UUID(), trackID: shapeTrack,
            timelineStart: try .seconds(1), duration: try .seconds(2)))
        let music = AudioClip(placement: .init(id: UUID(), trackID: audioTrack,
            timelineStart: .zero, duration: try .seconds(15)), assetID: project.primaryAssetID,
            sourceRange: project.primaryAsset.sourceRange)
        project.timeline.tracks.insert(.init(id: textTrack, name: "Text", kind: .text, items: [.text(title)]), at: 0)
        project.timeline.tracks.insert(.init(id: shapeTrack, name: "Shape", kind: .shape, items: [.shape(shape)]), at: 0)
        project.timeline.tracks.append(.init(id: audioTrack, name: "Music", kind: .audio, items: [.audio(music)]))
        project.timeline.markers = [.init(id: UUID(), time: try .seconds(12))]
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .useFullClip, in: project)
        XCTAssertEqual(plan.project.timeline.item(id: title.id)?.placement.timelineStart, try .seconds(16))
        XCTAssertEqual(plan.project.timeline.item(id: shape.id), .shape(shape))
        XCTAssertEqual(plan.project.timeline.audioClip(id: music.id), music)
        XCTAssertEqual(plan.project.timeline.markers.first?.time, try .seconds(17))
    }

    func testLockedFollowingClipAllowsKeepButRefusesRipple() throws {
        var (project, middle, last) = try sequence()
        var locked = project.timeline.videoClip(id: last)!
        locked.placement.isLocked = true
        try TimelineEditing.replace(last, with: [locked], in: &project)
        let before = project
        XCTAssertThrowsError(try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .useFullClip, in: project))
        XCTAssertEqual(project, before)
        XCTAssertNoThrow(try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .keepDuration, in: project))
    }

    func testLockedTargetRejectsReplacement() throws {
        var (project, middle, _) = try sequence()
        project.timeline.tracks[0].isLocked = true
        XCTAssertThrowsError(try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .keepDuration, in: project))
    }

    func testStillReplacementFillsSlotAndDropsEmbeddedAudio() throws {
        let (project, middle, last) = try sequence()
        let still = ProjectMediaAsset(id: UUID(), url: URL(fileURLWithPath: "/tmp/image.png"),
            sourceRange: .init(start: .zero, duration: try .seconds(3)),
            stillImage: .init(width: 400, height: 300))
        let plan = try ClipReplacement.prepare(clipID: middle, asset: still, timing: .keepDuration, in: project)
        XCTAssertEqual(plan.clip.placement.duration, try .seconds(5))
        XCTAssertNil(plan.clip.embeddedAudio)
        XCTAssertEqual(plan.project.timeline.videoClip(id: last), project.timeline.videoClip(id: last))
        try plan.project.validate()
    }

    func testReplacementKeepsSpeedAndUsesCorrectAmountOfSource() throws {
        var (project, middle, _) = try sequence()
        try TimelineEditing.setSpeed(middle, to: 2, in: &project)
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .keepDuration, in: project)
        XCTAssertEqual(plan.clip.speed, 2)
        XCTAssertEqual(plan.clip.placement.duration, try .seconds(2.5))
        XCTAssertEqual(plan.clip.sourceRange.duration, try .seconds(5))
        let full = try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .useFullClip, in: project)
        XCTAssertEqual(full.clip.placement.duration, try .seconds(5))
    }

    func testAudioChoiceAndSilentReplacement() throws {
        let (project, middle, _) = try sequence()
        let muted = try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .keepDuration, useAudio: false, in: project)
        XCTAssertNil(muted.clip.embeddedAudio)
        let silent = try ClipReplacement.prepare(clipID: middle, asset: asset(audio: false), timing: .keepDuration, in: project)
        XCTAssertNil(silent.clip.embeddedAudio)
    }

    func testUndoRedoAndPersistenceRestoreBothMediaAndTiming() throws {
        let (project, middle, last) = try sequence()
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .useFullClip, in: project)
        var history = TimelineHistory()
        history.record("Replace clip", before: project, after: plan.project)
        XCTAssertEqual(history.undo(), project)
        XCTAssertEqual(history.redo(), plan.project)
        let decoded = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(plan.project))
        try decoded.validate()
        XCTAssertEqual(decoded.timeline.videoClip(id: last)?.placement.timelineStart, try .seconds(15))
        XCTAssertEqual(decoded.timeline.videoClip(id: middle)?.assetID, plan.clip.assetID)
    }

    func testReuseExistingMediaDoesNotDuplicateAsset() throws {
        var (project, middle, _) = try sequence()
        let replacement = try asset()
        project.addAsset(replacement)
        let plan = try ClipReplacement.prepare(clipID: middle, asset: replacement, timing: .keepDuration, in: project)
        XCTAssertEqual(plan.project.assets, project.assets)
    }

    func testOutOfRangeAndNonvisualMediaAreRejected() throws {
        let (project, middle, _) = try sequence()
        XCTAssertThrowsError(try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .keepDuration,
            sourceStart: .seconds(10), in: project))
        var audio = try asset()
        audio.videoMetadata = nil
        audio.audioName = "Music"
        XCTAssertThrowsError(try ClipReplacement.prepare(clipID: middle, asset: audio, timing: .keepDuration, in: project))
    }

    func testHoldIsExactForFractionalCadenceAndFastPlayback() throws {
        for speed in [0.5, 1.0, 2.0, 3.7] {
            var (project, middle, _) = try sequence()
            try TimelineEditing.setSpeed(middle, to: speed, in: &project)
            var replacement = try asset(2.913)
            replacement.frameDuration = try .init(value: 1001, timescale: 30_000)
            let plan = try ClipReplacement.prepare(clipID: middle, asset: replacement, timing: .keepDuration, in: project)
            XCTAssertEqual(plan.clip.timeMap.timelineDuration, project.timeline.videoClip(id: middle)?.placement.duration)
            try plan.project.validate()
        }
    }

    func testFullReplacementPreservesNormalizedSpeedCurve() throws {
        var (project, middle, _) = try sequence()
        var remap = TimeRemap()
        remap.points = [.init(sourceOffset: .zero, speed: 1),
                        .init(sourceOffset: try .seconds(5), speed: 2)]
        try TimelineEditing.setTimeRemap(middle, to: remap, in: &project)
        let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(), timing: .useFullClip, in: project)
        XCTAssertEqual(plan.clip.timeRemap?.points.last?.sourceOffset, try .seconds(10))
        XCTAssertEqual(plan.clip.timeRemap?.points.last?.speed, 2)
        XCTAssertEqual(plan.clip.placement.duration, plan.clip.timeMap.timelineDuration)
        try plan.project.validate()
    }

    func testShortReplacementWithRampAndReverseKeepsDuration() throws {
        for reverses in [false, true] {
            var (project, middle, _) = try sequence()
            var remap = TimeRemap()
            remap.reverses = reverses
            remap.points = [.init(sourceOffset: .zero, speed: 1),
                            .init(sourceOffset: try .seconds(5), speed: 2)]
            try TimelineEditing.setTimeRemap(middle, to: remap, in: &project)
            let plan = try ClipReplacement.prepare(clipID: middle, asset: asset(2.9), timing: .keepDuration, in: project)
            XCTAssertEqual(plan.clip.timeMap.timelineDuration, project.timeline.videoClip(id: middle)?.placement.duration)
            XCTAssertEqual(plan.clip.isReversed, reverses)
            try plan.project.validate()
        }
    }

    func testReplacingAnOverlayRipplesOnlyItsOwnTrack() throws {
        var (project, middle, last) = try sequence()
        let overlayID = UUID()
        var overlay = project.timeline.videoClip(id: middle)!
        overlay.placement = .init(id: UUID(), trackID: overlayID,
            timelineStart: .zero, duration: try .seconds(5))
        var next = overlay
        next.placement = .init(id: UUID(), trackID: overlayID,
            timelineStart: try .seconds(5), duration: try .seconds(5))
        project.timeline.tracks.insert(.init(id: overlayID, name: "Overlay", kind: .videoOverlay,
            items: [.video(overlay), .video(next)]), at: 0)
        let plan = try ClipReplacement.prepare(clipID: overlay.id, asset: asset(), timing: .useFullClip, in: project)
        XCTAssertEqual(plan.project.timeline.videoClip(id: next.id)?.placement.timelineStart, try .seconds(10))
        XCTAssertEqual(plan.project.timeline.videoClip(id: middle), project.timeline.videoClip(id: middle))
        XCTAssertEqual(plan.project.timeline.videoClip(id: last), project.timeline.videoClip(id: last))
    }

    func testFreezeCacheIncludesSourceWidth() throws {
        let duration = try TimelineTime.seconds(3)
        var first = TimeRemap()
        first.freezes = [.init(sourceOffset: try .seconds(2), duration: try .seconds(1),
                              sourceWidth: try .seconds(1.0 / 30), integratesExactly: true)]
        var second = first
        second.freezes[0].sourceWidth = try .seconds(1.0 / 24)
        _ = TimeMap.cached(remap: first, sourceDuration: duration)
        XCTAssertEqual(TimeMap.cached(remap: second, sourceDuration: duration),
                       TimeMap(remap: second, sourceDuration: duration))
    }

    func testLegacyFreezeDecodesWithoutReplacementFlags() throws {
        let old = FreezeSegment(sourceOffset: try .seconds(1), duration: try .seconds(2),
                                sourceWidth: try .seconds(1.0 / 30))
        let decoded = try JSONDecoder().decode(FreezeSegment.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.integratesExactly)
        XCTAssertNil(decoded.silencesAudio)
        XCTAssertEqual(decoded, old)
    }
}

@MainActor
final class ClipReplacementModelTests: XCTestCase {
    func testConfirmIsOneUndoStepAndKeepsSelection() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/original.mov"),
            displayName: "Replacement", metadata: makeVideoMetadata(durationSeconds: 15))
        let middle = try TimelineEditing.split(project.timeline.firstVideoClip!.id, at: .seconds(5), in: &project)
        _ = try TimelineEditing.split(middle, at: .seconds(10), in: &project)
        let asset = ProjectMediaAsset(id: UUID(), url: URL(fileURLWithPath: "/tmp/new.mov"),
            sourceRange: .init(start: .zero, duration: try .seconds(10)),
            videoMetadata: makeVideoMetadata(durationSeconds: 10))
        let model = try EditorViewModel(project: project)
        XCTAssertTrue(model.replaceClip(middle, with: asset, timing: .useFullClip, sourceStart: nil, useAudio: true))
        XCTAssertEqual(model.history.undoEntries.count, 1)
        XCTAssertEqual(model.selectedClipID, middle)
        let replaced = model.project
        model.undo()
        XCTAssertEqual(model.project.assets, project.assets)
        XCTAssertEqual(model.project.timeline, project.timeline)
        model.redo()
        XCTAssertEqual(model.project.timeline, replaced.timeline)
        XCTAssertEqual(model.project.assets, replaced.assets)
    }

    func testStagedCleanupKeepsMediaNeededByUndo() throws {
        let imports = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GradeLab/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let usedURL = imports.appendingPathComponent("\(UUID()).mov")
        let unusedURL = imports.appendingPathComponent("\(UUID()).mov")
        try Data([0]).write(to: usedURL)
        try Data([0]).write(to: unusedURL)
        defer {
            try? FileManager.default.removeItem(at: usedURL)
            try? FileManager.default.removeItem(at: unusedURL)
        }
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/original.mov"),
            displayName: "Replacement", metadata: makeVideoMetadata(durationSeconds: 5))
        let model = try EditorViewModel(project: project)
        let used = ProjectMediaAsset(id: UUID(), url: usedURL,
            sourceRange: .init(start: .zero, duration: try .seconds(5)),
            videoMetadata: makeVideoMetadata(durationSeconds: 5))
        var unused = used
        unused.url = unusedURL
        XCTAssertTrue(model.replaceClip(project.timeline.firstVideoClip!.id, with: used,
            timing: .keepDuration, sourceStart: nil, useAudio: true))
        model.undo()
        model.discardStagedReplacementMedia([used, unused])
        XCTAssertTrue(FileManager.default.fileExists(atPath: usedURL.path), "Redo still needs this file.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unusedURL.path), "Cancelled imports should be released.")
    }
}
