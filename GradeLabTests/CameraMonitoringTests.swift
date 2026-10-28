import XCTest
@testable import GradeLab

final class CameraMonitoringTests: XCTestCase {
    private let limits = CameraControlLimits(iso: 50...1600, shutter: (1.0 / 8000)...1,
        supportsExposure: true, supportsWhiteBalance: true, supportsFocus: true)

    func testShutterAngleFollowsFrameRateWhileSpeedStaysAbsolute() {
        var controls = CameraControls()
        controls.manualExposure = true
        controls.shutterAngle = 180
        for fps in [24, 25, 30, 50, 60] {
            let value = limits.clamped(controls, fps: fps)
            XCTAssertEqual(value.shutterSeconds, 1 / Double(fps * 2), accuracy: 0.000001)
            XCTAssertEqual(CameraGeometry.angleLabel(value.shutterSeconds, fps: fps), "180°")
        }
        controls.shutterAngle = nil; controls.shutterSeconds = 1.0 / 100
        XCTAssertEqual(limits.clamped(controls, fps: 24).shutterSeconds, 1.0 / 100, accuracy: 0.000001)
        XCTAssertEqual(limits.clamped(controls, fps: 60).shutterSeconds, 1.0 / 100, accuracy: 0.000001)
    }

    func testFlickerPresetsUseWholeLightCyclesAtEverySupportedFrameRate() throws {
        for flicker in [CameraFlicker.hz50, .hz60] {
            for fps in [24, 25, 30, 50, 60] {
                var controls = CameraControls()
                controls.manualExposure = true; controls.flicker = flicker
                controls.shutterAngle = 180
                let actual = limits.clamped(controls, fps: fps)
                let cycles = actual.shutterSeconds * (flicker == .hz50 ? 100 : 120)
                XCTAssertEqual(cycles, cycles.rounded(), accuracy: 0.000001)
                XCTAssertLessThanOrEqual(actual.shutterSeconds, 1 / Double(fps) + 0.000001)
                XCTAssertEqual(actual.flicker, flicker)
                XCTAssertNil(actual.shutterAngle)
            }
        }
        XCTAssertEqual(try XCTUnwrap(CameraFlicker.hz50.duration(fps: 60, range: limits.shutterRange(fps: 60))), 1.0 / 100, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(CameraFlicker.hz60.duration(fps: 60, range: limits.shutterRange(fps: 60))), 1.0 / 120, accuracy: 0.000001)
        XCTAssertNil(CameraFlicker.hz50.duration(fps: 60, range: (1.0 / 8000)...(1.0 / 200)))
    }

    func testAngleAndFlickerRespectNarrowSensorLimits() {
        let restricted = CameraControlLimits(iso: 50...800, shutter: (1.0 / 2000)...(1.0 / 200), supportsExposure: true)
        var controls = CameraControls()
        controls.manualExposure = true; controls.shutterAngle = 360; controls.flicker = .hz50
        let actual = restricted.clamped(controls, fps: 60)
        XCTAssertEqual(actual.flicker, .off)
        XCTAssertEqual(actual.shutterSeconds, 1.0 / 200, accuracy: 0.000001)
        XCTAssertEqual(actual.shutterAngle ?? 0, 108, accuracy: 0.00001)
    }

    func testHorizonUsesCaptureOrientationAndHidesWhenPointedStraightDown() throws {
        for (x, y, rotation) in [(0.0, -1.0, 90), (-1.0, 0.0, 0), (1.0, 0.0, 180), (0.0, 1.0, 270)] {
            XCTAssertEqual(try XCTUnwrap(CameraGeometry.horizonAngle(x: x, y: y, rotation: rotation)), 0, accuracy: 0.00001)
        }
        XCTAssertEqual(try XCTUnwrap(CameraGeometry.horizonAngle(x: 0.5, y: -sqrt(0.75), rotation: 90)), -30, accuracy: 0.00001)
        XCTAssertNil(CameraGeometry.horizonAngle(x: 0.01, y: 0.01, rotation: 90))
        XCTAssertNil(CameraGeometry.horizonAngle(x: .nan, y: -1, rotation: 90))
    }

    func testHorizonMatchesTheNearestAxisWithoutAFalse45DegreeClamp() {
        for angle in [0.4, -0.4, 89.6, -89.6] {
            let reading = CameraHorizonReading(angle: angle)
            XCTAssertTrue(reading.isLevel)
            XCTAssertEqual(abs(reading.deviation), 0.4, accuracy: 0.00001)
        }
        let sideways = CameraHorizonReading(angle: 89.6)
        XCTAssertEqual(sideways.reference, 90)
        XCTAssertEqual(sideways.angle, 89.6)
        XCTAssertTrue(sideways.isVertical)
        XCTAssertEqual(CameraHorizonReading(angle: -75).deviation, 15)
        XCTAssertFalse(CameraHorizonReading(angle: -75).isLevel)
    }

    func testRecordingEstimateTracksFormatCodecAndSafetyReserve() {
        func estimate(width: Int, fps: Int, codec: CameraCodec, free: Int64 = 10_000_000_000) -> CameraRecordingEstimate {
            .init(freeBytes: free, format: .init(width: width, height: width == 1920 ? 1080 : 2160, fps: fps, profile: .sdr), codec: codec, hasAudio: true)
        }
        XCTAssertGreaterThan(estimate(width: 1920, fps: 30, codec: .hevc).seconds, estimate(width: 3840, fps: 30, codec: .hevc).seconds)
        XCTAssertGreaterThan(estimate(width: 3840, fps: 30, codec: .hevc).seconds, estimate(width: 3840, fps: 60, codec: .hevc).seconds)
        XCTAssertGreaterThan(estimate(width: 3840, fps: 60, codec: .hevc).seconds, estimate(width: 3840, fps: 60, codec: .proRes).seconds)
        let empty = estimate(width: 1920, fps: 30, codec: .hevc, free: 100_000_000)
        XCTAssertEqual(empty.seconds, 0); XCTAssertEqual(empty.label, "< 1 min"); XCTAssertTrue(empty.isLow)
    }

    func testEstimateUsesActualFileGrowthAfterEncoderWarmup() {
        let format = CameraFormatOption(width: 3840, height: 2160, fps: 60, profile: .sdr)
        let actual = CameraRecordingEstimate(freeBytes: 1_280_000_000, format: format, codec: .hevc,
            hasAudio: true, recordedBytes: 10_000_000, elapsed: 10)
        XCTAssertEqual(actual.seconds, 1000, accuracy: 0.001)
        let warming = CameraRecordingEstimate(freeBytes: 1_280_000_000, format: format, codec: .hevc,
            hasAudio: true, recordedBytes: 100, elapsed: 1)
        XCTAssertLessThan(warming.seconds, actual.seconds)
    }

    func testPeakingIsIndependentOfExposureAidAndNeverStoredInGrade() {
        var assist = ViewerAssistSettings()
        assist.focusPeaking = true; assist.peakingColor = .yellow; assist.peakingSensitivity = 80
        XCTAssertTrue(assist.isEnabled)
        XCTAssertEqual(assist.uniform.x, 0)
        XCTAssertEqual(assist.uniform.z, 3)
        XCTAssertEqual(assist.uniform.w, 0.8, accuracy: 0.00001)
        XCTAssertEqual(GradeUniforms(settings: .neutral, bypass: false).viewerAssist, .zero)
        assist.mode = .zebras
        XCTAssertEqual(assist.uniform.x, 2)
        XCTAssertEqual(assist.uniform.z, 3)
    }
}
