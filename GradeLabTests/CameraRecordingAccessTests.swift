#if !targetEnvironment(macCatalyst)
import XCTest
@testable import GradeLab

@MainActor
final class CameraRecordingAccessTests: XCTestCase {
    func testFreeRecordShowsPaywallWithoutCreatingATake() async throws {
        let probe = CameraAccessProbe()
        let (root, store, model) = try fixture { await probe.check() }
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(model.canRecord, "Record must stay tappable so it can explain the upgrade")
        await model.toggleRecording()
        XCTAssertEqual(model.paywallFeature, .cameraRecording)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.checkingRecordingAccess)
        XCTAssertTrue(try store.pending().isEmpty)
        model.paywallFeature = nil
        await model.toggleRecording()
        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(model.paywallFeature, .cameraRecording)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testFreePreviewAllowsLooksManualControlsZoomAndAllScopes() async throws {
        let probe = CameraAccessProbe()
        let (root, _, model) = try fixture { await probe.check() }
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let look = try XCTUnwrap(model.looks.first { ProAccessPolicy.requiresPro($0) })
        model.selectLook(look)
        model.setManualExposure(true)
        model.setManualWhiteBalance(true)
        model.setManualFocus(true)
        model.setZoom(2)
        model.scopeSettings.type = .vectorscope
        model.refreshScopes()
        XCTAssertEqual(model.grade.advanced?.lut, look.id)
        XCTAssertTrue(model.controls.manualExposure)
        XCTAssertTrue(model.controls.manualWhiteBalance)
        XCTAssertTrue(model.controls.manualFocus)
        XCTAssertEqual(model.zoomFactor, 2)
        XCTAssertNotNil(model.scopeAnalyzer)
        XCTAssertNil(model.paywallFeature)
        XCTAssertEqual(probe.calls, 0, "Preview controls must not ask for recording entitlement")
    }

    func testPaidStartAndStopDoNotShowAPaywall() async throws {
        let probe = CameraAccessProbe(); probe.allowed = true
        let (root, _, model) = try fixture { await probe.check() }
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        await model.toggleRecording()
        XCTAssertEqual(model.phase, .starting)
        XCTAssertNil(model.paywallFeature)
        model.receive(.recordingStarted)
        probe.allowed = false
        await model.toggleRecording()
        XCTAssertEqual(model.phase, .finishing)
        XCTAssertNil(model.paywallFeature)
        XCTAssertEqual(probe.calls, 1, "Stopping must stay available if Pro expires during a take")
    }

    func testDuplicateTapsAndClosingDuringAccessCheckCannotStartRecording() async throws {
        let probe = CameraAccessProbe(); probe.paused = true
        let (root, store, model) = try fixture { await probe.check() }
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let request = Task { await model.toggleRecording() }
        while probe.continuation == nil { await Task.yield() }
        XCTAssertTrue(model.checkingRecordingAccess)
        await model.toggleRecording()
        XCTAssertEqual(probe.calls, 1)
        model.stop()
        probe.continuation?.resume(returning: true)
        probe.continuation = nil
        await request.value
        XCTAssertNotEqual(model.phase, .starting)
        XCTAssertNil(model.paywallFeature)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testCleanViewPreservesTheCameraAndRestoresMonitoring() throws {
        let (root, _, model) = try fixture { false }
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.guides = .init(grid: .thirds, frame: .square, center: true, safeArea: true)
        model.assist.mode = .zebras
        model.assist.focusPeaking = true
        model.assist.peakingColor = .yellow
        model.scopeSettings.type = .waveform
        model.refreshPreview(); model.refreshScopes()
        model.controls.manualFocus = true
        model.controls.focus = 0.7
        model.setZoom(2)
        let renderer = try XCTUnwrap(model.renderer)
        let controls = model.controls, grade = model.grade, guides = model.guides
        model.toggleInterface()
        XCTAssertTrue(model.interfaceHidden)
        XCTAssertTrue(model.renderer === renderer)
        XCTAssertFalse(model.previewAssist.isEnabled)
        XCTAssertFalse(model.previewScopes.isEnabled)
        XCTAssertTrue(model.canRecord)
        model.toggleInterface()
        XCTAssertFalse(model.interfaceHidden)
        XCTAssertEqual(model.previewAssist.mode, .zebras)
        XCTAssertTrue(model.previewAssist.focusPeaking)
        XCTAssertEqual(model.previewAssist.peakingColor, .yellow)
        XCTAssertEqual(model.previewScopes.type, .waveform)
        XCTAssertTrue(model.previewScopes.isEnabled)
        XCTAssertEqual(model.controls, controls)
        XCTAssertEqual(model.grade, grade)
        XCTAssertEqual(model.guides, guides)
        XCTAssertEqual(model.zoomFactor, 2)
        XCTAssertTrue(model.renderer === renderer)
    }

    private func fixture(access: @escaping @MainActor () async -> Bool) throws -> (URL, CameraRecordingStore, CameraViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraAccess-\(UUID().uuidString)")
        let store = CameraRecordingStore(root: root)
        let capture = CameraCaptureController(recordingStore: store)
        let model = CameraViewModel(capture: capture, recordingStore: store, recordingAccess: access)
        let format = CameraFormatOption(width: 1920, height: 1080, fps: 30, profile: .sdr)
        model.receive(.configured(.init(lenses: [.init(id: "main", name: "Main", isFront: false, maxZoom: 6)],
            lensID: "main", formats: [format], selected: format, codecs: [.hevc], codec: .hevc,
            limits: .init(iso: 50...1600, shutter: (1.0/8000)...1, bias: -2...2,
                          supportsExposure: true, supportsWhiteBalance: true, supportsFocus: true),
            controls: CameraControls(), stabilizationAvailable: true, stabilizationEnabled: true,
            rotation: 90, hasAudio: true, zoomRange: 1...6)))
        capture.frames.update(try CameraScopeFixture.sample())
        model.receive(.interrupted(false))
        model.receive(.frameSize(.init(width: 180, height: 320), .sdr))
        return (root, store, model)
    }
}

@MainActor
private final class CameraAccessProbe {
    var allowed = false
    var calls = 0
    var paused = false
    var continuation: CheckedContinuation<Bool, Never>?
    func check() async -> Bool {
        calls += 1
        if paused { return await withCheckedContinuation { continuation = $0 } }
        return allowed
    }
}
#endif
