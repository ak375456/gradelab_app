import AVFoundation
import Foundation

/// Checks the destination volume before rendering starts. Leave room beyond
/// the estimated file size for variable bitrate and movie metadata.
enum ExportStorage {
    static func estimatedBytes(
        asset: VideoAsset, configuration: ExportConfiguration, project: VideoProject?
    ) -> Int64? {
        let hasProjectAudio = project?.assets.contains {
            $0.videoMetadata?.hasAudio == true || $0.audioName != nil
        } ?? false
        return ExportEstimate.make(
            configuration: configuration,
            canvasWidth: project?.canvas.width ?? asset.metadata.encodedWidth,
            canvasHeight: project?.canvas.height ?? asset.metadata.encodedHeight,
            fps: configuration.frameRate.value ?? project?.canvas.frameRate ?? asset.metadata.nominalFrameRate,
            durationSeconds: project?.timeline.duration.seconds ?? asset.metadata.durationSeconds,
            audioTrackCount: project == nil ? asset.metadata.audioTrackCount : (hasProjectAudio ? 1 : 0)
        )?.byteCount
    }

    static func requiredBytes(estimatedBytes: Int64?) -> Int64 {
        let required = Double(max(0, estimatedBytes ?? 0)) * 1.2 + 64_000_000
        return required >= Double(Int64.max) ? Int64.max : Int64(required.rounded(.up))
    }

    static func issue(at destination: URL, estimatedBytes: Int64?) -> String? {
        // The file does not exist yet. Query its parent on the same volume,
        // using reclaimable capacity appropriate for a user-requested export.
        let values = try? destination.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map { Int64($0) }
        return issue(availableBytes: available, estimatedBytes: estimatedBytes)
    }

    static func issue(availableBytes: Int64?, estimatedBytes: Int64?) -> String? {
        guard let availableBytes else { return nil }
        let required = requiredBytes(estimatedBytes: estimatedBytes)
        guard availableBytes < required else { return nil }
        let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: max(0, availableBytes), countStyle: .file)
        return String(localized: "Not enough storage. This export needs about \(needed) available; your device has \(available). Free up space and try again.")
    }

    /// AVAssetWriter can wrap Cocoa/POSIX disk errors in an AVFoundation error.
    static func isOutOfSpace(_ error: Error?) -> Bool {
        guard let error else { return false }
        var pending = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        while let current = pending.popLast() {
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            if (current.domain == AVFoundationErrorDomain && current.code == AVError.Code.diskFull.rawValue)
                || (current.domain == NSCocoaErrorDomain && current.code == NSFileWriteOutOfSpaceError)
                || (current.domain == NSPOSIXErrorDomain && current.code == Int(POSIXErrorCode.ENOSPC.rawValue)) {
                return true
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
        }
        return false
    }
}
