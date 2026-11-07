import AVFoundation
import CoreImage
import MetalKit
import SwiftUI
import XCTest
@testable import GradeLab

/// Opt in with a zh-Hans or zh-Hant test language. Captures the real SwiftUI workspaces
/// and their actual GPU output; no reconstructed controls or translated pixels.
@MainActor
final class SimplifiedChineseCaptureTests: XCTestCase {
    private var isTraditional: Bool {
        let language = Locale.preferredLanguages.first ?? ""
        return language.contains("Hant") || language.contains("TW") || language.contains("HK")
    }
    private var captureLocale: Locale { Locale(identifier: isTraditional ? "zh_Hant_TW" : "zh_Hans_CN") }
    private var output: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(isTraditional ? "gradelab-zh-Hant-captures" : "gradelab-zh-captures")
    }

    func testCaptureLocalizedWorkspaces() async throws {
        try XCTSkipUnless(Locale.preferredLanguages.first?.hasPrefix("zh") == true,
                          "Run with -testLanguage zh-Hans -testRegion CN for localized captures.")
        CompositorWarmup.shared.start()
        let warmupDeadline = Date().addingTimeInterval(90)
        while !CompositorWarmup.shared.isReady && Date() < warmupDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard CompositorWarmup.shared.isReady else { throw GradeLabError.rendererInitializationFailed }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let savedIntroduction = UserDefaults.standard.object(forKey: PhoneColorLayout.introductionSeenKey)
        UserDefaults.standard.set(true, forKey: PhoneColorLayout.introductionSeenKey)
        defer {
            if let savedIntroduction { UserDefaults.standard.set(savedIntroduction, forKey: PhoneColorLayout.introductionSeenKey) }
            else { UserDefaults.standard.removeObject(forKey: PhoneColorLayout.introductionSeenKey) }
        }
        let source = output.appendingPathComponent("source-photo.png")
        try XCTUnwrap(UIImage(named: "PaywallBefore")?.pngData()).write(to: source)
        let metadata = try ImageMetadataReader.read(url: source)
        var project = ImageProject(displayName: isTraditional ? "色彩練習" : "色彩练习", asset: .init(id: UUID(), url: source, metadata: metadata))
        project.gradeSettings.exposure = 0.25; project.gradeSettings.contrast = 12
        project.gradeSettings.saturation = 108; project.gradeSettings.vibrance = 16
        let model = try ImageEditorViewModel(project: project)
        let readyDeadline = Date().addingTimeInterval(10)
        while model.isPreparing && Date() < readyDeadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.isPreparing)
        let panels: [(String, GradePanel)] = [
            ("01-color-grading", .wheels), ("02-looks", .lut), ("03-color-warper", .warper),
            ("04-curves", .curves), ("05-fine-tune", .color), ("06-film-effects", .effects),
            ("07-local-masks", .mask), ("08-noise-reduction", .noise)
        ]
        #if targetEnvironment(macCatalyst)
        let targets: [(String, CGSize, CGFloat)] = [("mac", .init(width: 1440, height: 900), 2)]
        #else
        let targets: [(String, CGSize, CGFloat)] = [
            ("iphone", .init(width: 402, height: 874), 3),
            ("ipad", .init(width: 1032, height: 1376), 2)
        ]
        #endif
        for (platform, size, scale) in targets {
            for (name, panel) in panels {
                model.selectedPanel = panel
                var grade = model.settings
                if panel == .effects {
                    var advanced = grade.advanced ?? .neutral
                    advanced.effects = FilmEffects(bloom: 15, glow: 10, halation: 8, grain: 12)
                    grade.advanced = advanced
                } else if panel == .mask {
                    var advanced = grade.advanced ?? .neutral
                    advanced.mask = GradeMask(isEnabled: true, centerX: 50, centerY: 48, width: 55, height: 45)
                    grade.advanced = advanced
                } else { grade.advanced?.mask = nil; grade.advanced?.effects = nil }
                model.settings = grade
                if panel == .lut {
                    // Refresh after the first real preview draw so a cold
                    // launch cannot leave cached empty thumbnail textures.
                    model.refreshLookPreviews(force: true)
                    try await Task.sleep(for: .seconds(2))
                }
                model.setScopesEnabled(panel == .curves)
                let view = ImageEditorView(model: model, onBack: { _ in }, onSettingsChanged: { _, _ in })
                    .environment(\.locale, captureLocale)
                    .environment(\.horizontalSizeClass, platform == "iphone" ? .compact : .regular)
                try await capture(view, size: size, scale: scale, name: "\(platform)-\(name)", renderer: model.renderer)
            }
            let url = try XCTUnwrap(Bundle.main.url(forResource: "onboarding-1-before", withExtension: "mp4"))
            let asset = try await VideoMetadataReader().read(from: url)
            let videoProject = VideoProject(sourceURL: url, displayName: "旅途片段", metadata: asset.metadata,
                sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
            let video = try EditorViewModel(project: videoProject, stabilizationAccess: { true })
            let videoDeadline = Date().addingTimeInterval(10)
            while video.isPreparingTimeline && Date() < videoDeadline { try await Task.sleep(for: .milliseconds(50)) }
            video.playback.seekPrecisely(to: 1)
            let editor = EditorView(model: video, onBack: { _ in }, onShowSource: {}, onSettingsChanged: { _, _ in })
                .environment(\.locale, captureLocale)
            try await capture(editor, size: size, scale: scale, name: "\(platform)-10-video-editor", renderer: video.renderer)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            let poster = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            let stabilization = VStack(spacing: 0) {
                Text("Stabilization").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                Image(uiImage: UIImage(cgImage: poster)).resizable().scaledToFit()
                    .frame(maxHeight: size.height*0.38).clipped()
                StabilizationPanel(model: video)
            }.background(AppColors.background).preferredColorScheme(.dark)
                .environment(\.locale, captureLocale)
            try await capture(stabilization, size: size, scale: scale, name: "\(platform)-09-stabilization", renderer: nil)
            video.suspendPreviewForExport()
        }
        print("CHINESE_CAPTURE_ROOT \(output.path)")
    }

    private func capture<V: View>(_ view: V, size: CGSize, scale: CGFloat, name: String,
                                 renderer: MetalVideoRenderer?) async throws {
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size); window.rootViewController = host
        window.makeKeyAndVisible(); host.view.frame = window.bounds; window.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        host.view.layoutIfNeeded()
        func metals(_ view: UIView) -> [MTKView] {
            (view as? MTKView).map { [$0] } ?? view.subviews.flatMap(metals)
        }
        let views = metals(host.view)
        var delegates: [MetalCaptureDelegate] = []
        for metal in views {
            guard let original = metal.delegate else { continue }
            metal.framebufferOnly = false; metal.isPaused = true
            let proxy = MetalCaptureDelegate(original: original)
            delegates.append(proxy); metal.delegate = proxy
            renderer?.invalidate(); metal.draw()
        }
        try await Task.sleep(for: .milliseconds(200))
        // CALayer.render does not include CAMetalLayer. Substitute an exact
        // readback of the real drawable at the same z-order for the snapshot.
        var substitutions: [(MTKView, UIImageView)] = []
        for (metal, proxy) in zip(views, delegates) {
            guard let texture = proxy.texture, let device = metal.device,
                  let ci = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]),
                  let cg = CIContext(mtlDevice: device).createCGImage(ci.oriented(.downMirrored), from: ci.extent),
                  let parent = metal.superview, let index = parent.subviews.firstIndex(of: metal) else { continue }
            let image = UIImageView(image: UIImage(cgImage: cg)); image.frame = metal.frame
            image.contentMode = .scaleToFill; parent.insertSubview(image, at: index)
            metal.isHidden = true; substitutions.append((metal,image))
        }
        defer { for (metal, image) in substitutions { image.removeFromSuperview(); metal.isHidden = false } }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { host.view.layer.render(in: $0.cgContext) }
        try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent(name+".png"))
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print("CHINESE_CAPTURE \(name) \(Int(image.size.width*image.scale))x\(Int(image.size.height*image.scale)) GPU=\(substitutions.count)")
    }
}

private final class MetalCaptureDelegate: NSObject, MTKViewDelegate {
    let original: MTKViewDelegate
    var texture: MTLTexture?
    init(original: MTKViewDelegate) { self.original = original }
    func draw(in view: MTKView) {
        let drawable = view.currentDrawable
        original.draw(in: view)
        texture = drawable?.texture
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        original.mtkView(view, drawableSizeWillChange: size)
    }
}
