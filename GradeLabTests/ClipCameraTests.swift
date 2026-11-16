import CoreImage
import SwiftUI
import XCTest
@testable import GradeLab

final class ClipCameraTests: XCTestCase {
    private func project() -> VideoProject {
        VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/camera-source.mov"),
                     displayName: "Camera", metadata: makeVideoMetadata(durationSeconds: 5))
    }

    func testCropAndFitKeepsTheEntireTopStripWithTransparentSpace() throws {
        let clip = try XCTUnwrap(project().timeline.firstVideoClip)
        var framed = clip
        framed.camera = ClipCamera(mode: .crop, y: 0, cropHeight: 0.25)
        let source = CGSize(width: 80, height: 60)
        let canvas = CGSize(width: 80, height: 44)
        let placement = ClipPicturePlacement(clip: framed, encoded: source, preferred: .identity, canvas: canvas)
        let bounds = CGRect(origin: .zero, size: source)
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 45, width: 80, height: 15))
        let blue = CIImage(color: .blue).cropped(to: bounds)
        let result = placement.place(red.composited(over: blue))
        XCTAssertEqual(result.extent, CGRect(x: 0, y: 14, width: 80, height: 16))
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func pixel(x: CGFloat, y: CGFloat) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(result, toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            return rgba
        }
        XCTAssertEqual(pixel(x: 2, y: 22), [255, 0, 0, 255])
        XCTAssertEqual(pixel(x: 77, y: 22), [255, 0, 0, 255])
        XCTAssertEqual(pixel(x: 40, y: 4), [0, 0, 0, 0])
    }

    func testFocusKeepsCenterSharpAndSoftensOutside() throws {
        var clip = try XCTUnwrap(project().timeline.firstVideoClip)
        let size = CGSize(width: 320, height: 240)
        let bounds = CGRect(origin: .zero, size: size)
        let checker = CIImage(color: .white).applyingFilter("CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputWidth": 3.0, "inputSharpness": 1.0
        ]).cropped(to: bounds)
        clip.camera = ClipCamera(focusAmount: 1)
        let placement = ClipPicturePlacement(clip: clip, encoded: size, preferred: .identity, canvas: size)
        let sharp = placement.place(checker)
        let blurred = placement.place(checker, applyingFocus: true)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> UInt8 {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            return bytes[0]
        }
        XCTAssertEqual(pixel(sharp, x: 160, y: 120), pixel(blurred, x: 160, y: 120))
        XCTAssertGreaterThan(abs(Int(pixel(sharp, x: 18, y: 19)) - Int(pixel(blurred, x: 18, y: 19))), 20)
    }

    func testRolledFillStaysInsideRotatedPortraitSource() throws {
        var clip = try XCTUnwrap(project().timeline.firstVideoClip)
        clip.camera = ClipCamera(x: 1, y: 0, zoom: 1.1, roll: 34)
        let source = CGSize(width: 1920, height: 1080)
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: source.height, ty: 0)
        let canvas = CGSize(width: 1920, height: 1080)
        let placement = ClipPicturePlacement(clip: clip, encoded: source, preferred: preferred, canvas: canvas)
        let inverse = placement.sourceToCanvas.inverted()
        for y in [0.0, canvas.height] {
            for x in [0.0, canvas.width] {
                let p = CGPoint(x: x, y: y).applying(inverse)
                XCTAssertTrue((-0.001...source.width + 0.001).contains(p.x))
                XCTAssertTrue((-0.001...source.height + 0.001).contains(p.y))
            }
        }
    }

    func testCropHandlesCanShrinkAndExpandInBothDirections() {
        let size = CGSize(width: 800, height: 600)
        let camera = ClipCamera(mode: .crop, cropWidth: 0.5, cropHeight: 0.5)
        let original = camera.frame(source: size, canvas: size)
        let shrunk = camera.resizing(.bottomRight, by: CGPoint(x: -80, y: -60), source: size, canvas: size)
        let expanded = shrunk.resizing(.bottomRight, by: CGPoint(x: 80, y: 60), source: size, canvas: size)
        XCTAssertEqual(expanded.cropWidth, camera.cropWidth, accuracy: 0.0001)
        XCTAssertEqual(expanded.cropHeight, camera.cropHeight, accuracy: 0.0001)
        let topLeft = expanded.resizing(.topLeft, by: CGPoint(x: -40, y: -50), source: size, canvas: size)
            .frame(source: size, canvas: size)
        XCTAssertEqual(topLeft.size.width, original.size.width + 40, accuracy: 0.0001)
        XCTAssertEqual(topLeft.size.height, original.size.height + 50, accuracy: 0.0001)
        XCTAssertEqual(topLeft.center.x + topLeft.size.width / 2, original.center.x + original.size.width / 2, accuracy: 0.0001)
        XCTAssertEqual(topLeft.center.y + topLeft.size.height / 2, original.center.y + original.size.height / 2, accuracy: 0.0001)
        let zoomed = ClipCamera(mode: .crop, zoom: 2)
        let wider = zoomed.resizing(.right, by: CGPoint(x: 100, y: 0), source: size, canvas: size)
            .frame(source: size, canvas: size)
        XCTAssertEqual(wider.size.width, 500, accuracy: 0.0001)
        XCTAssertEqual(wider.size.height, 300, accuracy: 0.0001)
    }

    func testFillPanAtOneHundredPercentMakesRoomOnTheRequestedAxis() {
        let size = CGSize(width: 1920, height: 1080)
        let camera = ClipCamera()
        let horizontal = camera.adjusting(.cameraX, to: 0.75, source: size, canvas: size)
        XCTAssertGreaterThan(horizontal.zoom, 1)
        XCTAssertGreaterThan(horizontal.frame(source: size, canvas: size).center.x, size.width / 2)
        let vertical = camera.moving(by: CGPoint(x: 0, y: -40), zoomFactor: 1, rotation: 0,
                                     source: size, canvas: size, sourcePointsPerScreenPoint: 5)
        XCTAssertGreaterThan(vertical.zoom, 1)
        XCTAssertLessThan(vertical.frame(source: size, canvas: size).center.y, size.height / 2)
        let topCrop = ClipCamera(mode: .crop).adjusting(.cameraY, to: 0, source: size, canvas: size)
            .resizing(.bottom, by: CGPoint(x: 0, y: -400), source: size, canvas: size)
        XCTAssertEqual(topCrop.frame(source: size, canvas: size).size.width, size.width, accuracy: 0.0001)
    }

    func testLegacyDecodeAndCameraKeyframesRoundTrip() throws {
        var project = project()
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let legacy = try decoder.decode(VideoProject.self, from: encoder.encode(project))
        var clip = try XCTUnwrap(legacy.timeline.firstVideoClip)
        XCTAssertNil(clip.camera)
        clip.camera = ClipCamera()
        var animation = ClipAnimation()
        let end = try TimelineTime.seconds(4)
        animation.update(.cameraY) {
            $0.set(.number(0), at: .zero, interpolation: .easeInOut)
            $0.set(.number(1), at: end)
        }
        clip.animation = animation
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        let reopened = try decoder.decode(VideoProject.self, from: encoder.encode(project))
        XCTAssertTrue(reopened.needsLayerCompositor)
        let restored = try XCTUnwrap(reopened.timeline.firstVideoClip)
        let middle = try TimelineTime.seconds(2)
        XCTAssertEqual(restored.evaluated(at: .zero).camera?.y, 0)
        XCTAssertEqual(restored.evaluated(at: middle).camera?.y, 0.5)
        XCTAssertEqual(restored.evaluated(at: end).camera?.y, 1)
        XCTAssertEqual(restored.transform, VisualTransform())
    }

    @MainActor
    func testCameraSliderPreviewsBeforeReleaseAndPreservesTheTitle() throws {
        var project = project()
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.camera = ClipCamera()
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        let track = UUID()
        let title = TextClip(placement: .init(id: UUID(), trackID: track, timelineStart: .zero,
                                              duration: try .seconds(3)))
        project.timeline.tracks.insert(.init(id: track, name: "Title", kind: .text, items: [.text(title)]), at: 0)
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()

        model.previewCameraValue(1.4, property: .cameraZoom, showsResult: true)
        XCTAssertEqual(model.renderPreviewProject.timeline.videoClip(id: clip.id)?.camera?.zoom, 1.4)
        XCTAssertEqual(model.renderPreviewProject.timeline.item(id: title.id), .text(title))
        XCTAssertEqual(model.project, project)
        XCTAssertTrue(model.history.undoEntries.isEmpty)

        model.previewCameraValue(0.7, property: .cameraY, showsResult: true)
        let draft = try XCTUnwrap(model.renderPreviewProject.timeline.videoClip(id: clip.id)?.camera)
        XCTAssertEqual(draft.y, 0.7)
        XCTAssertGreaterThan(draft.zoom, 1)
        model.setCameraValue(0.7, property: .cameraY)
        XCTAssertNil(model.cameraPreview.edit)
        XCTAssertEqual(model.selectedClip?.camera, draft)
        XCTAssertEqual(model.history.undoEntries.count, 1)
    }

    @MainActor
    func testCameraGestureChangesOneHistoryEntryAndPanelFitsBothWidths() throws {
        var project = project()
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        let camera = ClipCamera(mode: .crop, y: 0)
        clip.camera = camera
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        var updated = camera
        updated.cropHeight = 0.24
        updated.x = 0.3
        model.applyCameraGesture(from: camera, to: updated, clipID: clip.id, time: .zero)
        XCTAssertEqual(model.history.undoEntries.count, 1)
        XCTAssertEqual(model.selectedClip?.camera, updated)
        model.undo()
        XCTAssertEqual(model.selectedClip?.camera, camera)

        for width in [320.0, 600.0] {
            let panel = ClipCameraPanel(model: model, tracking: ClipCameraTracking(),
                                        showsFrame: .constant(true), pickingFocus: .constant(false))
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
