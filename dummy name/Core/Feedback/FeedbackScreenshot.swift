import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FeedbackScreenshot {
    static func compressedJPEG(from data: Data) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }

        for dimension in [1600, 1280, 1024, 800] {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                return nil
            }

            for quality in [0.88, 0.76, 0.64] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                    return nil
                }
                let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
                CGImageDestinationAddImage(destination, image, properties)
                if CGImageDestinationFinalize(destination), output.length <= FeedbackSubmission.maximumScreenshotBytes {
                    return output as Data
                }
            }
        }
        return nil
    }
}
