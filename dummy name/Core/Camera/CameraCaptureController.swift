#if !targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
import Foundation
import CoreVideo
import VideoToolbox

final class CameraFrameSource: PreviewFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var time = CMTime.zero
    var latestFrame: CVPixelBuffer? { lock.withLock { buffer } }
    var presentationTime: CMTime { lock.withLock { time } }
    func pixelBuffer(forHostTime hostTime: CFTimeInterval) -> CVPixelBuffer? { latestFrame }
    func update(_ sample: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        update(buffer, time: CMSampleBufferGetPresentationTimeStamp(sample))
    }
    func update(_ value: CVPixelBuffer, time: CMTime) {
        lock.withLock {
            buffer = value
            self.time = time
        }
    }
    func clear() { lock.withLock { buffer = nil } }
}

struct CameraCaptureConfiguration: Sendable {
    let lenses: [CameraLens]
    let lensID: String
    let formats: [CameraFormatOption]
    let selected: CameraFormatOption
    let codecs: [CameraCodec]
    let codec: CameraCodec
    let limits: CameraControlLimits
    let controls: CameraControls
    let stabilizationAvailable: Bool
    let stabilizationEnabled: Bool
    let rotation: Int
    let hasAudio: Bool
    var zoomRange: ClosedRange<Double> = 1...1
    var zoomFactor: Double = 1
    var quality: CameraRecordingQuality = .high
}

struct CameraTelemetry: Sendable {
    var iso: Double = 100
    var shutter: Double = 1.0 / 60
    var temperature: Double = 5600
    var tint: Double = 0
    var focus: Double = 0.5
    var audioDB: [Float] = []
    var microphone = ""
    var elapsed: Double = 0
    var freeBytes: Int64 = 0
    var previewDrops = 0
    var isHot = false
    var zoomFactor: Double = 1
    var recordedBytes: Int64 = 0
}

enum CameraCaptureEvent: Sendable {
    case configured(CameraCaptureConfiguration)
    case frameSize(CGSize, CameraProfile)
    case telemetry(CameraTelemetry)
    case recordingStarted
    case recordingRequiresPro
    case finished(CameraRecording, warning: String? = nil)
    case interrupted(Bool)
    case message(String)
    case failed(String)
}

