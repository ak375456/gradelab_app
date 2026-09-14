import AVFoundation
import CoreMedia
import Metal
import XCTest
@testable import GradeLab

/// Numeric checks on the HDR compositing kernels themselves.
///
/// The HDR compositor cannot be exercised end to end on a simulator — it cannot
/// decode HEVC Main 10 — so these drive the real shaders directly with textures
/// holding known HLG signal values. That covers the parts that can be wrong
/// silently: the working-space round trip, where frame blending happens, how an
/// SDR layer is referenced, and where a transform puts a layer.
///
/// The reference numbers come from BT.2100's HLG OETF and its inverse, computed
/// here in Swift rather than read back out of the shader, so the shader is
/// checked against the specification and not against itself.
final class HDRCompositorTests: XCTestCase {
    private var context: MetalContext!
    private var videoPipeline: MTLComputePipelineState!
    private var imagePipeline: MTLComputePipelineState!
    private var resolvePipeline: MTLComputePipelineState!

    override func setUpWithError() throws {
        try super.setUpWithError()
        context = try MetalContext()
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            let function = try XCTUnwrap(context.library.makeFunction(name: name), "missing kernel \(name)")
            return try context.device.makeComputePipelineState(function: function)
        }
        videoPipeline = try pipeline("compositeVideoHDR")
        imagePipeline = try pipeline("compositeImageHDR")
        resolvePipeline = try pipeline("resolveHDRCanvas")
    }

    // MARK: - BT.2100 reference maths, independent of the shader

    // ITU-R BT.2100 Table 5. Written out here rather than read from
    // `HDRColorSpace` so the shader is checked against the specification and not
    // against another copy of the app's own arithmetic.
    private let a = 0.17883277
    private var b: Double { 1 - 4 * a }
    private var c: Double { 0.5 - a * log(4 * a) }

    /// HLG inverse OETF: signal → scene light.
    private func sceneLight(_ e: Double) -> Double {
        if e <= 0 { return 0 }
        if e <= 0.5 { return e * e / 3 }
        return (exp((e - c) / a) + b) / 12
    }

    /// HLG OETF: scene light → signal.
    private func signal(_ e: Double) -> Double {
        if e <= 0 { return 0 }
        if e <= 1.0 / 12.0 { return (3 * e).squareRoot() }
        return a * log(12 * e - b) + c
    }

    /// BT.2408 reference white, the point diffuse white sits on.
    private var referenceWhite: Double { sceneLight(0.75) }

    /// Signal → the working space the compositor grades in: diffuse white at 1.0.
    private func working(_ e: Double) -> Double { sceneLight(e) / referenceWhite }
    private func signalOfWorking(_ w: Double) -> Double { signal(max(w, 0) * referenceWhite) }

    // MARK: - Harness

    private let size = 8

    private func makeTexture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size, height: size, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        return try XCTUnwrap(context.device.makeTexture(descriptor: d))
    }

    private func halfTexture(filledWith rgb: (Double, Double, Double), alpha: Double = 1) throws -> MTLTexture {
        let texture = try makeTexture(.rgba16Float)
        var pixels = [Float16](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4 + 0] = Float16(rgb.0)
            pixels[i * 4 + 1] = Float16(rgb.1)
            pixels[i * 4 + 2] = Float16(rgb.2)
            pixels[i * 4 + 3] = Float16(alpha)
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: size * 8)
        }
        return texture
    }

    private func bgraTexture(filledWith bgra: (Double, Double, Double, Double)) throws -> MTLTexture {
        let texture = try makeTexture(.bgra8Unorm)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4 + 0] = UInt8(max(0, min(255, (bgra.0 * 255).rounded())))
            pixels[i * 4 + 1] = UInt8(max(0, min(255, (bgra.1 * 255).rounded())))
            pixels[i * 4 + 2] = UInt8(max(0, min(255, (bgra.2 * 255).rounded())))
            pixels[i * 4 + 3] = UInt8(max(0, min(255, (bgra.3 * 255).rounded())))
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: size * 4)
        }
        return texture
    }

    private func read(_ texture: MTLTexture, x: Int, y: Int) -> (Double, Double, Double) {
        var pixels = [Float16](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: size * 8,
                             from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        let i = (y * size + x) * 4
        return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
    }

    /// The identity placement the app produces for an untransformed clip that
    /// exactly fills the canvas — built by the compositor's own transform maths,
    /// so the mapping under test is the one the app uses.
    private var identityPlacement: CGAffineTransform {
        let canvas = CGSize(width: size, height: size)
        return LayerCompositor.transform(VisualTransform(), encoded: canvas, preferred: .identity, canvas: canvas)
    }

    /// Runs one video layer over black and resolves to an HLG signal.
    private func compositeVideo(
        source: MTLTexture,
        partner: MTLTexture? = nil,
        layer: HDRLayerUniforms,
        settings: GradeSettings = .neutral,
        bypass: Bool = false
    ) throws -> MTLTexture {
        let canvas = try halfTexture(filledWith: (0, 0, 0))
        let composited = try makeTexture(.rgba16Float)
        let resolved = try makeTexture(.rgba16Float)
        var grade = GradeUniforms(settings: settings, bypass: bypass)
        var hdr = HDRDisplayUniforms()
        var layer = layer
        let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(videoPipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(partner ?? source, index: 1)
            encoder.setTexture(canvas, index: 2)
            encoder.setTexture(composited, index: 3)
            encoder.setTexture(context.luts.texture(for: nil), index: 4)
            encoder.setTexture(context.curves.texture(for: nil), index: 6)
            encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
            encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
            // Bind everything the pipeline declares. These two were relying on
            // whatever an unbound argument slot happened to contain, which is
            // undefined and started producing black frames once the kernel took
            // one more buffer.
            var noLayerMask = LayerMaskUniforms(nil)
            encoder.setBytes(&noLayerMask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
            LocalGradeStack.empty.bind(encoder)
            encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(resolvePipeline)
            encoder.setTexture(composited, index: 0)
            encoder.setTexture(resolved, index: 1)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
            encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        return resolved
    }

    private func compositeImage(_ source: MTLTexture, layer: HDRLayerUniforms) throws -> MTLTexture {
        let canvas = try halfTexture(filledWith: (0, 0, 0))
        let composited = try makeTexture(.rgba16Float)
        let resolved = try makeTexture(.rgba16Float)
        var hdr = HDRDisplayUniforms()
        var layer = layer
        let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(imagePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(canvas, index: 2)
            encoder.setTexture(composited, index: 3)
            encoder.setBytes(&layer, length: MemoryLayout<HDRLayerUniforms>.stride, index: 2)
            var noLayerMask = LayerMaskUniforms(nil)
            encoder.setBytes(&noLayerMask, length: MemoryLayout<LayerMaskUniforms>.stride, index: 3)
            encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(resolvePipeline)
            encoder.setTexture(composited, index: 0)
            encoder.setTexture(resolved, index: 1)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
            encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        return resolved
    }

    private func layer(
        opacity: Double = 1, blend: Double = 0, sdr: Bool = false, premultiplied: Bool = false,
        transform: CGAffineTransform? = nil
    ) -> HDRLayerUniforms {
        HDRLayerUniforms(
            transform: transform ?? identityPlacement,
            sourceSize: CGSize(width: size, height: size),
            canvasSize: CGSize(width: size, height: size),
            opacity: opacity, blendAmount: blend, sourceIsSDR: sdr, premultiplied: premultiplied)
    }

    // MARK: - Tests

    /// An HLG frame through the compositor with a neutral grade must come out as
    /// the signal it went in as. If this drifts, every HDR preview is wrong by
    /// that amount whether or not anything was graded.
    func testAnUngradedHLGLayerSurvivesTheRoundTripUnchanged() throws {
        for level in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let source = try halfTexture(filledWith: (level, level, level))
            let out = try compositeVideo(source: source, layer: layer())
            let (r, g, b) = read(out, x: 4, y: 4)
            XCTAssertEqual(r, level, accuracy: 0.002, "red drifted at HLG \(level)")
            XCTAssertEqual(g, level, accuracy: 0.002, "green drifted at HLG \(level)")
            XCTAssertEqual(b, level, accuracy: 0.002, "blue drifted at HLG \(level)")
        }
    }

    /// Highlights above diffuse white must survive. Signal 1.0 is roughly 3.77x
    /// diffuse white in the working space; the old SDR compositor clipped it to
    /// white, which is the whole reason this path exists.
    func testHighlightsAboveDiffuseWhiteAreNotClipped() throws {
        let source = try halfTexture(filledWith: (1.0, 1.0, 1.0))
        let out = try compositeVideo(source: source, layer: layer())
        let (r, _, _) = read(out, x: 0, y: 0)
        XCTAssertEqual(r, 1.0, accuracy: 0.002)
        XCTAssertGreaterThan(working(r), 3.0, "signal 1.0 must stay well above diffuse white")
    }

    /// Frame blending has to happen in linear light. Mixing the signals directly
    /// would weight the two frames by a non-linear function of brightness, and
    /// a half-and-half blend would land visibly off the true midpoint.
    func testFrameBlendingMixesInLinearLightNotInTheSignal() throws {
        let a = 0.25, b = 0.9
        let first = try halfTexture(filledWith: (a, a, a))
        let second = try halfTexture(filledWith: (b, b, b))
        let out = try compositeVideo(source: first, partner: second, layer: layer(blend: 0.5))
        let (r, _, _) = read(out, x: 4, y: 4)

        let linearMidpoint = signalOfWorking((working(a) + working(b)) / 2)
        let signalMidpoint = (a + b) / 2
        XCTAssertEqual(r, linearMidpoint, accuracy: 0.004, "blend is not happening in working space")
        XCTAssertGreaterThan(abs(linearMidpoint - signalMidpoint), 0.02,
                             "these two must differ enough for the check above to mean something")
    }

    /// The ends of the ramp must be the exact source frames, or a clip would
    /// shimmer where the blend is meant to be a no-op.
    func testBlendEndpointsAreTheSourceFramesExactly() throws {
        let first = try halfTexture(filledWith: (0.3, 0.3, 0.3))
        let second = try halfTexture(filledWith: (0.8, 0.8, 0.8))
        let atStart = try compositeVideo(source: first, partner: second, layer: layer(blend: 0))
        XCTAssertEqual(read(atStart, x: 1, y: 1).0, 0.3, accuracy: 0.002)
        let atEnd = try compositeVideo(source: first, partner: second, layer: layer(blend: 1))
        XCTAssertEqual(read(atEnd, x: 1, y: 1).0, 0.8, accuracy: 0.002)
    }

    /// An SDR layer in an HDR project has to land on BT.2408 reference white -
    /// HLG signal 0.75 - which is where AVFoundation puts SDR white on the
    /// direct path (measured, Docs/HDR_PIPELINE_PLAN.md 2). Anything else and an
    /// SDR clip would glare or look washed out next to an HDR one.
    func testAnSDRLayerLandsOnReferenceWhite() throws {
        let source = try halfTexture(filledWith: (1.0, 1.0, 1.0))
        let out = try compositeVideo(source: source, layer: layer(sdr: true))
        let (r, g, b) = read(out, x: 4, y: 4)
        XCTAssertEqual(r, 0.75, accuracy: 0.005, "SDR white is not on reference white")
        XCTAssertEqual(g, 0.75, accuracy: 0.005)
        XCTAssertEqual(b, 0.75, accuracy: 0.005)
    }

    /// SDR black stays black: the gamut matrix must not introduce a lift.
    func testAnSDRLayerKeepsBlackAtBlack() throws {
        let source = try halfTexture(filledWith: (0, 0, 0))
        let out = try compositeVideo(source: source, layer: layer(sdr: true))
        XCTAssertEqual(read(out, x: 2, y: 2).0, 0, accuracy: 0.001)
    }

    /// Opacity is a linear-light coverage, so half opacity is half the light -
    /// not half the signal.
    func testOpacityCompositesInLinearLight() throws {
        let source = try halfTexture(filledWith: (0.75, 0.75, 0.75))
        let out = try compositeVideo(source: source, layer: layer(opacity: 0.5))
        let (r, _, _) = read(out, x: 4, y: 4)
        XCTAssertEqual(r, signalOfWorking(working(0.75) * 0.5), accuracy: 0.004)
    }

    /// Rendered artwork - text, stills - arrives premultiplied from Core Image.
    /// White text at half alpha is half of reference white in linear light.
    func testPremultipliedArtworkIsUnpremultipliedBeforeTheTransfer() throws {
        // Premultiplied white at alpha 0.5 is stored as 0.5 in every channel.
        let source = try bgraTexture(filledWith: (0.5, 0.5, 0.5, 0.5))
        let out = try compositeImage(source, layer: layer(premultiplied: true))
        let (r, _, _) = read(out, x: 4, y: 4)
        XCTAssertEqual(r, signalOfWorking(0.5), accuracy: 0.01,
                       "white artwork at half alpha should be half of diffuse white")
    }

    /// Fully transparent artwork must leave the canvas untouched.
    func testTransparentArtworkChangesNothing() throws {
        let source = try bgraTexture(filledWith: (0, 0, 0, 0))
        let out = try compositeImage(source, layer: layer(premultiplied: true))
        XCTAssertEqual(read(out, x: 4, y: 4).0, 0, accuracy: 0.001)
    }

    /// A scaled-down layer must cover the middle of the canvas and leave the
    /// corners as they were. This is the mapping the SDR path hands Core Image,
    /// inverted for the kernel, so a mistake here would show as a layer in the
    /// wrong place or mirrored.
    func testAScaledLayerCoversTheCentreAndLeavesTheCornersAlone() throws {
        var transform = VisualTransform()
        transform.scale = 0.5
        let canvas = CGSize(width: size, height: size)
        let placement = LayerCompositor.transform(transform, encoded: canvas, preferred: .identity, canvas: canvas)
        let source = try halfTexture(filledWith: (0.75, 0.75, 0.75))
        let out = try compositeVideo(source: source, layer: layer(transform: placement))
        XCTAssertEqual(read(out, x: 4, y: 4).0, 0.75, accuracy: 0.005, "the centre should carry the layer")
        XCTAssertEqual(read(out, x: 0, y: 0).0, 0, accuracy: 0.005, "the corner should stay black")
        XCTAssertEqual(read(out, x: 7, y: 7).0, 0, accuracy: 0.005)
    }

    /// Hold-to-compare must show the untouched signal, exactly as the direct HDR
    /// preview does.
    func testBypassReturnsTheSourceSignal() throws {
        var settings = GradeSettings.neutral
        settings.exposure = 1.5
        let source = try halfTexture(filledWith: (0.6, 0.6, 0.6))
        let out = try compositeVideo(source: source, layer: layer(), settings: settings, bypass: true)
        XCTAssertEqual(read(out, x: 4, y: 4).0, 0.6, accuracy: 0.002)
    }

    /// A grade must actually reach an HDR layer - a compositor that quietly
    /// ignored the grade would pass every check above.
    func testAGradeChangesTheResult() throws {
        var settings = GradeSettings.neutral
        settings.exposure = 1.0     // one stop
        let source = try halfTexture(filledWith: (0.5, 0.5, 0.5))
        let out = try compositeVideo(source: source, layer: layer(), settings: settings)
        let (r, _, _) = read(out, x: 4, y: 4)
        XCTAssertEqual(r, signalOfWorking(working(0.5) * 2), accuracy: 0.01,
                       "one stop of exposure should double the light")
    }
}

/// How an HDR project is wired up: which compositor renders it, how the
/// composition is tagged, and whether the colour mode survives the trip to the
/// exporter.
final class HDRCompositionRoutingTests: XCTestCase {
    private var hlgURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("hlg_test.mov")
    }

    private func hdrProject(smooth: Bool) async throws -> VideoProject {
        let asset = try await VideoMetadataReader().read(from: hlgURL)
        var project = VideoProject(sourceURL: asset.url, displayName: "hlg",
                                   metadata: asset.metadata, sourceRange: asset.sourceRange)
        XCTAssertTrue(project.colorMode.isHDR, "the fixture should open as an HDR project")
        guard smooth else { return project }
        let id = try XCTUnwrap(project.timeline.firstVideoClip?.id)
        try TimelineEditing.setSpeed(id, to: 0.5, in: &project)
        var clip = try TimelineEditing.editable(id, in: project)
        clip.smoothsMotion = true
        try TimelineEditing.replace(id, with: [clip], in: &project)
        return project
    }

    /// Smoothing is what forces an HDR project onto the compositing path, and it
    /// must be the HDR compositor that gets it. The SDR one writes 8-bit BGRA
    /// and would clip every highlight above diffuse white.
    func testASmoothedHDRProjectUsesTheHDRCompositor() async throws {
        let project = try await hdrProject(smooth: true)
        XCTAssertTrue(project.needsLayerCompositor, "smoothing must take the compositing path")
        let sequence = try await SequenceComposition.build(project: project, forExport: false)
        let composition = try XCTUnwrap(sequence.source.videoComposition)
        XCTAssertTrue(composition.customVideoCompositorClass === HDRLayerCompositor.self,
                      "an HDR project must not be composited by the 8-bit path")
    }

    /// The composition's tags are what relabel the frames handed to the
    /// compositor, and what describe the frames it returns.
    func testAnHDRCompositionIsTaggedBT2020HLG() async throws {
        let project = try await hdrProject(smooth: true)
        let built = try await SequenceComposition.build(project: project, forExport: false)
        let composition = try XCTUnwrap(built.source.videoComposition)
        XCTAssertEqual(composition.colorPrimaries, AVVideoColorPrimaries_ITU_R_2020)
        XCTAssertEqual(composition.colorTransferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(composition.colorYCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_2020)
    }

    /// An SDR project must be untouched by any of this.
    func testAnSDRProjectStillUsesTheSDRCompositorAndRec709Tags() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("retime_test.mov")
        let asset = try await VideoMetadataReader().read(from: url)
        var project = VideoProject(sourceURL: asset.url, displayName: "sdr",
                                   metadata: asset.metadata, sourceRange: asset.sourceRange)
        let id = try XCTUnwrap(project.timeline.firstVideoClip?.id)
        try TimelineEditing.setSpeed(id, to: 0.5, in: &project)
        var clip = try TimelineEditing.editable(id, in: project)
        clip.smoothsMotion = true
        try TimelineEditing.replace(id, with: [clip], in: &project)
        let built = try await SequenceComposition.build(project: project, forExport: false)
        let composition = try XCTUnwrap(built.source.videoComposition)
        XCTAssertTrue(composition.customVideoCompositorClass === LayerCompositor.self)
        XCTAssertEqual(composition.colorTransferFunction, AVVideoTransferFunction_ITU_R_709_2)
    }

    /// The exporter reads the colour mode off the built source to choose the
    /// reader format, the encoder profile and the output tags. It used to be
    /// left at its `.sdr` default by both composition builders, so an HDR
    /// project was checked as HDR and then written through the 8-bit path.
    func testTheColorModeSurvivesBothCompositionPaths() async throws {
        let direct = try await hdrProject(smooth: false)
        XCTAssertFalse(direct.needsLayerCompositor, "a plain HDR clip should take the direct path")
        let directSource = try await SequenceComposition.build(project: direct, forExport: false).source
        XCTAssertEqual(directSource.colorMode, .hdrHLG, "the direct path dropped the colour mode")

        let layered = try await hdrProject(smooth: true)
        let layeredSource = try await SequenceComposition.build(project: layered, forExport: false).source
        XCTAssertEqual(layeredSource.colorMode, .hdrHLG, "the compositing path dropped the colour mode")
    }

    /// The reader format follows from that colour mode, and half-float is what
    /// keeps the highlights: asking for 8-bit here is the silent reduction.
    func testAnHDRExportReadsHalfFloatFrames() throws {
        let settings = ExportMediaSettings.videoReaderSettings(colorMode: .hdrHLG)
        XCTAssertEqual(settings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
                       kCVPixelFormatType_64RGBAHalf)
    }
}
