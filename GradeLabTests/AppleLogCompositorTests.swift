import AVFoundation
import Metal
import XCTest
@testable import GradeLab

final class AppleLogCompositorTests: XCTestCase {
    private var harness: AppleLogLayerHarness!
    override func setUpWithError() throws {
        harness = try AppleLogLayerHarness(context: MetalContext())
    }

    func testAnUngradedLayerMatchesTheDirectAppleLogFragment() throws {
        let source = try AppleLogLayerHarness.rawFrame()
        let layers = try harness.render(source)
        let direct = try harness.direct(source)
        XCTAssertLessThan(AppleLogLayerHarness.worst(layers.display, direct), 0.002)
    }

    func testAGradedLayerMatchesTheSameGradeThroughDirectPreview() throws {
        let source = try AppleLogLayerHarness.rawFrame()
        var grade = GradeSettings.neutral
        grade.exposure = -1.3; grade.temperature = 18; grade.saturation = 85
        XCTAssertLessThan(AppleLogLayerHarness.worst(try harness.render(source, settings: grade).display,
                                                    try harness.direct(source, settings: grade)), 0.002)
    }

    func testWholeAndTiledRenderingAgreeForAGradedTransformedMaskedLayer() throws {
        let source = try AppleLogLayerHarness.rawFrame()
        var grade = GradeSettings.neutral; grade.exposure = -0.7
        var mask = LayerMask(); mask.isEnabled = true; mask.feather = 0.2
        let transform = CGAffineTransform(scaleX: 0.7, y: 0.7).translatedBy(x: 10, y: 5)
        let whole = try harness.render(source, settings: grade, opacity: 0.65, transform: transform, mask: mask)
        let tiled = try harness.render(source, settings: grade, tile: 13, opacity: 0.65, transform: transform, mask: mask)
        XCTAssertEqual(whole.working, tiled.working)
        XCTAssertEqual(whole.display, tiled.display)
        XCTAssertEqual(whole.working[0], 0)
    }

    func testTheWhitePaperCodesDecodeToSceneLightBeforeCompositing() throws {
        for point in AppleLog.referencePoints {
            let source = try AppleLogLayerHarness.rawFrame(code: UInt16(point.code10Bit))
            let values = try harness.render(source).working
            // Neutral chroma in 10-bit storage is 512. The production input
            // matrix uses the same full-range normalisation as direct preview.
            let rgb = AppleLog.rgb(fromYCbCr: SIMD3(Float(point.code10Bit) / 1023,
                                                   512.0 / 1023 - 0.5, 512.0 / 1023 - 0.5))
            for channel in 0..<3 {
                XCTAssertEqual(values[channel], AppleLog.toWorkingSpace(rgb[channel]), accuracy: 0.015)
            }
            XCTAssertEqual(Int((AppleLog.encode(point.reflectance) * 1023).rounded()), point.code10Bit)
        }
    }

    func testHighlightLatitudeSurvivesOpacityAndFrameBlending() throws {
        let source = try AppleLogLayerHarness.rawFrame(code: 1023)
        let partner = try AppleLogLayerHarness.rawFrame(code: 697)
        let full = try harness.render(source).working[0]
        let next = try harness.render(partner).working[0]
        let blended = try harness.render(source, opacity: 0.5, partner: partner, blendAmount: 0.25).working[0]
        XCTAssertGreaterThan(blended, 1)
        XCTAssertEqual(blended, (full * 0.75 + next * 0.25) * 0.5, accuracy: 0.01)
    }

    func testRec709VideoWhiteEntersTheWorkingSpaceAsDiffuseWhite() throws {
        let source = try AppleLogLayerHarness.rawFrame(code: 1023)
        let working = try harness.render(source, sourceIsSDR: true).working
        for channel in 0..<3 { XCTAssertEqual(working[channel], 1, accuracy: 0.002) }
    }

    func testAllBlendModesAndTransitionsRenderTheSameInTiles() throws {
        let first = harness.texture(.rgba16Float, width: 64, height: 32)
        let second = harness.texture(.rgba16Float, width: 64, height: 32)
        var values = (0..<(64 * 32)).flatMap { i -> [Float16] in
            [Float16(Float(i % 64) / 16), Float16(1.7), Float16(0.2), Float16(1)]
        }
        values.withUnsafeBytes { first.replace(region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0,
                                               withBytes: $0.baseAddress!, bytesPerRow: 64 * 8) }
        values = (0..<(64 * 32)).flatMap { _ in [Float16(0.4), Float16(0.2), Float16(1.2), Float16(1)] }
        values.withUnsafeBytes { second.replace(region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: 64 * 8) }
        func render(_ mode: UInt32, transition: Bool, tile: Int?) throws -> [Float] {
            let output = harness.texture(.rgba16Float, width: 64, height: 32)
            let command = harness.context.commandQueue.makeCommandBuffer()!
            var index = mode
            // TransitionUniforms consists of UInt32 plus three Float scalars.
            var transitionBytes = SIMD4<UInt32>(mode, Float(0.37).bitPattern, Float(2).bitPattern, 0)
            try harness.renderer.encode(transition ? "compositeTransitionAppleLog" : "blendAppleLogLayer",
                                        into: command, width: 64, height: 32, tileSize: tile) { enc in
                enc.setTexture(first, index: 0); enc.setTexture(second, index: 1); enc.setTexture(output, index: 2)
                if transition {
                    enc.setBytes(&transitionBytes, length: 16, index: 0)
                } else {
                    enc.setBytes(&index, length: 4, index: 0)
                }
            }
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            return harness.pixels(output)
        }
        for mode in VisualBlendMode.allCases {
            let index = AppleLogLayerRenderer.blendIndex(mode)
            let whole = try render(index, transition: false, tile: nil)
            XCTAssertEqual(whole, try render(index, transition: false, tile: 13))
            XCTAssertTrue(whole.allSatisfy(\.isFinite))
        }
        for index in UInt32(0)...44 {
            let whole = try render(index, transition: true, tile: nil)
            XCTAssertEqual(whole, try render(index, transition: true, tile: 13))
            XCTAssertTrue(whole.allSatisfy(\.isFinite))
        }
    }