/// All session/device mutations run on `queue`. AVFoundation owns the encoder;
/// the preview receives a bounded latest-frame buffer and cannot block the file
/// writer. This deliberately records no grading or monitoring overlays.
final class CameraCaptureController: NSObject, @unchecked Sendable {
    let frames = CameraFrameSource()
    private let queue = DispatchQueue(label: "com.gradelab.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let preview = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let recordingStore: CameraRecordingStore
    private var sampleRecorder: CameraSampleRecorder?
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    private var devices: [AVCaptureDevice] = []
    private var input: AVCaptureDeviceInput?
    private var formats: [(CameraFormatOption, AVCaptureDevice.Format)] = []
    private var selected = CameraFormatOption(width: 1920, height: 1080, fps: 30, profile: .sdr)
    private var codec: CameraCodec = .hevc
    private var quality: CameraRecordingQuality = .high
    private var previewConverter: CameraPreviewConverter?
    private var usesSampleRecording: Bool { selected.usesSampleRecording || codec.isProRes }
    private var controls = CameraControls()
    private var limits = CameraControlLimits()
    private var rotation = 90
    private var stabilization = true
    private var audioEnabled = false
    private var zoomFactor: Double = 1
    private var recordingInputIDs: [String]?
    private var prepared = false
    private var suspended = false
    private var recording: CameraRecording?
    private var timer: DispatchSourceTimer?
    private var observations: [NSObjectProtocol] = []
    private var frameSize = CGSize.zero
    private var previewDrops = 0
    private var sink: (@Sendable (CameraCaptureEvent) -> Void)?

    init(recordingStore: CameraRecordingStore = CameraRecordingStore()) {
        self.recordingStore = recordingStore
        super.init()
    }

    func start(audio: Bool, onEvent: @escaping @Sendable (CameraCaptureEvent) -> Void) {
        queue.async { [self] in
            sink = onEvent
            suspended = false
            do {
                if !prepared { try prepare(audio: audio) }
                else if audio && !audioEnabled {
                    session.beginConfiguration()
                    addMicrophoneIfAvailable()
                    session.commitConfiguration()
                }
                try activateAudio()
                // A resumed session can keep the same dimensions. It still
                // needs to announce its first NEW frame to rebuild the viewer.
                frameSize = .zero
                frames.clear()
                if !session.isRunning { session.startRunning() }
                guard session.isRunning else { throw CameraError.unavailable }
                publishConfiguration()
                startTelemetry()
            } catch {
                if !prepared {
                    session.beginConfiguration()
                    session.inputs.forEach(session.removeInput)
                    session.outputs.forEach(session.removeOutput)
                    session.commitConfiguration()
                    input = nil; audioEnabled = false
                }
                emit(.failed(error.localizedDescription))
            }
        }
    }

    func suspend() {
        queue.async { [self] in
            suspended = true
            stopActiveRecording()
            if session.isRunning { session.stopRunning() }
            timer?.cancel(); timer = nil
            frames.clear()
            frameSize = .zero
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func shutdown() {
        queue.async { [self] in
            suspended = true
            stopActiveRecording()
            if session.isRunning { session.stopRunning() }
            timer?.cancel(); timer = nil
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            frames.clear()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // A finishing delegate still needs to deliver the durable receipt.
            if recording == nil { sink = nil }
        }
    }

    func configure(lensID: String, format: CameraFormatOption, codec requestedCodec: CameraCodec,
                   rotation requestedRotation: Int, stabilization: Bool, quality requestedQuality: CameraRecordingQuality = .high) {
        queue.async { [self] in
            guard recording == nil, prepared, let device = devices.first(where: { $0.uniqueID == lensID }) else { return }
            let previousInput = input
            let previousFormat = selected
            let previousCodec = codec
            let previousRotation = rotation
            let previousStabilization = self.stabilization
            let previousControls = controls
            let previousZoom = zoomFactor
            let previousQuality = quality
            do {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                if input?.device.uniqueID == lensID, format == selected, requestedCodec == codec,
                   stabilization == self.stabilization, requestedQuality == quality {
                    rotation = requestedRotation
                    applyConnections()
                    frameSize = .zero
                    frames.clear()
                    // Rotation must preserve manual exposure, WB and focus.
                    publishConfiguration()
                    return
                }
                if input?.device.uniqueID != lensID {
                    let replacement = try AVCaptureDeviceInput(device: device)
                    let previous = input
                    if let previous { session.removeInput(previous) }
                    guard session.canAddInput(replacement) else {
                        if let previous, session.canAddInput(previous) { session.addInput(previous) }
                        throw CameraError.unavailable
                    }
                    session.addInput(replacement)
                    input = replacement
                    controls = CameraControls()
                    zoomFactor = 1
                }
                formats = Self.options(for: device)
                let choice = formats.first { $0.0 == format }
                    ?? formats.first { $0.0.width == format.width && $0.0.fps == format.fps && $0.0.profile == .sdr }
                    ?? formats.first { $0.0 == CameraFormatOption(width: 1920, height: 1080, fps: 30, profile: .sdr) }
                guard let choice else { throw CameraError.formatUnavailable }
                selected = choice.0
                codec = requestedCodec
                quality = requestedQuality
                rotation = [0, 90, 180, 270].contains(requestedRotation) ? requestedRotation : 90
                self.stabilization = stabilization
                try applyFormat(choice.1, device: device)
            } catch {
                let explanation = error.localizedDescription
                // Roll back a rejected combination instead of labeling a live
                // SDR stream as Log or leaving the preview waiting forever.
                do {
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    if input !== previousInput, let previousInput {
                        if let input { session.removeInput(input) }
                        guard session.canAddInput(previousInput) else { throw CameraError.unavailable }
                        session.addInput(previousInput)
                        input = previousInput
                    }
                    guard let restored = input?.device else { throw CameraError.unavailable }
                    formats = Self.options(for: restored)
                    guard let old = formats.first(where: { $0.0 == previousFormat }) else { throw CameraError.formatUnavailable }
                    selected = previousFormat; codec = previousCodec; rotation = previousRotation
                    quality = previousQuality
                    self.stabilization = previousStabilization
                    zoomFactor = previousZoom
                    try applyFormat(old.1, device: restored)
                    setControls(previousControls)
                    controls = previousControls
                } catch {
                    emit(.failed(error.localizedDescription))
                    return
                }
                emit(.message(explanation))
            }
            publishConfiguration()
        }
    }

    func setControls(_ requested: CameraControls) {
        queue.async { [self] in
            guard let device = input?.device, prepared else { return }
            do {
                let value = limits.clamped(requested, fps: selected.fps)
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                applyControlsLocked(value, device: device)
                controls = value
            } catch { emit(.message(error.localizedDescription)) }
        }
    }

    func setZoom(_ requested: Double, animated: Bool = false) {
        queue.async { [self] in
            guard let device = input?.device, prepared, session.isRunning else { return }
            do {
                let value = CameraGeometry.clampedZoom(requested, range: Self.zoomRange(for: device))
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                zoomFactor = value
                if animated { device.ramp(toVideoZoomFactor: CGFloat(value), withRate: 5) }
                else { device.videoZoomFactor = CGFloat(value) }
            } catch { emit(.message(error.localizedDescription)) }
        }
    }

    private static func baseZoom(for device: AVCaptureDevice) -> Double {
        if device.deviceType == .builtInUltraWideCamera { return 0.5 }
        let system = Double(device.displayVideoZoomFactorMultiplier)
        if device.deviceType == .builtInTelephotoCamera, system == 1 {
            let field = Double(device.activeFormat.videoFieldOfView) * .pi / 360
            return max(1, (tan(65 * .pi / 360) / max(0.01, tan(field))).rounded())
        }
        return system > 0 && system.isFinite ? system : 1
    }

    private static func zoomRange(for device: AVCaptureDevice) -> ClosedRange<Double> {
        let lower = max(1, Double(device.minAvailableVideoZoomFactor))
        let upper = min(Double(device.maxAvailableVideoZoomFactor), Double(device.activeFormat.videoMaxZoomFactor), 10 / baseZoom(for: device))
        return lower...max(lower, upper)
    }

    /// The caller owns the device configuration lock.
    private func applyControlsLocked(_ value: CameraControls, device: AVCaptureDevice) {
        if value.manualExposure {
            device.setExposureModeCustom(duration: CMTime(seconds: value.shutterSeconds, preferredTimescale: 1_000_000_000),
                                         iso: Float(value.iso), completionHandler: nil)
        } else if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(Float(value.exposureBias), completionHandler: nil)
        }
        if value.manualWhiteBalance {
            var gains = device.deviceWhiteBalanceGains(for: .init(temperature: Float(value.temperature), tint: Float(value.tint)))
            gains.redGain = min(max(gains.redGain, 1), device.maxWhiteBalanceGain)
            gains.greenGain = min(max(gains.greenGain, 1), device.maxWhiteBalanceGain)
            gains.blueGain = min(max(gains.blueGain, 1), device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if value.manualFocus {
            device.setFocusModeLocked(lensPosition: Float(value.focus), completionHandler: nil)
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    func focus(at point: CGPoint) {
        queue.async { [self] in
            guard let device = input?.device, !controls.manualFocus else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if !controls.manualExposure, device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
            } catch { emit(.message(error.localizedDescription)) }
        }
    }

    func startRecording(grade: GradeSettings, hasPro: Bool) {
        queue.async { [self] in
            guard ProAccessPolicy.cameraRecordingRequirement(hasPro: hasPro) == nil else {
                emit(.recordingRequiresPro)
                return
            }
            guard prepared, session.isRunning, recording == nil, !movie.isRecording else {
                emit(.message(String(localized: "Wait for the camera to be ready, then try again."))); return
            }
            var receipt: CameraRecording?
            do {
                guard availableBytes() > 250_000_000 else { throw CameraError.storageFull }
                let prepared = try recordingStore.prepare(grade: grade, profile: selected.profile)
                receipt = prepared
                if usesSampleRecording {
                    guard let videoFormat,
                          var settings = preview.recommendedVideoSettings(forVideoCodecType: codec.avCodec, assetWriterOutputFileType: .mov),
                          !audioEnabled || audioFormat != nil else { throw CameraError.unavailable }
                    let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
                    settings[AVVideoWidthKey] = Int(dimensions.width)
                    settings[AVVideoHeightKey] = Int(dimensions.height)
                    var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
                    compression[AVVideoExpectedSourceFrameRateKey] = selected.fps
                    if !codec.isProRes {
                        compression[AVVideoAllowFrameReorderingKey] = false
                        compression[AVVideoAverageBitRateKey] = quality.bitRate(format: selected, codec: codec)
                        if selected.profile.needsTenBit { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
                    }
                    settings[AVVideoCompressionPropertiesKey] = compression
                    if selected.profile == .hdrHLG || selected.profile == .displayP3 {
                        settings[AVVideoColorPropertiesKey] = Self.colorProperties(for: selected.profile)
                    }
                    sampleRecorder = try CameraSampleRecorder(url: recordingStore.mediaURL(for: prepared),
                        videoSettings: settings, videoFormat: videoFormat,
                        audioSettings: audioEnabled ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) : nil,
                        audioFormat: audioEnabled ? audioFormat : nil, fps: selected.fps, queue: queue,
                        onFailure: { [weak self] message in self?.stopActiveRecording(warning: message) })
                    recording = prepared
                } else {
                    recording = prepared
                    movie.startRecording(to: recordingStore.mediaURL(for: prepared), recordingDelegate: self)
                }
            } catch {
                if let receipt { try? recordingStore.discardEmpty(receipt) }
                emit(.message(error.localizedDescription))
            }
        }
    }

    func stopRecording() {
        queue.async { [self] in stopActiveRecording() }
    }

    private func stopActiveRecording(warning: String? = nil) {
        recordingInputIDs = nil
        if let sampleRecorder, let receipt = recording {
            sampleRecorder.finish { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.sampleRecorder = nil; self.recording = nil
                    if let error {
                        try? self.recordingStore.discardEmpty(receipt)
                        self.emit(.message(error))
                    } else { self.emit(.finished(receipt, warning: warning)) }
                }
            }
        } else if movie.isRecording { movie.stopRecording() }
    }

    private func prepare(audio: Bool) throws {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
                                                   mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            throw CameraError.unavailable
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        // Let AVFoundation select the microphone/polar pattern for the camera,
        // including the stereo mode requested on its audio input.
        session.automaticallyConfiguresApplicationAudioSession = true
        let camera = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(camera) else { throw CameraError.unavailable }
        session.addInput(camera); input = camera
        if audio { addMicrophoneIfAvailable() }
        guard session.canAddOutput(movie) else { throw CameraError.unavailable }
        session.addOutput(movie)
        movie.minFreeDiskSpaceLimit = 200_000_000
        movie.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        // Lower-rate modes use preview-sized buffers beside MovieFileOutput.
        // High-rate 4K modes use this as their sole video output and encoder input.
        preview.automaticallyConfiguresOutputBufferDimensions = false
        preview.deliversPreviewSizedOutputBuffers = true
        preview.alwaysDiscardsLateVideoFrames = true
        preview.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(preview) else { throw CameraError.unavailable }
        session.addOutput(preview)
        formats = Self.options(for: device)
        guard let initial = formats.first(where: { $0.0 == selected }) ?? formats.first else { throw CameraError.formatUnavailable }
        selected = initial.0
        try applyFormat(initial.1, device: device)
        prepared = true
        observeSession()
    }

    /// Called inside a capture-session configuration. External microphones keep
    /// their native channels; the multichannel mode applies only to built-in mic.
    private func addMicrophoneIfAvailable() {
        guard let microphone = AVCaptureDevice.default(for: .audio),
              let mic = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(mic) else { return }
        session.addInput(mic)
        if mic.isMultichannelAudioModeSupported(.stereo) { mic.multichannelAudioMode = .stereo }
        audioEnabled = true
    }

    private func activateAudio() throws {
        guard audioEnabled else { return }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
    }

    private static func options(for device: AVCaptureDevice) -> [(CameraFormatOption, AVCaptureDevice.Format)] {
        var result: [(CameraFormatOption, AVCaptureDevice.Format)] = []
        var seen = Set<CameraFormatOption>()
        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let standard = [(1280, 720), (1920, 1080), (3840, 2160)].contains { size.width == $0.0 && size.height == $0.1 }
            let sensor43 = size.width >= 1920 && size.width <= 4096 && abs(Double(size.width) / Double(size.height) - 4.0 / 3) < 0.01
            guard standard || sensor43 else { continue }
            for fps in [24, 25, 30, 50, 60] where format.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
            }) {
                for profile in CameraProfile.allCases {
                    guard let colorSpace = profile.avColorSpace, format.supportedColorSpaces.contains(colorSpace) else { continue }
                    let option = CameraFormatOption(width: Int(size.width), height: Int(size.height), fps: fps, profile: profile)
                    if seen.insert(option).inserted { result.append((option, format)) }
                    else if let index = result.firstIndex(where: { $0.0 == option }),
                            format.isVideoBinned && !result[index].1.isVideoBinned {
                        // Identical dimensions/FPS can use different sensor
                        // readouts. Binned readouts reserve less ISP bandwidth;
                        // device enumeration order is not a compatibility rank.
                        result[index] = (option, format)
                    }
                }
            }
        }
        return result.sorted {
            if $0.0.width != $1.0.width { return $0.0.width < $1.0.width }
            if $0.0.fps != $1.0.fps { return $0.0.fps < $1.0.fps }
            return $0.0.profile.rawValue > $1.0.profile.rawValue
        }
    }

    private func applyFormat(_ format: AVCaptureDevice.Format, device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        zoomFactor = CameraGeometry.clampedZoom(zoomFactor, range: Self.zoomRange(for: device))
        device.videoZoomFactor = CGFloat(zoomFactor)
        device.automaticallyAdjustsVideoHDREnabled = false
        if format.isVideoHDRSupported { device.isVideoHDREnabled = false }
        guard let colorSpace = selected.profile.avColorSpace, format.supportedColorSpaces.contains(colorSpace) else { throw CameraError.formatUnavailable }
        device.activeColorSpace = colorSpace
        let duration = CMTime(value: 1, timescale: Int32(selected.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        // Unlike the device's runtime limits, the input override also bounds
        // the hardware budget reserved for the format's maximum frame rate.
        input?.videoMinFrameDurationOverride = duration
        limits = CameraControlLimits(
            iso: Double(format.minISO)...Double(format.maxISO),
            shutter: max(0.000001, format.minExposureDuration.seconds)...max(0.000001, format.maxExposureDuration.seconds),
            bias: Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias),
            supportsExposure: device.isExposureModeSupported(.custom),
            supportsWhiteBalance: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            supportsFocus: device.isLockingFocusWithCustomLensPositionSupported)
        controls = limits.clamped(controls, fps: selected.fps)
        applyControlsLocked(controls, device: device)
        let encoders = preview.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        if !encoders.contains(codec.avCodec) || (selected.profile.needsTenBit && codec == .h264) {
            guard let fallback = CameraCodec.allCases.first(where: { encoders.contains($0.avCodec) && !(selected.profile.needsTenBit && $0 == .h264) }) else { throw CameraError.formatUnavailable }
            codec = fallback
        }
        // ProRes variants and wide-color capture use the single-stream writer.
        // HLG is written with HLG tags, without carrying stale Dolby metadata.
        if usesSampleRecording {
            if session.outputs.contains(movie) { session.removeOutput(movie) }
            if audioEnabled && !session.outputs.contains(audioOutput) {
                guard session.canAddOutput(audioOutput) else { throw CameraError.formatUnavailable }
                audioOutput.setSampleBufferDelegate(self, queue: queue)
                session.addOutput(audioOutput)
            }
        } else {
            if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
            if !session.outputs.contains(movie) {
                guard session.canAddOutput(movie) else { throw CameraError.formatUnavailable }
                session.addOutput(movie)
            }
        }
        preview.deliversPreviewSizedOutputBuffers = !usesSampleRecording
        // In single-stream modes these are recording frames too. Discarding
        // them while the encoder warms up creates gaps in an otherwise 60fps take.
        preview.alwaysDiscardsLateVideoFrames = !usesSampleRecording
        videoFormat = nil; audioFormat = nil
        let pixelTypes = preview.availableVideoPixelFormatTypes
        if selected.profile.needsTenBit || codec.isProRes {
            let preferred: [OSType] = codec.isProRes ? [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] : [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange]
            guard let tenBit = preferred
                .first(where: { pixelTypes.contains($0) }) else { throw CameraError.formatUnavailable }
            preview.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: tenBit]
        } else {
            preview.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        }
        previewConverter = selected.profile == .hdrHLG || selected.profile == .displayP3 ? try CameraPreviewConverter(profile: selected.profile) : nil
        let supported = supportedCodecs()
        guard let fallback = supported.first else { throw CameraError.formatUnavailable }
        if !supported.contains(codec) { codec = fallback }
        if let connection = movie.connection(with: .video) {
            var settings: [String: Any] = [AVVideoCodecKey: codec.avCodec]
            if !codec.isProRes && movie.supportedOutputSettingsKeys(for: connection).contains(AVVideoCompressionPropertiesKey) {
                settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: quality.bitRate(format: selected, codec: codec)]
            }
            movie.setOutputSettings(settings, for: connection)
        }
        applyConnections()
        // Adding/removing outputs can renegotiate capture timing. Reassert the
        // requested rate after the graph and output settings are complete.
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        input?.videoMinFrameDurationOverride = duration
        frameSize = .zero
        frames.clear()
        previewDrops = 0
    }

