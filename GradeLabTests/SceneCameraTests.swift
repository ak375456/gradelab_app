import SwiftUI
import XCTest
@testable import GradeLab

final class SceneCameraTests: XCTestCase {
    private func project() -> VideoProject {
        VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/scene-camera.mov"), displayName: "Camera",
                     metadata: makeVideoMetadata(durationSeconds: 4))
    }

    private func addTitle(to project: inout VideoProject, depth: CameraLayerDepth? = nil) -> TextClip {
        let track = UUID()
        let title = TextClip(placement: .init(id: UUID(), trackID: track, timelineStart: .zero,
                                             duration: project.timeline.duration, cameraDepth: depth))
        project.timeline.tracks.insert(.init(id: track, name: "Title", kind: .text, items: [.text(title)]), at: 0)
        return title
    }

    @discardableResult
    private func addCamera(to project: inout VideoProject, start: Double = 0, duration: Double,
                           position: SceneCameraPosition = .init(), animation: ClipAnimation? = nil) throws -> SceneCameraClip {
        let track = UUID()
        let camera = SceneCameraClip(placement: .init(id: UUID(), trackID: track, timelineStart: try .seconds(start),
                                                       duration: try .seconds(duration)),
                                     position: position, animation: animation)
        project.timeline.tracks.insert(.init(id: track, name: "Camera", kind: .camera, items: [.camera(camera)]), at: 0)
        return camera
    }

    func testActiveCameraUsesTopEnabledRowAndItsOwnTiming() throws {
        var project = project()
        let lower = try addCamera(to: &project, duration: 3, position: .init(z: 0.4))
        let upper = try addCamera(to: &project, start: 1, duration: 4, position: .init(x: 0.25, y: -0.5))
        let time = try TimelineTime.seconds(2)
        XCTAssertEqual(project.timeline.activeCamera(at: .zero)?.id, lower.id)
        XCTAssertEqual(project.timeline.activeCamera(at: time)?.id, upper.id)
        XCTAssertEqual(project.timeline.duration.seconds, 4)
        let projection = project.timeline.cameraPosition(at: time).projection(for: .foreground)
        var transform = VisualTransform()
        let canvas = CGSize(width: 1920, height: 1080)
        projection.apply(to: &transform, canvas: canvas)
        XCTAssertEqual(transform.positionX, 0.25)
        XCTAssertEqual(transform.positionY, 1)
        let authored = projection.authoredPosition(CGPoint(x: transform.positionX, y: transform.positionY), canvas: canvas)
        XCTAssertEqual(authored, CGPoint(x: 0.5, y: 0.5))
        project.timeline.tracks[0].isEnabled = false
        XCTAssertEqual(project.timeline.activeCamera(at: time)?.id, lower.id)
        XCTAssertNil(project.timeline.activeCamera(at: try .seconds(3)))
    }

    func testFramingProjectsRollInCanvasPixelsAndPreservesScreenLayers() throws {
        var project = project()
        let title = addTitle(to: &project, depth: .foreground)
        let caption = addTitle(to: &project)
        var position = SceneCameraPosition()
        position.rotation = 90
        position.zoom = 1.5
        position.frameWidth = 0.75
        position.frameHeight = 0.5
        _ = try addCamera(to: &project, duration: 2, position: position)

        let reopened = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        let framed = reopened.projectedForSceneCamera(at: .zero)
        guard case .text(let rolled) = framed.timeline.item(id: title.id) else { return XCTFail("Missing title") }
        XCTAssertEqual(rolled.transform.rotationDegrees, 90)
        XCTAssertEqual(rolled.transform.scale, 1.5)
        XCTAssertEqual(framed.timeline.item(id: caption.id), .text(caption))
        let canvas = CGSize(width: 200, height: 100)
        XCTAssertEqual(reopened.timeline.cameraPosition(at: .zero).frame(in: canvas),
                       CGRect(x: 25, y: 25, width: 150, height: 50))
        XCTAssertNil(reopened.timeline.cameraPosition(at: try .seconds(2)).frame(in: canvas))

        let projection = position.projection(for: .foreground)
        var transform = VisualTransform(positionX: 0.6, positionY: 0.5)
        projection.apply(to: &transform, canvas: canvas)
        XCTAssertEqual(transform.positionX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(transform.positionY, 0.8, accuracy: 0.0001)
        let authored = projection.authoredPosition(CGPoint(x: transform.positionX, y: transform.positionY), canvas: canvas)
        XCTAssertEqual(authored.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(authored.y, 0.5, accuracy: 0.0001)
    }

    func testLegacyCameraMigrationCarriesMotionAndKeepsFraming() throws {
        var project = project()
        var footage = try XCTUnwrap(project.timeline.firstVideoClip)
        footage.camera = ClipCamera(zoom: 2, dolly: 0.2)
        footage.animation = ClipAnimation(tracks: [AnimationTrack(property: .cameraDolly, keyframes: [
            Keyframe(time: .zero, value: .number(0.2), interpolation: .linear),
            Keyframe(time: try .seconds(2), value: .number(1.2), interpolation: .linear)
        ])])
        try TimelineEditing.replace(footage.id, with: [footage], in: &project)

        let decoded = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.timeline.tracks.first?.kind, .camera)
        XCTAssertEqual(decoded.timeline.cameraPosition(at: try .seconds(1)).z, 0.7, accuracy: 0.0001)
        XCTAssertEqual(decoded.timeline.videoClip(id: footage.id)?.camera?.zoom, 2)
        XCTAssertNil(decoded.timeline.videoClip(id: footage.id)?.camera?.dolly)
        XCTAssertNil(decoded.timeline.videoClip(id: footage.id)?.animation?.track(.cameraDolly))
    }

    func testAnimatedCameraGrowsForegroundFasterAndPassesItWhileScreenTextStaysInPlace() throws {
        var project = project()
        var footage = try XCTUnwrap(project.timeline.firstVideoClip)
        footage.placement.cameraDepth = .background
        let end = try TimelineTime.seconds(2)
        let animation = ClipAnimation(tracks: [.init(property: .cameraPositionZ, keyframes: [
            .init(time: .zero, value: .number(0), interpolation: .linear),
            .init(time: end, value: .number(1.2), interpolation: .linear)
        ])])
        try TimelineEditing.replace(footage.id, with: [footage], in: &project)
        let title = addTitle(to: &project, depth: .foreground)
        let caption = addTitle(to: &project)
        let camera = try addCamera(to: &project, duration: 3, animation: animation)

        XCTAssertEqual(project.projectedForSceneCamera(at: .zero), project)
        let during = project.projectedForSceneCamera(at: try .seconds(1))
        guard case .text(let near) = during.timeline.item(id: title.id) else { return XCTFail("Missing title") }
        XCTAssertEqual(near.transform.scale, 2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(during.timeline.videoClip(id: footage.id)).transform.scale, 4 / 3.4, accuracy: 0.0001)
        XCTAssertEqual(during.timeline.item(id: caption.id), .text(caption))

        let passed = project.projectedForSceneCamera(at: end)
        guard case .text(let behind) = passed.timeline.item(id: title.id) else { return XCTFail("Missing title") }
        XCTAssertEqual(behind.opacity, 0)
        XCTAssertEqual(passed.timeline.videoClip(id: footage.id)?.opacity, 1)
        XCTAssertEqual(project.timeline.item(id: title.id), .text(title))
        let reopened = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(reopened.projectedForSceneCamera(at: end), passed)

        var edited = reopened
        let split = try TimelineTime.seconds(0.5)
        let rightFootage = try TimelineEditing.split(footage.id, at: split, in: &edited)
        let rightTitle = try OverlayEditing.split(title.id, at: split, in: &edited)
        let copied = try OverlayEditing.paste(title, at: try .seconds(4), in: &edited)
        XCTAssertEqual(edited.timeline.videoClip(id: rightFootage)?.placement.cameraDepth, .background)
        XCTAssertEqual(edited.timeline.item(id: rightTitle)?.placement.cameraDepth, .foreground)
        XCTAssertEqual(edited.timeline.item(id: copied)?.placement.cameraDepth, .foreground)
        let rightCamera = try OverlayEditing.split(camera.id, at: split, in: &edited)
        XCTAssertEqual(edited.timeline.activeCamera(at: end)?.id, rightCamera)
        XCTAssertEqual(edited.timeline.cameraPosition(at: end).z, 1.2)
        try OverlayEditing.edit(rightCamera, operation: .trimEnd, to: .seconds(2.5), in: &edited)
        XCTAssertEqual(edited.timeline.cameraPosition(at: try .seconds(2.5)).z, 0)
        XCTAssertEqual(reopened.timeline.duration, project.timeline.duration)
    }

    @MainActor
    func testCameraSetupAndLiveDragKeepIndependentTitlesAndMakeOneUndoEntry() throws {
        var project = project()
        let footage = try XCTUnwrap(project.timeline.firstVideoClip)
        try TimelineEditing.trimClosingGaps(footage.id, edge: .right, to: .seconds(2.5), in: &project)
        let title = addTitle(to: &project)
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        model.addSceneCamera()
        let cameraID = try XCTUnwrap(model.selectedSceneCamera?.id)
        XCTAssertEqual(model.project.timeline.firstVideoClip?.placement.cameraDepth, .background)
        XCTAssertEqual(model.project.timeline.tracks.first?.kind, .camera)
        XCTAssertEqual(model.selectedSceneCamera?.placement.range, project.timeline.firstVideoClip?.placement.range)
        XCTAssertEqual(model.project.timeline.item(id: title.id), .text(title))
        model.setCameraDepth(.foreground, for: title.id)
        let history = model.history.undoEntries.count
        let authored = model.project
        model.previewSceneCameraValue(1.15, property: .cameraPositionZ)
        let frame = model.renderPreviewProject.projectedForSceneCamera(at: .zero)
        guard case .text(let projected) = frame.timeline.item(id: title.id) else { return XCTFail("Missing title") }
        XCTAssertEqual(projected.opacity, 0)
        XCTAssertEqual(model.project, authored)
        XCTAssertEqual(model.history.undoEntries.count, history)
        model.setSceneCameraValue(1.15, property: .cameraPositionZ)
        XCTAssertEqual(model.history.undoEntries.count, history + 1)
        XCTAssertNil(model.sceneCameraPreview.edit)
        model.undo()
        XCTAssertEqual(model.project.timeline.activeCamera(at: .zero)?.id, cameraID)
        XCTAssertEqual(model.project.timeline.cameraPosition(at: .zero).z, 0)

        let position = SceneCameraPosition(x: 0.3, y: -0.2, z: 1.15)
        let entries = model.history.undoEntries.count
        model.previewSceneCameraGesture(position, id: cameraID, time: .zero)
        XCTAssertEqual(model.renderPreviewProject.timeline.cameraPosition(at: .zero), position)
        model.applySceneCameraGesture(position, id: cameraID, time: .zero, from: .init())
        XCTAssertEqual(model.project.timeline.cameraPosition(at: .zero), position)
        XCTAssertEqual(model.history.undoEntries.count, entries + 1)

        let beforeFraming = model.project
        model.previewSceneCameraValue(0.6, property: .sceneCameraFrameWidth)
        XCTAssertEqual(model.renderPreviewProject.timeline.cameraPosition(at: .zero).frameWidth, 0.6)
        XCTAssertEqual(model.project, beforeFraming)
        model.setSceneCameraValue(0.6, property: .sceneCameraFrameWidth)
        XCTAssertEqual(model.project.timeline.cameraPosition(at: .zero).frameWidth, 0.6)
        XCTAssertEqual(model.history.undoEntries.count, entries + 2)
    }

    @MainActor
    func testCameraPanelFitsNarrowAndWideWithAccessibilityText() throws {
        var project = project()
        _ = addTitle(to: &project, depth: .foreground)
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        model.addSceneCamera()
        for width in [320.0, 640.0] {
            let panel = VStack(spacing: 0) {
                SceneCameraHeader(model: model, addCamera: model.addSceneCamera)
                SceneCameraPanel(model: model)
            }
            .environment(\.dynamicTypeSize, .accessibility2)
            let host = UIHostingController(rootView: panel)
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 520)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            func scrollView(in view: UIView) -> UIScrollView? {
                (view as? UIScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            let scroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        }
    }
}
