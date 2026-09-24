@preconcurrency import Metal
@preconcurrency import CoreVideo
import Foundation

final class MetalContext: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache
    /// Bundled creative looks, shared by every consumer of this context.
    let luts: LUTLibrary
    /// Curve lookup tables, built from control points and shared the same way.
    let curves: CurveLUTLibrary
    /// Color Warper fields, solved from control points and shared the same way.
    let warps: ColorWarpFieldLibrary

    init(library suppliedLibrary: MTLLibrary? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GradeLabError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw GradeLabError.rendererInitializationFailed
        }
        guard let library = suppliedLibrary ?? device.makeDefaultLibrary() else {
            throw GradeLabError.rendererInitializationFailed
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            throw GradeLabError.rendererInitializationFailed
        }

        self.device = device
        self.commandQueue = commandQueue
        self.library = library
        textureCache = cache
        luts = LUTLibrary(device: device)
        curves = CurveLUTLibrary(device: device)
        warps = ColorWarpFieldLibrary(device: device)

        #if DEBUG
        print("Metal device: \(device.name)")
        #endif
    }

    /// Same as `texture(from:pixelFormat:plane:)` but the result may be written
    /// by a compute kernel. Needed for the HDR export path, which composes
    /// directly into the encoder's 10-bit planes rather than through an
    /// intermediate buffer.
    func writableTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        plane: Int
    ) -> (reference: CVMetalTexture, texture: MTLTexture)? {
        texture(from: pixelBuffer, pixelFormat: pixelFormat, plane: plane, writable: true)
    }

    func texture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        plane: Int,
        writable: Bool = false
    ) -> (reference: CVMetalTexture, texture: MTLTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var reference: CVMetalTexture?
        let attributes: CFDictionary? = writable
            ? [kCVMetalTextureUsage: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue] as CFDictionary
            : nil
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            attributes,
            pixelFormat,
            width,
            height,
            plane,
            &reference
        )
        guard status == kCVReturnSuccess,
              let reference,
              let texture = CVMetalTextureGetTexture(reference) else {
            return nil
        }
        return (reference, texture)
    }

    func packedTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat
    ) -> (reference: CVMetalTexture, texture: MTLTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &reference
        )
        guard status == kCVReturnSuccess,
              let reference,
              let texture = CVMetalTextureGetTexture(reference) else {
            return nil
        }
        return (reference, texture)
    }

    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
