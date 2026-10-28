import Metal
import XCTest
@testable import GradeLab

final class CameraPeakingTests: XCTestCase {
    func testPeakingMarksSharpEdgesButLeavesFlatAndSoftAreasUntouched() throws {
        let fixture = try PeakingFixture()
        let original = try fixture.render(peaking: false)
        let peaked = try fixture.render(peaking: true)
        func difference(x: Int, y: Int) -> Float {
            let i = (y * 64 + x) * 4
            return (0..<3).map { abs(peaked[i + $0] - original[i + $0]) }.max() ?? 0
        }
        XCTAssertGreaterThan((28...35).map { difference(x: $0, y: 8) }.max() ?? 0, 0.2)
        for x in 4...59 {
            XCTAssertLessThan(difference(x: x, y: 24), 0.001, "A soft linear transition must not look sharp")
        }
        XCTAssertLessThan(difference(x: 4, y: 8), 0.001, "Flat areas must stay unchanged")
    }

    func testPeakingNeverChangesTheSharedGradingOutput() throws {
        let fixture = try PeakingFixture()
        let original = try fixture.render(peaking: false, compute: true)
        let peaked = try fixture.render(peaking: true, compute: true)
        XCTAssertEqual(original, peaked, "The render-to-texture path used for exports must ignore monitoring uniforms")
    }
}

private final class PeakingFixture {
    let context: MetalContext
    let source: MTLTexture

    init() throws {
        context = try MetalContext()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 64, height: 32, mipmapped: false)
        d.storageMode = .shared; d.usage = .shaderRead
        source = try XCTUnwrap(context.device.makeTexture(descriptor: d))
        var pixels = [Float](repeating: 1, count: 64 * 32 * 4)
        for y in 0..<32 { for x in 0..<64 {
            let value: Float = y < 16 ? (x < 32 ? 0.2 : 0.8) : 0.2 + Float(x) / 63 * 0.6
            for c in 0..<3 { pixels[(y * 64 + x) * 4 + c] = value }
        } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64 * 16) }
    }

    func render(peaking: Bool, compute: Bool = false) throws -> [Float] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 64, height: 32, mipmapped: false)
        d.storageMode = .shared; d.usage = [.renderTarget, .shaderWrite]
        let destination = try XCTUnwrap(context.device.makeTexture(descriptor: d))
        let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        var program = GradeProgram(settings: .neutral, aspect: 2)
        program.setGrainSeed(0.5)
        var grade = program.uniforms
        var assist = ViewerAssistSettings(); assist.focusPeaking = peaking
        grade.viewerAssist = assist.uniform
        if compute {
            let function = try XCTUnwrap(context.library.makeFunction(name: "gradeToTextureBGRA"))
            let state = try context.device.makeComputePipelineState(function: function)
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(state)
            encoder.setTexture(source, index: 0); encoder.setTexture(destination, index: 2)
            encoder.setTexture(context.luts.texture(for: program.lookIdentifier), index: 3)
            encoder.setTexture(context.curves.texture(for: program.curveRows), index: 6)
            encoder.setTexture(context.warps.texture(for: program.warp), index: 12)
            encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            program.locals.bind(encoder)
            encoder.dispatchThreads(MTLSize(width: 64, height: 32, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        } else {
            let pipeline = MTLRenderPipelineDescriptor()
            pipeline.vertexFunction = context.library.makeFunction(name: "videoVertex")
            pipeline.fragmentFunction = context.library.makeFunction(name: "gradeFragmentBGRA")
            pipeline.colorAttachments[0].pixelFormat = .rgba32Float
            let state = try context.device.makeRenderPipelineState(descriptor: pipeline)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            var vertices: [SIMD4<Float>] = [.init(-1, -1, 0, 1), .init(1, -1, 1, 1), .init(-1, 1, 0, 0), .init(1, 1, 1, 0)]
            encoder.setRenderPipelineState(state)
            encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(context.luts.texture(for: program.lookIdentifier), index: 3)
            encoder.setFragmentTexture(context.curves.texture(for: program.curveRows), index: 6)
            encoder.setFragmentTexture(context.warps.texture(for: program.warp), index: 12)
            encoder.setFragmentBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            program.locals.bindFragment(encoder)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        XCTAssertEqual(command.status, .completed)
        var pixels = [Float](repeating: 0, count: 64 * 32 * 4)
        pixels.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: 64 * 16, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0) }
        return pixels
    }
}
