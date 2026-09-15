import Metal
import XCTest
import simd
@testable import GradeLab

/// Apple Log 2 is the Apple Log curve on Apple Wide Gamut primaries. These tests
/// pin down the two halves of that sentence separately: that the gamut is the
/// gamut Apple published, and that the curve is shared rather than re-derived.
final class AppleLog2Tests: XCTestCase {

    // MARK: - The primaries are Apple's, not a plausible guess

    /// The check that makes the rest of this file trustworthy.
    ///
    /// Apple publishes Apple Wide Gamut as chromaticities, not as a matrix, so
    /// the matrix this app grades with is derived. A derived matrix is only as
    /// good as its derivation, so it is verified against an *independent* one:
    /// the Academy Software Foundation publishes an Apple Wide Gamut to
    /// ACES2065-1 matrix in the ACES OCIO config. Building that same matrix from
    /// the primaries in `AppleLog2` reproduces theirs to floating-point noise.
    ///
    /// If someone ever "tidies" a digit in those primaries, this fails.
    func testPrimariesReproduceThePublishedACESMatrix() {
        let awgToXYZ = Self.npm(AppleLog2.primaries, white: AppleLog2.primaries.white)
        let ap0ToXYZ = Self.npm(Self.ap0Primaries, white: Self.acesWhite)
        let adaptation = Self.bradford(from: AppleLog2.primaries.white, to: Self.acesWhite)
        let derived = ap0ToXYZ.inverse * adaptation * awgToXYZ

        // As published in AcademySoftwareFoundation/OpenColorIO-Config-ACES, for
        // the "Linear Apple Wide Gamut" colour space, Bradford adapted.
        let published = simd_double3x3(rows: [
            SIMD3<Double>(0.694961049318096, 0.241405268785364, 0.06363368189654),
            SIMD3<Double>(0.0473627464149325, 1.00429592505428, -0.0516586714692158),
            SIMD3<Double>(-0.021989789359883, -0.0289891049714743, 1.05097889433136)
        ])

        // 1e-6 rather than something tighter because `AppleLog2.primaries` are
        // stored as Float for the GPU, and widening them here only measures
        // Float's own rounding. Derived in double throughout, these agree with
        // the ACES config to about 3e-15; 1e-6 is still far tighter than any
        // transcription slip could survive.
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(derived[column][row], published[column][row], accuracy: 1e-6,
                               "Apple Wide Gamut primaries no longer agree with the ACES config at [\(row)][\(column)].")
            }
        }
    }

    /// A neutral must stay neutral. Every row of the gamut matrix sums to one,
    /// which is what makes that true for grey of any brightness — if it were not,
    /// converting Log 2 would tint the whole picture.
    func testGamutConversionLeavesNeutralsNeutral() {
        for row in 0..<3 {
            let sum = AppleLog2.wideGamutToBT2020[0][row]
                + AppleLog2.wideGamutToBT2020[1][row]
                + AppleLog2.wideGamutToBT2020[2][row]
            XCTAssertEqual(sum, 1, accuracy: 1e-6, "Row \(row) does not preserve neutral.")
        }
        for value in [Float(0.18), 1.0, 12.0] {
            let converted = AppleLog2.wideGamutToBT2020 * SIMD3<Float>(repeating: value)
            XCTAssertEqual(converted.x, value, accuracy: value * 1e-5)
            XCTAssertEqual(converted.y, value, accuracy: value * 1e-5)
            XCTAssertEqual(converted.z, value, accuracy: value * 1e-5)
        }
    }

    func testGamutMatrixRoundTrips() {
        let samples: [SIMD3<Float>] = [
            SIMD3(0.18, 0.18, 0.18), SIMD3(1.0, 0.2, 0.05),
            SIMD3(0.05, 0.9, 0.3), SIMD3(0.02, 0.1, 1.4)
        ]
        for sample in samples {
            let round = AppleLog2.bt2020ToWideGamut * (AppleLog2.wideGamutToBT2020 * sample)
            XCTAssertEqual(round.x, sample.x, accuracy: 1e-4)
            XCTAssertEqual(round.y, sample.y, accuracy: 1e-4)
            XCTAssertEqual(round.z, sample.z, accuracy: 1e-4)
        }
    }

    /// Apple Wide Gamut is wider than BT.2020, so a saturated primary lands
    /// outside it. That is carried as negative values rather than clipped on the
    /// way in, which is what keeps it available to a grade.
    func testOutOfGamutColourIsCarriedRatherThanClipped() {
        let saturatedBlue = AppleLog2.wideGamutToBT2020 * SIMD3<Float>(0, 0, 1)
        XCTAssertLessThan(saturatedBlue.min(), 0,
                          "Apple Wide Gamut is wider than BT.2020; a pure primary should leave the cube.")
        XCTAssertTrue(AppleLog2.isOutsideBT2020(saturatedBlue))
        XCTAssertFalse(AppleLog2.isOutsideBT2020(SIMD3(repeating: 0.2)))
    }

    // MARK: - The curve is shared, not re-derived

    /// Apple Log 2 uses Apple Log's transfer function. If that ever stops being
    /// true in the code — a second copy of the constants appearing, say — the
    /// two stop agreeing here.
    func testTransferFunctionIsSharedWithAppleLog() {
        for point in AppleLog.referencePoints {
            let encoded = point.encoded
            // Fed a neutral, the Log 2 input transform must land exactly where
            // Apple Log's does, because the gamut matrix preserves neutrals and
            // the curve is the same function.
            let log2 = AppleLog2.toWorkingSpace(SIMD3<Float>(repeating: encoded))
            let log1 = AppleLog.toWorkingSpace(encoded)
            XCTAssertEqual(log2.x, log1, accuracy: max(abs(log1) * 1e-4, 1e-6),
                           "Apple Log 2 diverged from Apple Log on neutral at encoded \(encoded).")
        }
    }

    // MARK: - Identity and routing

    func testDetectionAndProjectModeStayDistinctFromAppleLog() {
        let metadata = makeVideoMetadata(
            logProfileIdentifier: "com.apple.apple-wide-gamut.apple-log", bitDepth: 10)
        XCTAssertEqual(SourceColorProfile.detect(metadata: metadata), .appleLog2)
        XCTAssertEqual(ProjectColorMode.default(for: metadata), .appleLog2)
        XCTAssertTrue(ProjectColorMode.appleLog2.isAppleLog)
        XCTAssertTrue(ProjectColorMode.appleLog2.isWidePrecision)
        XCTAssertFalse(ProjectColorMode.appleLog2.isHDR)
        XCTAssertEqual(ProjectColorMode.appleLog2.badge, "APPLE LOG 2")

        // Apple Log's own routing is unchanged by any of this.
        let log1 = makeVideoMetadata(
            logProfileIdentifier: "com.apple.rec2020.apple-log", bitDepth: 10)
        XCTAssertEqual(ProjectColorMode.default(for: log1), .appleLog)
    }

    /// `.appleLog2` is persisted in saved projects, so its raw value is part of
    /// the file format and must not be renamed.
    func testColorModeRawValueIsStable() {
        XCTAssertEqual(ProjectColorMode.appleLog2.rawValue, "appleLog2")
        XCTAssertEqual(ProjectColorMode(rawValue: "appleLog2"), .appleLog2)
        XCTAssertEqual(ProjectColorMode(rawValue: "appleLog"), .appleLog)
    }

    // MARK: - GPU: the shader agrees with the CPU reference

    /// The shader carries its own copy of the gamut matrix, because it has to.
    /// This runs the real specialised kernel and checks it against the Swift
    /// reference — the two copies drifting apart is precisely the failure this
    /// guards, and it would show up as a colour cast nobody could source.
    func testShaderInputTransformMatchesTheCPUReference() throws {
        let harness: AppleLogLayerHarness
        do {
            harness = try AppleLogLayerHarness(context: MetalContext(), isLog2: true)
        } catch {
            throw XCTSkip("Apple Log 2 layer pipelines unavailable: \(error)")
        }

        // A flat field at each white-paper code. The reference runs the same
        // chain the shader should: the shared YCbCr matrix, then the *Log 2*
        // working transform — the Apple Log curve plus the gamut conversion.
        // Chroma sits at storage-neutral 512, which is a hair off zero once
        // normalised, so the channels are not exactly equal and the gamut matrix
        // has something real to do.
        for point in AppleLog.referencePoints {
            let frame = try AppleLogLayerHarness.rawFrame(code: UInt16(point.code10Bit))
            let working = try harness.render(frame).working
            let rgb = AppleLog.rgb(fromYCbCr: SIMD3(Float(point.code10Bit) / 1023,
                                                    512.0 / 1023 - 0.5, 512.0 / 1023 - 0.5))
            let expected = AppleLog2.toWorkingSpace(rgb)
            for channel in 0..<3 {
                XCTAssertEqual(working[channel], expected[channel], accuracy: 0.015,
                               "Log 2 shader disagreed on code \(point.code10Bit), channel \(channel).")
            }
        }
    }

    /// The two specialisations must be genuinely different pipelines. If the
    /// function constant were ignored, Log 2 would silently be decoded as Apple
    /// Log — the exact bug this whole design exists to prevent — and every test
    /// above would still pass, because they only exercise neutrals.
    func testLog2ShaderDiffersFromAppleLogOnSaturatedColour() throws {
        let log1: AppleLogLayerHarness
        let log2: AppleLogLayerHarness
        do {
            let context = try MetalContext()
            log1 = try AppleLogLayerHarness(context: context, isLog2: false)
            log2 = try AppleLogLayerHarness(context: context, isLog2: true)
        } catch {
            throw XCTSkip("Apple Log layer pipelines unavailable: \(error)")
        }
        // The default ramp frame carries a chroma-bearing signal, so the two
        // gamuts have something to disagree about.
        let frame = try AppleLogLayerHarness.rawFrame()
        let a = try log1.render(frame).working
        let b = try log2.render(frame).working
        let difference = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(difference, 1e-3,
                             "The Apple Log 2 specialisation produced the Apple Log result; the function constant is not taking effect.")
    }

    // MARK: - Colour-science helpers, kept local to the test

    private static let ap0Primaries = (
        red: SIMD2<Float>(0.7347, 0.2653),
        green: SIMD2<Float>(0.0, 1.0),
        blue: SIMD2<Float>(0.0001, -0.0770),
        white: SIMD2<Float>(0.32168, 0.33767)
    )
    private static let acesWhite = SIMD2<Float>(0.32168, 0.33767)

    /// Normalised primary matrix: RGB to XYZ for a set of chromaticities.
    private static func npm(
        _ primaries: (red: SIMD2<Float>, green: SIMD2<Float>, blue: SIMD2<Float>, white: SIMD2<Float>),
        white: SIMD2<Float>
    ) -> simd_double3x3 {
        func column(_ c: SIMD2<Float>) -> SIMD3<Double> {
            let x = Double(c.x), y = Double(c.y)
            return SIMD3(x / y, 1, (1 - x - y) / y)
        }
        let base = simd_double3x3(columns: (column(primaries.red), column(primaries.green), column(primaries.blue)))
        let scale = base.inverse * column(white)
        return simd_double3x3(columns: (base[0] * scale.x, base[1] * scale.y, base[2] * scale.z))
    }

    private static let bradfordMatrix = simd_double3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296)
    ])

    private static func bradford(from source: SIMD2<Float>, to destination: SIMD2<Float>) -> simd_double3x3 {
        func cone(_ c: SIMD2<Float>) -> SIMD3<Double> {
            let x = Double(c.x), y = Double(c.y)
            return bradfordMatrix * SIMD3(x / y, 1, (1 - x - y) / y)
        }
        let s = cone(source), d = cone(destination)
        let ratio = simd_double3x3(diagonal: SIMD3(d.x / s.x, d.y / s.y, d.z / s.z))
        return bradfordMatrix.inverse * ratio * bradfordMatrix
    }
}
