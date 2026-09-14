import XCTest
import SwiftUI
@testable import GradeLab

@MainActor
final class PaywallVisualTests: XCTestCase {
    func testBeforeAfterSliderAppearance() {
        let size = CGSize(width: 332, height: 415)
        let controller = UIHostingController(
            rootView: BeforeAfterSlider()
                .frame(width: size.width, height: size.height)
        )
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .black
        controller.view.layoutIfNeeded()

        let image = UIGraphicsImageRenderer(size: size).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Paywall before-after slider"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(image.size, size)
    }
}
