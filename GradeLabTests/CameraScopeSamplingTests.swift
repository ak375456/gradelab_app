import AVFoundation
import Metal
import XCTest
@testable import GradeLab

final class CameraScopeSamplingTests: XCTestCase {
    func testHistogramLeavesEmptyBinsBlackAndFillsBelowTheTrace() throws {
        let context = try MetalContext()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 256, height: 128, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
        let output = try XCTUnwrap(context.device.makeTexture(descriptor: descriptor))
        var values = [UInt32](repeating: 0, count: 256 * 3)
        values[64] = 10; values[2 * 256 + 200] = 100
        let bins = try XCTUnwrap(values.withUnsafeBytes {
            context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        var peak: UInt32 = 100
        let maximum = try XCTUnwrap(context.device.makeBuffer(bytes: &peak, length: MemoryLayout<UInt32>.stride, options: .storageModeShared))
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = context.library.makeFunction(name: "scopeVertex")
        pipeline.fragmentFunction = context.library.makeFunction(name: "scopeHistogramFragment")
        pipeline.colorAttachments[0].pixelFormat = .rgba32Float
        let state = try context.device.makeRenderPipelineState(descriptor: pipeline)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var uniforms = ScopeUniforms(width: 256, height: 128, bins: 256, cells: 256, intensity: 1)
        encoder.setRenderPipelineState(state)
        encoder.setFragmentBuffer(bins, offset: 0, index: 0)
        encoder.setFragmentBuffer(maximum, offset: 0, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScopeUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var pixels = [Float](repeating: 0, count: 256 * 128 * 4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 256 * 16,
            from: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0) }
        for y in [8, 64, 120] {
            let empty = (y * 256 + 10) * 4
            XCTAssertEqual(pixels[empty], 0, accuracy: 0.001)
            XCTAssertEqual(pixels[empty + 1], 0, accuracy: 0.001)
            XCTAssertEqual(pixels[empty + 2], 0, accuracy: 0.001)
        }
        XCTAssertLessThan(pixels[(8 * 256 + 64) * 4], 0.001, "Above the red trace stays black")
        XCTAssertGreaterThan(pixels[(120 * 256 + 64) * 4], 0.5, "A populated bin fills from the bottom")
    }

    /// Camera Log scopes must measure the displayed look, rather than mistake
    /// the flat sensor signal for an ordinary Rec.709 frame.
    func testAppleLogHistogramMatchesTheActualPreviewForBothInputTransforms() throws {
        let context = try MetalContext()
        let source = try AppleLogLayerHarness.rawFrame(code: 500)
        CVPixelBufferLockBaseAddress(source, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 1) / 2
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 1)).assumingMemoryBound(to: UInt16.self)
        for y in 0..<CVPixelBufferGetHeightOfPlane(source, 1) {
            for x in 0..<CVPixelBufferGetWidth(source) { chroma[y * stride + x] = (x.isMultiple(of: 2) ? 460 : 570) << 6 }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let textures = try XCTUnwrap(PixelBufferTextures(pixelBuffer: source, context: context))
        for log2 in [false, true] {
            let harness = try AppleLogLayerHarness(context: context, isLog2: log2)
            for exposure: Float in [0, 1] {
                var settings = GradeSettings.neutral
                settings.exposure = exposure
                settings.temperature = 12
                let expected = try harness.direct(source, settings: settings)
                var program = GradeProgram(settings: settings, aspect: 2)
                program.setGrainSeed(0.5)
                let analyzer = try XCTUnwrap(ScopeAnalyzer(context: context, colorSpace: .rec709,
                    colorMode: log2 ? .appleLog2 : .appleLog))
                XCTAssertTrue(analyzer.analyze(textures: textures, pixelBuffer: source, type: .histogram,
                    grade: program.uniforms, locals: program.locals,
                    yuv: YUVUniforms.make(for: source, fallbackMatrix: "BT.709"), hdr: HDRDisplayUniforms(),
                    intensity: 1, lut: try XCTUnwrap(context.luts.texture(for: program.lookIdentifier)),
                    curveLUT: try XCTUnwrap(context.curves.texture(for: program.curveRows)),
                    warpField: try XCTUnwrap(context.warps.texture(for: program.warp)), renderingLUT: harness.renderer.renderingLUT))
                let bins = try XCTUnwrap(analyzer.visualisationBuffers(for: .histogram)?.bins)
                let copy = try XCTUnwrap(context.device.makeBuffer(length: bins.length, options: .storageModeShared))
                let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
                let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                blit.copy(from: bins, sourceOffset: 0, to: copy, destinationOffset: 0, size: bins.length)
                blit.endEncoding()
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                let values = copy.contents().bindMemory(to: UInt32.self, capacity: ScopeAnalyzer.binCount * 3)
                for channel in 0..<3 {
                    let peak = (0..<ScopeAnalyzer.binCount).max { values[channel * 256 + $0] < values[channel * 256 + $1] }!
                    let expectedBin = Int((min(1, max(0, expected[channel])) * 255).rounded())
                    XCTAssertEqual(peak, expectedBin, accuracy: 1, "Log2=\(log2), exposure=\(exposure), channel=\(channel)")
                    XCTAssertGreaterThan(values[channel * 256 + peak], 0)
                }
            }
        }
    }
}
