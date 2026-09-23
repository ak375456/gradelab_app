import XCTest
import UIKit
@testable import GradeLab

/// The Mac workspace shipped onto iPad once, because it was gated on
/// `usesDesktopWorkspace` — which is true on iPad by design. These guard the
/// two halves of that mistake: the input that must belong to a pointer, and
/// the cost that came with the panel.
@MainActor
final class DesktopOnlySurfaceTests: XCTestCase {

    /// `buttonMaskRequired` filters buttons, and a finger presses none — so on
    /// its own it let every tap through and opened the clip menu on touch.
    /// The recogniser has to be restricted to an indirect pointer as well.
    func testTheClipMenuClickIsAPointerGestureOnly() throws {
        let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 300))
        canvas.layoutIfNeeded()

        func recognizers(_ view: UIView) -> [UIGestureRecognizer] {
            (view.gestureRecognizers ?? []) + view.subviews.flatMap(recognizers)
        }
        let secondary = recognizers(canvas)
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.buttonMaskRequired.contains(.secondary) }

        XCTAssertEqual(secondary.count, 1, "exactly one recogniser opens the clip menu")
        let allowed = try XCTUnwrap(secondary.first).allowedTouchTypes
        XCTAssertEqual(allowed, [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)],
                       "a direct touch must not reach it, or tapping a clip opens the menu on iPad")
    }

    /// Tapping a clip is plain selection on every platform, so nothing else may
    /// quietly require a secondary button either.
    func testOrdinaryTapsAreNotButtonFiltered() {
        let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 300))
        canvas.layoutIfNeeded()
        func recognizers(_ view: UIView) -> [UIGestureRecognizer] {
            (view.gestureRecognizers ?? []) + view.subviews.flatMap(recognizers)
        }
        let plainTaps = recognizers(canvas)
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { !$0.buttonMaskRequired.contains(.secondary) }
        XCTAssertFalse(plainTaps.isEmpty, "selection still happens on a plain tap")
        for tap in plainTaps {
            let allowed = tap.allowedTouchTypes
            XCTAssertTrue(allowed.isEmpty
                          || allowed.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)),
                          "a finger must still be able to select a clip")
        }
    }

    // MARK: - What the bin costs

    /// Counted in one pass for the whole project. Asking per row walked every
    /// timeline item per asset, which is what made the editor judder with a
    /// couple of dozen sources loaded.
    func testUsageIsCountedOnceForEveryAsset() throws {
        let model = try EditorViewModel(project: GradeProject(
            sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
            displayName: "Clip", metadata: makeMetadata(duration: 10)))
        let primary = model.project.primaryAssetID
        model.placeAsset(primary, as: .mainTrack)
        model.placeAsset(primary, as: .overlay(at: 2))

        let counts = model.assetUsageCounts
        XCTAssertEqual(counts[primary], 3)
        XCTAssertEqual(counts[primary], model.usageCount(of: primary),
                       "the one-pass count and the per-asset one must agree")
        XCTAssertNil(counts[UUID()])
    }

    /// The panel takes values so a playhead tick cannot rebuild it. If it ever
    /// goes back to holding the view model this stops compiling, which is the
    /// point.
    func testThePanelRebuildsOnlyWhenItsMediaChanges() throws {
        let asset = ProjectMediaAsset(id: UUID(), url: URL(fileURLWithPath: "/tmp/a.mov"),
                                      sourceRange: .init(start: .zero, duration: try .seconds(4)),
                                      videoMetadata: nil, stillImage: .init(width: 100, height: 100))
        func panel(usage: Int, enabled: Bool = true) -> MediaBinPanel {
            MediaBinPanel(assets: [asset], usageCounts: [asset.id: usage], assetFrames: [:],
                          isEnabled: enabled, onImport: {}, onPlace: { _, _ in }, onImportFiles: { _ in })
        }
        XCTAssertEqual(panel(usage: 1), panel(usage: 1), "same media, same panel")
        XCTAssertNotEqual(panel(usage: 1), panel(usage: 2), "a clip added or removed shows")
        XCTAssertNotEqual(panel(usage: 1), panel(usage: 1, enabled: false), "availability shows")
    }
}
