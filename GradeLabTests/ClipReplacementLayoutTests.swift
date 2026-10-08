import SwiftUI
import XCTest
@testable import GradeLab

@MainActor
final class ClipReplacementLayoutTests: XCTestCase {
    func testReplacementScrollsWithinPhoneWidth() throws {
        try render(size: CGSize(width: 390, height: 844), name: "replacement-phone")
    }

    func testReplacementFitsAnIPadSheet() throws {
        try render(size: CGSize(width: 540, height: 620), name: "replacement-ipad")
    }

    private func render(size: CGSize, name: String) throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/original.mov"),
            displayName: "Replacement", metadata: makeVideoMetadata(fileName: "Original shot.mov", durationSeconds: 15))
        let middle = try TimelineEditing.split(project.timeline.firstVideoClip!.id, at: .seconds(5), in: &project)
        _ = try TimelineEditing.split(middle, at: .seconds(10), in: &project)
        let replacement = ProjectMediaAsset(id: UUID(), url: URL(fileURLWithPath: "/tmp/replacement.mov"),
            sourceRange: .init(start: .zero, duration: try .seconds(10)),
            videoMetadata: makeVideoMetadata(fileName: "New take.mov", durationSeconds: 10),
            frameDuration: try .seconds(1.0 / 30))
        project.addAsset(replacement)
        let model = try EditorViewModel(project: project)
        let controller = UIHostingController(rootView: ClipReplacementSheet(
            model: model, clipID: middle, assetFrames: [:], initialAsset: replacement))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        let end = Date().addingTimeInterval(0.8)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: controller.view).first { $0.contentSize.height > $0.bounds.height })
        XCTAssertTrue(scroll.isScrollEnabled, "The source picker and trim control must remain reachable.")
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                                 "The duration choices must fit without horizontal scrolling.")
        let image = UIGraphicsImageRenderer(size: size).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
            try data.write(to: url)
            print("REPLACEMENT_SHOT \(url.path)")
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
