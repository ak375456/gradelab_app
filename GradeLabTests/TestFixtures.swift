import CoreGraphics
import Foundation
@testable import GradeLab

func makeVideoMetadata(
    fileName: String = "clip.mov",
    durationSeconds: Double = 65.75,
    encodedWidth: Int = 1_920,
    encodedHeight: Int = 1_080,
    displayWidth: Int = 1_920,
    displayHeight: Int = 1_080,
    preferredTransform: VideoMetadata.AffineTransform = .init(.identity),
    nominalFrameRate: Double? = 30,
    minimumFrameDurationSeconds: Double? = 1.0 / 30.0,
    codec: String = "HEVC",
    codecFourCC: String = "hvc1",
    estimatedBitrate: Double? = 12_000_000,
    fileSize: Int64? = 4_000_000,
    hasAudio: Bool = true,
    videoTrackCount: Int = 1,
    audioTrackCount: Int = 1,
    colorPrimaries: String? = "BT.709",
    transferFunction: String? = "BT.709",
    yCbCrMatrix: String? = "BT.709",
    logTransferFunction: String? = nil,
    logProfileIdentifier: String? = nil,
    isHDR: Bool? = false,
    bitDepth: Int? = 8,
    creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> VideoMetadata {
    VideoMetadata(
        fileName: fileName,
        durationSeconds: durationSeconds,
        encodedWidth: encodedWidth,
        encodedHeight: encodedHeight,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        preferredTransform: preferredTransform,
        nominalFrameRate: nominalFrameRate,
        minimumFrameDurationSeconds: minimumFrameDurationSeconds,
        codec: codec,
        codecFourCC: codecFourCC,
        estimatedBitrate: estimatedBitrate,
        fileSize: fileSize,
        hasAudio: hasAudio,
        videoTrackCount: videoTrackCount,
        audioTrackCount: audioTrackCount,
        colorPrimaries: colorPrimaries,
        transferFunction: transferFunction,
        yCbCrMatrix: yCbCrMatrix,
        logTransferFunction: logTransferFunction,
        logProfileIdentifier: logProfileIdentifier,
        isHDR: isHDR,
        bitDepth: bitDepth,
        creationDate: creationDate
    )
}
