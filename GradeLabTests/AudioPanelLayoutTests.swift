import SwiftUI
import XCTest
@testable import GradeLab

@MainActor
final class AudioPanelLayoutTests: XCTestCase {
    func testCompactInspectorScrollsWithoutHorizontalOverflow() throws {
        try render(size: CGSize(width: 320, height: 260), expanded: false, name: "audio-compact")
    }
    func testExpandedToneFitsPhoneWidth() throws {
        try render(size: CGSize(width: 360, height: 1_120), expanded: true, name: "audio-tone-phone")
    }
    func testExpandedToneFitsTabletInspector() throws {
        try render(size: CGSize(width: 540, height: 640), expanded: true, name: "audio-tone-tablet")
    }

    func testCompressorFitsNarrowPhone() throws {
        try render(size: CGSize(width: 320, height: 900), expanded: false, name: "audio-compressor-phone", section: "compressor")
    }
    func testDuckingFitsNarrowPhone() throws {
        try render(size: CGSize(width: 320, height: 1_000), expanded: false, name: "audio-ducking-phone", section: "ducking")
    }
    func testEchoReverbFitsPhone() throws {
        try render(size: CGSize(width: 360, height: 1_120), expanded: false, name: "audio-space-phone", section: "space")
    }
    func testTextureFitsNarrowPhone() throws {
        try render(size: CGSize(width: 320, height: 900), expanded: false, name: "audio-texture-phone", section: "texture")
    }

    private func render(size: CGSize, expanded: Bool, name: String, section: String = "") throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/audio-layout.mov"),
                                   displayName: "Audio", metadata: makeVideoMetadata(durationSeconds: 10))
        var video = project.timeline.firstVideoClip!
        let voiceLayer = UUID(), voiceID = UUID()
        let voice = AudioClip(placement: .init(id: voiceID, trackID: voiceLayer, timelineStart: .zero, duration: try .seconds(10)),
                              assetID: video.assetID, sourceRange: video.sourceRange)
        project.timeline.tracks.append(.init(id: voiceLayer, name: "Voice", kind: .audio, items: [.audio(voice)]))
        var settings = AudioVoicePreset.warm.settings
        if !section.isEmpty {
            settings.compressor = .init(); settings.ducking = .init(sourceClipID: voiceID)
            settings.echo = .init(); settings.reverb = .init(); settings.texture = .init(distortion: 0.2, crush: 0.3)
        }
        video.embeddedAudio?.processing = settings
        try TimelineEditing.replace(video.id, with: [video], in: &project)
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        let panel = AudioToolPanel(model: model, addSoundEffect: {}, addAudio: {}, showTracks: {},
                                   waveformUnavailable: false, toneExpanded: expanded,
                                   compressorExpanded: section == "compressor", duckingExpanded: section == "ducking",
                                   spaceExpanded: section == "space", textureExpanded: section == "texture",
                                   compressorAdvanced: section == "compressor")
            .padding(12).background(AppColors.editorBackground).preferredColorScheme(.dark)
        let controller = UIHostingController(rootView: panel)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        let end = Date().addingTimeInterval(0.4)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: controller.view).first)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        if size.height < 300 { XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height) }
        if !section.isEmpty {
            let above: CGFloat = section == "compressor" ? 334 : section == "ducking" ? 398 : section == "space" ? 462 : 526
            scroll.setContentOffset(CGPoint(x: 0, y: min(above, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
            controller.view.layoutIfNeeded()
        }
        let image = UIGraphicsImageRenderer(size: size).image { controller.view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let data = image.pngData() {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
            try data.write(to: url)
            print("AUDIO_PANEL_SHOT \(url.path)")
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
