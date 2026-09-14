import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

/// Host-only regression check for the still-image path. No simulator, no device.
///
/// It proves the three things about a photograph that cannot be checked by eye
/// in a preview, and that would otherwise only be discovered in an exported
/// file:
///
/// 1. **Tiled rendering is seamless and frame-absolute.** The full-resolution
///    export renders in tiles. `gradeStillTileBGRA` is handed each tile's origin
///    so the vignette and the grain field see the whole picture; if that were
///    wrong, both would restart inside every tile. The check renders an image
///    once whole and once in tiles with a heavy vignette and grain, and demands
///    the two be identical — not merely similar.
///
/// 2. **The glow radius does not depend on output resolution.** Bloom, glow and
///    halation reach a fixed number of texels of the blur pyramid, so building
///    that pyramid at a fraction of the surface would make the halo shrink as
///    the export grew. `FilmEffectsStage.blurSize` pins it for stills; this
///    checks the reach is the same fraction of the picture at 1024 and at 8192
///    pixels wide.
///
/// 3. **EXIF orientation is applied the right way round.** All eight
///    orientations are checked against what EXIF actually says — which visual
///    edge the stored first row and first column lie along — rather than against
///    a remembered table. Getting 5...8 backwards is a 180° error that leaves
///    landscape pictures looking correct and turns portrait ones upside down.
///
/// Build and run from the repository root:
///
/// ```sh
/// xcrun swiftc -O -o /tmp/validatestill Scripts/ValidateStillImage.swift \
///   "dummy name/Core/Grading/GradeSettings.swift" "dummy name/Core/Grading/AdvancedGrade.swift" \
///   "dummy name/Core/Grading/AdvancedCurves.swift" "dummy name/Core/Grading/CurveEvaluator.swift" \
///   "dummy name/Core/Grading/CurveEditing.swift" "dummy name/Core/Rendering/CurveLUTTexture.swift" \
///   "dummy name/Core/Grading/FilmEffects.swift" "dummy name/Core/Rendering/RenderUniforms.swift" \
///   "dummy name/Core/Grading/HDRColorSpace.swift" "dummy name/Core/AppError.swift" \
///   "dummy name/Core/Rendering/FilmEffectsStage.swift" "dummy name/Core/Rendering/MetalContext.swift" \
///   "dummy name/Core/LUT/LUTLibrary.swift" "dummy name/Core/LUT/LUTAsset.swift" \
///   "dummy name/Core/LUT/LUTTexture.swift" "dummy name/Core/LUT/CubeLUT.swift" \
///   "dummy name/Core/LUT/CubeLUTParser.swift" "dummy name/Core/LUT/LUTStore.swift" \
///   && /tmp/validatestill
/// ```
@main
struct ValidateStillImage {
    static let tileSide = ImageExportGeometry.tileSide
    static let tilePadding = ImageExportGeometry.tilePadding

    static func main() throws {
        // Unbuffered, so a failure's diagnostics are not lost behind the
        // successes that preceded it.
        setvbuf(stdout, nil, _IONBF, 0)
        try checkOrientationTransforms()
        try checkDecodedOrientationRoundTrip()
        try checkBlurRadiusIsResolutionIndependent()
        // Three configurations, with the tolerance each one actually deserves.
        //
        // The first two must be EXACT. They are where a tile-origin mistake
        // would live: the vignette and the grain field read the normalised
        // coordinate, and the glows read a halo covering the whole picture, so
        // any of the three getting a tile-local coordinate would differ by a
        // great deal rather than by a rounding step.
        //
        // Only the unsharp mask is allowed a single code value. Its taps sit at
        // a fixed fraction of the picture, which becomes a slightly different
        // sub-texel offset once expressed against a tile instead of the whole
        // frame; the bilinear sample lands a fraction of a texel away and can
        // round differently in the last bit of an 8-bit channel.
        try checkTiledRenderMatchesWholeFrame(glows: false, sharpen: false, tolerance: 0)
        try checkTiledRenderMatchesWholeFrame(glows: true, sharpen: false, tolerance: 0)
        try checkTiledRenderMatchesWholeFrame(glows: true, sharpen: true, tolerance: 1)
        print("\nAll still-image checks passed.")
    }

    // MARK: - Orientation, through the real decoder

