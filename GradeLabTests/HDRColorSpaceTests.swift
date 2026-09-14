import XCTest
@testable import GradeLab

/// Reference-value tests for the HLG transfer and the working-space scale.
///
/// The expected numbers come from the published BT.2100 curve and from what
/// AVFoundation's decoder actually returns (`Scripts/ValidateHDRDecode.swift`),
/// not from re-running our own implementation — otherwise the test would only
/// prove the code agrees with itself.
final class HDRColorSpaceTests: XCTestCase {
    /// BT.2100 Table 5 anchor points.
    func testHLGInverseOETFMatchesTheSpecification() {
        // Below the 0.5 breakpoint the curve is E'^2 / 3.
        XCTAssertEqual(HDRColorSpace.hlgSceneLight(fromSignal: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(HDRColorSpace.hlgSceneLight(fromSignal: 0.25), 0.25 * 0.25 / 3, accuracy: 1e-12)
        XCTAssertEqual(HDRColorSpace.hlgSceneLight(fromSignal: 0.5), 1.0 / 12, accuracy: 1e-12)
        // At signal 1.0 the log segment reaches exactly 1.0 scene light.
        XCTAssertEqual(HDRColorSpace.hlgSceneLight(fromSignal: 1.0), 1.0, accuracy: 1e-6)
    }

    /// The forward OETF is the only HLG maths we implement ourselves, so it is
    /// checked against the inverse we did not write.
    func testHLGForwardAndInverseRoundTrip() {
        for step in 0...200 {
            let signal = Double(step) / 200
            let light = HDRColorSpace.hlgSceneLight(fromSignal: signal)
            let back = HDRColorSpace.hlgSignal(fromSceneLight: light)
            XCTAssertEqual(back, signal, accuracy: 1e-9, "round trip failed at signal \(signal)")
        }
    }

    func testHLGCurveIsMonotonicAndContinuousAtTheBreakpoint() {
        var previous = -Double.infinity
        for step in 0...1000 {
            let value = HDRColorSpace.hlgSceneLight(fromSignal: Double(step) / 1000)
            XCTAssertGreaterThanOrEqual(value, previous, "curve is not monotonic")
            previous = value
        }
        // The two segments must meet at 0.5; a discontinuity there would band.
        let below = HDRColorSpace.hlgSceneLight(fromSignal: 0.5 - 1e-9)
        let above = HDRColorSpace.hlgSceneLight(fromSignal: 0.5 + 1e-9)
        XCTAssertEqual(below, above, accuracy: 1e-7)
    }

    /// Measured with `Scripts/ValidateHDRDecode.swift`: when AVFoundation is
    /// asked for the HLG representation it returns the signal itself for an HLG
    /// source, and maps an SDR Rec.709 white onto signal 0.749 — BT.2408
    /// reference white. That conversion is what makes a mixed SDR/HDR timeline
    /// sit at a sane brightness, and it is Apple's, not ours.
    func testMeasuredDecoderBehaviourMatchesTheDesign() {
        // HLG source, asked for HLG: identity.
        for level in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let working = HDRColorSpace.toWorkingSpace(signal: SIMD3(repeating: level))
            let back = HDRColorSpace.signal(fromWorkingSpace: working)
            XCTAssertEqual(back.x, level, accuracy: 1e-9)
        }
        // SDR white arrives at 0.749; that must be diffuse white, not a
        // near-peak highlight.
        let sdrWhite = HDRColorSpace.toWorkingSpace(signal: SIMD3(repeating: 0.749))
        XCTAssertEqual(sdrWhite.x, 1.0, accuracy: 0.01,
                       "an SDR white in an HDR project must land on diffuse white")
        XCTAssertLessThan(sdrWhite.x, HDRColorSpace.peakInWorkingSpace,
                          "SDR white must not be stretched toward HDR peak")
    }

    /// Diffuse white is HLG signal 0.75 (BT.2408) and must land on exactly 1.0,
    /// which is what keeps SDR content, text and white UI at a sane brightness
    /// in an HDR project.
    func testReferenceWhiteBecomesOneInTheWorkingSpace() {
        let working = HDRColorSpace.toWorkingSpace(signal: SIMD3(repeating: 0.75))
        XCTAssertEqual(working.x, 1.0, accuracy: 1e-9)
        XCTAssertEqual(working.y, 1.0, accuracy: 1e-9)
        XCTAssertEqual(working.z, 1.0, accuracy: 1e-9)
    }

    /// Peak signal must exceed diffuse white, or highlights have nowhere to go.
    /// This is scene-referred headroom - deliberately not BT.2408's 4.926, which
    /// is a property of the display after the OOTF. The OOTF is the system's
    /// job; applying it here as well double-counted it.
    func testPeakSurvivesAboveDiffuseWhite() {
        let peak = HDRColorSpace.toWorkingSpace(signal: SIMD3(repeating: 1.0))
        XCTAssertEqual(peak.x, HDRColorSpace.peakInWorkingSpace, accuracy: 1e-6)
        XCTAssertEqual(peak.x, 3.774, accuracy: 0.001)
        XCTAssertGreaterThan(peak.x, 1.0)
    }

    /// The transform used for display and for encoding is the same one, so a
    /// round trip must be exact: what is previewed is what is written.
    func testSignalRoundTripsThroughTheWorkingSpace() {
        for level in stride(from: 0.0, through: 1.0, by: 0.05) {
            let signal = SIMD3(repeating: level)
            let back = HDRColorSpace.signal(fromWorkingSpace:
                HDRColorSpace.toWorkingSpace(signal: signal))
            XCTAssertEqual(back.x, level, accuracy: 1e-9, "signal \(level)")
        }
    }

}

/// Phase 0: the project colour mode, its persistence and its migration default.
final class ProjectColorModeTests: XCTestCase {
    func testHLGTenBitCanPreserveHDR() {
        let hlg = makeVideoMetadata(colorPrimaries: "BT.2020", transferFunction: "HLG", bitDepth: 10)
        XCTAssertTrue(ProjectColorMode.canPreserveHDR(for: hlg))
        XCTAssertEqual(ProjectColorMode.default(for: hlg), .hdrHLG)
    }

