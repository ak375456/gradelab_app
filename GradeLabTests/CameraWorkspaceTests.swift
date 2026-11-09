#if !targetEnvironment(macCatalyst)
import AVFoundation
import SwiftUI
import XCTest
@testable import GradeLab

@MainActor
final class CameraWorkspaceTests: XCTestCase {
    func testCameraRulersKeepHardwareLimitsAndFrameRateStops() {
        let iso = CameraRulerScale.iso(37...1472)
        XCTAssertEqual(iso.values.first, 37)
        XCTAssertEqual(iso.values.last, 1472)
        XCTAssertTrue(iso.values.contains(400))

        let limits = CameraControlLimits(shutter: (1.0 / 8000)...(1.0 / 24))
        let range = limits.shutterRange(fps: 60)
        let shutter = CameraRulerScale.shutter(range, fps: 60)
        XCTAssertEqual(shutter.values.first, range.lowerBound)
        XCTAssertEqual(shutter.values.last, 1.0 / 60)
        XCTAssertTrue(shutter.values.contains(1.0 / 120))
        XCTAssertFalse(shutter.values.contains(1.0 / 30))
    }

    func testExposureRulerPreservesTheLiveValueUntilATickChanges() throws {
        var value = 0.04
        var applied: [Double] = []
        let scale = CameraRulerScale(range: -2...2, step: 0.1, labelEvery: 5)
        let picker = CameraRulerPicker(title: "Exposure", value: Binding(get: { value }, set: {
            value = $0
            applied.append($0)
        }), scale: scale, feedbackEnabled: false, soundsEnabled: false) { String(format: "%+.1f EV", $0) }
        try snapshot(picker.padding(16).background(AppColors.surface),
                     size: .init(width: 320, height: 160), name: "camera-exposure-ruler") { view in
            let ruler = try XCTUnwrap(self.scrollViews(in: view).first { $0.contentSize.width > $0.bounds.width })
            let pitch = (ruler.contentSize.width - ruler.bounds.width) / CGFloat(scale.values.count - 1)
            XCTAssertEqual(ruler.contentOffset.x, 20.4 * pitch, accuracy: 0.5)
            XCTAssertTrue(applied.isEmpty)

            ruler.delegate?.scrollViewWillBeginDragging?(ruler)
            ruler.setContentOffset(CGPoint(x: 20.45 * pitch, y: 0), animated: false)
            XCTAssertTrue(applied.isEmpty)
            ruler.setContentOffset(CGPoint(x: 20.7 * pitch, y: 0), animated: false)
            XCTAssertEqual(applied, [0.1])

            var proposed = CGPoint(x: 22.7 * pitch, y: 0)
            ruler.delegate?.scrollViewWillEndDragging?(ruler, withVelocity: .zero, targetContentOffset: &proposed)
            XCTAssertEqual(proposed.x, 23 * pitch, accuracy: 0.5)
        }
    }

    func testShutterAnglePanelFitsPhone() throws {
        try render(size: .init(width: 390, height: 844), tool: .exposure, name: "camera-shutter-angle", manual: true)
    }

    func testFlickerControlsAreReachableOnSmallPhone() throws {
        try render(size: .init(width: 320, height: 640), tool: .exposure, name: "camera-flicker-small", manual: true, panelBottom: true)
    }

    func testPeakingControlsAreReachableOnPhone() throws {
        try render(size: .init(width: 390, height: 844), tool: .focus, name: "camera-focus-peaking", monitoring: true, panelBottom: true)
    }

    func testPeakingAndAngleControlsFitLandscape() throws {
        try render(size: .init(width: 844, height: 390), tool: .exposure, name: "camera-monitoring-landscape", monitoring: true, manual: true, panelBottom: true)
    }

    func testGuideMonitoringControlsFitLargeText() throws {
        try render(size: .init(width: 390, height: 844), tool: .assist, name: "camera-monitoring-large", largeText: true, monitoring: true, panelBottom: true)
    }

    func testHorizonIndicatorShowsLevelAndTiltClearly() throws {
        try snapshot(LazyVGrid(columns: [.init(.fixed(144)), .init(.fixed(144))], spacing: 16) {
            CameraHorizonIndicator(angle: 0); CameraHorizonIndicator(angle: -12)
            CameraHorizonIndicator(angle: 89.6); CameraHorizonIndicator(angle: -75)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray).ignoresSafeArea(),
            size: .init(width: 320, height: 300), name: "camera-horizon-level")
    }

