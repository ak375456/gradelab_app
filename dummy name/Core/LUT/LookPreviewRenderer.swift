@preconcurrency import Metal
import CoreGraphics
import UIKit

/// Renders "what this look does to this frame" thumbnails for the look picker.
///
/// It reuses the shipping `gradeStillBGRA` kernel rather than reimplementing the
/// transform, so a thumbnail cannot drift from what the preview and the export
/// actually produce — if they ever disagreed, the picker would be lying.
///
/// Every look is rendered with an otherwise neutral grade, so the strip compares
/// looks against each other rather than against the clip's current adjustments.
/// That also keeps the thumbnails still while the sliders move, instead of
/// re-rendering the whole strip on every slider tick.
final class LookPreviewRenderer: @unchecked Sendable {
    private let context: MetalContext
    private let pipeline: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        guard let function = context.library.makeFunction(name: "gradeStillBGRA") else {
            throw GradeLabError.rendererInitializationFailed
        }
        self.pipeline = try context.device.makeComputePipelineState(function: function)
    }

    /// Applies one look to `source`. Returns nil rather than throwing so a single
    /// broken LUT costs one thumbnail, not the whole strip.
    func render(look: LUTAsset?, source: MTLTexture) -> UIImage? {
        guard let look else { return image(from: source) }
        guard context.luts.prepare(look), let lut = context.luts.texture(for: look.id) else {
            return nil
        }

        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.lut = look.id
        advanced.lutIntensity = 100
        settings.advanced = advanced
        return render(settings: settings, lut: lut, source: source, label: "Look preview \(look.name)")
    }

    /// Applies a whole grade to `source`, for a grade preset's thumbnail.
    ///
    /// Same kernel as the picker and the preview, so what the tile shows is what
    /// the preset does: light, colour, every curve, HSL, wheels, vignette, the
    /// look at its stored strength, plus the per-pixel finishing effects (fade
    /// and grain). The four spatial effects — sharpen, bloom, glow, halation —
    /// live in a separate post-grade pass over the full frame and are not run
    /// here; they are stored and applied on the clip exactly as saved, they just
    /// do not show in a 400px tile.
    func render(settings: GradeSettings, source: MTLTexture) -> UIImage? {
        let advanced = settings.advanced ?? .neutral
        var lut = context.luts.texture(for: nil)
        if let identifier = advanced.lut, context.luts.prepare(identifier) {
            lut = context.luts.texture(for: identifier)
        }
        guard let lut else { return nil }
        return render(settings: settings, lut: lut, source: source, label: "Preset thumbnail")
    }

    private func render(
        settings: GradeSettings,
        lut: MTLTexture,
        source: MTLTexture,
        label: String
    ) -> UIImage? {
        var uniforms = GradeUniforms(settings: settings, bypass: false)
        let curves = settings.advanced.map { context.curves.texture(for: $0.resolvedCurves) }
            ?? context.curves.texture(for: nil)
        let warps = context.warps.texture(for: settings.advanced?.resolvedColorWarp)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        #if os(iOS)
        descriptor.storageMode = .shared
        #endif
        guard let output = context.device.makeTexture(descriptor: descriptor),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.label = label
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 2)
        encoder.setTexture(lut, index: 3)
        encoder.setTexture(curves, index: 6)
        encoder.setTexture(warps, index: 12)
        encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        // A look tile shows the look itself, not a clip's local grades, so the
        // stack is bound empty rather than left unpopulated.
        LocalGradeStack.empty.bind(encoder)
        encoder.dispatchThreads(
            MTLSize(width: source.width, height: source.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        return image(from: output)
    }

    /// Uploads a thumbnail-sized frame once, so every look in the strip renders
    /// from the same texture.
    func makeSourceTexture(from image: UIImage, maximumEdge: Int = 240) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = min(
            1,
            CGFloat(maximumEdge) / CGFloat(max(cgImage.width, cgImage.height))
        )
        let width = max(1, Int((CGFloat(cgImage.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(cgImage.height) * scale).rounded()))

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        #if os(iOS)
        descriptor.storageMode = .shared
        #endif
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    private func image(from texture: MTLTexture) -> UIImage? {
        let width = texture.width
        let height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Drawn when a frame cannot be read from the clip, so the strip still shows
/// something a person can judge a look by: a tonal ramp plus the colours looks
/// most often go wrong on — skin, sky and foliage.
enum LookReferenceImage {
    static func make(size: CGSize = CGSize(width: 180, height: 240)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { rendererContext in
            let context = rendererContext.cgContext
            let rampHeight = size.height * 0.45
            let steps = 24
            for step in 0..<steps {
                let value = CGFloat(step) / CGFloat(steps - 1)
                context.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                context.fill(CGRect(
                    x: size.width * CGFloat(step) / CGFloat(steps),
                    y: 0,
                    width: size.width / CGFloat(steps) + 1,
                    height: rampHeight
                ))
            }
            let patches: [UIColor] = [
                UIColor(red: 0.76, green: 0.57, blue: 0.47, alpha: 1),  // skin
                UIColor(red: 0.36, green: 0.55, blue: 0.80, alpha: 1),  // sky
                UIColor(red: 0.28, green: 0.45, blue: 0.20, alpha: 1)   // foliage
            ]
            let patchHeight = (size.height - rampHeight) / CGFloat(patches.count)
            for (index, color) in patches.enumerated() {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(
                    x: 0,
                    y: rampHeight + patchHeight * CGFloat(index),
                    width: size.width,
                    height: patchHeight + 1
                ))
            }
        }
    }
}