    /// PQ, Apple Log and 8-bit sources must not be offered as HDR: they are
    /// different transfer functions with no validated path.
    func testOnlyHLGIsOfferedAsHDR() {
        let pq = makeVideoMetadata(colorPrimaries: "BT.2020", transferFunction: "PQ", isHDR: true, bitDepth: 10)
        XCTAssertFalse(ProjectColorMode.canPreserveHDR(for: pq))
        XCTAssertFalse(ProjectColorMode.usesWidePrecisionSDR(for: pq),
                       "PQ is a colour problem, not a precision one")
        XCTAssertEqual(ProjectColorMode.default(for: pq), .sdr)

        let log = makeVideoMetadata(transferFunction: "HLG", logTransferFunction: "Apple Log", bitDepth: 10)
        XCTAssertFalse(ProjectColorMode.canPreserveHDR(for: log))

        let eightBit = makeVideoMetadata(transferFunction: "HLG", bitDepth: 8)
        XCTAssertFalse(ProjectColorMode.canPreserveHDR(for: eightBit))
        XCTAssertFalse(ProjectColorMode.usesWidePrecisionSDR(for: eightBit))

        let sdr = makeVideoMetadata()
        XCTAssertFalse(ProjectColorMode.canPreserveHDR(for: sdr))
        XCTAssertEqual(ProjectColorMode.default(for: sdr), .sdr)
    }