    func testPendingRecordingDeleteFitsSmallPhone() throws {
        let recording = CameraRecording(id: UUID(), fileName: "take.mov", createdAt: .now, grade: .neutral)
        try snapshot(PendingCameraRecordingRow(recording: recording, originalURL: URL(fileURLWithPath: "/tmp/take.mov"), onOpen: {}, onDelete: {})
            .padding(16).background(AppColors.surface), size: .init(width: 288, height: 160), name: "camera-recording-delete")
    }
    func testCleanViewFitsPhoneWithOnlyRestoreControl() throws {
        try render(size: .init(width: 390, height: 844), tool: .assist, name: "camera-clean-phone", scopes: true, guides: true, hidden: true)
    }

    func testCleanViewFitsLandscape() throws {
        try render(size: .init(width: 844, height: 390), tool: .assist, name: "camera-clean-landscape", scopes: true, guides: true, hidden: true)
    }

    func testCameraRecordingPaywallExplainsTheFreePreview() throws {
        try snapshot(PaywallView(feature: .cameraRecording), size: .init(width: 390, height: 844), name: "camera-recording-paywall")
    }
    func testLiveDashboardWithGuidesAndHeatFitsPhone() throws {
        try render(size: .init(width: 390, height: 844), tool: .assist, name: "camera-dashboard-guides", scopes: true, guides: true)
    }

    func testSimpleDashboardFitsSmallPhone() throws {
        try render(size: .init(width: 320, height: 640), tool: .looks, name: "camera-dashboard-simple", scopes: true, pro: false)
    }

    func testFormatSheetHasScrollableReachableSections() throws {
        try snapshot(CameraFormatSheet(model: formatModel()), size: .init(width: 390, height: 844), name: "camera-format-sheet")
    }

    func testFormatSheetScrollsToCodecAndStabilization() throws {
        try snapshot(CameraFormatSheet(model: formatModel()), size: .init(width: 390, height: 600), name: "camera-format-bottom", scrollToBottom: true)
    }

    func testGuideControlsFitNarrowPhone() throws {
        try render(size: .init(width: 320, height: 640), tool: .assist, name: "camera-guide-controls")
    }

    func testZoomPresetsUseRealLensesAndPreserveManualControls() throws {
        let model = CameraViewModel()
        model.receive(.configured(configuration()))
        XCTAssertEqual(model.zoomStops.map(\.display), [0.5, 1, 2])
        model.controls.manualExposure = true
        model.controls.iso = 400
        let controls = model.controls
        model.setZoom(100)
        XCTAssertEqual(model.zoomFactor, 6)
        XCTAssertEqual(model.controls, controls)
        model.receive(.recordingStarted)
        let wide = try XCTUnwrap(model.zoomStops.first { $0.display == 0.5 })
        model.selectZoom(wide)
        XCTAssertEqual(model.configuration?.lensID, "main")
        XCTAssertEqual(model.phase, .recording, "A physical lens switch cannot interrupt a take")
    }

    private func formatModel() -> CameraViewModel {
        let model = CameraViewModel()
        var config = configuration()
        config = CameraCaptureConfiguration(lenses: config.lenses, lensID: config.lensID,
            formats: [CameraProfile.sdr, .hdrHLG, .displayP3].flatMap { profile in
                [1920, 3840].flatMap { width in [24,25,30,50,60].map { CameraFormatOption(width: width, height: width == 1920 ? 1080 : 2160, fps: $0, profile: profile) } }
            } + [.init(width: 1920, height: 1440, fps: 30, profile: .sdr), .init(width: 4032, height: 3024, fps: 30, profile: .sdr)],
            selected: config.selected, codecs: [.hevc, .h264], codec: .hevc, limits: config.limits,
            controls: config.controls, stabilizationAvailable: true, stabilizationEnabled: true, rotation: 90, hasAudio: true)
        model.receive(.configured(config))
        return model
    }

    func testAudioMeterReferenceLayout() throws {
        try snapshot(CameraAudioMeter(levels: [-12, -8], hasAudio: true, microphone: "iPhone Microphone")
            .padding(8).background(Color.gray.opacity(0.3)).ignoresSafeArea(),
            size: .init(width: 300, height: 100), name: "camera-audio-reference")
    }

