#if !targetEnvironment(macCatalyst)
import AVFoundation
import MetalKit
import XCTest
@testable import GradeLab

/// Physical-device acceptance: no permission prompts. Its brief test take is
/// written only in a unique temporary folder and deleted before returning.
/// Exercises the real session/output combination that a simulator cannot supply.
@MainActor
final class CameraCaptureDeviceTests: XCTestCase {
    func testExpandedColorFormatsRecordTaggedOriginalsAndReopen() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical camera")
        #else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw XCTSkip("Camera permission required") }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let activeDeadline = Date().addingTimeInterval(10)
        while UIApplication.shared.applicationState != .active && Date() < activeDeadline { try await Task.sleep(for: .milliseconds(100)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraFormats-\(UUID())")
        let store = CameraRecordingStore(root: root)
        let capture = CameraCaptureController(recordingStore: store)
        let probe = CaptureProbe()
        defer { capture.shutdown(); try? FileManager.default.removeItem(at: root) }
        capture.start(audio: false) { event in Task { @MainActor in probe.receive(event) } }
        try await probe.waitForFrame(after: 0)
        let initial = try XCTUnwrap(probe.configuration)
        print("CAMERA_FORMAT_CAPABILITIES \(Set(initial.formats.map { $0.profile.rawValue }).sorted()), codecs=\(initial.codecs.map(\.title)), resolutions=\(Set(initial.formats.map(\.resolution)).sorted())")
        var modes: [(CameraFormatOption, CameraCodec)] = []
        for profile in CameraProfile.allCases {
            if let format = initial.formats.first(where: { $0.width == 1920 && $0.fps == 30 && $0.profile == profile }) { modes.append((format, .hevc)) }
        }
        if let hdr60 = initial.formats.first(where: { $0.width == 3840 && $0.fps == 60 && $0.profile == .hdrHLG }) { modes.append((hdr60, .hevc)) }
        if let hd = initial.formats.first(where: { $0.width == 1280 && $0.fps == 30 && $0.profile == .sdr }) { modes.append((hd, .h264)) }
        for sensor in initial.formats where sensor.isOpenGate && sensor.fps == 30 && sensor.profile == .sdr { modes.append((sensor, .hevc)) }
        for codec in initial.codecs where codec.isProRes { modes.append((initial.selected, codec)) }
        for (format, codec) in modes {
            do { try await recordAndVerifyFormat(capture: capture, probe: probe, store: store, lensID: initial.lensID, format: format, codec: codec) }
            catch { XCTFail("Format \(format.title) \(format.profile) failed: \(error)"); return }
        }
        #endif
    }

    private func recordAndVerifyFormat(capture: CameraCaptureController, probe: CaptureProbe, store: CameraRecordingStore,
                                       lensID: String, format: CameraFormatOption, codec: CameraCodec) async throws {
        let count = probe.frames
        capture.configure(lensID: lensID, format: format, codec: codec, rotation: 90, stabilization: true, quality: .maximum)
        try await probe.waitForFrame(after: count)
        XCTAssertEqual(probe.configuration?.selected, format)
        XCTAssertEqual(probe.configuration?.codec, codec)
        XCTAssertEqual(probe.configuration?.quality, .maximum)
        let previewTime = capture.frames.presentationTime.seconds
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(capture.frames.presentationTime.seconds, previewTime)
        var grade = GradeSettings.neutral; grade.saturation = 24; grade.vibrance = 35
        capture.startRecording(grade: grade, hasPro: true)
        try await probe.wait(until: { probe.started })
        try await Task.sleep(for: .seconds(format.fps == 60 ? 5 : 2))
        capture.stopRecording()
        try await probe.wait(until: { probe.finished != nil })
        let recording = try XCTUnwrap(probe.finished)
        XCTAssertEqual(recording.grade, grade)
        let asset = try await VideoMetadataReader().read(from: store.mediaURL(for: recording))
        let metadata = asset.metadata
        XCTAssertTrue(format.profile.matches(SourceColorProfile.detect(metadata: metadata)), "\(format.profile) written as \(metadata)")
        XCTAssertEqual(min(metadata.encodedWidth, metadata.encodedHeight), format.height)
        XCTAssertEqual(max(metadata.encodedWidth, metadata.encodedHeight), format.width)
        XCTAssertEqual(metadata.nominalFrameRate ?? 0, Double(format.fps), accuracy: 1)
        if format.profile.needsTenBit || codec.isProRes { XCTAssertGreaterThanOrEqual(metadata.bitDepth ?? 0, 10) }
        XCTAssertTrue(ColorPipelineSupport(metadata: metadata).allowsEditor)
        print("CAMERA_FORMAT_METADATA \(format.profile.badge) \(metadata.colorPrimaries ?? "nil")/\(metadata.transferFunction ?? "nil")")
        let movie = AVURLAsset(url: asset.url)
        let tracks = try await movie.loadTracks(withMediaType: .video)
        print("CAMERA_FORMAT_TRACK_LOADED")
        let track = try XCTUnwrap(tracks.first)
        _ = try await ExportSourceInspector.inspect(asset, requireExportColorTags: true)
        print("CAMERA_FORMAT_PREFLIGHT_PASSED")
        try verifySampleCadence(asset: movie, track: track, fps: Double(format.fps))
        print("CAMERA_FORMAT_PASS \(format.title) \(format.profile.badge) \(codec.title), \(metadata.bitDepth ?? 0)-bit, tags=\(metadata.colorPrimaries ?? "nil")/\(metadata.transferFunction ?? "nil"); editor preflight passed")
        probe.started = false; probe.finished = nil
    }

    func testHorizonReceivesDeviceMotionAndStopsWhenHidden() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical motion sensors")
        #else
        let monitor = CameraLevelMonitor()
        guard monitor.isAvailable else { throw XCTSkip("Device motion unavailable") }
        defer { monitor.stop() }
        monitor.setEnabled(true, rotation: 90)
        let deadline = Date().addingTimeInterval(5)
        while monitor.gravity == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let gravity = try XCTUnwrap(monitor.gravity, "The horizon must receive real sensor samples")
        XCTAssertTrue(gravity.x.isFinite && gravity.y.isFinite)
        monitor.setEnabled(false, rotation: 90)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(monitor.gravity, "Hidden monitoring must stop motion updates")
        XCTAssertNil(monitor.angle)
        print("CAMERA_DEVICE_HORIZON real gravity received; hidden monitoring stopped")
        #endif
    }

