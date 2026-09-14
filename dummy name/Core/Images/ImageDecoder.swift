@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Decodes a still into the pixel format the grading pipeline already speaks.
///
/// The output is a `kCVPixelFormatType_32BGRA` `CVPixelBuffer` in the app's
/// Rec.709 working space. That is not a convenience: it is the same storage case
/// `PixelBufferTextures.bgra` the video path already handles, which is why a
/// photograph reaches `applyLookAndGrade`, the finishing-effects stage, the
/// scopes and the eyedropper through the code video uses rather than through a
/// second implementation of any of it.
///
/// Two things are settled here and never revisited downstream:
///
/// - **Orientation.** The EXIF transform is baked in during the decode, so
///   everything after this — the preview geometry, the tiles, the scopes, the
///   exported file — works in one coordinate system and a portrait photograph
///   cannot come out sideways.
/// - **Colour.** CoreGraphics converts from the file's embedded profile into
///   `itur_709`, the space `applyGrade` is written for and the space
///   `LayerCompositor` already puts stills into. An untagged file is treated as
///   sRGB, which is what an untagged file means.
///
/// `UIImage` appears nowhere in the path. It is used for thumbnails elsewhere in
/// the app, but a decode that goes through it would carry an orientation flag
/// instead of applying one, and would give the renderer no buffer to hold.
/// A decoded picture on its way across an isolation boundary.
///
/// `CVPixelBuffer` is a Core Video reference type that is deliberately not
/// `Sendable`: two threads writing one buffer is a real hazard. Here exactly one
/// decode produces the buffer, hands it over, and never touches it again, which
/// is the same promise `PixelBufferTextures` makes for the same reason.
struct DecodedStill: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

enum ImageDecoder {
    /// The one working space. Everything the app grades is in it.
    static let workingColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    /// How large the on-screen preview is decoded.
    ///
    /// A 48 MP photograph is not re-decoded when a slider moves — it is decoded
    /// once, at a size the display can actually resolve, and every subsequent
    /// edit is a change of uniforms on a texture that is already resident. The
    /// export is the only thing that ever touches full resolution.
    /// Asks ImageIO for the SDR picture, explicitly.
    ///
    /// A photograph with a gain map contains an ordinary SDR image plus the map,
    /// and that SDR image is what this app grades. ImageIO returns it by default
    /// today, but "by default" is not something to build a colour pipeline on:
    /// if a future release decided to compose the gain map in, the preview and
    /// the export would quietly change and the grade would be applied to a
    /// picture nobody asked for. Saying so outright costs one key.
    private static let sdrDecodeOptions: [CFString: Any] = [
        kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
    ]

    /// The device's own long edge in pixels, or a sensible stand-in when there
    /// is no screen — the host validation harness runs this file outside an app.
    static var screenLongEdge: CGFloat {
        #if canImport(UIKit)
        let bounds = UIScreen.main.nativeBounds
        return max(bounds.width, bounds.height)
        #else
        return 1200
        #endif
    }

    static func previewLongEdge(screenLongEdge: CGFloat = ImageDecoder.screenLongEdge) -> Int {
        // Twice the long edge of the panel: enough to stay sharp when the
        // preview is pinched in, without paying for pixels nothing can show.
        min(3000, max(1600, Int(screenLongEdge * 2)))
    }

    /// Decodes `url`, optionally limited to `maximumLongEdge` pixels.
    ///
    /// - Parameter maximumLongEdge: nil decodes at the file's full resolution.
    ///   Any value smaller than the image asks ImageIO to downsample **during**
    ///   the decode, so a 48 MP file never becomes a 48 MP bitmap on the way to a
    ///   2,400-pixel preview.
    /// Decodes off the main thread. The decode of a 48 MP file is hundreds of
    /// milliseconds of CPU work and must never happen on the thread drawing the
    /// interface.
    static func decodeDetached(url: URL, maximumLongEdge: Int?) async throws -> DecodedStill {
        try await Task.detached(priority: .userInitiated) {
            DecodedStill(buffer: try decode(url: url, maximumLongEdge: maximumLongEdge))
        }.value
    }