    /// The transform check above proves the table. This proves the whole path:
    /// a real file with a real EXIF tag, read by `ImageMetadataReader` and
    /// decoded by `ImageDecoder` exactly as an import and an export do it.
    ///
    /// Both routes are exercised, because they apply the orientation in
    /// different places: the downsampling decode lets ImageIO do it, and the
    /// full-resolution decode — the one the export uses — does it while drawing.
    /// A table that is right and a route that forgets to use it look the same
    /// until a file comes out sideways.
    static func checkDecodedOrientationRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradelab-orientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Four flat quadrants, so a rotation or a mirror is unmistakable.
        let width = 640, height = 480
        let quadrants: [(name: String, blue: UInt8, green: UInt8, red: UInt8)] = [
            ("red", 20, 20, 230), ("green", 20, 230, 20),
            ("blue", 230, 20, 20), ("yellow", 20, 230, 230)
        ]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let quadrant = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                pixels[index] = quadrants[quadrant].blue
                pixels[index + 1] = quadrants[quadrant].green
                pixels[index + 2] = quadrants[quadrant].red
                pixels[index + 3] = 255
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            fatalError("Could not build the orientation round-trip source")
        }

        // Both formats, because they carry orientation differently: JPEG in an
        // EXIF tag, PNG in metadata ImageIO synthesises. A photograph coming out
        // of a camera is the JPEG/HEIF case, so it is the one that matters most.
        for (type, ext) in [(UTType.png, "png"), (UTType.jpeg, "jpg")] {
        for orientation in 1...8 {
            let url = directory.appendingPathComponent("o\(orientation).\(ext)")
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil) else {
                fatalError("Could not write the orientation round-trip source")
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: 1.0
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                fatalError("Could not finalise the orientation round-trip source")
            }

            let metadata = try ImageMetadataReader.read(url: url)
            guard metadata.orientation == orientation else {
                fatalError("""
                    A \(ext.uppercased()) written with EXIF orientation \(orientation) reads \
                    back as \(metadata.orientation). The rest of this check cannot mean \
                    anything until that is understood.
                    """)
            }
            let sideways = (5...8).contains(orientation)
            let expectedWidth = sideways ? height : width
            let expectedHeight = sideways ? width : height
            guard metadata.displayWidth == expectedWidth, metadata.displayHeight == expectedHeight else {
                fatalError("Orientation \(orientation): displayed size is \(metadata.displayWidth)x\(metadata.displayHeight), expected \(expectedWidth)x\(expectedHeight)")
            }

            // Full resolution is the route the export takes; the small one is
            // the route the preview takes. They must agree.
            for (label, longEdge) in [("full", Int?.none), ("preview", Int?.some(320))] {
                let buffer = try ImageDecoder.decode(url: url, maximumLongEdge: longEdge)
                let decodedWidth = CVPixelBufferGetWidth(buffer)
                let decodedHeight = CVPixelBufferGetHeight(buffer)
                guard decodedWidth * expectedHeight == decodedHeight * expectedWidth else {
                    fatalError("Orientation \(orientation) (\(label)): decoded \(decodedWidth)x\(decodedHeight) does not match the displayed shape \(expectedWidth)x\(expectedHeight)")
                }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                    fatalError("The decoded buffer has no base address")
                }
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                func quadrant(atX fx: Double, y fy: Double) -> String {
                    let x = min(decodedWidth - 1, Int(Double(decodedWidth) * fx))
                    let y = min(decodedHeight - 1, Int(Double(decodedHeight) * fy))
                    let pixel = base.advanced(by: y * stride + x * 4)
                        .assumingMemoryBound(to: UInt8.self)
                    let b = Int(pixel[0]), g = Int(pixel[1]), r = Int(pixel[2])
                    if r > 128, g > 128 { return "yellow" }
                    if r > 128 { return "red" }
                    if g > 128 { return "green" }
                    if b > 128 { return "blue" }
                    return "unknown(\(r),\(g),\(b))"
                }
                // Where each stored quadrant belongs once the orientation is
                // applied, derived from the EXIF definition rather than from the
                // transform being tested.
                for (index, quadrantName) in quadrants.map(\.name).enumerated() {
                    let storedX = (index % 2 == 0 ? width / 4 : width * 3 / 4)
                    let storedY = (index < 2 ? height / 4 : height * 3 / 4)
                    let target = expectedPosition(orientation, x: storedX, y: storedY,
                                                  width: width, height: height)
                    let found = quadrant(atX: (Double(target.x) + 0.5) / Double(expectedWidth),
                                         y: (Double(target.y) + 0.5) / Double(expectedHeight))
                    guard found == quadrantName else {
                        fatalError("""
                            \(ext.uppercased()), EXIF orientation \(orientation), \(label) decode: \
                            the stored \(quadrantName) quadrant should land at \
                            \(target.x),\(target.y) of a \(expectedWidth)x\(expectedHeight) \
                            picture; found \(found) there.
                            """)
                    }
                }
            }
        }
        }
        print("Orientation: all eight survive the real decode as PNG and as JPEG, at full resolution and at preview size.")
    }

    // MARK: - 1. Tiling

    /// Renders a test picture whole, then in tiles, and demands they agree
    /// exactly. Vignette and grain are turned well up: both are computed from
    /// the normalised coordinate, so a tile that reported its own local
    /// coordinate would differ by a lot, at every tile boundary.
    /// - Parameters:
    ///   - glows: run bloom, glow and halation, composited against a halo
    ///     blurred over the whole picture. A tile-origin error in
    ///     `effectCompositeTile` would repeat the glow inside every tile.
    ///   - sharpen: run the unsharp mask, whose taps are the only part of the
    ///     pipeline expressed against the tile rather than the picture.
    ///   - tolerance: the largest per-channel difference allowed, in 8-bit code
    ///     values.
    static func checkTiledRenderMatchesWholeFrame(
        glows: Bool, sharpen: Bool, tolerance: Int
    ) throws {
        let spatialEffects = glows || sharpen
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required for still-image validation")
        }
        let source = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let effectsSource = try String(contentsOfFile: "dummy name/Metal/EffectShaders.metal", encoding: .utf8)
        let effectsLibrary = try device.makeLibrary(source: effectsSource, options: nil)
        guard let function = library.makeFunction(name: "gradeStillTileBGRA"),
              let compositeFunction = effectsLibrary.makeFunction(name: "effectCompositeTile") else {
            fatalError("The still-image kernels are missing from the shader library")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let compositePipeline = try device.makeComputePipelineState(function: compositeFunction)

        // Larger than one tile in both axes and deliberately not a multiple of
        // the tile side, so there are interior tiles, partial edge tiles, and a
        // padded window that has to shift inward at the right and the bottom.
        let width = 3500, height = 2100
        let picture = testPicture(width: width, height: height)

        var grade = GradeSettings.neutral
        grade.contrast = 24
        grade.saturation = -18
        var advanced = AdvancedGrade.neutral
        advanced.vignette = -80          // frame-absolute
        advanced.vignetteMidpoint = 40
        advanced.vignetteFeather = 55
        advanced.effects = FilmEffects(
            fade: 12, sharpness: sharpen ? 60 : 0,
            bloom: glows ? 70 : 0, glow: glows ? 45 : 0, halation: glows ? 55 : 0,
            grain: 70)
        grade.advanced = advanced

        var uniforms = GradeUniforms(settings: grade, bypass: false)
        let curves = CurveLUTLibrary(device: device)
        guard let curveTexture = curves.texture(for: nil),
              let identityLUT = LUTLibrary(device: device).texture(for: nil) else {
            fatalError("The neutral curve and look tables could not be built")
        }

        // The whole-image halo, built exactly as the exporter builds it: once,
        // over the entire picture, at a fixed size. Every tile — and the
        // whole-frame reference render — composites against this same texture.
        var halo: MTLTexture?
        if spatialEffects {
            guard let stage = FilmEffectsStage(context: try MetalContext(library: try device.makeLibrary(
                source: source + "\n" + effectsSource, options: nil))) else {
                fatalError("The finishing-effects stage could not be built")
            }
            let reference = StillEffectGeometry.referenceSize(
                for: CGSize(width: width, height: height))
            let graded = renderGraded(
                picture: picture, width: width, height: height,
                outputWidth: Int(reference.width), outputHeight: Int(reference.height),
                pipeline: pipeline, uniforms: &uniforms, lut: identityLUT, curves: curveTexture,
                device: device, queue: queue)
            guard let command = queue.makeCommandBuffer(),
                  let built = stage.encodeBlur(source: graded, grade: uniforms, workingSpace: false,
                                               blurLongEdge: StillEffectGeometry.blurLongEdge,
                                               into: command) else {
                fatalError("The whole-image halo could not be built")
            }
            command.commit()
            command.waitUntilCompleted()
            halo = built
        }

        func render(originX: Int, originY: Int, tileWidth: Int, tileHeight: Int) -> [UInt8] {
            let sourceTexture = upload(picture, width: width, height: height,
                                       originX: originX, originY: originY,
                                       tileWidth: tileWidth, tileHeight: tileHeight, device: device)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: tileWidth, height: tileHeight, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            let gradedDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: tileWidth, height: tileHeight, mipmapped: false)
            gradedDescriptor.usage = [.shaderRead, .shaderWrite]
            guard let output = device.makeTexture(descriptor: descriptor),
                  let graded = device.makeTexture(descriptor: gradedDescriptor),
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else {
                fatalError("The GPU refused the validation pass")
            }
            var tile = SIMD4<Float>(Float(originX), Float(originY), Float(width), Float(height))
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(spatialEffects ? graded : output, index: 2)
            encoder.setTexture(identityLUT, index: 3)
            encoder.setTexture(curveTexture, index: 6)
            encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            encoder.setBytes(&tile, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            LocalGradeStack.empty.bind(encoder)
            encoder.dispatchThreads(
                MTLSize(width: tileWidth, height: tileHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()

            if spatialEffects, let halo {
                var effectUniforms = FilmEffectsStage.uniforms(
                    uniforms, size: (tileWidth, tileHeight), workingSpace: false)
                effectUniforms.step = StillEffectGeometry.sharpenStep(
                    imageSize: CGSize(width: width, height: height),
                    surfaceSize: CGSize(width: tileWidth, height: tileHeight))
                guard let composite = command.makeComputeCommandEncoder() else {
                    fatalError("The GPU refused the composite pass")
                }
                composite.setComputePipelineState(compositePipeline)
                composite.setTexture(graded, index: 0)
                composite.setTexture(halo, index: 1)
                composite.setTexture(output, index: 2)
                composite.setBytes(&effectUniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
                composite.setBytes(&tile, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                composite.dispatchThreads(
                    MTLSize(width: tileWidth, height: tileHeight, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                composite.endEncoding()
            }

            command.commit()
            command.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: tileWidth * tileHeight * 4)
            bytes.withUnsafeMutableBytes { raw in
                output.getBytes(raw.baseAddress!, bytesPerRow: tileWidth * 4,
                                from: MTLRegionMake2D(0, 0, tileWidth, tileHeight), mipmapLevel: 0)
            }
            return bytes
        }

        let whole = render(originX: 0, originY: 0, tileWidth: width, tileHeight: height)

        // The exporter's own tiling arithmetic, reproduced exactly.
        var assembled = [UInt8](repeating: 0, count: width * height * 4)
        let paddedWidth = min(width, tileSide + tilePadding * 2)
        let paddedHeight = min(height, tileSide + tilePadding * 2)
        var tileCount = 0
        var y = 0
        while y < height {
            let outHeight = min(tileSide, height - y)
            var x = 0
            while x < width {
                let outWidth = min(tileSide, width - x)
                let originX = min(max(x - tilePadding, 0), max(0, width - paddedWidth))
                let originY = min(max(y - tilePadding, 0), max(0, height - paddedHeight))
                let cropX = x - originX, cropY = y - originY
                let rendered = render(originX: originX, originY: originY,
                                      tileWidth: paddedWidth, tileHeight: paddedHeight)
                for row in 0..<outHeight {
                    let sourceStart = ((cropY + row) * paddedWidth + cropX) * 4
                    let destinationStart = ((y + row) * width + x) * 4
                    for byte in 0..<(outWidth * 4) {
                        assembled[destinationStart + byte] = rendered[sourceStart + byte]
                    }
                }
                tileCount += 1
                x += tileSide
            }
            y += tileSide
        }

        var worst = 0
        var worstAt = (0, 0)
        for index in stride(from: 0, to: whole.count, by: 4) {
            for channel in 0..<3 {
                let difference = abs(Int(whole[index + channel]) - Int(assembled[index + channel]))
                if difference > worst {
                    worst = difference
                    worstAt = ((index / 4) % width, (index / 4) / width)
                }
            }
        }
        guard worst <= tolerance else {
            fatalError("""
                Tiled rendering does not match a whole-frame render.
                Worst difference \(worst)/255 (allowed \(tolerance)) at \(worstAt) over \(tileCount) tiles.
                A difference beyond the tolerance means a stage is reading a tile-local
                coordinate where it should read the picture's: the vignette, the grain
                field, or the halo lookup in effectCompositeTile.
                """)
        }
        var active = ["vignette", "grain", "fade"]
        if glows { active.append("bloom/glow/halation") }
        if sharpen { active.append("sharpen") }
        let verdict = worst == 0 ? "exactly" : "to within \(worst)/255"
        print("Tiling: \(tileCount) tiles over \(width)x\(height) match the whole-frame render \(verdict) "
              + "(\(active.joined(separator: ", "))).")
    }

    /// Grades the whole picture into a reference-sized float texture, which is
    /// what the halo is blurred from.
    static func renderGraded(
        picture: [UInt8], width: Int, height: Int, outputWidth: Int, outputHeight: Int,
        pipeline: MTLComputePipelineState, uniforms: inout GradeUniforms,
        lut: MTLTexture, curves: MTLTexture, device: MTLDevice, queue: MTLCommandQueue
    ) -> MTLTexture {
        // Rendered at full size and then used directly: the harness only needs a
        // graded picture to blur, and matching the exporter's downsample step is
        // not what is under test here.
        let source = upload(picture, width: width, height: height, originX: 0, originY: 0,
                            tileWidth: width, tileHeight: height, device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            fatalError("Could not build the halo's graded source")
        }
        var tile = SIMD4<Float>(0, 0, Float(width), Float(height))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 2)
        encoder.setTexture(lut, index: 3)
        encoder.setTexture(curves, index: 6)
        encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        encoder.setBytes(&tile, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        LocalGradeStack.empty.bind(encoder)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        _ = (outputWidth, outputHeight)
        return output
    }

    /// A picture with structure at every scale, so a coordinate error anywhere
    /// shows up rather than landing on a flat area.
    static func testPicture(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let u = Double(x) / Double(width), v = Double(y) / Double(height)
                let checker = ((x / 17) + (y / 13)) % 2 == 0 ? 0.18 : 0.0
                bytes[index + 0] = UInt8(min(255, max(0, (v * 0.8 + checker) * 255)))       // B
                bytes[index + 1] = UInt8(min(255, max(0, (u * 0.7 + 0.15) * 255)))          // G
                bytes[index + 2] = UInt8(min(255, max(0, ((1 - u) * 0.6 + checker) * 255))) // R
                bytes[index + 3] = 255
            }
        }
        return bytes
    }

    static func upload(
        _ picture: [UInt8], width: Int, height: Int,
        originX: Int, originY: Int, tileWidth: Int, tileHeight: Int, device: MTLDevice
    ) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: tileWidth, height: tileHeight, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Could not allocate the validation source texture")
        }
        picture.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: (originY * width + originX) * 4)
            texture.replace(region: MTLRegionMake2D(0, 0, tileWidth, tileHeight),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
        }
        return texture
    }

    // MARK: - 2. Resolution-independent glow

    /// The Gaussian reaches a fixed number of blur texels, so its reach as a
    /// fraction of the picture is `reach / blurWidth`. Video derives the blur
    /// size from the surface, which makes that fraction change with resolution;
    /// the still path pins it, and this checks that it really is pinned.
    static func checkBlurRadiusIsResolutionIndependent() throws {
        // Two Gaussian passes per axis, each reaching the outermost tap offset.
        let reachInTexels = Double(FilmEffectsStage.blurIterations) * 7.1333
        var fractions: [Double] = []
        for width in [1024, 2048, 4096, 8192] {
            let height = width * 2 / 3
            let size = FilmEffectsStage.blurSize(
                width: width, height: height, longEdge: StillEffectGeometry.blurLongEdge)
            fractions.append(reachInTexels / Double(size.width))
        }
        let spread = (fractions.max() ?? 0) - (fractions.min() ?? 0)
        guard spread < 0.0005 else {
            fatalError("""
                The still blur radius depends on output resolution.
                Reach as a fraction of the picture: \(fractions.map { String(format: "%.4f", $0) }).
                A halo judged in the preview would not be the halo in the exported file.
                """)
        }
        print(String(format: "Glow radius: %.2f%% of the long edge at every resolution from 1K to 8K.",
                     (fractions.first ?? 0) * 100))

        // And the video rule must be untouched: still derived from the surface.
        let video = FilmEffectsStage.blurSize(width: 1024, height: 768, longEdge: nil)
        guard video == (256, 192) else {
            fatalError("The video blur size rule changed: expected a quarter of each edge, got \(video)")
        }
        print("Video blur size rule unchanged: a quarter of each edge.")
    }

    // MARK: - 3. Orientation

    /// Checks all eight EXIF orientations against the definition, by drawing a
    /// picture whose corners are all different and asking where each one landed.
    static func checkOrientationTransforms() throws {
        let width = 8, height = 6
        // One distinctive value per corner, so a 180° error cannot pass.
        let corners: [(x: Int, y: Int, value: UInt8)] = [
            (0, 0, 40), (width - 1, 0, 90), (0, height - 1, 150), (width - 1, height - 1, 220)
        ]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for corner in corners {
            let index = (corner.y * width + corner.x) * 4
            pixels[index + 0] = corner.value
            pixels[index + 1] = corner.value
            pixels[index + 2] = corner.value
            pixels[index + 3] = 255
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            fatalError("Could not build the orientation test image")
        }

        for orientation in 1...8 {
            let sideways = (5...8).contains(orientation)
            let destinationWidth = sideways ? height : width
            let destinationHeight = sideways ? width : height
            var output = [UInt8](repeating: 0, count: destinationWidth * destinationHeight * 4)
            output.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress, width: destinationWidth, height: destinationHeight,
                    bitsPerComponent: 8, bytesPerRow: destinationWidth * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    fatalError("Could not build the orientation test context")
                }
                context.interpolationQuality = .none
                context.concatenate(orientationTransform(orientation,
                                                         width: destinationWidth,
                                                         height: destinationHeight))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            for corner in corners {
                let expected = expectedPosition(orientation, x: corner.x, y: corner.y,
                                                width: width, height: height)
                let index = (expected.y * destinationWidth + expected.x) * 4
                let found = output[index + 2]
                guard found == corner.value else {
                    fatalError("""
                        EXIF orientation \(orientation) is applied wrongly.
                        The stored pixel at \(corner.x),\(corner.y) should land at \
                        \(expected.x),\(expected.y) with value \(corner.value); found \(found).
                        """)
                }
            }
        }
        print("Orientation: all eight EXIF orientations place every corner where the specification says.")
    }

    /// Where a stored pixel belongs after `orientation` is applied, derived from
    /// what EXIF says rather than from the transform being tested.
    ///
    /// EXIF names which visual edge the stored first row and first column lie
    /// along: 1 TopLeft, 2 TopRight, 3 BottomRight, 4 BottomLeft, 5 LeftTop,
    /// 6 RightTop, 7 RightBottom, 8 LeftBottom.
    static func expectedPosition(_ orientation: Int, x: Int, y: Int, width: Int, height: Int)
        -> (x: Int, y: Int) {
        switch orientation {
        case 1: (x, y)
        case 2: (width - 1 - x, y)
        case 3: (width - 1 - x, height - 1 - y)
        case 4: (x, height - 1 - y)
        case 5: (y, x)
        case 6: (height - 1 - y, x)
        case 7: (height - 1 - y, width - 1 - x)
        case 8: (y, width - 1 - x)
        default: (x, y)
        }
    }

    /// The transform under test, copied from `ImageDecoder` so this harness does
    /// not need the whole app's UIKit dependencies to link.
    static func orientationTransform(_ orientation: Int, width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width), h = CGFloat(height)
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)
        default: return .identity
        }
    }
}

/// The exporter's tile constants, restated so the harness does not have to link
/// the exporter (which pulls in ImageIO, UIKit and the whole project model).
/// `GradeLabTests/ImageExportGeometryTests.swift` asserts the two agree.
enum ImageExportGeometry {
    static let tileSide = 1536
    static let tilePadding = 16
}