    func testMainCameraSwitchesTo4K60AndResumesWithFreshFrames() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical camera")
        #else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("Grant camera access in GradeLab before running device acceptance")
        }
        let idleWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleWasDisabled }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraDevice-\(UUID().uuidString)")
        let recordings = CameraRecordingStore(root: root)
        let capture = CameraCaptureController(recordingStore: recordings)
        let probe = CaptureProbe()
        defer { capture.shutdown(); try? FileManager.default.removeItem(at: root) }
        let audio = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        capture.start(audio: audio) { event in Task { @MainActor in probe.receive(event) } }
        try await probe.waitForFrame(after: 0)
        let initial = try XCTUnwrap(probe.configuration)
        capture.startRecording(grade: .neutral, hasPro: false)
        try await probe.wait(until: { probe.proRequests == 1 })
        XCTAssertFalse(probe.started)
        XCTAssertTrue(try recordings.pending().isEmpty, "A blocked recording must not create a take or recovery receipt")
        XCTAssertGreaterThanOrEqual(initial.zoomRange.upperBound, 2)
        capture.setZoom(2, animated: true)
        try await probe.wait(until: { abs(probe.zoomFactor - 2) < 0.05 })
        let builtInStereo = audio && AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .builtInMic }
        if builtInStereo {
            try await probe.wait(until: { probe.audioLevels.count == 2 })
            // Exercise MovieFileOutput as well as the 4K60 sample recorder below.
            capture.startRecording(grade: .neutral, hasPro: true)
            try await probe.wait(until: { probe.started })
            try await Task.sleep(for: .seconds(1))
            capture.stopRecording()
            try await probe.wait(until: { probe.finished != nil })
            let take = try XCTUnwrap(probe.finished)
            try await verifyStereoAudio(asset: AVURLAsset(url: recordings.mediaURL(for: take)))
            probe.started = false; probe.finished = nil
        }
        let target = try XCTUnwrap(initial.formats.first {
            $0.width == 3840 && $0.height == 2160 && $0.fps == 60 && $0.profile == .sdr
        }, "Main camera must expose native 4K60")
        let firstCount = probe.frames
        capture.configure(lensID: initial.lensID, format: target, codec: .hevc,
                          rotation: 90, stabilization: true)
        try await probe.waitForFrame(after: firstCount)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(probe.failure)
        XCTAssertEqual(probe.configuration?.selected, target)
        XCTAssertEqual(probe.configuration?.zoomFactor ?? 0, 2, accuracy: 0.05, "Format changes preserve camera zoom")
        let time = capture.frames.presentationTime
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(capture.frames.presentationTime.seconds, time.seconds, "4K60 preview must keep streaming")
        let beforeResume = probe.frames
        capture.suspend()
        try await Task.sleep(for: .milliseconds(300))
        capture.start(audio: audio) { event in Task { @MainActor in probe.receive(event) } }
        try await probe.waitForFrame(after: beforeResume)
        XCTAssertEqual(probe.configuration?.selected, target)
        if builtInStereo { try await probe.wait(until: { probe.audioLevels.count == 2 }) }
        var exposure = CameraControls()
        exposure.manualExposure = true; exposure.iso = 200; exposure.shutterAngle = 180
        capture.setControls(exposure)
        try await probe.wait(until: { abs(probe.shutter - 1.0 / 120) < 0.0001 })
        exposure.flicker = .hz50
        capture.setControls(exposure)
        try await probe.wait(until: { abs(probe.shutter - 1.0 / 100) < 0.0001 })
        exposure.flicker = .hz60
        capture.setControls(exposure)
        try await probe.wait(until: { abs(probe.shutter - 1.0 / 120) < 0.0001 })
        exposure.flicker = .off
        capture.setControls(exposure)
        // Exercise the live scope GPU pass alongside the full-rate encoder,
        // rather than checking recording with the preview switched off.
        let context = try MetalContext()
        let portrait = CGSize(width: 2160, height: 3840)
        let renderer = try MetalVideoRenderer(context: context, frameProvider: capture.frames,
            displaySize: portrait, encodedSize: portrait, preferredTransform: .identity,
            fallbackMatrix: "BT.709")
        renderer.setScopes(.init(isEnabled: true, type: .histogram, intensity: 1))
        var assist = ViewerAssistSettings(); assist.focusPeaking = true
        renderer.setViewerAssist(assist)
        let analyzer = try XCTUnwrap(renderer.scopeAnalyzer)
        analyzer.onUpdate = { Task { @MainActor in probe.scopeUpdates += 1 } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 216, height: 384))
        renderer.configure(view)
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        view.isPaused = false
        defer { view.isPaused = true; view.delegate = nil; window.isHidden = true }
        try await probe.wait(until: { probe.scopeUpdates > 2 })
        let updatesBeforeTake = probe.scopeUpdates
        capture.startRecording(grade: .neutral, hasPro: true)
        try await probe.wait(until: { probe.started })
        for factor in stride(from: 2.1, through: 2.5, by: 0.1) {
            capture.setZoom(factor)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await probe.wait(until: { abs(probe.zoomFactor - 2.5) < 0.05 })
        try await Task.sleep(for: .seconds(6))
        XCTAssertGreaterThan(probe.recordedBytes, 0, "Remaining-time estimates must receive real encoded file growth")
        capture.stopRecording()
        try await probe.wait(until: { probe.finished != nil })
        XCTAssertGreaterThan(probe.scopeUpdates, updatesBeforeTake + 2, "Live scope must keep updating during 4K60 capture")
        view.isPaused = true
        let receipt = try XCTUnwrap(probe.finished)
        let asset = AVURLAsset(url: recordings.mediaURL(for: receipt))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(min(size.width, size.height), 2160)
        XCTAssertEqual(max(size.width, size.height), 3840)
        XCTAssertEqual(fps, 60, accuracy: 1)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if audio { XCTAssertEqual(audioTracks.count, 1) }
        if builtInStereo { try await verifyStereoAudio(asset: asset) }
        try verifySampleCadence(asset: asset, track: track, fps: 60)
        print("CAMERA_DEVICE_PASS \(Int(size.width))x\(Int(size.height)) \(fps) fps HEVC, audio=\(audioTracks.count); continuous preview and resume")
        // Rebuild both capture topologies, including 4K50, without leaving a
        // stale movie/audio connection or a stale frame-size cache behind.
        let fifty = try XCTUnwrap(initial.formats.first { $0.width == 3840 && $0.fps == 50 && $0.profile == .sdr })
        for (format, angle) in [(initial.selected, 90), (fifty, 0), (target, 0)] {
            let count = probe.frames
            capture.configure(lensID: initial.lensID, format: format, codec: .hevc, rotation: angle, stabilization: true)
            try await probe.waitForFrame(after: count)
            XCTAssertEqual(probe.configuration?.selected, format)
            XCTAssertEqual(probe.configuration?.controls.shutterSeconds ?? 0, 1 / Double(format.fps * 2), accuracy: 0.00001,
                "An angle must follow frame-rate changes")
        }
        probe.started = false; probe.finished = nil
        capture.startRecording(grade: .neutral, hasPro: true)
        try await probe.wait(until: { probe.started })
        try await Task.sleep(for: .seconds(1))
        capture.stopRecording()
        try await probe.wait(until: { probe.finished != nil })
        let landscapeReceipt = try XCTUnwrap(probe.finished)
        let landscape = AVURLAsset(url: recordings.mediaURL(for: landscapeReceipt))
        let landscapeTracks = try await landscape.loadTracks(withMediaType: .video)
        let landscapeTrack = try XCTUnwrap(landscapeTracks.first)
        let landscapeSize = try await landscapeTrack.load(.naturalSize)
        let landscapeFPS = try await landscapeTrack.load(.nominalFrameRate)
        XCTAssertEqual(landscapeSize.width, 3840)
        XCTAssertEqual(landscapeSize.height, 2160)
        XCTAssertEqual(landscapeFPS, 60, accuracy: 1)
        if builtInStereo { try await verifyStereoAudio(asset: landscape) }
        try verifySampleCadence(asset: landscape, track: landscapeTrack, fps: 60)
        print("CAMERA_DEVICE_PASS landscape 3840x2160 \(landscapeFPS) fps; 1080p ↔ 4K50 ↔ 4K60 switching")
        if let wide = initial.lenses.first(where: { $0.baseZoom == 0.5 }) {
            let count = probe.frames
            capture.configure(lensID: wide.id, format: target, codec: .hevc, rotation: 0, stabilization: true)
            try await probe.waitForFrame(after: count)
            XCTAssertEqual(probe.configuration?.lensID, wide.id)
            XCTAssertEqual(probe.configuration?.zoomFactor, 1)
            print("CAMERA_DEVICE_ZOOM 2× and 2.5× capture zoom, zoom preserved across format/resume, 0.5× physical lens")
        }
        #endif
    }

    private func verifyStereoAudio(asset: AVAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(descriptions.first)
        let stream = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        XCTAssertEqual(stream.pointee.mChannelsPerFrame, 2, "The movie must contain actual stereo audio")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        var difference = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let decoded = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  decoded.pointee.mChannelsPerFrame == 2,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var pcm = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.stride)
            let status = pcm.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            for index in stride(from: 0, to: pcm.count - 1, by: 2) {
                difference += abs(Double(pcm[index]) - Double(pcm[index + 1]))
                frames += 1
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(frames, 1000)
        XCTAssertGreaterThan(difference, 0, "Left/right must not be duplicated mono samples")
        print("CAMERA_DEVICE_STEREO \(frames) decoded frames, distinct L/R channels; \(stream.pointee.mSampleRate) Hz")
    }

    private func verifySampleCadence(asset: AVAsset, track: AVAssetTrack, fps: Double) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if CMSampleBufferGetNumSamples(sample) > 0, time.isNumeric { times.append(time.seconds) }
        }
        XCTAssertEqual(reader.status, .completed)
        // Compressed readers can include repeated preroll timestamps around an
        // edit boundary. Measure unique presentation intervals, not packet count.
        let sorted = Array(Set(times)).sorted()
        let intervals = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.sorted()
        XCTAssertGreaterThan(sorted.count, 40)
        let median = try XCTUnwrap(intervals.dropFirst(intervals.count / 2).first)
        XCTAssertEqual(1 / median, fps, accuracy: 1, "Actual frame cadence must match the requested FPS")
        let regular = intervals.filter { abs($0 - 1 / fps) < 0.003 }.count
        XCTAssertGreaterThan(Double(regular) / Double(max(1, intervals.count)), 0.95)
        print("CAMERA_DEVICE_CADENCE \(sorted.count) unique samples, median \(1 / median) fps")
    }
}

