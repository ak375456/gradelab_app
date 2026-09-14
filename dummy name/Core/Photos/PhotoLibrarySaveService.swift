import Foundation
import Photos

enum PhotoLibrarySaveError: LocalizedError, Equatable, Sendable {
    case sourceUnavailable
    case accessDenied
    case accessRestricted
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The exported file is no longer available."
        case .accessDenied:
            "Allow GradeLab to add to Photos in Settings, then try again."
        case .accessRestricted:
            "This device does not allow GradeLab to add to Photos."
        case .saveFailed:
            "The export could not be saved to Photos."
        }
    }
}

struct PhotoLibrarySaveService: Sendable {
    /// Saves a graded still. The same add-only authorisation and the same
    /// creation request the video path uses; only the resource type differs.
    func saveImage(at imageURL: URL) async throws {
        try await save(imageURL, as: .photo)
    }

    func saveVideo(at videoURL: URL) async throws {
        try await save(videoURL, as: .video)
    }

    private func save(_ url: URL, as resourceType: PHAssetResourceType) async throws {
        guard
            url.isFileURL,
            FileManager.default.isReadableFile(atPath: url.path)
        else {
            throw PhotoLibrarySaveError.sourceUnavailable
        }

        let authorizationStatus = await addOnlyAuthorizationStatus()
        switch authorizationStatus {
        case .authorized, .limited:
            break
        case .denied:
            throw PhotoLibrarySaveError.accessDenied
        case .restricted:
            throw PhotoLibrarySaveError.accessRestricted
        case .notDetermined:
            // `addOnlyAuthorizationStatus()` resolves this before returning.
            throw PhotoLibrarySaveError.accessDenied
        @unknown default:
            throw PhotoLibrarySaveError.accessDenied
        }

        try Task.checkCancellation()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                options.shouldMoveFile = false
                request.addResource(with: resourceType, fileURL: url, options: options)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PhotoLibrarySaveError.saveFailed
        }
    }

    private func addOnlyAuthorizationStatus() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard currentStatus == .notDetermined else { return currentStatus }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}
