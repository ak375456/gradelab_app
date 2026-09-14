import XCTest
@testable import GradeLab

final class ColorPipelineSupportTests: XCTestCase {
    func testFullyTaggedRec709SourceIsSupportedButSRGBIsGated() {
        XCTAssertEqual(ColorPipelineSupport(metadata: makeVideoMetadata()), .supported)
        XCTAssertEqual(
            ColorPipelineSupport(metadata: makeVideoMetadata(transferFunction: "sRGB")),
            .unsupported(reason: "The sRGB transfer function is not yet supported for grading.")
        )
    }

    func testLogSourceIsRejectedBeforeOtherUnsupportedProperties() {
        let support = ColorPipelineSupport(
            metadata: makeVideoMetadata(
                transferFunction: "HLG",
                logTransferFunction: "Apple Log",
                isHDR: true,
                bitDepth: 10
            )
        )
        // Classified by its Log identity, not by the HLG transfer tag it also
        // carries: a Log file is Log first, and grading it as HLG would apply
        // the wrong transfer function to every pixel.
        XCTAssertEqual(support, .appleLogSupported)
        XCTAssertEqual(support.colorMode, .appleLog)
        XCTAssertTrue(support.allowsGrading)
        XCTAssertFalse(support.isBlocking)
        XCTAssertTrue(support.notice?.contains("Apple Log") == true)
    }

    /// Apple Log and Apple Log 2 are different colour spaces — different
    /// primaries as well as a different curve — and Apple Log 2's identifier
    /// ends in the same "apple-log" as Apple Log's. Anything that matched on a
    /// substring would call this one Apple Log and process it through the wrong
    /// transform, so the two are pinned apart here.
    func testAppleLog2IsNeverMistakenForAppleLog() {
        let appleLog = SourceColorProfile.fromLogIdentifier("com.apple.rec2020.apple-log")
        let appleLog2 = SourceColorProfile.fromLogIdentifier("com.apple.apple-wide-gamut.apple-log")
        XCTAssertEqual(appleLog, .appleLog)
        XCTAssertEqual(appleLog2, .appleLog2)

        let support = ColorPipelineSupport(
            metadata: makeVideoMetadata(
                logProfileIdentifier: "com.apple.apple-wide-gamut.apple-log",
                bitDepth: 10
            )
        )
        XCTAssertEqual(support.recognizedProfile, .appleLog2)
        XCTAssertNotEqual(support, .appleLogSupported, "Apple Log 2 must never take the Apple Log path")
        XCTAssertFalse(support.allowsGrading)
        XCTAssertTrue(support.notice?.contains("Apple Log 2") == true)

        // A Log format from another vendor stays honestly unsupported rather
        // than borrowing Apple's transform.
        let other = SourceColorProfile.fromLogIdentifier("com.example.some-other-log")
        XCTAssertEqual(other, .otherLog(identifier: "com.example.some-other-log"))
    }

    /// An HLG source without a verifiable 10-bit depth stays blocked: its
    /// precision cannot be confirmed, so decoding it as HDR would be a guess.
    func testHLGWithoutVerifiedTenBitDepthIsStillBlocked() {
        let support = ColorPipelineSupport(
            metadata: makeVideoMetadata(transferFunction: "HLG", isHDR: true)
        )
        XCTAssertFalse(support.allowsGrading)
        XCTAssertFalse(support.allowsEditor)
        XCTAssertTrue(support.notice?.contains("10-bit") ?? false)
    }

    /// Verified 10-bit HLG opens, previews and grades. Export stays gated
    /// separately, and the source is never converted to SDR without a choice.
    func testVerifiedHLGPreviewsAndGradesWithoutSilentSDRConversion() {
        let support = ColorPipelineSupport(
            metadata: makeVideoMetadata(transferFunction: "HLG", isHDR: true, bitDepth: 10)
        )
        XCTAssertEqual(support, .hdrSupported(transfer: "HLG"))
        XCTAssertTrue(support.allowsEditor)
        XCTAssertTrue(support.allowsGrading)
        XCTAssertFalse(support.isBlocking)
        XCTAssertEqual(support.colorMode, .hdrHLG)
        XCTAssertTrue(support.notice?.contains("never converted to SDR") ?? false)
    }

    /// HDR that is not HLG - PQ, or an untagged transfer - must stay blocked
    /// rather than being treated as HLG, which would render it wrongly.
    func testNonHLGHDRIsBlockedAndNamesHLGAsTheSupportedPath() {
        let untagged = ColorPipelineSupport(
            metadata: makeVideoMetadata(transferFunction: nil, isHDR: true)
        )
        XCTAssertFalse(untagged.allowsEditor)
        XCTAssertTrue(untagged.notice?.contains("HLG") ?? false)

        let pq = ColorPipelineSupport(
            metadata: makeVideoMetadata(transferFunction: "PQ", isHDR: true, bitDepth: 10)
        )
        XCTAssertFalse(pq.allowsEditor)
        XCTAssertTrue(pq.notice?.contains("PQ") ?? false)
    }

    /// More than 8 bits of Rec.709 is a precision question, not a colour one:
    /// the colour handling is the same path 8-bit SDR has always used, so it is
    /// supported with wider containers rather than refused.
    func testTenBitRec709IsSupportedAtWidePrecision() {
        let support = ColorPipelineSupport(metadata: makeVideoMetadata(bitDepth: 10))
        XCTAssertEqual(support, .sdrWideSupported(bitDepth: 10))
        XCTAssertTrue(support.allowsGrading)
        XCTAssertTrue(support.allowsEditor)
        XCTAssertEqual(support.colorMode, .sdrWide)
    }

    /// Depth alone is not enough. A deep source with a colour property we have
    /// no transform for stays blocked.
    func testTenBitWideGamutIsStillRejected() {
        let support = ColorPipelineSupport(
            metadata: makeVideoMetadata(colorPrimaries: "Display P3", bitDepth: 10)
        )
        XCTAssertFalse(support.allowsGrading)
        XCTAssertTrue(support.isBlocking)
    }

    func testUnknownBitDepthIsBlockedInsteadOfSilentlyQuantized() {
        let support = ColorPipelineSupport(metadata: makeVideoMetadata(bitDepth: nil))

        XCTAssertEqual(
            support,
            .unsupported(
                reason: "The source bit depth could not be verified as 8-bit. Grading is disabled to avoid an unreported precision conversion."
            )
        )
        XCTAssertFalse(support.allowsGrading)
    }
}