    private func applyConnections() {
        for connection in [movie.connection(with: .video), preview.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(CGFloat(rotation)) { connection.videoRotationAngle = CGFloat(rotation) }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilization ? .standard : .off
            }
        }
    }

    private func supportedCodecs() -> [CameraCodec] {
        let writer = preview.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        return CameraCodec.allCases.filter {
            let available = usesSampleRecording || $0.isProRes ? writer : movie.availableVideoCodecTypes
            return available.contains($0.avCodec) && !(selected.profile.needsTenBit && $0 == .h264)
        }
    }

    private static func colorProperties(for profile: CameraProfile) -> [String: String] {
        if profile == .hdrHLG {
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }

    private func publishConfiguration() {
        guard let device = input?.device else { return }
        #if DEBUG
        print("Camera configuration: \(selected.title), binned=\(device.activeFormat.isVideoBinned), hardwareCost=\(session.hardwareCost)")
        #endif
        emit(.configured(CameraCaptureConfiguration(
            lenses: devices.map { device in
                let name: String
                if device.position == .front { name = String(localized: "Front") }
                else if device.deviceType == .builtInUltraWideCamera { name = String(localized: "Ultra Wide") }
                else if device.deviceType == .builtInTelephotoCamera { name = String(localized: "Telephoto") }
                else { name = String(localized: "Main") }
                return CameraLens(id: device.uniqueID, name: name, isFront: device.position == .front,
                                  baseZoom: Self.baseZoom(for: device), maxZoom: Self.zoomRange(for: device).upperBound)
            }, lensID: device.uniqueID, formats: formats.map(\.0), selected: selected,
            codecs: supportedCodecs(), codec: codec, limits: limits, controls: controls,
            stabilizationAvailable: (movie.connection(with: .video) ?? preview.connection(with: .video))?.isVideoStabilizationSupported == true,
            stabilizationEnabled: stabilization, rotation: rotation, hasAudio: audioEnabled,
            zoomRange: Self.zoomRange(for: device), zoomFactor: Double(device.videoZoomFactor), quality: quality)))
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.stopActiveRecording()
                self.frames.clear(); self.frameSize = .zero
                self.emit(.interrupted(true))
            }
        })
        observations.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.suspended else { return }
                if !self.session.isRunning { self.session.startRunning() }
                self.frameSize = .zero
                self.emit(.interrupted(false))
            }
        })
        observations.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            #if DEBUG
            if let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                print("Camera runtime error: \(error.domain) \(error.code); \(error.userInfo[NSUnderlyingErrorKey] ?? error.localizedDescription)")
            }
            #endif
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? CameraError.unavailable.localizedDescription
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.stopActiveRecording()
                self.emit(.failed(message))
            }
        })
        observations.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                // Deferred notifications from configuring stereo or rebuilding
                // outputs must not be mistaken for a change during this take.
                guard let self, self.recording != nil, let previous = self.recordingInputIDs else { return }
                let current = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
                guard current != previous else { return }
                self.recordingInputIDs = current
                self.emit(.message(String(localized: "The audio input changed. Check the microphone meter.")))
            }
        })
    }

    private func startTelemetry() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, let device = self.input?.device else { return }
            // Immediately after a sensor-mode switch, the last WB gains can
            // still belong to the previous format's wider gain range. The SDK
            // raises an Objective-C exception for those transient values.
            var gains = device.deviceWhiteBalanceGains
            let maximum = max(1, device.maxWhiteBalanceGain)
            gains.redGain = gains.redGain.isFinite ? min(max(gains.redGain, 1), maximum) : 1
            gains.greenGain = gains.greenGain.isFinite ? min(max(gains.greenGain, 1), maximum) : 1
            gains.blueGain = gains.blueGain.isFinite ? min(max(gains.blueGain, 1), maximum) : 1
            let wb = device.temperatureAndTintValues(for: gains)
            let thermal = ProcessInfo.processInfo.thermalState
            if self.sampleRecorder != nil && self.availableBytes() < 200_000_000 {
                self.stopActiveRecording(warning: CameraError.storageFull.localizedDescription)
            }
            self.emit(.telemetry(CameraTelemetry(
                iso: Double(device.iso), shutter: device.exposureDuration.seconds,
                temperature: Double(wb.temperature), tint: Double(wb.tint), focus: Double(device.lensPosition),
                audioDB: (self.usesSampleRecording ? self.audioOutput : self.movie).connection(with: .audio)?.audioChannels.map(\.averagePowerLevel) ?? [],
                microphone: self.audioEnabled ? AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? String(localized: "Microphone") : String(localized: "No microphone"),
                elapsed: self.sampleRecorder?.duration ?? max(0, self.movie.recordedDuration.seconds.isFinite ? self.movie.recordedDuration.seconds : 0),
                freeBytes: self.availableBytes(), previewDrops: self.previewDrops,
                isHot: thermal == .serious || thermal == .critical, zoomFactor: Double(device.videoZoomFactor),
                recordedBytes: self.recordedBytes())))
        }
        self.timer = timer
        timer.resume()
    }

    private func availableBytes() -> Int64 {
        let values = try? recordingStore.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func recordedBytes() -> Int64 {
        guard let recording else { return 0 }
        if sampleRecorder == nil { return max(0, movie.recordedFileSize) }
        let values = try? recordingStore.mediaURL(for: recording).resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func emit(_ event: CameraCaptureEvent) { sink?(event) }

    private func beganRecording() {
        recordingInputIDs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
        emit(.recordingStarted)
    }
}

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            audioFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
        } else {
            videoFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
        }
        if let sampleRecorder {
            do {
                if try sampleRecorder.append(sampleBuffer, isVideo: output === preview) { beganRecording() }
            } catch { stopActiveRecording(warning: error.localizedDescription) }
        }
        guard output === preview, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let converter = previewConverter {
            converter.convert(sampleBuffer) { [weak self, weak converter] frame in
                self?.queue.async { [weak self, weak converter] in
                    guard let self, let converter, self.previewConverter === converter, !self.suspended else { return }
                    self.frames.update(frame.buffer, time: frame.time)
                    self.announceFrameSize(frame.buffer)
                }
            }
            return
        }
        frames.update(sampleBuffer)
        announceFrameSize(buffer)
    }
    private func announceFrameSize(_ buffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if frameSize != size {
            #if DEBUG
            if let device = input?.device {
                print("Camera timing: min=\(device.activeVideoMinFrameDuration.seconds), max=\(device.activeVideoMaxFrameDuration.seconds)")
            }
            #endif
            frameSize = size; emit(.frameSize(size, selected.profile))
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        previewDrops += 1
    }
}

