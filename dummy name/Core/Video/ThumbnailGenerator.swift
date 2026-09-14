@preconcurrency import AVFoundation
import UIKit

struct ThumbnailGenerator: Sendable {
    func makeThumbnail(for url: URL, maximumSize: CGSize = CGSize(width: 720, height: 720)) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        let duration = try await asset.load(.duration)
        let targetSeconds = min(max(duration.seconds * 0.12, 0), 1)
        let result = try await generator.image(at: CMTime(seconds: targetSeconds, preferredTimescale: 600))
        return UIImage(cgImage: result.image)
    }
}
