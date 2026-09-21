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
            String(localized: "This video format is not supported.")
        case .protectedVideo:
            String(localized: "Protected videos can’t be graded.")
        case .unableToReadMetadata:
            String(localized: "GradeLab couldn’t read this video’s technical information.")
        case .missingVideoTrack:
            String(localized: "The selected file does not contain a video track.")
        case .unsupportedCodec(let codec):
            String(localized: "The \(codec) codec is not supported on this device.")
        case .rendererInitializationFailed:
            String(localized: "The video renderer could not be started.")
        case .metalUnavailable:
            String(localized: "Metal is unavailable on this device.")
        case .exportFailed(let detail):
            detail.isEmpty ? String(localized: "The graded video could not be exported.") : detail
        case .insufficientStorage:
            String(localized: "There isn’t enough free storage to export this video.")
        case .photoLibrarySaveFailed:
            String(localized: "The exported video could not be saved to Photos.")
        case .invalidLUT(let detail):
            String(localized: "This LUT is invalid. \(detail)")
        case .assetUnavailable:
            String(localized: "The source video is no longer available.")
        case .exportCancelled:
            String(localized: "Export was cancelled.")
        case .unsupportedExport(let detail):
            detail
        case .presetThumbnailFailed:
            String(localized: "The preview image for this preset could not be created.")
        case .invalidPresetName:
            String(localized: "Give the preset a name before saving it.")
        case .unableToReadImage:
            String(localized: "GradeLab couldn’t read this image.")
        case .imageTooLarge:
            String(localized: "This image is too large to process on this device.")
        case .imageExportFailed(let detail):
            detail.isEmpty ? String(localized: "The graded image could not be exported.") : detail
        }
    }
}