    static func decode(url: URL, maximumLongEdge: Int?) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw GradeLabError.unableToReadImage
        }
        let metadata = try ImageMetadataReader.read(source: source, url: url)
        return try decode(source: source, metadata: metadata, maximumLongEdge: maximumLongEdge)
    }

    static func decode(
        source: CGImageSource,
        metadata: ImageMetadata,
        maximumLongEdge: Int?
    ) throws -> CVPixelBuffer {
        let decoded = try decodeCGImage(source: source, metadata: metadata,
                                        maximumLongEdge: maximumLongEdge)
        // The downsampling decode applies the EXIF transform itself; the
        // full-resolution one does not, so it is applied while drawing.
        return try buffer(from: decoded.image,
                          orientation: decoded.isUpright ? 1 : metadata.orientation)
    }

    /// The decoded picture, upright, at or below `maximumLongEdge`.
    static func decodeCGImage(
        source: CGImageSource,
        metadata: ImageMetadata,
        maximumLongEdge: Int?
    ) throws -> (image: CGImage, isUpright: Bool) {
        let longest = max(metadata.displayWidth, metadata.displayHeight)
        if let maximumLongEdge, maximumLongEdge < longest {
            // `kCGImageSourceCreateThumbnailWithTransform` applies the EXIF
            // orientation for us, and the downsample happens inside the decoder
            // rather than after it.
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumLongEdge
            ]
            options.merge(sdrDecodeOptions) { current, _ in current }
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (thumbnail, true)
            }
        }
        var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        options.merge(sdrDecodeOptions) { current, _ in current }
        guard let full = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw GradeLabError.unableToReadImage
        }
        return (full, false)
    }

    /// Draws `image` into a Rec.709 BGRA pixel buffer, applying the EXIF
    /// orientation if the decode has not already done it.
    ///
    /// The orientation is applied by drawing rather than by tagging: a tag would
    /// have to be respected by the renderer, the tile arithmetic, the scopes and
    /// the encoder, and one of them would eventually forget.
    private static func buffer(from image: CGImage, orientation: Int = 1) throws -> CVPixelBuffer {
        let sideways = (5...8).contains(orientation)
        let width = sideways ? image.height : image.width
        let height = sideways ? image.width : image.height
        guard width > 0, height > 0 else { throw GradeLabError.unableToReadImage }

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw GradeLabError.imageTooLarge
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: workingColorSpace,
                // Opaque: this app grades photographs, it does not composite
                // them, so transparency is resolved against black once, here,
                // rather than carried through every stage to no purpose.
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw GradeLabError.rendererInitializationFailed
        }
        context.interpolationQuality = .high
        context.concatenate(orientationTransform(orientation, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The buffer is tagged with the space it was drawn in, so anything that
        // reads it later — the compositor, a thumbnail — is told the truth.
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    /// Maps the EXIF orientation onto the drawing transform. Identity for 1,
    /// which is the case that matters most: it must cost nothing.
    ///
    /// The signs here are easy to get backwards, because two coordinate systems
    /// disagree: a bitmap context's own coordinates run bottom-up, while the
    /// buffer's first row is the picture's top and EXIF describes the picture
    /// top-down. A transform that reads plausibly can still be a 180° rotation
    /// of the right answer — which is exactly what turns a portrait photograph
    /// upside down on export while leaving landscape ones looking fine.
    ///
    /// So each row is derived rather than recalled, from what EXIF actually
    /// says: which visual edge the stored image's first row and first column lie
    /// along. Orientation 6 — the one an iPhone writes for a portrait photograph
    /// — puts the first row on the right and the first column on the top.
    /// `Scripts/ValidateStillImage.swift` checks all eight against that
    /// definition.
    static func orientationTransform(_ orientation: Int, width: Int, height: Int) -> CGAffineTransform {
        // `width`/`height` are the DESTINATION's, so they are already exchanged
        // for the sideways orientations.
        let w = CGFloat(width), h = CGFloat(height)
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)   // mirrored
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)  // 180°
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)   // flipped
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h)  // transpose
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)   // 90° CW
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)    // transverse
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)   // 90° CCW
        default: return .identity
        }
    }

    /// A small upright thumbnail, for project cards.
    static func thumbnail(url: URL, maximumPixelSize: Int = 512) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary)
    }
}
