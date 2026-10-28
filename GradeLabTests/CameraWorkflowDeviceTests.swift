#if !targetEnvironment(macCatalyst)
import AVFoundation
import SwiftUI
import XCTest
@testable import GradeLab

@MainActor
final class CameraWorkflowDeviceTests: XCTestCase {
    func testFullCameraStopsPresentsDestinationAndRecordsAgainIn1080pAnd4K60() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical camera")
        #else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw XCTSkip("Camera permission required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraWorkflow-\(UUID())")
        let store = CameraRecordingStore(root: root)
        let capture = CameraCaptureController(recordingStore: store)
        let model = CameraViewModel(capture: capture, recordingStore: store, recordingAccess: { true })
        let wasAwake = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: CameraView(model: model, onClose: {}, onRecording: { _ in }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            model.stop(); window.isHidden = true
            UIApplication.shared.isIdleTimerDisabled = wasAwake
            try? FileManager.default.removeItem(at: root)
        }
        try await wait(model, "initial preview") { model.canRecord }
        model.assist.focusPeaking = true
        model.guides.level = true
        model.refreshPreview()
        if let look = model.looks.first { model.selectLook(look) }
        model.setCreativeColor(.saturation, value: -15)
        model.setCreativeColor(.vibrance, value: 30)
        for (width, fps, profile) in [(1920, 30, CameraProfile.sdr), (1920, 30, .sdr), (3840, 60, .sdr), (3840, 60, .sdr), (3840, 60, .hdrHLG), (1920, 30, .displayP3)] {
            if model.configuration?.selected.profile != profile {
                model.setProfile(profile)
                try await wait(model, "color profile preview") { model.canRecord }
            }
            if model.configuration?.selected.width != width {
                model.setResolution(width)
                try await wait(model, "resolution preview") { model.canRecord }
            }
            if model.configuration?.selected.fps != fps {
                model.setFrameRate(fps)
                try await wait(model, "frame-rate preview") { model.canRecord }
            }
            print("CAMERA_WORKFLOW_START \(model.configuration?.selected.title ?? "nil")")
            await model.toggleRecording()
            try await wait(model, "recording start") { model.phase == .recording || model.completedRecording != nil }
            XCTAssertEqual(model.phase, .recording, model.message ?? "Stopped before recording")
            try await Task.sleep(for: .seconds(8))
            XCTAssertEqual(model.phase, .recording, model.message ?? "Stopped before user pressed Stop")
            print("CAMERA_WORKFLOW_STOP \(fps)")
            await model.toggleRecording()
            try await wait(model, "destination sheet") { model.completedRecording != nil && host.presentedViewController != nil }
            let recording = try XCTUnwrap(model.completedRecording)
            XCTAssertEqual(recording.grade.saturation, -15)
            XCTAssertEqual(recording.grade.vibrance, 30)
            let asset = AVURLAsset(url: store.mediaURL(for: recording))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let video = try XCTUnwrap(tracks.first)
            let duration = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(duration, 6)
            let actualFPS = try await video.load(.nominalFrameRate)
            XCTAssertEqual(actualFPS, Float(fps), accuracy: 1)
            let size = try await video.load(.naturalSize)
            XCTAssertEqual(Int(max(size.width, size.height)), width)
            try verifyFrameTiming(asset: asset, track: video, fps: fps)
            XCTAssertNil(model.recordingWarning, "A normal take must not finish with an encoder warning")
            print("CAMERA_WORKFLOW_DESTINATION \(fps), valid movie")
            model.dismissRecordingChoice()
            try await wait(model, "resume after destination") { model.canRecord && host.presentedViewController == nil }
            print("CAMERA_WORKFLOW_READY_AGAIN \(fps)")
        }
        #endif
    }

    private func verifyFrameTiming(asset: AVAsset, track: AVAssetTrack, fps: Int) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var timestamps: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isNumeric { timestamps.append(time.seconds) }
        }
        XCTAssertEqual(reader.status, .completed)
        let sorted = Array(Set(timestamps)).sorted()
        let intervals = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        let regular = intervals.filter { abs($0 - 1 / Double(fps)) < 0.003 }.count
        XCTAssertGreaterThan(Double(regular) / Double(max(1, intervals.count)), 0.95,
            "The full-screen preview must not starve the encoder")
        XCTAssertGreaterThan(sorted.count, fps * 6)
        print("CAMERA_WORKFLOW_CADENCE \(fps) fps, \(sorted.count) unique frames, \(regular)/\(intervals.count) regular intervals")
    }

    private func wait(_ model: CameraViewModel, _ step: String, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "\(step): phase=\(model.phase), message=\(model.message ?? "none")", file: file, line: line)
        if !condition() { throw Failure.timeout }
    }
    private enum Failure: Error { case timeout }
}
#endif