@MainActor
private final class CaptureProbe {
    var configuration: CameraCaptureConfiguration?
    var frames = 0
    var failure: String?
    var started = false
    var proRequests = 0
    var finished: CameraRecording?
    var scopeUpdates = 0
    var audioLevels: [Float] = []
    var zoomFactor: Double = 1
    var shutter: Double = 0
    var recordedBytes: Int64 = 0
    func receive(_ event: CameraCaptureEvent) {
        switch event {
        case .configured(let value): configuration = value
        case .frameSize(let size, _):
            frames += 1
            print("CAMERA_DEVICE_FRAME \(Int(size.width))x\(Int(size.height))")
        case .failed(let message): failure = message
        case .message(let message): failure = message
        case .recordingStarted: started = true
        case .recordingRequiresPro: proRequests += 1
        case .interrupted(true): failure = "Camera interrupted during device acceptance (app state \(UIApplication.shared.applicationState.rawValue))"
        case .finished(let recording, _): finished = recording
        case .telemetry(let value):
            audioLevels = value.audioDB; zoomFactor = value.zoomFactor
            shutter = value.shutter; recordedBytes = value.recordedBytes
        default: break
        }
    }
    func wait(until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() && failure == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(failure, failure ?? "", file: file, line: line)
        XCTAssertTrue(condition(), "Camera state timed out: frames=\(frames), zoom=\(zoomFactor), channels=\(audioLevels.count), proRequests=\(proRequests), started=\(started), finished=\(finished != nil)", file: file, line: line)
        if failure != nil || !condition() { throw ProbeError.noFrame }
    }
    func waitForFrame(after count: Int) async throws {
        let deadline = Date().addingTimeInterval(12)
        while frames <= count && failure == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(failure, failure ?? "")
        XCTAssertGreaterThan(frames, count, "Camera never delivered the first preview frame")
        if failure != nil || frames <= count { throw ProbeError.noFrame }
    }
    enum ProbeError: Error { case noFrame }
}
#endif
