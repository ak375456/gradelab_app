#if !targetEnvironment(macCatalyst)
import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, configuring, ready, starting, recording, finishing, reviewing, interrupted, denied, unavailable
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var configuration: CameraCaptureConfiguration?
    @Published private(set) var renderer: MetalVideoRenderer?
    @Published private(set) var previewSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var telemetry = CameraTelemetry()
    @Published var controls = CameraControls()
    @Published var grade = GradeSettings.neutral
    @Published var assist = ViewerAssistSettings()
    @Published var guides = CameraGuideSettings() { didSet { refreshLevel() } }
    @Published var shutterUnit: CameraShutterUnit = .speed
    let level = CameraLevelMonitor()
    @Published private(set) var zoomFactor: Double = 1
    @Published var message: String?
    @Published private(set) var completedRecording: CameraRecording?
    @Published private(set) var recordingWarning: String?
    @Published private(set) var isSavingToPhotos = false
    @Published private(set) var photosSaveError: String?
    @Published private(set) var photosAccessDenied = false
    @Published var notice: String?
    @Published var scopeSettings = ScopeSettings(isEnabled: true, type: .histogram, intensity: 1)
    @Published private(set) var interfaceHidden = false
    @Published private(set) var checkingRecordingAccess = false
    @Published var paywallFeature: ProFeature?
    @Published private(set) var permissionMessage = ""
    let looks = LUTAsset.allLooks.filter { $0.kind == .creative }
    private let capture: CameraCaptureController
    private var context: MetalContext?
    private var active = false
    private var hasFrame = false
    private var pendingRotation = 90
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var previewWaitTask: Task<Void, Never>?
    private let previewTimeout: Duration
    private let recordingStore: CameraRecordingStore
    private let saveVideo: @Sendable (URL) async throws -> Void
    private var scopeRendererStorage: ScopeRenderer?
    private var pendingZoom: CameraZoomStop?
    private var zoomGesture = false
    private let recordingAccess: @MainActor () async -> Bool

    init(capture: CameraCaptureController = CameraCaptureController(), previewTimeout: Duration = .seconds(12),
         recordingStore: CameraRecordingStore = CameraRecordingStore(),
         saveVideo: @escaping @Sendable (URL) async throws -> Void = { try await PhotoLibrarySaveService().saveVideo(at: $0) },
         recordingAccess: @escaping @MainActor () async -> Bool = {
             let store = ProStore.shared
             if store.isCheckingAccess { await store.refreshAccess() }
             return store.hasPro
         }) {
        self.capture = capture
        self.previewTimeout = previewTimeout
        self.recordingStore = recordingStore
        self.saveVideo = saveVideo
        self.recordingAccess = recordingAccess
    }

    var isRecording: Bool { phase == .recording || phase == .starting || phase == .finishing }
    var canRecord: Bool { active && phase == .ready && hasFrame && completedRecording == nil }
    var canConfigure: Bool { phase == .ready && completedRecording == nil }
    var canClose: Bool { !isRecording && !isSavingToPhotos }
    var currentLook: LUTAsset? { looks.first { $0.id == grade.advanced?.lut } }
    var previewAssist: ViewerAssistSettings { interfaceHidden ? ViewerAssistSettings() : assist }
    var previewScopes: ScopeSettings { interfaceHidden ? ScopeSettings() : scopeSettings }

    func toggleInterface() {
        interfaceHidden.toggle()
        refreshPreview()
        refreshScopes()
        refreshLevel()
    }
    var recordingEstimate: CameraRecordingEstimate? {
        guard let configuration, telemetry.freeBytes > 0 else { return nil }
        return CameraRecordingEstimate(freeBytes: telemetry.freeBytes, format: configuration.selected,
            codec: configuration.codec, hasAudio: configuration.hasAudio,
            recordedBytes: telemetry.recordedBytes, elapsed: telemetry.elapsed, quality: configuration.quality)
    }

    func refreshLevel() {
        level.setEnabled(guides.level && !interfaceHidden && active && (phase == .ready || isRecording),
                         rotation: configuration?.rotation ?? pendingRotation)
    }
    var canZoom: Bool { phase == .ready || phase == .recording }
    var currentLens: CameraLens? { configuration?.lenses.first { $0.id == configuration?.lensID } }
    var displayedZoom: Double { zoomFactor * (currentLens?.baseZoom ?? 1) }
    var zoomStops: [CameraZoomStop] {
        guard let config = configuration else { return [] }
        let lenses = config.lenses.filter { $0.isFront == (currentLens?.isFront ?? false) }
        var stops = lenses.map { CameraZoomStop(lensID: $0.id, factor: 1, display: $0.baseZoom) }
        if let main = lenses.first(where: { $0.baseZoom == 1 }), main.maxZoom >= 2,
           !stops.contains(where: { abs($0.display - 2) < 0.1 }) {
            stops.append(.init(lensID: main.id, factor: 2, display: 2))
        }
        return stops.sorted { $0.display < $1.display }
    }

    func setZoom(_ value: Double, animated: Bool = false, gesture: Bool = false) {
        guard canZoom, let config = configuration else { return }
        zoomGesture = gesture
        zoomFactor = CameraGeometry.clampedZoom(value, range: config.zoomRange)
        capture.setZoom(zoomFactor, animated: animated)
    }

    func endZoomGesture() { zoomGesture = false }

    func selectZoom(_ stop: CameraZoomStop) {
        guard let config = configuration else { return }
        if stop.lensID == config.lensID { setZoom(stop.factor, animated: true) }
        else if canConfigure { pendingZoom = stop; reconfigure(lensID: stop.lensID) }
    }

    var resolutions: [CameraFormatOption] {
        guard let config = configuration else { return [] }
        var seen = Set<String>()
        return config.formats.filter { $0.profile == config.selected.profile && seen.insert($0.resolutionID).inserted }
            .sorted { $0.width * $0.height < $1.width * $1.height }
    }

    func setResolution(_ width: Int, height: Int? = nil) {
        guard let config = configuration else { return }
        let options = config.formats.filter { $0.profile == config.selected.profile && $0.width == width && (height == nil ? !$0.isOpenGate : $0.height == height) }
        if let format = options.min(by: { abs($0.fps - config.selected.fps) < abs($1.fps - config.selected.fps) }) {
            reconfigure(format: format)
        }
    }

    func setFrameRate(_ fps: Int) {
        guard let config = configuration,
              let option = config.formats.first(where: { $0.resolutionID == config.selected.resolutionID && $0.profile == config.selected.profile && $0.fps == fps }) else { return }
        reconfigure(format: option)
    }

    var scopeAnalyzer: ScopeAnalyzer? { renderer?.scopeAnalyzer }
    var scopeColorSpace: ScopeColorSpace { ScopeColorSpace(renderer?.colorMode ?? .sdr) }
    var scopeRenderer: ScopeRenderer? {
        guard !interfaceHidden, scopeSettings.isEnabled, let renderer, let analyzer = renderer.scopeAnalyzer else { return nil }
        if scopeRendererStorage == nil {
            scopeRendererStorage = ScopeRenderer(context: renderer.metalContext, analyzer: analyzer,
                                                 type: scopeSettings.type, intensity: scopeSettings.intensity)
        }
        return scopeRendererStorage
    }

    func refreshScopes() {
        if !previewScopes.isEnabled { scopeRendererStorage = nil }
        renderer?.setScopes(previewScopes)
    }

    /// Dismissing the choice keeps the durable take on Home for a later edit.
    func dismissRecordingChoice() {
        guard !isSavingToPhotos else { return }
        completedRecording = nil
        recordingWarning = nil
        photosSaveError = nil
        photosAccessDenied = false
        phase = .interrupted
    }

    func saveCompletedRecordingToPhotos() async {
        guard let recording = completedRecording, !isSavingToPhotos else { return }
        isSavingToPhotos = true
        photosSaveError = nil
        photosAccessDenied = false
        defer { isSavingToPhotos = false }
        do {
            try await saveVideo(recordingStore.mediaURL(for: recording))
            // Photos owns a confirmed full-quality copy now. Never run this
            // cleanup before the library transaction succeeds.
            try? recordingStore.removeAfterPhotoSave(recording)
            completedRecording = nil
            phase = .interrupted
            notice = String(localized: "Saved to Photos")
        } catch {
            photosSaveError = error.localizedDescription
            photosAccessDenied = (error as? PhotoLibrarySaveError) == .accessDenied
        }
    }

    func start() async {
        guard !active, completedRecording == nil else { return }
        active = true
        message = nil
        hasFrame = false
        renderer = nil
        scopeRendererStorage = nil
        phase = .authorizing
        let video = await Self.permission(for: .video)
        guard active else { return }
        guard video else {
            phase = .denied
            permissionMessage = String(localized: "Allow Camera access in Settings to record video in GradeLab.")
            active = false
            return
        }
        let audio = await Self.permission(for: .audio)
        guard active else { return }
        phase = .configuring
        waitForPreview()
        capture.start(audio: audio) { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
    }

    func stop() {
        level.stop()
        previewWaitTask?.cancel()
        active = false
        capture.shutdown()
        renderer = nil
        scopeRendererStorage = nil
        endBackgroundTask()
    }

    func suspend() {
        level.stop()
        previewWaitTask?.cancel()
        active = false
        hasFrame = false
        if isRecording {
            phase = .finishing
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish camera recording") { [weak self] in
                    self?.capture.stopRecording()
                    self?.endBackgroundTask()
                }
            }
        } else { phase = .interrupted }
        capture.suspend()
    }

    func updateOrientation(_ orientation: UIDeviceOrientation) {
        let angle: Int
        switch orientation {
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        default: return
        }
        pendingRotation = angle
        guard canConfigure, let configuration, configuration.rotation != angle else { return }
        reconfigure(rotation: angle)
    }

    func reconfigure(lensID: String? = nil, format: CameraFormatOption? = nil,
                     codec: CameraCodec? = nil, rotation: Int? = nil, stabilization: Bool? = nil, quality: CameraRecordingQuality? = nil) {
        guard canConfigure, let config = configuration else { return }
        phase = .configuring
        level.stop()
        message = nil
        hasFrame = false
        renderer = nil
        scopeRendererStorage = nil
        waitForPreview()
        capture.configure(lensID: lensID ?? config.lensID, format: format ?? config.selected,
                          codec: codec ?? config.codec, rotation: rotation ?? config.rotation,
                          stabilization: stabilization ?? config.stabilizationEnabled, quality: quality ?? config.quality)
    }

    func setProfile(_ profile: CameraProfile) {
        guard let config = configuration else { return }
        let sameSize = config.formats.filter { $0.profile == profile && $0.resolutionID == config.selected.resolutionID }
        let matching = sameSize.min { abs($0.fps - config.selected.fps) < abs($1.fps - config.selected.fps) }
            ?? config.formats.first { $0.profile == profile }
        if let matching { reconfigure(format: matching) }
    }

    func toggleRecording() async {
        // Stopping and keeping an existing take never depends on entitlement.
        if phase == .recording { phase = .finishing; capture.stopRecording(); return }
        guard canRecord, !checkingRecordingAccess else { return }
        checkingRecordingAccess = true
        let hasPro = await recordingAccess()
        checkingRecordingAccess = false
        // The camera may have closed or been interrupted during the check.
        guard canRecord else { return }
        if let feature = ProAccessPolicy.cameraRecordingRequirement(hasPro: hasPro) {
            paywallFeature = feature
            return
        }
        phase = .starting
        message = nil
        capture.startRecording(grade: grade, hasPro: hasPro)
    }

    func applyControls() {
        guard phase == .ready || phase == .recording else { return }
        if let config = configuration { controls = config.limits.clamped(controls, fps: config.selected.fps) }
        capture.setControls(controls)
    }

    func setManualExposure(_ enabled: Bool) {
        if enabled { controls.iso = telemetry.iso; controls.shutterSeconds = telemetry.shutter }
        controls.shutterAngle = enabled && shutterUnit == .angle
            ? CameraGeometry.shutterAngle(controls.shutterSeconds, fps: configuration?.selected.fps ?? 30) : nil
        controls.flicker = .off
        controls.manualExposure = enabled
        applyControls()
    }

    func setShutterUnit(_ unit: CameraShutterUnit) {
        shutterUnit = unit
        guard controls.manualExposure, controls.flicker == .off else { return }
        controls.shutterAngle = unit == .angle
            ? CameraGeometry.shutterAngle(controls.shutterSeconds, fps: configuration?.selected.fps ?? 30) : nil
        applyControls()
    }

    func setShutterSpeed(_ seconds: Double) {
        controls.flicker = .off
        controls.shutterAngle = nil
        controls.shutterSeconds = seconds
        applyControls()
    }

    func setShutterAngle(_ angle: Double) {
        if !controls.manualExposure { setManualExposure(true) }
        shutterUnit = .angle
        controls.flicker = .off
        controls.shutterAngle = angle
        applyControls()
    }

    func setFlicker(_ flicker: CameraFlicker) {
        if flicker != .off && !controls.manualExposure { setManualExposure(true) }
        controls.flicker = flicker
        controls.shutterAngle = flicker == .off && shutterUnit == .angle
            ? CameraGeometry.shutterAngle(controls.shutterSeconds, fps: configuration?.selected.fps ?? 30) : nil
        applyControls()
    }

    func setManualWhiteBalance(_ enabled: Bool) {
        if enabled { controls.temperature = telemetry.temperature; controls.tint = telemetry.tint }
        controls.manualWhiteBalance = enabled
        applyControls()
    }

    func setManualFocus(_ enabled: Bool) {
        if enabled { controls.focus = telemetry.focus }
        controls.manualFocus = enabled
        applyControls()
    }

    func selectLook(_ look: LUTAsset?) {
        guard canConfigure else { return }
        var advanced = grade.advanced ?? AdvancedGrade()
        advanced.lut = look?.id
        advanced.lutIntensity = look == nil ? nil : 100
        grade.advanced = advanced == .neutral ? nil : advanced
        if let look { renderer?.prepareLook(look.id) }
        renderer?.update(settings: grade, bypass: false)
    }

    /// Creative color shares the editor's single GPU grading pass and receipt.
    /// Freeze the grade during a take, just like LUT selection.
    func setCreativeColor(_ parameter: GradeParameter, value: Float) {
        guard canConfigure, parameter == .saturation || parameter == .vibrance, value.isFinite else { return }
        grade[keyPath: parameter.keyPath] = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        renderer?.update(settings: grade, bypass: false)
    }

    func refreshPreview() {
        renderer?.setViewerAssist(previewAssist)
        renderer?.update(settings: grade, bypass: false)
    }

    func focus(at location: CGPoint, bounds: CGSize) {
        guard phase == .ready || phase == .recording, !controls.manualFocus, let configuration else { return }
        let rect = CameraGeometry.fittedRect(image: previewSize, in: bounds)
        guard let point = CameraGeometry.focusPoint(tap: location, imageRect: rect, rotation: configuration.rotation) else { return }
        capture.focus(at: point)
    }

    func receive(_ event: CameraCaptureEvent) {
        defer { refreshLevel() }
        switch event {
        case .configured(let value):
            guard completedRecording == nil else { return }
            // A synchronous session start can return after the preview watchdog
            // has failed. That late notification must not reopen the spinner.
            guard phase != .unavailable || active else { return }
            configuration = value
            controls = value.controls
            zoomFactor = value.zoomFactor
            phase = .ready
            if let stop = pendingZoom {
                pendingZoom = nil
                if stop.lensID == value.lensID { setZoom(stop.factor) }
            }
            if !hasFrame { waitForPreview() }
            if pendingRotation != value.rotation { reconfigure(rotation: pendingRotation) }
        case .frameSize(let size, let profile):
            guard active else { return }
            previewWaitTask?.cancel()
            do {
                if context == nil { context = try MetalContext() }
                guard let context else { return }
                let renderer = try MetalVideoRenderer(context: context, frameProvider: capture.frames,
                    displaySize: size, encodedSize: size, preferredTransform: .identity,
                    fallbackMatrix: profile.needsTenBit ? "BT.2020" : "BT.709", colorMode: profile.colorMode)
                renderer.preloadLooks()
                renderer.setViewerAssist(previewAssist)
                renderer.setScopes(previewScopes)
                renderer.update(settings: grade, bypass: false)
                previewSize = size
                self.renderer = renderer
                scopeRendererStorage = nil
                hasFrame = true
            } catch { active = false; phase = .unavailable; message = error.localizedDescription; capture.suspend() }
        case .telemetry(let value):
            telemetry = value
            if !zoomGesture { zoomFactor = value.zoomFactor }
        case .recordingStarted: phase = .recording
        case .recordingRequiresPro:
            if phase == .starting { phase = .ready }
            paywallFeature = .cameraRecording
        case .finished(let receipt, let warning):
            #if DEBUG
            print("Camera finished: phase=\(phase)")
            #endif
            previewWaitTask?.cancel()
            endBackgroundTask()
            completedRecording = receipt
            recordingWarning = warning ?? message
            message = nil
            photosSaveError = nil
            photosAccessDenied = false
            active = false
            hasFrame = false
            phase = .reviewing
            capture.suspend()
        case .interrupted(let interrupted):
            guard completedRecording == nil else { return }
            active = !interrupted
            if interrupted { hasFrame = false }
            if isRecording && interrupted { phase = .finishing }
            else if !isRecording { phase = interrupted ? .interrupted : .ready }
        case .message(let value):
            #if DEBUG
            print("Camera message: \(value), phase=\(phase)")
            #endif
            if completedRecording != nil { recordingWarning = value; return }
            message = value
            if phase == .starting || phase == .finishing {
                endBackgroundTask()
                phase = active ? .ready : .interrupted
            }
        case .failed(let value):
            previewWaitTask?.cancel()
            endBackgroundTask()
            message = value
            phase = .unavailable
            active = false
            hasFrame = false
            renderer = nil
            capture.suspend()
        }
    }

    private func waitForPreview() {
        previewWaitTask?.cancel()
        previewWaitTask = Task { [weak self, previewTimeout] in
            do { try await Task.sleep(for: previewTimeout) } catch { return }
            guard let self, !self.hasFrame,
                  self.phase == .ready || self.phase == .configuring else { return }
            self.receive(.failed(String(localized: "The camera did not deliver a preview. Resume the camera to try again.")))
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func permission(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
}
#endif
