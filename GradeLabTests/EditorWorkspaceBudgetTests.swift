import XCTest
import SwiftUI
@testable import GradeLab

/// The tall layout stacks rigid heights. If the picture and the timeline
/// together ask for more than the window has, SwiftUI does not shrink them — it
/// lets the mode bar fall off the bottom, and with it the first-run warm-up
/// notice. These assert the budget adds up on the screens the app ships to.
final class EditorWorkspaceBudgetTests: XCTestCase {

    /// GeometryReader heights, i.e. the screen minus its safe areas, for the
    /// phones and tablets this has to work on.
    private let heights: [(name: String, height: CGFloat)] = [
        ("iPhone SE", 647),
        ("iPhone 13 mini", 715),
        ("iPhone 16", 759),
        ("iPhone 16 Pro Max", 848),
        ("iPad portrait", 956),
        ("iPad split view", 640)
    ]

    /// The whole column, laid out the way `editorLayout` stacks it.
    private func total(height: CGFloat, preview: CGFloat, timeline: CGFloat,
                       warmup: Bool) -> CGFloat {
        preview + timeline + EditorWorkspaceBudget.chrome(showsTimeline: true, showsWarmupNotice: warmup)
    }

    func testPictureAndTimelineTogetherAlwaysLeaveRoomForTheModeBar() {
        for warmup in [true, false] {
            for device in heights {
                let preview = EditorWorkspaceBudget.previewCeiling(
                    height: device.height, floor: 140, showsTimeline: true, showsWarmupNotice: warmup)
                let timeline = EditorWorkspaceBudget.timelineCeiling(
                    height: device.height, previewHeight: preview, showsWarmupNotice: warmup)
                let used = total(height: device.height, preview: preview, timeline: timeline, warmup: warmup)
                XCTAssertLessThanOrEqual(
                    used, device.height + 0.5,
                    "\(device.name) overflows by \(used - device.height)pt with warmup=\(warmup)")
            }
        }
    }

    func testAPictureDraggedTooLargeIsCorrectedRatherThanHidingTheModeBar() {
        // The iPad screenshot that started this: a stored preview height of
        // about two thirds of the window, which on its own pushed the mode bar
        // off the bottom.
        let height: CGFloat = 956
        let dragged: CGFloat = 640
        let allowed = EditorWorkspaceBudget.previewCeiling(
            height: height, floor: 140, showsTimeline: true, showsWarmupNotice: false)
        XCTAssertLessThan(allowed, dragged, "a workspace stored before the ceiling existed must be reined in")
        XCTAssertGreaterThanOrEqual(
            height - allowed - EditorWorkspaceBudget.chrome(showsTimeline: true, showsWarmupNotice: false),
            EditorWorkspaceBudget.minimumTimeline)
    }

    func testTheTimelineNeverGivesUpItsToolbarRulerAndARow() {
        for device in heights {
            let ceiling = EditorWorkspaceBudget.timelineCeiling(
                height: device.height, previewHeight: device.height * 0.9, showsWarmupNotice: true)
            XCTAssertGreaterThanOrEqual(ceiling, EditorWorkspaceBudget.minimumTimeline, device.name)
        }
        // The floor really does hold a toolbar, a ruler and a row.
        let content = TimelineToolbar<EmptyView>.height + TimelineMetrics.rowsTop
            + TimelineTrackHeightChoice.compact.points(for: .mainVideo)
        XCTAssertLessThanOrEqual(content, EditorWorkspaceBudget.minimumTimeline)
    }

    func testHidingTheTimelineHandsItsRoomBackToThePicture() {
        let height: CGFloat = 759
        let withTimeline = EditorWorkspaceBudget.previewCeiling(
            height: height, floor: 140, showsTimeline: true, showsWarmupNotice: false)
        let without = EditorWorkspaceBudget.previewCeiling(
            height: height, floor: 140, showsTimeline: false, showsWarmupNotice: false)
        XCTAssertGreaterThan(without, withTimeline)
        XCTAssertEqual(without, height * 0.72, accuracy: 0.001)
    }

    /// The default one-track workspace, on every device, on first run — the
    /// exact situation the redesign broke. Nothing may overflow, and the
    /// timeline must still be a timeline: toolbar, ruler, and a row of at
    /// least the compact size under it. Small screens shrink the row rather
    /// than clipping it, which is `TimelineCanvas.clipHeight`'s job.
    func testTheDefaultWorkspaceFitsEveryDeviceOnFirstRun() {
        for (name, height) in heights {
            let preview = defaultPreview(height: height, warmup: true)
            let timeline = EditorWorkspaceBudget.timelineCeiling(
                height: height, previewHeight: preview, showsWarmupNotice: true)
            let used = total(height: height, preview: preview, timeline: timeline, warmup: true)
            XCTAssertLessThanOrEqual(used, height + 0.5, "\(name) overflows by \(used - height)pt")

            let canvas = timeline - TimelineToolbar<EmptyView>.height
            XCTAssertGreaterThanOrEqual(
                canvas - TimelineMetrics.rowsTop,
                TimelineTrackHeightChoice.compact.points(for: .mainVideo),
                "\(name) has no room for a row at all")
        }
    }

    /// Anything from a current-generation phone upwards shows the whole
    /// regular row by default, warm-up notice and all — a filmstrip above a
    /// waveform, not a squeezed strip.
    func testACurrentPhoneShowsAFullHeightRowOnFirstRun() {
        let oneRow = TimelineToolbar<EmptyView>.height + TimelineMetrics.rowsTop
            + TimelineTrackHeightChoice.regular.points(for: .mainVideo)
        for (name, height) in heights where height >= 759 {
            let ceiling = EditorWorkspaceBudget.timelineCeiling(
                height: height, previewHeight: defaultPreview(height: height, warmup: true),
                showsWarmupNotice: true)
            XCTAssertGreaterThanOrEqual(ceiling, oneRow, "\(name) cannot show a whole row on first run")
        }
    }

    /// `previewHeight`'s untouched default for a single-track project.
    private func defaultPreview(height: CGFloat, warmup: Bool) -> CGFloat {
        min(height * 0.40, EditorWorkspaceBudget.previewCeiling(
            height: height, floor: 140, showsTimeline: true, showsWarmupNotice: warmup))
    }
}
