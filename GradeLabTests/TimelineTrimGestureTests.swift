import XCTest
import UIKit
@testable import GradeLab

/// Drives the UIKit action with the positions a pan reports after crossing its
/// recognition threshold, rather than calling the editing model directly.
@MainActor
final class TimelineTrimGestureTests: XCTestCase {
    private final class Touch: UITouch {
        var point = CGPoint.zero
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private final class Pan: UIPanGestureRecognizer {
        var phase: UIGestureRecognizer.State = .possible
        var point = CGPoint.zero
        var travel = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { phase }
            set { phase = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { point }
        override func translation(in view: UIView?) -> CGPoint { travel }
    }

    private func fixture(time: Double = 0, onVideoLayer: Bool = false) throws -> (TimelineCanvas, EditorViewModel, UUID) {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/handle-recovery.mov"),
            displayName: "Handle recovery", metadata: makeVideoMetadata(durationSeconds: 12))
        let original = try XCTUnwrap(project.timeline.firstVideoClip).id
        if onVideoLayer {
            try TimelineEditing.moveToVideoLayer(original, destinationTrackID: nil, at: .zero, in: &project)
        }
        let retained = try TimelineEditing.split(original, at: .seconds(3), in: &project)
        try TimelineEditing.deleteClosingGaps(original, in: &project)
        if onVideoLayer { try TimelineEditing.insertMove(retained, to: .zero, in: &project) }
        let model = try EditorViewModel(project: project)
        let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: 390, height: 130))
        canvas.clips = project.timeline.items.compactMap(TimelineDisplayClip.init)
        canvas.tracks = project.timeline.tracks
        canvas.assets = project.assets
        canvas.selectedID = retained
        canvas.selectedIDs = [retained]
        canvas.isSnappingEnabled = false
        canvas.minimumDuration = 1 / 30
        canvas.onEdit = model.editTiming
        canvas.layoutIfNeeded()
        canvas.update(time: time)
        return (canvas, model, retained)
    }

    private func send(_ phase: UIGestureRecognizer.State, translation: CGFloat,
                      from origin: CGPoint, pan: Pan, canvas: TimelineCanvas) {
        if phase == .began {
            let touch = Touch()
            touch.point = origin
            let scroll = canvas.subviews.compactMap { $0 as? UIScrollView }.first!
            let trimPan = scroll.gestureRecognizers!.compactMap { $0 as? UIPanGestureRecognizer }
                .first { $0 !== scroll.panGestureRecognizer }!
            let accepted = canvas.gestureRecognizer(trimPan, shouldReceive: touch)
            XCTAssertEqual(canvas.gestureRecognizerShouldBegin(trimPan), accepted)
        }
        pan.phase = phase
        pan.travel = CGPoint(x: translation, y: 0)
        pan.point = CGPoint(x: origin.x + translation, y: origin.y)
        canvas.perform(NSSelectorFromString("edited:"), with: pan)
    }

    func testLeftwardGrabUsesTouchDownBeforePanRecognitionMovement() throws {
        let (canvas, model, retained) = try fixture()
        let pan = Pan()
        // A valid grab 16pt left of the edge is 28pt away by .began.
        let origin = CGPoint(x: 195 - 16, y: TimelineMetrics.rowsTop + 30)
        send(.began, translation: -12, from: origin, pan: pan, canvas: canvas)
        send(.changed, translation: -96, from: origin, pan: pan, canvas: canvas)
        send(.ended, translation: -96, from: origin, pan: pan, canvas: canvas)
        XCTAssertNil(model.editError)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.sourceRange.start, try .seconds(1))
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.placement.timelineStart, .zero)
    }

    func testVideoLayerLeftHandleRestoresAllDeletedZeroToThreeSecondsAtZero() throws {
        let (canvas, model, retained) = try fixture(onVideoLayer: true)
        let before = model.project.timeline
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.placement.timelineStart, .zero)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.sourceRange.start, try .seconds(3))
        let pan = Pan()
        let origin = CGPoint(x: 201, y: TimelineMetrics.rowsTop + 30)
        send(.began, translation: -12, from: origin, pan: pan, canvas: canvas)
        send(.changed, translation: -144, from: origin, pan: pan, canvas: canvas)
        send(.ended, translation: -144, from: origin, pan: pan, canvas: canvas)
        XCTAssertNil(model.editError)
        let clip = try XCTUnwrap(model.project.timeline.videoClip(id: retained))
        XCTAssertEqual(clip.sourceRange.start, .zero)
        XCTAssertEqual(clip.sourceRange.duration, try .seconds(12))
        XCTAssertEqual(clip.placement.timelineStart, .zero)
        XCTAssertEqual(clip.placement.duration, try .seconds(12))
        let restored = model.project.timeline
        model.undo()
        XCTAssertEqual(model.project.timeline, before)
        model.redo()
        XCTAssertEqual(model.project.timeline, restored)
    }

    func testVisibleHeadCanBeGrabbedEvenWhenRecognitionCrossesIntoHeader() throws {
        let header = TimelineMetrics.headerWidth(for: 390)
        let time = (195 - header - 4) / 48
        let (canvas, model, retained) = try fixture(time: time)
        let pan = Pan()
        let origin = CGPoint(x: header + 8, y: TimelineMetrics.rowsTop + 30)
        send(.began, translation: -12, from: origin, pan: pan, canvas: canvas)
        send(.changed, translation: -48, from: origin, pan: pan, canvas: canvas)
        send(.ended, translation: -48, from: origin, pan: pan, canvas: canvas)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.sourceRange.start, try .seconds(2))
    }

    func testShortDragCommitsTravelEvenWithoutAChangedCallback() throws {
        let (canvas, model, retained) = try fixture()
        let pan = Pan()
        let origin = CGPoint(x: 195 + 6, y: TimelineMetrics.rowsTop + 30)
        send(.began, translation: -16, from: origin, pan: pan, canvas: canvas)
        send(.ended, translation: -16, from: origin, pan: pan, canvas: canvas)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.sourceRange.start, try .seconds(8 / 3))
    }

    func testDragStartingInClipBodyDoesNotBecomeAHandleGrab() throws {
        let (canvas, model, _) = try fixture()
        let before = model.project.timeline
        let pan = Pan()
        let origin = CGPoint(x: 300, y: TimelineMetrics.rowsTop + 30)
        send(.began, translation: -105, from: origin, pan: pan, canvas: canvas)
        send(.changed, translation: -153, from: origin, pan: pan, canvas: canvas)
        send(.ended, translation: -153, from: origin, pan: pan, canvas: canvas)
        XCTAssertEqual(model.project.timeline, before)
    }

    func testSlowHandleGrabCannotBecomeAWholeClipMove() throws {
        let (canvas, _, _) = try fixture()
        let scroll = try XCTUnwrap(canvas.subviews.compactMap { $0 as? UIScrollView }.first)
        let hold = try XCTUnwrap(scroll.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }
            .first { $0.delegate === canvas })
        let touch = Touch()
        touch.point = CGPoint(x: 201, y: TimelineMetrics.rowsTop + 30)
        XCTAssertFalse(canvas.gestureRecognizer(hold, shouldReceive: touch))
        touch.point.x = 300
        XCTAssertTrue(canvas.gestureRecognizer(hold, shouldReceive: touch))
    }

    func testRightHandleCanStillTrimAndRestoreTheTail() throws {
        let (canvas, model, retained) = try fixture()
        canvas.applyExternalZoom(12)
        let pan = Pan()
        let origin = CGPoint(x: 195 + 9 * 12 - 6, y: TimelineMetrics.rowsTop + 30)
        send(.began, translation: -6, from: origin, pan: pan, canvas: canvas)
        send(.ended, translation: -12, from: origin, pan: pan, canvas: canvas)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.placement.duration, try .seconds(8))

        canvas.clips = model.project.timeline.items.compactMap(TimelineDisplayClip.init)
        let trimmedEdge = CGPoint(x: 195 + 8 * 12 - 6, y: origin.y)
        send(.began, translation: 6, from: trimmedEdge, pan: pan, canvas: canvas)
        send(.ended, translation: 12, from: trimmedEdge, pan: pan, canvas: canvas)
        XCTAssertNil(model.editError)
        XCTAssertEqual(model.project.timeline.videoClip(id: retained)?.placement.duration, try .seconds(9))
    }

    func testHeadHandleVisiblyFollowsTheFingerDuringRecovery() throws {
        let (canvas, _, _) = try fixture()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func snapshot() -> UIImage {
            UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { _ in
                canvas.draw(canvas.bounds)
            }
        }
        func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
            let cgImage = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cgImage.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            let offset = y * cgImage.bytesPerRow + x * cgImage.bitsPerPixel / 8
            return Array(UnsafeBufferPointer(start: bytes + offset, count: cgImage.bitsPerPixel / 8))
        }
        let before = snapshot()
        let pan = Pan()
        let origin = CGPoint(x: 201, y: TimelineMetrics.rowsTop + 30)
        send(.began, translation: -12, from: origin, pan: pan, canvas: canvas)
        send(.changed, translation: -24, from: origin, pan: pan, canvas: canvas)
        let during = snapshot()
        let handleColor = try pixel(before, x: 205, y: 53)
        XCTAssertEqual(try pixel(during, x: 181, y: 53), handleColor)
        XCTAssertNotEqual(try pixel(during, x: 205, y: 53), handleColor)
        for (name, image) in [("Before recovering head", before), ("Dragging head left", during)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        send(.cancelled, translation: -24, from: origin, pan: pan, canvas: canvas)
    }
}