    func testMonoAudioMeterFitsNarrowSpace() throws {
        try snapshot(CameraAudioMeter(levels: [-17], hasAudio: true, microphone: "iPhone Microphone")
            .padding(8).background(Color.gray.opacity(0.3)).ignoresSafeArea(),
            size: .init(width: 120, height: 100), name: "camera-audio-mono")
    }

    func testDisabledAudioMeterIsExplicit() throws {
        try snapshot(CameraAudioMeter(levels: [], hasAudio: false, microphone: "")
            .padding(8).background(Color.black).ignoresSafeArea(),
            size: .init(width: 145, height: 120), name: "camera-audio-disabled")
    }

    func testAudioMeterScalePreservesThresholdsAndQuietReadings() {
        XCTAssertEqual(CameraAudioScale.position(-100), 0)
        XCTAssertEqual(CameraAudioScale.position(.nan), 0)
        XCTAssertEqual(CameraAudioScale.position(-.infinity), 0)
        XCTAssertEqual(CameraAudioScale.position(-10), 0.61, accuracy: 0.0001)
        XCTAssertEqual(CameraAudioScale.position(0), 0.90, accuracy: 0.0001)
        XCTAssertEqual(CameraAudioScale.position(3), 1)
        let values = stride(from: -45.0, through: 3, by: 0.25).map(CameraAudioScale.position)
        for (low, high) in zip(values, values.dropFirst()) { XCTAssertLessThanOrEqual(low, high) }
    }

    func testPhonePortraitControlsFit() throws { try render(size: .init(width: 320, height: 640), tool: .looks, name: "camera-phone") }
    func testPhoneLandscapeControlsFit() throws { try render(size: .init(width: 844, height: 390), tool: .exposure, name: "camera-landscape") }
    func testTabletControlsFit() throws { try render(size: .init(width: 1024, height: 768), tool: .whiteBalance, name: "camera-tablet") }
    func testLargeTextFocusControlsFit() throws { try render(size: .init(width: 390, height: 844), tool: .focus, name: "camera-large-type", largeText: true) }
    func testMiniScopeFitsPhonePreview() throws {
        try render(size: .init(width: 390, height: 844), tool: .looks, name: "camera-mini-scope", scopes: true)
    }
    func testExpandedScopeStaysCompactOnPhone() throws {
        try render(size: .init(width: 390, height: 844), tool: .looks, name: "camera-expanded-scope", scopes: true, expandedScope: true)
    }
    func testExpandedScopeFitsLandscape() throws {
        try render(size: .init(width: 844, height: 390), tool: .looks, name: "camera-landscape-scope", scopes: true, expandedScope: true)
    }

    func testRecordingChoiceFitsPhone() throws {
        try renderChoice(size: .init(width: 390, height: 390), largeText: false)
    }

    func testRecordingChoiceSupportsLargeText() throws {
        try renderChoice(size: .init(width: 320, height: 650), largeText: true)
    }

    func testScopesLeaveRoomForThePicture() {
        for image in [CGSize(width: 290, height: 520), CGSize(width: 480, height: 270), CGSize(width: 700, height: 400)] {
            let mini = CameraScopeLayout.size(in: image, expanded: false)
            let expanded = CameraScopeLayout.size(in: image, expanded: true)
            XCTAssertLessThanOrEqual(mini.width, 160)
            XCTAssertLessThanOrEqual(mini.height, 76)
            XCTAssertGreaterThan(expanded.width, mini.width)
            XCTAssertLessThanOrEqual(expanded.width, image.width - 16)
            XCTAssertLessThan(expanded.height, image.height * 0.6)
        }
        let picture = CGRect(x: 230, y: 0, width: 120, height: 220)
        let card = CameraScopeLayout.frame(in: picture, viewport: .init(width: 580, height: 220), expanded: true)
        XCTAssertEqual(card.width, 200)
        XCTAssertFalse(card.intersects(picture), "A narrow portrait take can use the landscape letterbox")
        XCTAssertGreaterThanOrEqual(card.minX, 8)
        XCTAssertLessThanOrEqual(card.maxY, 220)
        let belowDashboard = CameraScopeLayout.frame(in: picture, viewport: .init(width: 580, height: 220), expanded: true, topInset: 74)
        XCTAssertGreaterThanOrEqual(belowDashboard.minY, 74)
        XCTAssertLessThanOrEqual(belowDashboard.maxY, 212)
    }

