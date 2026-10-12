import SwiftUI
import MetalKit
import UIKit
import XCTest
@testable import GradeLab

@MainActor
final class AppStoreMaskCaptureTests: XCTestCase {
    func testCaptureMaskAndTrackingArtworkSources() async throws {
        let url = URL(fileURLWithPath: "/tmp/gradelab-mask-demo.mp4")
        let project = VideoProject(sourceURL: url, displayName: "Alpine Light",
                                   metadata: makeVideoMetadata(durationSeconds: 3, hasAudio: false, audioTrackCount: 0))
        let model = try EditorViewModel(project: project)
        for _ in 0..<100 where model.isPreparingTimeline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(model.isPreparingTimeline)
        model.addMask(.freehand)
        let id = try XCTUnwrap(model.selectedMaskID)
        // Follow the skyline, retaining visible anchor points for refinement.
        let points: [MaskPoint] = [
            .init(x: 0.012, y: 0.018), .init(x: 0.985, y: 0.018),
            .init(x: 0.985, y: 0.18), .init(x: 0.91, y: 0.205),
            .init(x: 0.848, y: 0.165), .init(x: 0.79, y: 0.082),
            .init(x: 0.731, y: 0.205), .init(x: 0.665, y: 0.252),
            .init(x: 0.612, y: 0.204), .init(x: 0.548, y: 0.268),
            .init(x: 0.47, y: 0.218), .init(x: 0.413, y: 0.258),
            .init(x: 0.375, y: 0.211), .init(x: 0.315, y: 0.292),
            .init(x: 0.25, y: 0.248), .init(x: 0.205, y: 0.302),
            .init(x: 0.105, y: 0.321), .init(x: 0.012, y: 0.264)
        ]
        for point in points { model.appendMaskPoint(id, point) }
        model.finishDrawingMask(id)
        model.renameMask(id, to: "Sky")
        model.setMaskPointSmooth(id, index: 8, smooth: true)
        model.updateMask(id, label: "Sky grade", immediate: true) {
            $0.localGrade.exposure = -0.12
            $0.localGrade.saturation = 12
        }
        model.selectedPanel = .masks
        XCTAssertTrue(model.canTrackSelectedMask)
        model.requestMaskTracking(.forward)
        for _ in 0..<300 where model.maskTrackingSession != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(model.maskTrackingSession)
        print("ARTWORK TRACKING RESULT: \(model.maskTrackingNotice?.text ?? "No result")")
        model.selectedMaskPointIndex = 8
        let photo = try XCTUnwrap(UIImage(contentsOfFile: "/tmp/gradelab-mask-photo.png"))
        for (name, size) in [("iphone", CGSize(width: 390, height: 844)),
                             ("ipad", CGSize(width: 1100, height: 760))] {
            AppPlatform.appStoreCaptureIdiom = name == "iphone" ? .phone : .pad
            let root = EditorView.appStoreMaskCapture(model: model)
                .preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: "en_US"))
            try await capture(root, size: size, name: name, photo: photo, model: model)
        }
        AppPlatform.appStoreCaptureIdiom = nil
        try await capture(MaskPanel.appStoreTrackingCapture(model: model).preferredColorScheme(.dark),
                          size: CGSize(width: 360, height: 335), name: "tracking", photo: nil)
        try await capture(PreviewViewport(interaction: .pinchOnly) {
            ZStack {
                Image(uiImage: photo).resizable().aspectRatio(contentMode: .fill)
                MaskOverlay(model: model, displayedRect: { CGRect(x: 0, y: 0, width: 1, height: 1) })
            }.clipped()
        }.preferredColorScheme(.dark), size: CGSize(width: 800, height: 450), name: "mask_detail", photo: nil)
    }

    private func capture<V: View>(_ root: V, size: CGSize, name: String, photo: UIImage?, model: EditorViewModel? = nil) async throws {
        let host = UIHostingController(rootView: root.frame(width: size.width, height: size.height))
        host.safeAreaRegions = []
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .black
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        host.view.layoutIfNeeded()
        if let photo {
            // CPU snapshots cannot read a Metal drawable. Use the source frame
            // inside that view while preserving all real editor controls above it.
            func supplyFrame(_ view: UIView) {
                if let metal = view as? MTKView {
                    metal.drawableSize = CGSize(width: view.bounds.width * 3, height: view.bounds.height * 3)
                    metal.delegate?.mtkView(metal, drawableSizeWillChange: metal.drawableSize)
                    metal.delegate?.draw(in: metal)
                    let frame = UIImageView(image: photo)
                    frame.frame = view.bounds
                    frame.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    frame.contentMode = .scaleAspectFit
                    frame.backgroundColor = UIColor(white: 0.125, alpha: 1)
                    view.addSubview(frame)
                } else { view.subviews.forEach(supplyFrame) }
            }
            supplyFrame(host.view)
            model?.objectWillChange.send()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/gradelab-appstore-\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "App Store \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
