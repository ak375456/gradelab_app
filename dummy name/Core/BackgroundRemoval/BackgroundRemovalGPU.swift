import CoreGraphics
import CoreVideo
import Metal

/// Builds one source-local soft matte, then applies it to processed BGRA. The
/// same matte texture is also consumed directly by the HDR/Apple Log kernels.
final class BackgroundRemovalGPU {
    private let context: MetalContext
    private let yuvPipeline: MTLComputePipelineState
    private let bgraPipeline: MTLComputePipelineState
    private let applyPipeline: MTLComputePipelineState
    private let white: MTLTexture
    private let black: MTLTexture

    init(context: MetalContext, resources: CompositorResources.Bundle) throws {
        self.context = context
        guard let yuv = resources.pipeline("buildBackgroundMaskYUV"),
              let bgra = resources.pipeline("buildBackgroundMaskBGRA"),
              let apply = resources.pipeline("applyBackgroundRemovalBGRA"),
              let white = Self.constantTexture(255, context: context),
              let black = Self.constantTexture(0, context: context) else {
            throw GradeLabError.rendererInitializationFailed
        }
        yuvPipeline = yuv; bgraPipeline = bgra; applyPipeline = apply
        self.white = white; self.black = black
    }

    func makeMatte(
        source: CVPixelBuffer,
        settings authored: BackgroundRemovalSettings,
        automatic: BackgroundMaskPlane?,
        localTime: TimelineTime?,
        frameDuration: TimelineTime?
    ) throws -> MTLTexture {
        let settings = authored.clamped
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let destination = context.device.makeTexture(descriptor: descriptor),
              let sourceTextures = PixelBufferTextures(pixelBuffer: source, context: context),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        let base = automatic.flatMap(texture) ?? white
        let add = correctionTexture(settings.addStrokes, localTime: localTime,
                                    frameDuration: frameDuration, width: width, height: height) ?? black
        let remove = correctionTexture(settings.removeStrokes, localTime: localTime,
                                       frameDuration: frameDuration, width: width, height: height) ?? black
        var uniforms = BackgroundRemovalUniforms(settings)
        switch sourceTextures.storage {
        case .biPlanar(_, let luma, _, let chroma):
            var yuv = YUVUniforms.make(for: source, fallbackMatrix: "BT.709")
            encoder.setComputePipelineState(yuvPipeline)
            encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
            encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        case .bgra(_, let texture), .linearHalf(_, let texture):
            encoder.setComputePipelineState(bgraPipeline)
            encoder.setTexture(texture, index: 0)
        }
        encoder.setTexture(base, index: 2)
        encoder.setTexture(add, index: 3)
        encoder.setTexture(remove, index: 4)
        encoder.setTexture(destination, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 0)
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(sourceTextures) {}
        guard command.status == .completed else { throw GradeLabError.rendererInitializationFailed }
        return destination
    }

    func apply(processed: CVPixelBuffer, matte: MTLTexture,
               settings: BackgroundRemovalSettings, output: CVPixelBuffer) throws {
        guard let source = context.packedTexture(from: processed, pixelFormat: .bgra8Unorm),
              let destination = context.packedTexture(from: output, pixelFormat: .bgra8Unorm),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        var uniforms = BackgroundRemovalUniforms(settings)
        encoder.setComputePipelineState(applyPipeline)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(matte, index: 1)
        encoder.setTexture(destination.texture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<BackgroundRemovalUniforms>.stride, index: 0)
        encoder.dispatchThreads(.init(width: matte.width, height: matte.height, depth: 1),
                                threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(source) {}; withExtendedLifetime(destination) {}
        guard command.status == .completed else { throw GradeLabError.rendererInitializationFailed }
    }

    private func texture(_ plane: BackgroundMaskPlane) -> MTLTexture? {
        guard plane.width > 0, plane.height > 0,
              plane.values.count == plane.width * plane.height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: plane.width, height: plane.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        plane.values.withUnsafeBytes { bytes in
            texture.replace(region: .init(origin: .init(), size: .init(width: plane.width, height: plane.height, depth: 1)),
                            mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: plane.width)
        }
        return texture
    }

    private func correctionTexture(_ strokes: [BackgroundRemovalStroke], localTime: TimelineTime?,
                                   frameDuration: TimelineTime?, width: Int, height: Int) -> MTLTexture? {
        let tolerance = (frameDuration?.seconds ?? 1.0 / 30.0) * 0.75
        let active = strokes.filter { stroke in
            guard let time = stroke.localTime else { return true }
            guard let localTime else { return false }
            return abs(time.seconds - localTime.seconds) <= tolerance
        }
        guard !active.isEmpty else { return nil }
        let longEdge = 1_024.0
        let scale = min(1, longEdge / Double(max(width, height)))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        var pixels = Data(repeating: 0, count: w * h)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let cg = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            cg.setLineCap(.round); cg.setLineJoin(.round)
            for authored in active {
                let stroke = authored.clamped
                guard let first = stroke.points.first else { continue }
                let radius = CGFloat(stroke.radius) * CGFloat(min(w, h))
                // Several concentric passes preserve an editable soft falloff
                // without baking a preview-resolution bitmap into the project.
                for band in stride(from: 0, through: 6, by: 1) {
                    let t = CGFloat(band) / 6
                    let softness = CGFloat(stroke.softness)
                    let line = max(1, radius * 2 * (1 - softness + softness * t))
                    let alpha = CGFloat(stroke.opacity) * (0.10 + 0.15 * t)
                    cg.setStrokeColor(gray: 1, alpha: alpha)
                    cg.setFillColor(gray: 1, alpha: alpha)
                    cg.setLineWidth(line)
                    if stroke.points.count == 1 {
                        cg.fillEllipse(in: CGRect(x: CGFloat(first.x) * CGFloat(w) - line / 2,
                                                  y: CGFloat(1 - first.y) * CGFloat(h) - line / 2,
                                                  width: line, height: line))
                    } else {
                        cg.beginPath(); cg.move(to: CGPoint(x: CGFloat(first.x) * CGFloat(w),
                                                           y: CGFloat(1 - first.y) * CGFloat(h)))
                        for point in stroke.points.dropFirst() {
                            cg.addLine(to: CGPoint(x: CGFloat(point.x) * CGFloat(w),
                                                   y: CGFloat(1 - point.y) * CGFloat(h)))
                        }
                        cg.strokePath()
                    }
                }
            }
            return true
        }
        guard rendered else { return nil }
        return texture(.init(width: w, height: h, values: pixels))
    }

    private static func constantTexture(_ value: UInt8, context: MetalContext) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        var byte = value
        texture.replace(region: .init(origin: .init(), size: .init(width: 1, height: 1, depth: 1)),
                        mipmapLevel: 0, withBytes: &byte, bytesPerRow: 1)
        return texture
    }
}