    func testNoRecordingBeforeTheFirstCameraFrame() {
        let model = CameraViewModel()
        model.receive(.configured(configuration()))
        XCTAssertFalse(model.canRecord, "A configured session without a live frame must not enable recording.")
        XCTAssertTrue(model.canConfigure)
        model.receive(.recordingStarted)
        XCTAssertFalse(model.canConfigure)
        XCTAssertFalse(model.canClose)
        model.receive(.interrupted(true))
        XCTAssertFalse(model.canRecord)
    }

    func testLookSelectionUsesTheEditorsExistingGradeModel() throws {
        let model = CameraViewModel()
        model.receive(.configured(configuration()))
        let look = try XCTUnwrap(model.looks.first)
        model.selectLook(look)
        XCTAssertEqual(model.grade.advanced?.lut, look.id)
        XCTAssertEqual(model.grade.advanced?.lutIntensity, 100)
        model.selectLook(nil)
        XCTAssertEqual(model.grade, .neutral)
    }

    func testCreativeColorPreservesLUTAndFreezesDuringRecording() throws {
        let model = CameraViewModel()
        model.receive(.configured(configuration()))
        let look = try XCTUnwrap(model.looks.first)
        model.selectLook(look)
        model.setCreativeColor(.saturation, value: 45)
        model.setCreativeColor(.vibrance, value: 180)
        XCTAssertEqual(model.grade.saturation, 45)
        XCTAssertEqual(model.grade.vibrance, 100)
        XCTAssertEqual(model.grade.advanced?.lut, look.id)
        model.selectLook(nil)
        XCTAssertEqual(model.grade.saturation, 45)
        XCTAssertEqual(model.grade.vibrance, 100)
        model.setCreativeColor(.saturation, value: .nan)
        model.setCreativeColor(.exposure, value: 1)
        XCTAssertEqual(model.grade.saturation, 45)
        XCTAssertEqual(model.grade.exposure, 0)
        model.receive(.recordingStarted)
        model.setCreativeColor(.saturation, value: -90)
        XCTAssertEqual(model.grade.saturation, 45)
    }

    func testCreativeColorSlidersFitNarrowPhone() throws {
        try render(size: .init(width: 320, height: 640), tool: .looks, name: "camera-creative-color-small", panelBottom: true)
    }

    func testCreativeColorSlidersFitLandscape() throws {
        try render(size: .init(width: 844, height: 390), tool: .looks, name: "camera-creative-color-landscape", panelBottom: true)
    }

    func testExpandedFormatSheetShowsHDRAndQuality() throws {
        try snapshot(CameraFormatSheet(model: formatModel()), size: .init(width: 390, height: 844), name: "camera-wide-color-formats", scrollToBottom: true)
    }

    func testHardwareClampingIsReflectedInVisibleControls() {
        let model = CameraViewModel()
        model.receive(.configured(configuration()))
        model.controls.manualExposure = true
        model.controls.iso = 8000
        model.controls.shutterSeconds = 1
        model.applyControls()
        XCTAssertEqual(model.controls.iso, 1600)
        XCTAssertEqual(model.controls.shutterSeconds, 1.0 / 30, accuracy: 0.00001)
    }

    func testMissingPreviewStopsWaitingAndOffersRetry() async throws {
        let model = CameraViewModel(previewTimeout: .milliseconds(20))
        model.receive(.configured(configuration()))
        let deadline = Date().addingTimeInterval(1)
        while model.phase != .unavailable && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertFalse(model.canRecord)
        XCTAssertTrue(model.canClose)
        XCTAssertNotNil(model.message)
        // A delayed configuration from the failed start cannot leave the user
        // staring at an endless Starting camera indicator again.
        model.receive(.configured(configuration()))
        XCTAssertEqual(model.phase, .unavailable)
    }

    func testRuntimeFailureClearsRecordReadiness() {
        let model = CameraViewModel()
        model.receive(.configured(configuration()))
        model.receive(.failed("Cannot Record"))
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertFalse(model.canRecord)
        XCTAssertNil(model.renderer)
        XCTAssertTrue(model.canClose)
    }

