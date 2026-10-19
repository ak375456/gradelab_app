import SwiftUI
import XCTest
@testable import GradeLab

final class TimelineMarkerPersistenceTests: XCTestCase {
    func testMarkerTimecodeUsesCanvasFramesAndSupportsHours() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/marker.mov"),
                                   displayName: "Markers", metadata: makeVideoMetadata(durationSeconds: 7_200))
        project.canvas.frameDuration = try TimelineTime(value: 1, timescale: 25)
        for (seconds, expected) in [(1.04, "00:00:01:01"), (59.96, "00:00:59:24"),
                                    (60.0, "00:01:00:00"), (3_661.48, "01:01:01:12")] {
            let marker = TimelineMarker(id: UUID(), time: try .seconds(seconds))
            XCTAssertEqual(marker.timeLabel(in: project), expected)
        }
        project.canvas.frameDuration = try TimelineTime(value: 1001, timescale: 30_000)
        let fractionalRateMarker = TimelineMarker(id: UUID(), time: try TimelineTime(value: 31_031, timescale: 30_000))
        XCTAssertEqual(fractionalRateMarker.timeLabel(in: project), "00:00:01:01")
    }

    func testMarkerTimecodeFallsBackToKnownSourceRateWithoutInventingFrames() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/marker.mov"),
                                   displayName: "Markers", metadata: makeMetadata(nominalFrameRate: 60))
        project.canvas.frameDuration = nil
        let marker = TimelineMarker(id: UUID(), time: try .seconds(1.5))
        XCTAssertEqual(marker.timeLabel(in: project), "00:00:01:30")
        let unknownRate = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/marker.mov"), displayName: "Markers",
                                       metadata: makeMetadata(nominalFrameRate: nil, minimumFrameDuration: nil))
        XCTAssertEqual(marker.timeLabel(in: unknownRate), "00:00:01:--")
    }

    func testLegacyAndUnrecognizedColorsOpenAsYellow() throws {
        let marker = TimelineMarker(id: UUID(), time: try .seconds(3.5), label: "Beat", color: .purple)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(marker)) as? [String: Any])
        for color in [nil, "future-color"] as [String?] {
            json["color"] = color
            let decoded = try JSONDecoder().decode(TimelineMarker.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.color, .yellow)
            XCTAssertEqual(decoded.id, marker.id)
            XCTAssertEqual(decoded.time, marker.time)
            XCTAssertEqual(decoded.label, "Beat")
        }
    }

    func testEveryColorSurvivesSavingWithoutChangingMovieContent() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/marker.mov"),
                                   displayName: "Markers", metadata: makeVideoMetadata(durationSeconds: 10))
        let duration = project.timeline.duration
        let tracks = project.timeline.tracks
        project.timeline.markers = try TimelineMarkerColor.allCases.enumerated().map { index, color in
            .init(id: UUID(), time: try .seconds(Double(index)), color: color)
        }
        let reopened = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(reopened, project)
        XCTAssertEqual(reopened.timeline.duration, duration)
        XCTAssertEqual(reopened.timeline.tracks, tracks)
        XCTAssertFalse(reopened.needsLayerCompositor)
        try reopened.validate()
    }
}

