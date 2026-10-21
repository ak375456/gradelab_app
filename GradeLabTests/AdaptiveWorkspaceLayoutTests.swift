import SwiftUI
import UIKit
import XCTest
@testable import GradeLab

final class AdaptiveWorkspaceLayoutTests: XCTestCase {
    func testLandscapeIPhoneKeepsCompactToolsEvenWithRegularWidth() {
        XCTAssertTrue(AdaptiveWorkspaceLayout.hasExpandedPhoneSpace(horizontal: .regular, vertical: .regular))
        XCTAssertFalse(AdaptiveWorkspaceLayout.hasExpandedPhoneSpace(horizontal: .regular, vertical: .compact))
        XCTAssertFalse(AdaptiveWorkspaceLayout.hasExpandedPhoneSpace(horizontal: .compact, vertical: .regular))
    }

    func testUnfoldedPhoneKeepsPortraitCanvasFullWidth() {
        XCTAssertTrue(AdaptiveWorkspaceLayout.usesColumns(size: .init(width: 951, height: 669),
            horizontalSizeClass: .regular, idiom: .phone, isMac: false))
        XCTAssertFalse(AdaptiveWorkspaceLayout.usesColumns(size: .init(width: 669, height: 951),
            horizontalSizeClass: .regular, idiom: .phone, isMac: false))
        XCTAssertFalse(AdaptiveWorkspaceLayout.usesColumns(size: .init(width: 390, height: 844),
            horizontalSizeClass: .compact, idiom: .phone, isMac: false))
        XCTAssertFalse(AdaptiveWorkspaceLayout.usesColumns(size: .init(width: 500, height: 800),
            horizontalSizeClass: .regular, idiom: .phone, isMac: false), "a narrow split must still stack")
        XCTAssertTrue(AdaptiveWorkspaceLayout.usesColumns(size: .init(width: 760, height: 350),
            horizontalSizeClass: .compact, idiom: .phone, isMac: false))
    }

    func testIPadAndMacKeepTheirExistingLayoutChoices() {
        for idiom in [UIUserInterfaceIdiom.pad, .mac] {
            for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
                for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
                    XCTAssertEqual(AdaptiveWorkspaceLayout.usesColumns(size: size, horizontalSizeClass: sizeClass,
                        idiom: idiom, isMac: idiom == .mac), size.width > size.height)
                }
            }
        }
    }

    func testCornerObstructionOnlyInsetsHeaderAndClearsTheBody() {
        let size = CGSize(width: 951, height: 669)
        let camera = CGRect(x: 850, y: 0, width: 101, height: 106)
        let clearance = WorkspaceHeaderClearance.resolve(size: size, occlusions: [camera])
        XCTAssertTrue(clearance.isActive)
        let header = CGRect(x: clearance.leading, y: 0,
                            width: size.width - clearance.leading - clearance.trailing, height: 44)
        let picture = CGRect(x: 0, y: clearance.height, width: size.width, height: 400)
        XCTAssertFalse(header.intersects(camera), "Export and Settings must remain outside the camera/status region")
        XCTAssertFalse(picture.intersects(camera))
        XCTAssertEqual(picture.midX, size.width / 2, "content below the status area stays centered on the display")
        XCTAssertEqual(picture.width, size.width, "the entire right column must not be discarded")
    }

    func testLeftSideAndRightToLeftLayoutsAvoidTheSamePhysicalRegion() {
        let size = CGSize(width: 951, height: 669)
        let camera = CGRect(x: 0, y: -20, width: 105, height: 126)
        let ltr = WorkspaceHeaderClearance.resolve(size: size, occlusions: [camera])
        let rtl = WorkspaceHeaderClearance.resolve(size: size, occlusions: [camera], layoutDirection: .rightToLeft)
        XCTAssertEqual(ltr.leading, 105)
        XCTAssertEqual(ltr.trailing, 0)
        XCTAssertEqual(rtl.trailing, ltr.leading)
        XCTAssertEqual(rtl.leading, ltr.trailing)
        XCTAssertEqual(ltr.height, 106)
        XCTAssertEqual(rtl.height, ltr.height)
    }

    func testClosedPhoneReclaimsTheSpaceBelowACornerCamera() {
        let size = CGSize(width: 466, height: 678)
        let camera = CGRect(x: 361, y: 0, width: 105, height: 110)
        let clearance = WorkspaceHeaderClearance.resolve(size: size, occlusions: [camera])
        XCTAssertTrue(clearance.isActive)
        XCTAssertEqual(clearance.trailing, 105)
        XCTAssertEqual(clearance.height, 110)
        // A conventional iPhone's centered camera must retain its normal safe area.
        XCTAssertFalse(WorkspaceHeaderClearance.resolve(size: size,
            occlusions: [.init(x: 190, y: 0, width: 86, height: 44)]).isActive)
    }

    func testTallerStatusHeaderLeavesRoomForTimelineAndModeBar() {
        let window = CGSize(width: 466, height: 678)
        let headerHeight: CGFloat = 180
        let budget = AdaptiveWorkspaceLayout.budgetSize(window, headerHeight: headerHeight)
        let preview = min(budget.height * 0.4, EditorWorkspaceBudget.previewCeiling(
            height: budget.height, floor: 140, showsTimeline: true, showsWarmupNotice: false))
        let timeline = min(200, EditorWorkspaceBudget.timelineCeiling(
            height: budget.height, previewHeight: preview, showsWarmupNotice: false))
        let total = preview + timeline
            + EditorWorkspaceBudget.chrome(showsTimeline: true, showsWarmupNotice: false)
            + headerHeight - EditorWorkspaceBudget.header
        XCTAssertLessThanOrEqual(total, window.height)
        XCTAssertGreaterThanOrEqual(timeline, EditorWorkspaceBudget.minimumTimeline)
        XCTAssertEqual(AdaptiveWorkspaceLayout.budgetSize(window, headerHeight: 0), window)
        XCTAssertEqual(AdaptiveWorkspaceLayout.budgetSize(window, headerHeight: 44), window)
    }

    func testUnknownOrLongEdgeOcclusionsKeepSystemSafeAreas() {
        let size = CGSize(width: 951, height: 669)
        for regions in [[], [CGRect(x: 850, y: 0, width: 101, height: 669)],
                        [CGRect(x: 430, y: 0, width: 90, height: 40)],
                        [CGRect(x: 0, y: 320, width: 951, height: 20)],
                        [CGRect(x: 1200, y: 0, width: 100, height: 100)]] {
            XCTAssertFalse(WorkspaceHeaderClearance.resolve(size: size, occlusions: regions).isActive)
        }
    }
}
