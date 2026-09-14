@preconcurrency import AVFoundation
import Combine
import UIKit

@MainActor
final class FilmstripStore: ObservableObject {
    @Published private(set) var frames: [UIImage] = []
    @Published private(set) var unavailable = false
    private static let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    func load(url: URL, range: TimelineRange) async {
        frames = []; unavailable = false
        let key = "\(url.absoluteString)|\(range.start.value)/\(range.start.timescale)|\(range.duration.value)/\(range.duration.timescale)" as NSString
        if let cached = Self.cache.object(forKey: key) as? [UIImage] { frames = cached; return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 108)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        // Bounded sampling across the entire source, not one full-sized image/frame.
        let count = Int(max(1, min(32, ceil(range.duration.seconds / 2))))
        var images: [UIImage] = []
        for index in 0..<count {
            guard !Task.isCancelled else { generator.cancelAllCGImageGeneration(); return }
            let seconds = range.start.seconds + range.duration.seconds * (Double(index) + 0.5) / Double(count)
            do {
                let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: TimelineTime.projectTimescale))
                guard !Task.isCancelled else { return }
                images.append(UIImage(cgImage: result.image))
            } catch {
                guard !Task.isCancelled else { return }
                // Do not shift timestamp-to-thumbnail indexing by dropping a sample.
                unavailable = true
                return
            }
        }
        Self.cache.setObject(images as NSArray, forKey: key, cost: images.reduce(0) { $0 + ($1.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) })
        frames = images
    }
}