    private func configuration() -> CameraCaptureConfiguration {
        let format = CameraFormatOption(width: 1920, height: 1080, fps: 30, profile: .sdr)
        return CameraCaptureConfiguration(lenses: [.init(id: "wide", name: "Ultra Wide", isFront: false, baseZoom: 0.5, maxZoom: 6), .init(id: "main", name: "Main", isFront: false, maxZoom: 6)], lensID: "main",
            formats: [format], selected: format, codecs: [.hevc], codec: .hevc,
            limits: .init(iso: 50...1600, shutter: (1.0 / 8000)...1, bias: -2...2,
                          supportsExposure: true, supportsWhiteBalance: true, supportsFocus: true),
            controls: CameraControls(), stabilizationAvailable: true, stabilizationEnabled: true, rotation: 90, hasAudio: true, zoomRange: 1...6)
    }

    private func render(size: CGSize, tool: CameraTool, name: String, largeText: Bool = false,
                        scopes: Bool = false, expandedScope: Bool = false, guides: Bool = false, pro: Bool = true, hidden: Bool = false,
                        monitoring: Bool = false, manual: Bool = false, panelBottom: Bool = false) throws {
        let previous = UserDefaults.standard.object(forKey: "camera.proControls")
        UserDefaults.standard.set(pro, forKey: "camera.proControls")
        defer { UserDefaults.standard.set(previous, forKey: "camera.proControls") }
        let capture = CameraCaptureController()
        let model = CameraViewModel(capture: capture)
        model.receive(.configured(configuration()))
        if monitoring { model.assist.focusPeaking = true }
        if manual { model.setShutterAngle(180) }
        if scopes {
            let buffer = try CameraScopeFixture.sample()
            capture.frames.update(buffer)
            model.receive(.interrupted(false))
            model.receive(.frameSize(.init(width: 180, height: 320), .sdr))
        }
        model.receive(.telemetry(.init(iso: 640, shutter: 1.0 / 60, temperature: 5200, tint: 4, focus: 0.7,
            audioDB: [-24, -18], microphone: "iPhone Microphone", freeBytes: 25_000_000_000, isHot: guides)))
        if guides { model.guides = .init(grid: .thirds, frame: .square, center: true, safeArea: true) }
        if hidden { model.toggleInterface() }
        let content = CameraWorkspace(model: model, onClose: {}, initialTool: tool, initiallyExpanded: !scopes,
                                      scopeInitiallyExpanded: expandedScope)
            .environment(\.dynamicTypeSize, largeText ? .accessibility2 : .large)
        try snapshot(content, size: size, name: name, scrollToBottom: panelBottom)
    }

    private func renderChoice(size: CGSize, largeText: Bool) throws {
        let recording = CameraRecording(id: UUID(), fileName: "take.mov", createdAt: Date(), grade: .neutral)
        let model = CameraViewModel()
        model.receive(.finished(recording))
        let content = CameraRecordingChoice(model: model, recording: recording, onEdit: {}, onContinue: {})
            .environment(\.dynamicTypeSize, largeText ? .accessibility2 : .large)
        try snapshot(content, size: size, name: largeText ? "camera-choice-large-type" : "camera-choice")
    }

    private func snapshot<Content: View>(_ content: Content, size: CGSize, name: String, scrollToBottom: Bool = false,
                                         inspect: ((UIView) throws -> Void)? = nil) throws {
        let controller = UIHostingController(rootView: content)
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
        if scrollToBottom {
            let scroll = try XCTUnwrap(scrollViews(in: controller.view).first { $0.contentSize.height > $0.bounds.height + 1 })
            XCTAssertTrue(scroll.isScrollEnabled, "Recording format sections must remain scrollable")
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            controller.view.layoutIfNeeded()
        }
        for scroll in scrollViews(in: controller.view) where scroll.contentSize.height > scroll.bounds.height + 1 {
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "\(name): vertical panel must not overflow horizontally")
        }
        let image = UIGraphicsImageRenderer(size: size).image { _ in controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try image.pngData()?.write(to: url)
        print("CAMERA_LAYOUT_SHOT \(url.path)")
        try inspect?(controller.view)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}

enum CameraScopeFixture {
    static func sample() throws -> CMSampleBuffer {
        var storage: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 180, 320, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &storage), kCVReturnSuccess)
        let buffer = try XCTUnwrap(storage)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<320 { for x in 0..<180 {
            let index = y * stride + x * 4
            base[index] = UInt8(40 + x / 2); base[index + 1] = UInt8(60 + y / 3)
            base[index + 2] = UInt8(80 + x / 2); base[index + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
#endif
