import Foundation

enum GradeLabError: LocalizedError, Equatable, Sendable {
    case unsupportedVideo
    case protectedVideo
    case unableToReadMetadata
    case missingVideoTrack
    case unsupportedCodec(String)
    case rendererInitializationFailed
    case metalUnavailable
    case exportFailed(String)
    case insufficientStorage
    case photoLibrarySaveFailed
    case invalidLUT(String)
    case assetUnavailable
    case exportCancelled
    case unsupportedExport(String)
    case presetThumbnailFailed
    case invalidPresetName
    case unableToReadImage
    case imageTooLarge
    case imageExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVideo:
            "This video format is not supported."
        case .protectedVideo:
            "Protected videos can’t be graded."
        case .unableToReadMetadata:
            "GradeLab couldn’t read this video’s technical information."
        case .missingVideoTrack:
            "The selected file does not contain a video track."
        case .unsupportedCodec(let codec):
            "The \(codec) codec is not supported on this device."
        case .rendererInitializationFailed:
            "The video renderer could not be started."
        case .metalUnavailable:
            "Metal is unavailable on this device."
        case .exportFailed(let detail):
            detail.isEmpty ? "The graded video could not be exported." : detail
        case .insufficientStorage:
            "There isn’t enough free storage to export this video."
        case .photoLibrarySaveFailed:
            "The exported video could not be saved to Photos."
        case .invalidLUT(let detail):
            "This LUT is invalid. \(detail)"
        case .assetUnavailable:
            "The source video is no longer available."
        case .exportCancelled:
            "Export was cancelled."
        case .unsupportedExport(let detail):
            detail
        case .presetThumbnailFailed:
            "The preview image for this preset could not be created."
        case .invalidPresetName:
            "Give the preset a name before saving it."
        case .unableToReadImage:
            "GradeLab couldn’t read this image."
        case .imageTooLarge:
            "This image is too large to process on this device."
        case .imageExportFailed(let detail):
            detail.isEmpty ? "The graded image could not be exported." : detail
        }
    }
}
