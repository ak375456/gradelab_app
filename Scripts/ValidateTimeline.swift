import Foundation
import CoreMedia

/// Runs the actual document/store code on the Mac. Does not launch a simulator.
@main
struct ValidateTimeline {
    struct Legacy: Encodable {
        let id: UUID
        let sourceURL: URL
        let displayName: String
        let metadata: VideoMetadata
        let gradeSettings: GradeSettings
        let createdAt: Date
        let updatedAt: Date
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GradeLab-TimelineCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = VideoMetadata(fileName: "source.mov", durationSeconds: 10,
            encodedWidth: 3840, encodedHeight: 2160, displayWidth: 3840, displayHeight: 2160,
            preferredTransform: .init(.identity), nominalFrameRate: 59.94005994,
            minimumFrameDurationSeconds: 1001.0/60000, codec: "HEVC", codecFourCC: "hvc1",
            estimatedBitrate: nil, fileSize: nil, hasAudio: true, videoTrackCount: 1, audioTrackCount: 1,
            colorPrimaries: "BT.709", transferFunction: "BT.709", yCbCrMatrix: "BT.709",
            logTransferFunction: nil, isHDR: false, bitDepth: 8, creationDate: nil)
        var grade = GradeSettings.neutral
        grade.exposure = 0.4
        grade.advanced = .neutral
        grade.advanced?.hsl[0].saturation = -20
        let legacy = Legacy(id: UUID(), sourceURL: root.appendingPathComponent("source.mov"),
            displayName: "Legacy", metadata: metadata, gradeSettings: grade,
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacyData = try encoder.encode(["projects": [legacy]])
        let database = root.appendingPathComponent("projects.json")
        try legacyData.write(to: database)
        let store = ProjectStore(rootURL: root)
        let initial = try await store.loadProjects()
        var project = initial[0]
        precondition(project.projectVersion == 2)
        precondition(project.timeline.firstVideoClip!.gradeSettings == grade)
        precondition(project.sourceURL == legacy.sourceURL && project.id == legacy.id)
        precondition(project.canvas.width == 3840 && project.canvas.height == 2160)
        let expectedFrame = try TimelineTime(value: 1001, timescale: 60_000)
        precondition(project.canvas.frameDuration == expectedFrame)
        let secondRead = try await store.loadProjects()
        precondition(secondRead == initial, "Migration IDs must remain stable")
        precondition(tryData(database) == legacyData, "Load must not rewrite V1")
        try await store.save(project)
        precondition(tryData(root.appendingPathComponent("projects-v1-backup.json")) == legacyData)
        let saved = try await store.loadProjects()
        precondition(saved == initial)
        let encoded = try encoder.encode(project)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(object["gradeSettings"] == nil && object["selectedClipID"] == nil)
        var future = object; future["projectVersion"] = 99
        do {
            _ = try decoder.decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: future))
            fatalError("Future version was accepted")
        } catch is TimelineError {}
        let first = project.timeline.firstVideoClip!
        do {
        var sound = project
        let pictureBefore = sound.timeline.firstVideoClip!
        let audioID = try AudioEditing.separate(first.id, in: &sound)
        precondition(sound.timeline.firstVideoClip!.embeddedAudio == nil)
        precondition(sound.timeline.firstVideoClip!.sourceRange == pictureBefore.sourceRange)
        precondition(sound.timeline.firstVideoClip!.gradeSettings == pictureBefore.gradeSettings)
        precondition(sound.timeline.audioClip(id: audioID)!.sourceRange == pictureBefore.sourceRange)
        precondition(sound.needsLayerCompositor)
        let separated = sound
        var removedSound = separated
        try AudioEditing.replace(audioID, with: [], in: &removedSound)
        precondition(removedSound.timeline.tracks.count == 1 && removedSound.timeline.audioClips.isEmpty)
        precondition(removedSound.timeline.firstVideoClip!.embeddedAudio == nil && removedSound.needsLayerCompositor, "Deleting separated audio must not restore embedded sound")
        do { _ = try AudioEditing.separate(first.id, in: &sound); fatalError("Separated twice") } catch is TimelineError {}
        precondition(sound == separated)
        let audioRight = try AudioEditing.split(audioID, at: .seconds(3), in: &sound)
        let audioTrack = sound.timeline.audioClip(id: audioID)!.placement.trackID
        precondition(sound.timeline.audioClips.count == 2)
        let leftEnd = try sound.timeline.audioClip(id: audioID)!.sourceRange.end
        precondition(sound.timeline.audioClip(id: audioRight)!.sourceRange.start == leftEnd)
        try AudioEditing.replace(audioID, with: [], in: &sound)
        precondition(sound.timeline.firstVideoClip == separated.timeline.firstVideoClip)
        let beforeMove = sound.timeline.audioClip(id: audioRight)!
        try AudioEditing.edit(audioRight, operation: .move, to: .zero, in: &sound)
        precondition(sound.timeline.audioClip(id: audioRight)!.sourceRange == beforeMove.sourceRange)
        try AudioEditing.edit(audioRight, operation: .trimEnd, to: .seconds(2), in: &sound)
        let copiedAudio = sound.timeline.audioClip(id: audioRight)!
        let pastedID = try AudioEditing.paste(copiedAudio, at: .seconds(1), trackID: audioTrack, in: &sound)
        precondition(sound.timeline.audioClip(id: pastedID)!.placement.trackID != audioTrack, "Overlapping paste should create a mixing track")
        precondition(sound.timeline.audioClip(id: pastedID)!.sourceRange == copiedAudio.sourceRange)
        let savedAudio = try decoder.decode(VideoProject.self, from: encoder.encode(sound))
        precondition(savedAudio == sound)
        var soundHistory = TimelineHistory()
        soundHistory.record("Audio edits", before: separated, after: sound)
        precondition(soundHistory.undo() == separated && soundHistory.redo() == sound)
        let audioTrackIndex = sound.timeline.tracks.firstIndex { $0.id == audioTrack }!
        sound.timeline.tracks[audioTrackIndex].isLocked = true
        let lockedSound = sound
        do { try AudioEditing.edit(audioRight, operation: .move, to: .seconds(1), in: &sound); fatalError("Moved locked audio") } catch is TimelineError {}
        precondition(sound == lockedSound)
        _ = try TimelineEditing.clips(in: sound)
        print("PASS: separate audio without changing picture, no double separation, audio split/trim/move/delete/paste, overlap-to-new-track, persistence, undo/redo and locks")
        }
        var magnetic = project
        let middle = try TimelineEditing.split(first.id, at: .seconds(3), in: &magnetic)
        let last = try TimelineEditing.split(middle, at: .seconds(6), in: &magnetic)
        let beforeMove = try TimelineEditing.clips(in: magnetic)
        var multiTrack = magnetic
        let overlayTrack = UUID()
        var overlayClip = beforeMove[0]
        overlayClip.placement = .init(id: UUID(), trackID: overlayTrack, timelineStart: try .seconds(1), duration: overlayClip.placement.duration)
        overlayClip.transform.scale = 0.5; overlayClip.blendMode = .multiply
        multiTrack.timeline.tracks.insert(.init(id: overlayTrack, name: "Overlay", kind: .videoOverlay, items: [.video(overlayClip)]), at: 0)
        let originalOverlay = overlayClip
        try TimelineEditing.deleteClosingGaps(middle, in: &multiTrack)
        precondition(multiTrack.timeline.videoClip(id: overlayClip.id) == originalOverlay, "Main ripple moved overlay")
        multiTrack.timeline.tracks[0].isLocked = true
        _ = try TimelineEditing.clips(in: multiTrack)
        do { try TimelineEditing.trimClosingGaps(overlayClip.id, edge: .right, to: .seconds(2), in: &multiTrack); fatalError("Locked layer edited") } catch is TimelineError {}
        multiTrack.timeline.tracks[0].isEnabled = false
        _ = try TimelineEditing.clips(in: multiTrack)
        let roundTrip = try decoder.decode(VideoProject.self, from: encoder.encode(multiTrack))
        precondition(roundTrip == multiTrack, "Layer settings did not persist")
        let stillAsset = ProjectMediaAsset(id: UUID(), url: root.appendingPathComponent("still.png"), sourceRange: .init(start: .zero, duration: try .seconds(3)), videoMetadata: nil,
            frameDuration: nil, stillImage: .init(width: 100, height: 100))
        multiTrack.addAsset(stillAsset)
        var stillClip = originalOverlay
        stillClip.assetID = stillAsset.id; stillClip.embeddedAudio = nil
        multiTrack.timeline.tracks[0].items = [.video(stillClip)]
        multiTrack.timeline.tracks[0].isLocked = false
        try TimelineEditing.trim(stillClip.id, edge: .right, to: .seconds(20), clamping: true, in: &multiTrack)
        _ = try TimelineEditing.clips(in: multiTrack)
        let stillRoundTrip = try decoder.decode(VideoProject.self, from: encoder.encode(multiTrack))
        precondition(stillRoundTrip == multiTrack, "Still overlay did not persist")
        for edge in [TimelineEditing.Edge.left, .right] {
            var trimmed = magnetic
            try TimelineEditing.trimClosingGaps(middle, edge: edge, to: .seconds(4), in: &trimmed)
            let result = try TimelineEditing.clips(in: trimmed)
            for pair in zip(result, result.dropFirst()) {
                let end = try pair.0.placement.range.end
                precondition(end == pair.1.placement.timelineStart)
            }
            precondition(result[2].sourceRange == beforeMove[2].sourceRange)
            precondition(result[1].placement.duration < beforeMove[1].placement.duration)
            var trimHistory = TimelineHistory()
            trimHistory.record("Ripple trim", before: magnetic, after: trimmed)
            precondition(trimHistory.undo() == magnetic && trimHistory.redo() == trimmed)
        }
        var ripple = magnetic
        try TimelineEditing.deleteClosingGaps(middle, in: &ripple)
        let joined = try TimelineEditing.clips(in: ripple)
        let joinedEnd = try joined[0].placement.range.end
        precondition(joined.map(\.id) == [first.id, last])
        precondition(joined[1].placement.timelineStart == joinedEnd)
        precondition(joined[1].sourceRange == beforeMove[2].sourceRange)
        let boundary = joinedEnd.seconds
        precondition(TimelineEditing.snapPlayhead(boundary + 0.02, clips: joined, tolerance: 0.05) == boundary)
        precondition(TimelineEditing.snapPlayhead(boundary + 0.2, clips: joined, tolerance: 0.05) == boundary + 0.2)
        let snapMarkers = [TimelineMarker(id: UUID(), time: try .seconds(1.25))]
        for zoom in [4.0, 48, 320, 2400] {
            let nearby = 1.25 + min(0.01, 6/zoom)
            precondition(TimelineEditing.snapPlayhead(nearby, clips: joined, markers: snapMarkers, tolerance: 12/zoom) == 1.25)
        }
        precondition(TimelineEditing.snapPlayhead(1.4, clips: joined, markers: snapMarkers, tolerance: 0.05) == 1.4)
        precondition(TimelineEditing.snapPlayhead(1.26, clips: joined, markers: [], tolerance: 0.05) == 1.26)
        let outside = TimelineMarker(id: UUID(), time: try joined.last!.placement.range.end.adding(.seconds(0.01)))
        let finalEnd = try joined.last!.placement.range.end.seconds
        precondition(TimelineEditing.snapPlayhead(finalEnd, clips: joined, markers: [outside], tolerance: 0.05) == finalEnd)
        let rippleBeforeLock = ripple
        ripple.timeline.tracks[0].isLocked = true
        let lockedRipple = ripple
        do { try TimelineEditing.deleteClosingGaps(first.id, in: &ripple); fatalError("Locked ripple accepted") } catch is TimelineError {}
        precondition(ripple == lockedRipple)
        var rippleHistory = TimelineHistory()
        rippleHistory.record("Delete", before: magnetic, after: rippleBeforeLock)
        precondition(rippleHistory.undo() == magnetic && rippleHistory.redo() == rippleBeforeLock)
        let originalDuration = magnetic.timeline.duration
        let targetTime = try TimelineTime.seconds(7)
        precondition(TimelineEditing.splitTarget(in: magnetic, at: targetTime) == last)
        precondition(TimelineEditing.splitTarget(in: magnetic, at: .zero) == nil)
        try TimelineEditing.insertMove(last, to: .zero, in: &magnetic)
        var reordered = try TimelineEditing.clips(in: magnetic)
        precondition(reordered.map(\.id) == [last, first.id, middle])
        precondition(magnetic.timeline.duration == originalDuration)
        for clip in reordered {
            let original = beforeMove.first { $0.id == clip.id }!
            precondition(clip.sourceRange == original.sourceRange && clip.gradeSettings == original.gradeSettings)
        }
        try TimelineEditing.insertMove(last, to: .seconds(100), in: &magnetic)
        reordered = try TimelineEditing.clips(in: magnetic)
        precondition(reordered.map(\.id) == beforeMove.map(\.id))
        precondition(magnetic.timeline.duration == originalDuration)
        try TimelineEditing.insertMove(last, to: beforeMove[1].placement.timelineStart, in: &magnetic)
        precondition(tryIDs(magnetic) == [first.id, last, middle])
        let beforeLockedMove = magnetic
        magnetic.timeline.tracks[0].isLocked = true
        do { try TimelineEditing.insertMove(last, to: .zero, in: &magnetic); fatalError("Locked reorder accepted") } catch is TimelineError {}
        magnetic = beforeLockedMove
        try TimelineEditing.trim(first.id, edge: .left, to: .seconds(100), clamping: true, in: &magnetic)
        let clamped = try TimelineEditing.clips(in: magnetic)
        precondition(clamped[0].placement.duration == expectedFrame)
        try TimelineEditing.trim(first.id, edge: .right, to: .seconds(100), clamping: true, in: &magnetic)
        _ = try TimelineEditing.clips(in: magnetic)
        var edited = project
        let rightID = try TimelineEditing.split(first.id, at: .seconds(4), in: &edited)
        precondition(edited.timeline.videoClip(id: rightID)!.gradeSettings == grade)
        try TimelineEditing.trim(rightID, edge: .right, to: .seconds(8), in: &edited)
        try TimelineEditing.move(rightID, to: .seconds(6), in: &edited)
        let editedClips = try TimelineEditing.clips(in: edited)
        let cutTime = try TimelineEditing.snapped(.seconds(4), frame: project.canvas.frameDuration)
        let movedTime = try TimelineEditing.snapped(.seconds(6), frame: project.canvas.frameDuration)
        let trimTime = try TimelineEditing.snapped(.seconds(8), frame: project.canvas.frameDuration)
        let trimmedDuration = try trimTime.subtracting(cutTime)
        precondition(editedClips.count == 2 && editedClips[1].sourceRange.start == cutTime)
        precondition(editedClips[1].placement.timelineStart == movedTime && editedClips[1].placement.duration == trimmedDuration)
        var history = TimelineHistory()
        history.record("Edit", before: project, after: edited)
        precondition(history.undo() == project && history.redo() == edited)
        let clipboard = editedClips[1]
        try TimelineEditing.replace(rightID, with: [], in: &edited)
        let pastedID = try TimelineEditing.paste(clipboard, at: .seconds(4), in: &edited)
        precondition(pastedID != clipboard.id && edited.timeline.videoClip(id: pastedID)!.gradeSettings == clipboard.gradeSettings)
        _ = try TimelineEditing.clips(in: edited)
        var overlapping = edited
        try TimelineEditing.move(pastedID, to: .seconds(1), in: &overlapping)
        do { _ = try TimelineEditing.clips(in: overlapping); fatalError("Overlap accepted") } catch is TimelineError {}
        edited.timeline.tracks[0].isLocked = true
        do { try TimelineEditing.replace(pastedID, with: [], in: &edited); fatalError("Locked delete accepted") } catch is TimelineError {}
        var copy = first
        copy.placement = .init(id: UUID(), trackID: first.placement.trackID,
                               timelineStart: try first.placement.range.end, duration: first.placement.duration)
        project.timeline.tracks[0].items.append(.video(copy))
        precondition(project.timeline.setGrade(.neutral, for: copy.id))
        precondition(project.timeline.videoClip(id: first.id)!.gradeSettings == grade)
        precondition(project.singleSourceClip == nil)
        project.timeline.tracks[0].isLocked = true
        precondition(!project.timeline.setGrade(.neutral, for: first.id))
        try project.validate()
        var time = TimelineTime.zero
        for _ in 0..<60_000 { time = try time.adding(expectedFrame) }
        precondition(time.seconds == 1001)
        for zoom in [4.0, 48, 320, 2400] {
            let viewport = TimelineViewport(pixelsPerSecond: zoom, width: 390, offset: 75 * zoom)
            precondition(viewport.x(for: 75) == 195)
            precondition(viewport.seconds(at: 195, duration: 3600) == 75)
            precondition(abs(viewport.seconds(at: viewport.x(for: 76.25), duration: 3600) - 76.25) < 0.000001)
            precondition(viewport.rulerInterval * zoom >= 70)
        }
        var mappedClip = first
        mappedClip.sourceRange.start = expectedFrame
        mappedClip.placement.timelineStart = try .seconds(2)
        let mappedTime = try mappedClip.sourceTime(at: .seconds(3))
        let expectedMapped = try expectedFrame.adding(.seconds(1))
        precondition(mappedTime == expectedMapped)
        let markerTime = try TimelineTime.seconds(900)
        let duration = project.timeline.duration
        project.timeline.markers.append(.init(id: UUID(), time: markerTime))
        precondition(project.timeline.duration == duration)
        var invalid = project
        var missingAssetClip = invalid.timeline.firstVideoClip!
        missingAssetClip.assetID = UUID()
        invalid.timeline.tracks[0].items[0] = .video(missingAssetClip)
        do { try invalid.validate(); fatalError("Missing assets accepted") } catch is TimelineError {}
        print("PASS: ripple deletion and undo/redo; boundary snapping; magnetic reorder; source/grade/duration preservation; playhead split target; clamped trim; migration/store/locks; exact frame arithmetic; viewport/source mapping")
    }
    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
    static func tryIDs(_ project: VideoProject) -> [UUID] { try! TimelineEditing.clips(in: project).map(\.id) }
}