@MainActor
final class TimelineMarkerInteractionTests: XCTestCase {
    private func canvas(width: Double) -> TimelineCanvas {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/marker.mov"),
                                   displayName: "Markers", metadata: makeVideoMetadata(durationSeconds: 20))
        let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 180))
        canvas.tracks = project.timeline.tracks
        canvas.clips = project.timeline.items.compactMap(TimelineDisplayClip.init)
        canvas.layoutIfNeeded()
        return canvas
    }

    private func model() throws -> EditorViewModel {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/marker.mov"),
                                   displayName: "Markers", metadata: makeVideoMetadata(durationSeconds: 10))
        let first = try XCTUnwrap(project.timeline.firstVideoClip)
        let second = VideoClip(placement: .init(id: UUID(), trackID: first.placement.trackID,
                                               timelineStart: try .seconds(10), duration: first.placement.duration),
                               assetID: first.assetID, sourceRange: first.sourceRange)
        project.timeline.tracks[0].items.append(.video(second))
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        model.selectClips(Set([first.id, second.id]))
        return model
    }

    func testAddingAnExistingMarkerKeepsItWithoutRemovingOrDuplicatingIt() throws {
        let model = try model()
        let selection = model.selectedClipIDs
        let marker = try XCTUnwrap(model.addMarker())
        XCTAssertEqual(model.addMarker()?.id, marker.id)
        XCTAssertEqual(model.project.timeline.markers, [marker])
        XCTAssertEqual(model.history.undoEntries.count, 1)
        XCTAssertEqual(model.selectedClipIDs, selection)
    }

    func testColorAndRemovalEachUndoOnceAndPreserveSelectionAndTiming() throws {
        let model = try model()
        let selection = model.selectedClipIDs
        let tracks = model.project.timeline.tracks
        let time = model.timelineTime
        let marker = try XCTUnwrap(model.addMarker())
        model.setMarkerColor(marker.id, to: .blue)
        model.setMarkerColor(marker.id, to: .blue)
        XCTAssertEqual(model.history.undoEntries.count, 2, "reselecting a color must not add history")
        XCTAssertEqual(model.project.timeline.markers.first?.color, .blue)
        model.deleteMarker(marker.id)
        XCTAssertTrue(model.project.timeline.markers.isEmpty)
        XCTAssertEqual(model.history.undoEntries.count, 3)
        XCTAssertEqual(model.selectedClipIDs, selection)
        XCTAssertEqual(model.timelineTime, time)
        XCTAssertEqual(model.project.timeline.tracks, tracks)
        XCTAssertFalse(model.isPreparingTimeline, "metadata edits must not rebuild playback")

        model.undo()
        XCTAssertEqual(model.project.timeline.markers.first?.color, .blue)
        model.undo()
        XCTAssertEqual(model.project.timeline.markers.first?.color, .yellow)
        model.redo()
        XCTAssertEqual(model.project.timeline.markers.first?.color, .blue)
        XCTAssertEqual(model.selectedClipIDs, selection)
        model.suspendPreviewForExport()
    }

    func testMarkerTapDoesNotSeekOrChangeClipSelectionOnNarrowAndWideCanvases() throws {
        for width in [320.0, 1_024] {
            let canvas = canvas(width: width)
            let marker = TimelineMarker(id: UUID(), time: try .seconds(10))
            canvas.markers = [marker]
            var edited: UUID?
            canvas.onSelectMarker = { edited = $0.id; XCTAssertEqual($1.x, 0.5, accuracy: 0.001) }
            canvas.onSelect = { _ in XCTFail("marker tap changed the clip selection") }
            canvas.onSelectTransition = { _ in XCTFail("marker tap selected a transition") }
            canvas.onBeginSeek = { XCTFail("marker tap began scrubbing") }
            canvas.onSeek = { _ in XCTFail("marker tap moved the playhead") }
            canvas.onBeginEdit = { XCTFail("marker tap started a clip edit") }
            for zoom in [4.0, 48, 2_400] {
                canvas.applyExternalZoom(zoom)
                canvas.update(time: 10)
                canvas.handleTap(at: CGPoint(x: width / 2 + 15, y: TimelineMetrics.markerCenterY))
                XCTAssertEqual(edited, marker.id)
                edited = nil
            }
        }
    }

    func testMarkerHitTargetsNeverExtendIntoClipsHeadersOrOffscreenMarkers() throws {
        let canvas = canvas(width: 390)
        let marker = TimelineMarker(id: UUID(), time: try .seconds(10))
        let nearby = TimelineMarker(id: UUID(), time: try .seconds(10.25))
        canvas.markers = [marker, nearby]
        canvas.update(time: 10)
        XCTAssertEqual(canvas.hitMarker(at: CGPoint(x: 207, y: 25))?.id, nearby.id, "nearest marker wins")
        XCTAssertNil(canvas.hitMarker(at: CGPoint(x: 195, y: TimelineMetrics.rulerHeight)))
        XCTAssertNil(canvas.hitMarker(at: CGPoint(x: 195, y: 80)))
        XCTAssertNil(canvas.hitMarker(at: CGPoint(x: 110, y: 25)))
        canvas.markers = [.init(id: UUID(), time: try .seconds(8))] // x=99, behind the header
        XCTAssertNil(canvas.hitMarker(at: CGPoint(x: 118, y: 25)))
    }

    func testEmptyRulerStillSeeksAndClipBodyStillSelects() throws {
        let model = try model()
        let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: 390, height: 180))
        canvas.tracks = model.project.timeline.tracks
        canvas.clips = model.project.timeline.items.compactMap(TimelineDisplayClip.init)
        canvas.markers = [.init(id: UUID(), time: .zero)]
        canvas.layoutIfNeeded()
        var seeks = 0
        var selected: UUID?
        canvas.onSeek = { _ in seeks += 1 }
        canvas.onSelect = { selected = $0 }
        canvas.onSelectMarker = { _, _ in XCTFail("empty ruler or clip tap opened marker controls") }
        canvas.handleTap(at: CGPoint(x: 280, y: 25))
        XCTAssertEqual(seeks, 1)
        canvas.handleTap(at: CGPoint(x: 230, y: 65))
        XCTAssertEqual(selected, canvas.clips.first?.id)
    }

    #if targetEnvironment(macCatalyst)
    func testTimelineMarkerPresentsAnAnchoredEditorWithoutChangingTheProject() throws {
        let model = try model()
        let marker = try XCTUnwrap(model.addMarker())
        let before = model.project
        let selection = model.selectedClipIDs
        let root = EditorView(model: model, onBack: { _ in }, onShowSource: {}, onSettingsChanged: { _, _ in })
        let controller = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        func settle() {
            let end = Date().addingTimeInterval(0.4)
            while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            controller.view.layoutIfNeeded()
        }
        settle()
        func canvases(_ view: UIView) -> [TimelineCanvas] {
            (view as? TimelineCanvas).map { [$0] } ?? view.subviews.flatMap(canvases)
        }
        let canvas = try XCTUnwrap(canvases(controller.view).first)
        canvas.handleTap(at: CGPoint(x: canvas.bounds.midX, y: TimelineMetrics.markerCenterY))
        settle()
        let presented = try XCTUnwrap(controller.presentedViewController)
        XCTAssertNotNil(presented.popoverPresentationController, "wide workspace should use a popover")
        XCTAssertGreaterThanOrEqual(presented.preferredContentSize.width, 280)
        XCTAssertLessThanOrEqual(presented.preferredContentSize.width, 420)
        XCTAssertGreaterThanOrEqual(presented.preferredContentSize.height, 300)
        XCTAssertLessThanOrEqual(presented.preferredContentSize.height, 440)
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.selectedClipIDs, selection)
        XCTAssertEqual(model.project.timeline.markers.first?.id, marker.id)
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "marker-workspace-popover"; attachment.lifetime = .keepAlways; add(attachment)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("marker-workspace-popover.png"))
        presented.dismiss(animated: false)
    }
    #endif

    func testMarkerEditorFitsPhoneAndPopoverWidthsAndLargerText() throws {
        XCTAssertNotNil(UIImage(systemName: "bookmark"))
        XCTAssertNotNil(UIImage(systemName: "plus.circle.fill"))
        XCTAssertNotNil(UIImage(systemName: "arrow.right.to.line"))
        let model = try model()
        let marker = try XCTUnwrap(model.addMarker())
        for (width, textSize, suffix) in [(320.0, DynamicTypeSize.large, "phone"),
                                         (340.0, .large, "popover"),
                                         (320.0, .accessibility3, "large-text")] {
            let panel = MarkerEditor(model: model, markerID: marker.id).environment(\.dynamicTypeSize, textSize)
            let controller = UIHostingController(rootView: panel)
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 400)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.view.frame = window.bounds
            window.layoutIfNeeded()
            let end = Date().addingTimeInterval(0.2)
            while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            controller.view.layoutIfNeeded()
            func scrollViews(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            let scroll = try XCTUnwrap(scrollViews(controller.view).first)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, suffix)
            if textSize.isAccessibilitySize {
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, "large text must remain scrollable")
            }
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { controller.view.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "marker-\(suffix)"; attachment.lifetime = .keepAlways; add(attachment)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("marker-\(suffix).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("MARKER_PANEL_SHOT \(url.path)")
        }
    }
}
