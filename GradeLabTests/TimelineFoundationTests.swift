import CoreMedia
import XCTest
@testable import GradeLab

final class TimelineFoundationTests: XCTestCase {
    func testRationalTimingDoesNotDrift() throws {
        let frame = try TimelineTime(value: 1001, timescale: 60_000)
        var time = TimelineTime.zero
        for _ in 0..<60_000 { time = try time.adding(frame) }
        XCTAssertEqual(time, try TimelineTime(value: 1001, timescale: 1))
        XCTAssertEqual(try time.subtracting(frame).adding(frame), time)
        XCTAssertEqual(try TimelineTime(value: 1, timescale: 2), try TimelineTime(value: 2, timescale: 4))
        XCTAssertThrowsError(try TimelineTime(.indefinite))
        XCTAssertThrowsError(try JSONDecoder().decode(TimelineTime.self, from: Data(#"{"value":1,"timescale":0}"#.utf8)))
    }

    func testInitialProjectPreservesCanvasGradeAndAudioLink() throws {
        var grade = GradeSettings.neutral
        grade.exposure = 0.4
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "4K",
            metadata: makeVideoMetadata(displayWidth: 3840, displayHeight: 2160, nominalFrameRate: 59.94005994), gradeSettings: grade)
        try project.validate()
        XCTAssertEqual(project.canvas.width, 3840)
        XCTAssertEqual(project.canvas.frameDuration, try TimelineTime(value: 1001, timescale: 60_000))
        XCTAssertEqual(project.timeline.firstVideoClip?.gradeSettings, grade)
        XCTAssertNotNil(project.timeline.firstVideoClip?.embeddedAudio)
        XCTAssertEqual(project.timeline.duration.seconds, project.metadata.durationSeconds, accuracy: 0.00001)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        XCTAssertNil(json["gradeSettings"])
        XCTAssertNil(json["selectedClipID"])
    }

    func testClipGradesHaveValueSemanticsAndRespectLocks() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "Test", metadata: makeVideoMetadata())
        let first = try XCTUnwrap(project.timeline.firstVideoClip)
        var second = first
        second.placement = ItemPlacement(id: UUID(), trackID: first.placement.trackID,
            timelineStart: try first.placement.range.end, duration: first.placement.duration)
        project.timeline.tracks[0].items.append(.video(second))
        var grade = GradeSettings.neutral
        grade.advanced = .neutral
        grade.advanced?.curves[0].midtones = 0.7
        XCTAssertTrue(project.timeline.setGrade(grade, for: second.id))
        XCTAssertEqual(project.timeline.videoClip(id: first.id)?.gradeSettings, .neutral)
        XCTAssertEqual(project.timeline.videoClip(id: second.id)?.gradeSettings, grade)
        project.timeline.tracks[0].isLocked = true
        XCTAssertFalse(project.timeline.setGrade(.neutral, for: second.id))
        XCTAssertNil(project.singleSourceClip)
        try project.validate()
    }

    func testMalformedReferencesAreRejected() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "Test", metadata: makeVideoMetadata())
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.assetID = UUID()
        project.timeline.tracks[0].items = [.video(clip)]
        XCTAssertThrowsError(try project.validate())
        XCTAssertThrowsError(try JSONEncoder().encode(project))
    }

    func testMarkersDoNotChangeDurationAndDisabledItemsKeepExtent() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "Test", metadata: makeVideoMetadata())
        let duration = project.timeline.duration
        project.timeline.markers.append(.init(id: UUID(), time: try .seconds(900)))
        project.timeline.tracks[0].isEnabled = false
        XCTAssertEqual(project.timeline.duration, duration)
        XCTAssertNil(project.singleSourceClip)
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project)), project)
    }

    func testLayerMaskPersistsAndForcesTheLayerCompositor() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Mask", metadata: makeVideoMetadata())
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.layerMask = LayerMask(isEnabled: true, shape: .rectangle,
                                   centerX: 0.3, centerY: 0.7,
                                   width: 0.5, height: 0.25,
                                   rotationDegrees: 30, feather: 0.2,
                                   isInverted: true)
        project.timeline.tracks[0].items = [.video(clip)]

        XCTAssertTrue(project.needsLayerCompositor)
        let decoded = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.timeline.firstVideoClip?.layerMask, clip.layerMask)

        let uniforms = LayerMaskUniforms(clip.layerMask)
        XCTAssertEqual(MemoryLayout<LayerMaskUniforms>.stride, 32)
        XCTAssertEqual(uniforms.geometry.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(uniforms.geometry.y, 0.7, accuracy: 0.0001)
        XCTAssertEqual(uniforms.options.z, 1)
        XCTAssertEqual(uniforms.options.w, 5, "rectangle + inverted flags")

        var linear = clip.layerMask!
        linear.shape = .linear
        linear.isInverted = false
        XCTAssertEqual(LayerMaskUniforms(linear).options.w, 2, "linear shape flag")
    }

    func testLegacyClipDecodesWithoutLayerMask() throws {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Legacy", metadata: makeVideoMetadata())
        let clip = try XCTUnwrap(project.timeline.firstVideoClip)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        json.removeValue(forKey: "layerMask")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(VideoClip.self, from: legacy)
        XCTAssertNil(decoded.layerMask)
        XCTAssertFalse(decoded.resolvedLayerMask.isEnabled)
    }
}
