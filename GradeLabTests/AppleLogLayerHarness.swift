import AVFoundation
import Metal
import Foundation
#if !APPLE_LOG_VALIDATOR
@testable import GradeLab
#endif

/// Shared by XCTest and the host validator, so tiled and direct checks exercise
/// the production layer encoder rather than another implementation of it.
final class AppleLogLayerHarness {
    let context: MetalContext
    let renderer: AppleLogLayerRenderer
    /// Which Log format this harness decodes. Apple Log 2 differs from Apple Log
    /// by the input transform only, so the same harness exercises both and any
    /// difference in the result is the gamut matrix and nothing else.
    let isLog2: Bool
    init(context: MetalContext, isLog2: Bool = false) throws {
        self.context = context
        self.isLog2 = isLog2
        renderer = try AppleLogLayerRenderer(context: context, isLog2: isLog2)
    }
    func texture(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        return context.device.makeTexture(descriptor: d)!
    }
    func pixels(_ texture: MTLTexture) -> [Float] {
        let count = texture.width * texture.height * 4
        if texture.pixelFormat == .rgba16Float {
            var values = [Float16](repeating: 0, count: count)
            values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
            return values.map(Float.init)
        }
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 16,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        return values
    }
    static func rawFrame(width: Int = 64, height: Int = 32, code: UInt16? = nil) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw GradeLabError.rendererInitializationFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
            for y in 0..<height {
                for x in 0..<width {
                    let ramp = UInt16(154 + x * 691 / max(width - 1, 1) + y % 7)
                    let luma: UInt16 = code ?? ramp
                    let value: UInt16 = plane == 0 ? luma : 512
                    base[y * stride + x] = value << 6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    func render(_ source: CVPixelBuffer, settings: GradeSettings = .neutral, tile: Int? = nil,
                opacity: Double = 1, transform: CGAffineTransform = .identity,
                mask authoredMask: LayerMask? = nil, sourceIsSDR: Bool = false,
                partner: CVPixelBuffer? = nil, blendAmount: Double = 0, canvasSize: CGSize? = nil) throws -> (working: [Float], display: [Float]) {
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        let size = canvasSize ?? sourceSize
        let width = Int(size.width), height = Int(size.height)
        let working = texture(.rgba16Float, width: width, height: height)
        let base = texture(.rgba16Float, width: width, height: height)
        let canvas = texture(.rgba16Float, width: width, height: height)
        let display = texture(.rgba32Float, width: width, height: height)
        let sourceTextures = PixelBufferTextures(pixelBuffer: source, context: context)!
        let partnerTextures = PixelBufferTextures(pixelBuffer: partner ?? source, context: context)!
        guard case .biPlanar(_, let y, _, let c) = sourceTextures.storage,
              case .biPlanar(_, let py, _, let pc) = partnerTextures.storage else { fatalError("Expected raw planes") }
        let command = context.commandQueue.makeCommandBuffer()!
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = base
        clear.colorAttachments[0].loadAction = .clear; clear.colorAttachments[0].storeAction = .store
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        command.makeRenderCommandEncoder(descriptor: clear)!.endEncoding()
        var program = GradeProgram(settings: settings, aspect: sourceSize.maskAspect)
        program.setGrainSeed(0.5)
        var grade = program.uniforms
        var yuv = YUVUniforms.make(for: source, fallbackMatrix: "BT.709")
        var layer = HDRLayerUniforms(transform: transform, sourceSize: sourceSize, canvasSize: size, opacity: opacity,
            blendAmount: blendAmount, sourceIsSDR: sourceIsSDR)
        var mask = LayerMaskUniforms(authoredMask)
        try renderer.encode(AppleLogSpecialization.key("compositeVideoAppleLog", isLog2: isLog2),
                            into: command, width: width, height: height, tileSize: tile) { enc in
            enc.setTexture(y, index: 0); enc.setTexture(c, index: 1); enc.setTexture(working, index: 2)
            enc.setTexture(context.luts.texture(for: program.lookIdentifier), index: 3)
            enc.setTexture(py, index: 4); enc.setTexture(pc, index: 5)
            enc.setTexture(context.curves.texture(for: program.curveRows), index: 6)
            enc.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            enc.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
            enc.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
            enc.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
            program.locals.bind(enc)
        }
        var mode: UInt32 = 0
        try renderer.encode("blendAppleLogLayer", into: command, width: width, height: height, tileSize: tile) { enc in
            enc.setTexture(working, index: 0); enc.setTexture(base, index: 1); enc.setTexture(canvas, index: 2)
            enc.setBytes(&mode, length: MemoryLayout<UInt32>.stride, index: 0)
        }
        try renderer.encode("resolveAppleLogCanvas", into: command, width: width, height: height, tileSize: tile) { enc in
            enc.setTexture(canvas, index: 0); enc.setTexture(display, index: 1)
            enc.setTexture(renderer.renderingLUT, index: 4)
        }
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime((sourceTextures, partnerTextures)) {}
        if let error = command.error { throw error }
        return (pixels(canvas), pixels(display))
    }
    /// Runs the actual direct-preview fragment, including its raster sampling.
    func direct(_ source: CVPixelBuffer, settings: GradeSettings = .neutral) throws -> [Float] {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let output = texture(.rgba32Float, width: width, height: height)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = context.library.makeFunction(name: "videoVertex")
        d.fragmentFunction = AppleLogSpecialization.makeFunction(
            "previewFragmentAppleLog", isLog2: isLog2, library: context.library)
        d.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try context.device.makeRenderPipelineState(descriptor: d)
        let textures = PixelBufferTextures(pixelBuffer: source, context: context)!
        guard case .biPlanar(_, let y, _, let c) = textures.storage else { fatalError("Expected raw planes") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        let command = context.commandQueue.makeCommandBuffer()!
        let enc = command.makeRenderCommandEncoder(descriptor: pass)!
        var vertices: [SIMD4<Float>] = [SIMD4(-1, -1, 0, 1), SIMD4(1, -1, 1, 1), SIMD4(-1, 1, 0, 0), SIMD4(1, 1, 1, 0)]
        var program = GradeProgram(settings: settings, aspect: Double(width) / Double(height))
        program.setGrainSeed(0.5)
        var grade = program.uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setFragmentTexture(y, index: 0); enc.setFragmentTexture(c, index: 1)
        enc.setFragmentTexture(context.luts.texture(for: program.lookIdentifier), index: 3)
        enc.setFragmentTexture(renderer.renderingLUT, index: 4)
        enc.setFragmentTexture(context.curves.texture(for: program.curveRows), index: 6)
        enc.setFragmentBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 1)
        program.locals.bindFragment(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(textures) {}
        if let error = command.error { throw error }
        return pixels(output)
    }
    static func worst(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }
}
