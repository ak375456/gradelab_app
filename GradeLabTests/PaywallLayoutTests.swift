import XCTest
import SwiftUI
@testable import GradeLab

/// The paywall has to stay reachable on iPad.
///
/// It was rejected once because it was not. An iPad form sheet is roughly 540
/// by 620 points; the comparison card was a 4:5 portrait the full width of the
/// column, which made it taller than the whole sheet, and its drag gesture
/// claimed every touch that landed on it. Between them there was no way to
/// reach the plans, the buy button or the restore link. These tests hold the
/// layout half of that fix in place — the gesture half lives in
/// `BeforeAfterSlider.track(_:width:)`.
@MainActor
final class PaywallLayoutTests: XCTestCase {
    /// About what UIKit hands a sheet on iPad.
    private let formSheet = CGSize(width: 540, height: 620)

    func testHeroLeavesMostOfAnIPadSheetForThePlans() {
        let hero = PaywallView().heroHeight(in: formSheet)
        XCTAssertLessThanOrEqual(hero, formSheet.height * 0.45)
        XCTAssertGreaterThan(hero, 120, "A hero too small to read is not a fix either")
    }

    func testComparisonCardIsWiderThanItIsTall() {
        // A portrait card at the column's full width is what made the sheet
        // unscrollable in the first place.
        XCTAssertGreaterThan(BeforeAfterSlider().aspect, 1)
    }

    func testPaywallScrollsInsideAnIPadFormSheet() throws {
        // In a real window, because SwiftUI only builds the scroll view's
        // UIKit backing once the hierarchy is hosted.
        let window = UIWindow(frame: CGRect(origin: .zero, size: formSheet))
        let controller = UIHostingController(rootView: PaywallView())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let scroll = try XCTUnwrap(firstScrollView(in: window),
                                   "The paywall must be inside a scroll view")
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertGreaterThan(scroll.contentSize.height, formSheet.height,
                             "There is more paywall than sheet, so it has to scroll")

        let image = UIGraphicsImageRenderer(size: formSheet).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Paywall on an iPad form sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("paywall-ipad.png")
            try? data.write(to: url)
            print("SHOT \(url.path)")
        }
    }


    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