extension CameraCaptureController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async { [self] in beganRecording() }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let nsError = error as NSError?
        let success = nsError == nil || nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let message = nsError?.localizedDescription
        queue.async { [self] in
            guard let receipt = recording else { return }
            recording = nil
            recordingInputIDs = nil
            if success { emit(.finished(receipt, warning: message)) }
            else {
                try? recordingStore.discardEmpty(receipt)
                emit(.message(message ?? String(localized: "Recording stopped. Any captured footage is kept for recovery.")))
            }
        }
    }
}

private extension CameraCodec {
    var avCodec: AVVideoCodecType {
        switch self { case .hevc: .hevc; case .h264: .h264; case .proResHQ: .proRes422HQ; case .proRes: .proRes422; case .proResLT: .proRes422LT; case .proResProxy: .proRes422Proxy }
    }
}

private extension CameraProfile {
    var avColorSpace: AVCaptureColorSpace? {
        switch self {
        case .sdr: .sRGB
        case .hdrHLG: .HLG_BT2020
        case .displayP3: .P3_D65
        case .appleLog: .appleLog
        case .appleLog2:
            if #available(iOS 26.0, *) { .appleLog2 } else { nil }
        }
    }
}

private enum CameraError: LocalizedError {
    case unavailable, formatUnavailable, storageFull
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The camera is unavailable. Close other camera apps and try again.")
        case .formatUnavailable: String(localized: "This camera cannot record that combination of format and frame rate.")
        case .storageFull: String(localized: "Free up at least 250 MB before starting a recording.")
        }
    }
}
#endif