    func testPremultipliedSDRArtworkKeepsItsCoverageThroughTransformsAndMasks() throws {
        let source = harness.texture(.rgba16Float, width: 32, height: 32)
        let values = [Float16](repeating: 0.5, count: 32 * 32 * 4)
        values.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: 32 * 8) }
        let output = harness.texture(.rgba16Float, width: 32, height: 32)
        let command = harness.context.commandQueue.makeCommandBuffer()!
        let size = CGSize(width: 32, height: 32)
        var placement = VisualTransform(); placement.scale = 0.5
        var layer = HDRLayerUniforms(transform: LayerCompositor.transform(placement, encoded: size,
            preferred: .identity, canvas: size), sourceSize: size, canvasSize: size,
            opacity: 0.5, sourceIsSDR: true, premultiplied: true)
        var authoredMask = LayerMask(); authoredMask.isEnabled = true
        var mask = LayerMaskUniforms(authoredMask)
        var program = GradeProgram(settings: .neutral)
        try harness.renderer.encode("compositeImageAppleLog", into: command, width: 32, height: 32, tileSize: 13) { enc in
            enc.setTexture(source, index: 0); enc.setTexture(output, index: 2)
            enc.setTexture(harness.context.luts.texture(for: nil), index: 3)
            enc.setTexture(harness.context.curves.texture(for: nil), index: 6)
            enc.setBytes(&program.uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            enc.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
            enc.setBytes(&mask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
            program.locals.bind(enc)
        }
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let pixels = harness.pixels(output)
        for channel in 0..<4 {
            XCTAssertEqual(pixels[(16 * 32 + 16) * 4 + channel], 0.25, accuracy: 0.001)
            XCTAssertEqual(pixels[channel], 0)
        }
    }

    func testExportResolveWritesTenBitRec709WithoutAnEightBitIntermediate() throws {
        let width = 32, height = 16
        let canvas = harness.texture(.rgba16Float, width: width, height: height)
        let values = (0..<(width * height)).flatMap { index -> [Float16] in
            let value = Float16(Float(index % width) / 8)
            return [value, value, value, 1]
        }
        values.withUnsafeBytes { canvas.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let rgb = harness.texture(.rgba32Float, width: width, height: height)
        let y = harness.texture(.r16Unorm, width: width, height: height)
        let c = harness.texture(.rg16Unorm, width: width / 2, height: height)
        let command = harness.context.commandQueue.makeCommandBuffer()!
        try harness.renderer.encode("resolveAppleLogCanvas", into: command, width: width, height: height) { enc in
            enc.setTexture(canvas, index: 0); enc.setTexture(rgb, index: 1)
            enc.setTexture(harness.renderer.renderingLUT, index: 4)
        }
        try harness.renderer.encode("resolveAppleLogCanvas422", into: command, width: width / 2, height: height, tileSize: 7) { enc in
            enc.setTexture(canvas, index: 0); enc.setTexture(y, index: 1); enc.setTexture(c, index: 2)
            enc.setTexture(harness.renderer.renderingLUT, index: 4)
        }
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let display = harness.pixels(rgb)
        var codes = [UInt16](repeating: 0, count: width * height)
        codes.withUnsafeMutableBytes { y.getBytes($0.baseAddress!, bytesPerRow: width * 2,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        for index in 0..<(width * height) {
            let luma = display[index * 4] * 0.2126 + display[index * 4 + 1] * 0.7152 + display[index * 4 + 2] * 0.0722
            XCTAssertEqual(Float(codes[index] >> 6), (64 + luma * 876).rounded(), accuracy: 1)
            XCTAssertEqual(codes[index] & 63, 0)
        }
    }

    func testAppleLogRequestsRawInputsAndSeparatePreviewAndExportSurfaces() {
        let preview = AppleLogLayerCompositor()
        let export = AppleLogExportLayerCompositor()
        XCTAssertTrue(preview.supportsWideColorSourceFrames)
        XCTAssertTrue(preview.supportsHDRSourceFrames)
        XCTAssertTrue(preview.canConformColorOfSourceFrames)
        XCTAssertEqual(preview.sourcePixelBufferAttributes?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
                       kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
        XCTAssertEqual(preview.requiredPixelBufferAttributesForRenderContext[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
                       kCVPixelFormatType_32BGRA)
        XCTAssertEqual(export.requiredPixelBufferAttributesForRenderContext[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
                       kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    }

    func testAMistaggedProjectCannotGainALogTransformByAddingLayers() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("retime_test.mov")
        let source = try await VideoMetadataReader().read(from: url)
        var project = VideoProject(sourceURL: url, displayName: "Not Log", metadata: source.metadata,
                                   sourceRange: source.sourceRange, frameDuration: source.frameDuration)
        project.colorMode = .appleLog
        do {
            _ = try await SequenceComposition.buildLayers(project: project, forExport: true)
            XCTFail("Unidentified footage must not take the Log transform")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no supported Apple Log profile"))
        }
    }
}