    /// The migration guarantee: a project saved before HDR existed has no
    /// colour-mode key and must come back as SDR, unchanged.
    func testProjectsSavedBeforeHDRDecodeAsSDR() throws {
        let hlg = makeVideoMetadata(colorPrimaries: "BT.2020", transferFunction: "HLG", bitDepth: 10)
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: hlg)
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(project)
        ) as! [String: Any]
        json.removeValue(forKey: "colorMode")
        let legacy = try JSONDecoder().decode(
            VideoProject.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(legacy.colorMode, .sdr, "a pre-HDR project must not change behaviour")
    }

    func testAnHLGImportDefaultsToKeepHDRAndPersists() throws {
        let hlg = makeVideoMetadata(colorPrimaries: "BT.2020", transferFunction: "HLG", bitDepth: 10)
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: hlg)
        XCTAssertEqual(project.colorMode, .hdrHLG)
        XCTAssertTrue(project.canPreserveHDR)

        let reloaded = try JSONDecoder().decode(
            VideoProject.self, from: try JSONEncoder().encode(project)
        )
        XCTAssertEqual(reloaded.colorMode, .hdrHLG, "the choice must survive save and reopen")
    }

    /// Choosing Convert to SDR at import is recorded, not re-derived.
    func testAnExplicitSDRChoiceIsHonouredForAnHLGSource() throws {
        let hlg = makeVideoMetadata(colorPrimaries: "BT.2020", transferFunction: "HLG", bitDepth: 10)
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: hlg, colorMode: .sdr)
        XCTAssertEqual(project.colorMode, .sdr)
        let reloaded = try JSONDecoder().decode(
            VideoProject.self, from: try JSONEncoder().encode(project)
        )
        XCTAssertEqual(reloaded.colorMode, .sdr)
    }

    func testAnSDRProjectStaysSDR() {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: makeVideoMetadata())
        XCTAssertEqual(project.colorMode, .sdr)
        XCTAssertFalse(project.canPreserveHDR)
    }
}

/// The editor must open for HLG even while grading is still gated.
final class HDRSupportGateTests: XCTestCase {
    private var hlg: VideoMetadata {
        makeVideoMetadata(colorPrimaries: "BT.2020", transferFunction: "HLG", bitDepth: 10)
    }

    func testHLGOpensAndGrades() {
        let support = ColorPipelineSupport(metadata: hlg)
        XCTAssertEqual(support, .hdrSupported(transfer: "HLG"))
        XCTAssertTrue(support.allowsEditor, "an HLG source must be openable")
        XCTAssertTrue(support.allowsGrading, "HLG grading is enabled")
        XCTAssertFalse(support.isBlocking)
        XCTAssertEqual(support.colorMode, .hdrHLG)
        XCTAssertTrue(support.notice?.contains("never converted to SDR") ?? false,
                      "the notice must promise no silent SDR conversion")
    }

    func testPQIsStillBlockedAndSaysWhy() {
        for isHDRTag in [true, false] {
            // The second case is the contradictory one: a PQ transfer with the
            // HDR flag missing. It must still be recognised as PQ and refused
            // for the right reason, not fall through to a bit-depth message.
            let pq = makeVideoMetadata(
                colorPrimaries: "BT.2020", transferFunction: "PQ",
                isHDR: isHDRTag, bitDepth: 10
            )
            let support = ColorPipelineSupport(metadata: pq)
            XCTAssertFalse(support.allowsEditor, "isHDR tag \(isHDRTag)")
            XCTAssertTrue(support.isBlocking)
            XCTAssertTrue(support.notice?.contains("PQ") ?? false,
                          "the reason must name PQ, not the bit depth (isHDR tag \(isHDRTag))")
            XCTAssertTrue(support.notice?.contains("HLG") ?? false,
                          "the reason must say HLG is the supported path")
        }
    }

    func testSDRSourcesAreUnaffected() {
        let support = ColorPipelineSupport(metadata: makeVideoMetadata())
        XCTAssertEqual(support, .supported)
        XCTAssertTrue(support.allowsEditor)
        XCTAssertTrue(support.allowsGrading)
        XCTAssertEqual(support.colorMode, .sdr)
    }
}
