import CoreGraphics
import XCTest
@testable import GradeLab

final class VideoMetadataTests: XCTestCase {
    func testVideoMetadataFormattingAndOrientation() {
        let metadata = makeMetadata(
            duration: 3_661.9,
            encodedWidth: 1_920,
            encodedHeight: 1_080,
            displayWidth: 1_080,
            displayHeight: 1_920,
            nominalFrameRate: 29.97,
            estimatedBitrate: 52_000_000,
            fileSize: 2_000_000
        )

        XCTAssertEqual(metadata.orientation, .portrait)
        XCTAssertEqual(metadata.resolutionLabel, "1080 × 1920")
        XCTAssertEqual(metadata.resolutionClass, "1080p")
        XCTAssertEqual(metadata.frameRateLabel, "29.97 FPS")
        XCTAssertEqual(metadata.durationLabel, "01:01:01")
        XCTAssertEqual(metadata.bitrateLabel, "52 Mbps")
        XCTAssertNotNil(metadata.fileSizeLabel)
    }

    func testFrameRateFallsBackToMinimumFrameDuration() {
        let metadata = makeMetadata(
            nominalFrameRate: nil,
            minimumFrameDuration: 1.0 / 60.0
        )

        XCTAssertEqual(metadata.bestFrameRate ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(metadata.frameRateLabel, "60 FPS")
    }

    func testEditorTimecodeUsesFramesRatherThanMilliseconds() {
        XCTAssertEqual(TimecodeFormatter.frameString(from: 16.85, frameRate: 30), "00:00:16:25")
        XCTAssertEqual(TimecodeFormatter.frameString(from: 5.04, frameRate: 25), "00:00:05:01")
        XCTAssertEqual(TimecodeFormatter.frameString(from: 1.5, frameRate: nil), "00:00:01:--")
    }

    func testRec709SupportIsExplicitAndConservative() {
        XCTAssertEqual(ColorPipelineSupport(metadata: makeMetadata()), .supported)

        let untagged = makeMetadata(colorPrimaries: nil, transferFunction: nil)
        XCTAssertEqual(ColorPipelineSupport(metadata: untagged), .assumedRec709)
        XCTAssertTrue(ColorPipelineSupport(metadata: untagged).allowsGrading)
        XCTAssertTrue(ColorPipelineSupport(metadata: untagged).notice?.contains("preview and export") == true)

        let missingMatrix = makeVideoMetadata(yCbCrMatrix: nil)
        XCTAssertEqual(ColorPipelineSupport(metadata: missingMatrix), .assumedRec709)

        let conflictingMatrix = makeVideoMetadata(yCbCrMatrix: "BT.601")
        XCTAssertFalse(ColorPipelineSupport(metadata: conflictingMatrix).allowsEditor)

        let hdr = makeMetadata(transferFunction: "ITU_R_2100_HLG", isHDR: true, bitDepth: 10)
        XCTAssertFalse(ColorPipelineSupport(metadata: hdr).allowsGrading)
    }
}

func makeMetadata(
    duration: Double = 12,
    encodedWidth: Int = 3_840,
    encodedHeight: Int = 2_160,
    displayWidth: Int = 3_840,
    displayHeight: Int = 2_160,
    nominalFrameRate: Double? = 30,
    minimumFrameDuration: Double? = 1.0 / 30.0,
    estimatedBitrate: Double? = 30_000_000,
    fileSize: Int64? = 45_000_000,
    colorPrimaries: String? = "BT.709",
    transferFunction: String? = "BT.709",
    isHDR: Bool? = false,
    bitDepth: Int? = 8
) -> VideoMetadata {
    VideoMetadata(
        fileName: "Source.mov",
        durationSeconds: duration,
        encodedWidth: encodedWidth,
        encodedHeight: encodedHeight,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        preferredTransform: .init(.identity),
        nominalFrameRate: nominalFrameRate,
        minimumFrameDurationSeconds: minimumFrameDuration,
        codec: "HEVC",
        codecFourCC: "hvc1",
        estimatedBitrate: estimatedBitrate,
        fileSize: fileSize,
        hasAudio: true,
        videoTrackCount: 1,
        audioTrackCount: 1,
        colorPrimaries: colorPrimaries,
        transferFunction: transferFunction,
        yCbCrMatrix: "BT.709",
        logTransferFunction: nil,
        logProfileIdentifier: nil,
        isHDR: isHDR,
        bitDepth: bitDepth,
        creationDate: Date(timeIntervalSince1970: 1_700_000_000)
    )
}
