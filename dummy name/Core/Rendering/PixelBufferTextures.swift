@preconcurrency import CoreVideo
@preconcurrency import Metal

// Immutable references keep the source storage alive until GPU completion.
struct PixelBufferTextures: @unchecked Sendable {
    enum Storage {
        case biPlanar(
            lumaReference: CVMetalTexture,
            luma: MTLTexture,
            chromaReference: CVMetalTexture,
            chroma: MTLTexture
        )
        case bgra(reference: CVMetalTexture, texture: MTLTexture)
        /// Extended-range linear RGBA half-float, as produced by AVFoundation
        /// when asked for a linear transfer function. Already de-matrixed and
        /// transfer-converted, and able to carry values above 1.0 (highlights)
        /// and below 0.0 (colour outside the P3 gamut).
        case linearHalf(reference: CVMetalTexture, texture: MTLTexture)
    }

    let storage: Storage
    private let retainedBuffer: CVPixelBuffer

    init?(pixelBuffer: CVPixelBuffer, context: MetalContext) {
        retainedBuffer = pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let luma = context.texture(from: pixelBuffer, pixelFormat: .r8Unorm, plane: 0),
                  let chroma = context.texture(from: pixelBuffer, pixelFormat: .rg8Unorm, plane: 1) else {
                return nil
            }
            storage = .biPlanar(
                lumaReference: luma.reference,
                luma: luma.texture,
                chromaReference: chroma.reference,
                chroma: chroma.texture
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             // 4:2:2 keeps full chroma height. The plane sizes come from
             // CVPixelBuffer, and the shader samples chroma with normalised
             // coordinates, so no other change is needed for it.
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            guard let luma = context.texture(from: pixelBuffer, pixelFormat: .r16Unorm, plane: 0),
                  let chroma = context.texture(from: pixelBuffer, pixelFormat: .rg16Unorm, plane: 1) else {
                return nil
            }
            storage = .biPlanar(
                lumaReference: luma.reference,
                luma: luma.texture,
                chromaReference: chroma.reference,
                chroma: chroma.texture
            )
        case kCVPixelFormatType_64RGBAHalf:
            guard let packed = context.packedTexture(from: pixelBuffer, pixelFormat: .rgba16Float) else {
                return nil
            }
            storage = .linearHalf(reference: packed.reference, texture: packed.texture)
        case kCVPixelFormatType_32BGRA:
            guard let packed = context.packedTexture(from: pixelBuffer, pixelFormat: .bgra8Unorm) else {
                return nil
            }
            storage = .bgra(reference: packed.reference, texture: packed.texture)
        default:
            return nil
        }
    }
}
