import XCTest
@testable import GradeLab

final class CameraSettingsTests: XCTestCase {
    func testZoomClampsHardwareLimitsAndRejectsInvalidGestureValues() {
        XCTAssertEqual(CameraGeometry.clampedZoom(-2, range: 1...6), 1)
        XCTAssertEqual(CameraGeometry.clampedZoom(100, range: 1...6), 6)
        XCTAssertEqual(CameraGeometry.clampedZoom(.nan, range: 1...6), 1)
        XCTAssertEqual(CameraGeometry.clampedZoom(2.5, range: 1...6), 2.5)
        XCTAssertEqual(CameraGeometry.zoomLabel(0.5), "0.5×")
        XCTAssertEqual(CameraGeometry.zoomLabel(2), "2×")
    }

    func testCompositionFramesStayInsideTheActualCameraPicture() {
        for image in [CGRect(x: 40, y: 12, width: 280, height: 500), CGRect(x: 0, y: 50, width: 700, height: 300)] {
            for guide in CameraFrameGuide.allCases {
                let rect = CameraGeometry.guideRect(aspect: guide.aspect, image: image)
                XCTAssertTrue(image.insetBy(dx: -0.01, dy: -0.01).contains(rect))
                XCTAssertEqual(rect.midX, image.midX, accuracy: 0.001)
                XCTAssertEqual(rect.midY, image.midY, accuracy: 0.001)
                if let aspect = guide.aspect { XCTAssertEqual(rect.width / rect.height, aspect, accuracy: 0.001) }
            }
        }
        XCTAssertEqual(CameraGrid.thirds.divisions.count, 2)
        XCTAssertEqual(CameraGrid.quarters.divisions.count, 3)
    }
    func testOnlyHighRate4KUsesTheSingleStreamRecorder() {
        for fps in [24, 25, 30] {
            XCTAssertFalse(CameraFormatOption(width: 3840, height: 2160, fps: fps, profile: .sdr).usesSampleRecording)
        }
        for fps in [50, 60] {
            XCTAssertTrue(CameraFormatOption(width: 3840, height: 2160, fps: fps, profile: .sdr).usesSampleRecording)
            XCTAssertFalse(CameraFormatOption(width: 1920, height: 1080, fps: fps, profile: .sdr).usesSampleRecording)
        }
    }
    func testManualExposureHonorsLensLimitsAndFramePeriod() {
        let limits = CameraControlLimits(iso: 50...800, shutter: (1.0 / 8000)...1, bias: -2...2,
                                        supportsExposure: true, supportsWhiteBalance: true, supportsFocus: true)
        var authored = CameraControls()
        authored.manualExposure = true
        authored.iso = 5000
        authored.shutterSeconds = 1.0 / 50
        authored.exposureBias = 4
        let actual = limits.clamped(authored, fps: 60)
        XCTAssertEqual(actual.iso, 800)
        XCTAssertEqual(actual.shutterSeconds, 1.0 / 60, accuracy: 0.000001)
        XCTAssertEqual(actual.exposureBias, 2)
        XCTAssertTrue(actual.manualExposure)
        XCTAssertEqual(CameraGeometry.shutterLabel(actual.shutterSeconds), "1/60")
    }

    func testFixedFocusAndUnsupportedManualModesCannotBeEnabled() {
        var controls = CameraControls()
        controls.manualFocus = true; controls.manualExposure = true; controls.manualWhiteBalance = true
        controls.focus = 2; controls.temperature = 15000; controls.tint = -200
        let actual = CameraControlLimits().clamped(controls, fps: 30)
        XCTAssertFalse(actual.manualFocus)
        XCTAssertFalse(actual.manualExposure)
        XCTAssertFalse(actual.manualWhiteBalance)
        XCTAssertEqual(actual.focus, 1)
        XCTAssertEqual(actual.temperature, 10000)
        XCTAssertEqual(actual.tint, -100)
    }

    func testFocusRejectsLetterboxAndConvertsAllCaptureOrientations() throws {
        let rect = CameraGeometry.fittedRect(image: .init(width: 1920, height: 1080), in: .init(width: 320, height: 400))
        XCTAssertEqual(rect.width, 320, accuracy: 0.01)
        XCTAssertEqual(rect.height, 180, accuracy: 0.01)
        XCTAssertNil(CameraGeometry.focusPoint(tap: .init(x: 160, y: 20), imageRect: rect, rotation: 90))
        let tap = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.75)
        let expected: [(Int, CGPoint)] = [(0, .init(x: 0.25, y: 0.75)), (90, .init(x: 0.75, y: 0.75)),
                                        (180, .init(x: 0.75, y: 0.25)), (270, .init(x: 0.25, y: 0.25))]
        for (angle, point) in expected {
            let actual = try XCTUnwrap(CameraGeometry.focusPoint(tap: tap, imageRect: rect, rotation: angle))
            XCTAssertEqual(actual.x, point.x, accuracy: 0.00001)
            XCTAssertEqual(actual.y, point.y, accuracy: 0.00001)
        }
    }

    func testPortraitFrameFitsWithoutCroppingOnWideLayout() {
        let rect = CameraGeometry.fittedRect(image: .init(width: 1080, height: 1920), in: .init(width: 600, height: 300))
        XCTAssertEqual(rect.height, 300)
        XCTAssertEqual(rect.width, 168.75)
        XCTAssertGreaterThan(rect.minX, 0)
    }
}
