@preconcurrency import CoreVideo
@preconcurrency import Metal
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a graded still at the source's own resolution and writes it out.
///
/// # Why it is tiled
///
/// A 48 MP photograph is 8064 × 6048. Grading it in one pass with the finishing
/// effects switched on would want three surfaces of that size at 16 bits per
/// channel — well over a gigabyte — so the picture is rendered in tiles and the
/// finished rows are assembled in an ordinary byte buffer. This is the only path
/// for every image, large or small, so the tile arithmetic is exercised by every
/// export rather than by a rare one.
///
/// # What tiling would break, and what is done about it
///
/// Three of the grading stages are **frame-absolute** — the vignette, the grain
/// field, and anything else that reads the normalised coordinate. A tile that
/// reported its own local coordinate would restart all three inside every tile.
/// `gradeStillTileBGRA` is handed the tile's origin and the size of the whole
/// image, so the coordinate reaching the shared `applyLookAndGrade` is always
/// the coordinate in the finished picture.
///
/// The three **glows** — bloom, glow, halation — read pixels far outside any
/// reasonable tile margin, and their radius has to be a fraction of the
/// photograph rather than of a tile. Both problems are solved the same way: the
/// blur is built **once, over the whole image**, at a fixed size, and every tile
/// composites against it. There is no seam to hide because no tile ever blurs
/// anything.
///
/// Sharpening is the only genuinely local effect left, so tiles overlap by a
/// small margin that is then cropped away.
///
/// # Why it matches the preview
///
/// Same shader functions, same `GradeSettings`, same look and curve textures,
/// same effects stage, same fixed blur geometry. The preview differs only in
/// resolution.
final class ImageExporter: @unchecked Sendable {
    /// Output side of one tile. Small enough that the padded working surfaces
    /// stay in the tens of megabytes on any device.
    static let tileSide = 1536
    /// Smallest overlap on each edge, cropped away afterwards.
    ///
    /// Only the unsharp mask reaches outside its pixel — the glows are
    /// composited from a halo blurred over the whole picture and reach nothing —
    /// so this only has to cover that. Its radius is one texel of the reference
    /// size, which is a few real pixels on an ordinary photograph but grows with
    /// the picture, so `tilePadding(for:)` derives the actual overlap and this
    /// is the floor.
    static let tilePadding = 16

    /// The overlap for a given picture: enough to cover the unsharp mask's reach
    /// at this resolution, plus a texel for the bilinear spread.
    ///
    /// A fixed overlap would be correct for every photograph a camera produces
    /// and quietly wrong for a large stitched panorama, which is exactly the
    /// kind of thing that only shows up in someone's finished file.
    static func tilePadding(for imageSize: CGSize) -> Int {
        let reference = StillEffectGeometry.referenceSize(for: imageSize)
        let scale = max(imageSize.width / max(reference.width, 1),
                        imageSize.height / max(reference.height, 1))
        return max(tilePadding, Int(scale.rounded(.up)) + 2)
    }

    struct Output: Sendable {
        let url: URL
        let width: Int
        let height: Int
        let format: ImageExportFormat
        let byteCount: Int64
    }

    private let context: MetalContext
    private let gradePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let effects: FilmEffectsStage?

    init(context: MetalContext? = nil) throws {
        let resolved = try context ?? MetalContext()
        self.context = resolved
        guard let grade = resolved.library.makeFunction(name: "gradeStillTileBGRA"),
              let composite = resolved.library.makeFunction(name: "effectCompositeTile") else {
            throw GradeLabError.rendererInitializationFailed
        }
        gradePipeline = try resolved.device.makeComputePipelineState(function: grade)
        compositePipeline = try resolved.device.makeComputePipelineState(function: composite)
        effects = FilmEffectsStage(context: resolved)
    }

    /// Renders and writes the graded picture.
    ///
    /// - Parameter progress: 0...1, called on an arbitrary queue.
    func export(
        project: ImageProject,
        configuration: ImageExportConfiguration,
        destinationDirectory: URL = FileManager.default.temporaryDirectory,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Output {
        let grade = project.gradeSettings
        let source = try autoreleasepool {
            try ImageDecoder.decode(url: project.sourceURL, maximumLongEdge: nil)
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { throw GradeLabError.unableToReadImage }
        progress?(0.05)

        // Look and curve tables: the same caches the preview reads, so the
        // exported picture is produced from the identical data.
        let advanced = grade.advanced ?? .neutral
        if let identifier = advanced.lut { _ = context.luts.prepare(identifier) }
        guard let lut = context.luts.texture(for: advanced.lut),
              let curves = context.curves.texture(for: advanced.resolvedCurves) else {
            throw GradeLabError.imageExportFailed(String(localized: "The look or curve tables could not be prepared."))
        }

        var uniforms = GradeUniforms(settings: grade, bypass: false)
        // Grain seed stays at zero. The preview's frame source reports a fixed
        // presentation time for a still, so this is the same pattern that was on
        // screen rather than one taken from whenever the export happened to run.
        let effectsActive = FilmEffectsStage.isActive(uniforms)
        let imageSize = CGSize(width: width, height: height)

        // The whole-image halo, built once. Present whenever the spatial stage
        // runs at all: a sharpen-only export still has to bind something at the
        // halo texture, and a zero-sized stand-in contributes nothing because
        // every glow amount is zero in that case.
        let halo: MTLTexture? = try effectsActive
            ? makeHalo(sourceURL: project.sourceURL, source: source, imageSize: imageSize,
                       uniforms: uniforms, lut: lut, curves: curves)
            : nil
        if effectsActive, halo == nil {
            throw GradeLabError.imageExportFailed(String(localized: "The finishing effects could not be prepared."))
        }
        progress?(0.15)

        // The finished picture is assembled straight into one allocation that
        // is later handed to ImageIO without being copied. At 48 megapixels a
        // copy would be another 195 MB for nothing.
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let destination = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<UInt32>.alignment)
        destination.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        var handedOff = false
        defer { if !handedOff { destination.deallocate() } }

        let padding = Self.tilePadding(for: imageSize)
        let padded = paddedTileSize(imageWidth: width, imageHeight: height, padding: padding)
        let tiles = tileGrid(imageWidth: width, imageHeight: height)
        guard let surfaces = makeTileSurfaces(size: padded, effectsActive: effectsActive) else {
            throw GradeLabError.imageTooLarge
        }

        for (index, tile) in tiles.enumerated() {
            // A cancelled export stops between tiles rather than finishing a
            // picture nobody is waiting for.
            try Task.checkCancellation()
            try autoreleasepool {
                try renderTile(
                    tile, padded: padded, padding: padding, imageSize: imageSize,
                    source: source, surfaces: surfaces, halo: halo,
                    uniforms: &uniforms, lut: lut, curves: curves,
                    effectsActive: effectsActive,
                    into: destination, bytesPerRow: bytesPerRow)
            }
            progress?(0.15 + 0.75 * Double(index + 1) / Double(max(tiles.count, 1)))
        }

        // The provider takes ownership of the buffer the moment it is created,
        // and frees it when the image is released. Ownership therefore has to
        // transfer here, not after the file is written: if the encode failed
        // after the provider existed, the deferred cleanup below would free a
        // buffer the provider had already freed.
        guard let provider = CGDataProvider(
            dataInfo: nil, data: destination, size: byteCount,
            releaseData: { _, pointer, _ in
                UnsafeMutableRawPointer(mutating: pointer).deallocate()
            }) else {
            throw GradeLabError.imageExportFailed(String(localized: "The graded pixels could not be assembled."))
        }
        handedOff = true

        let url = try write(
            provider: provider, width: width, height: height,
            bytesPerRow: bytesPerRow, configuration: configuration,
            project: project, directory: destinationDirectory)
        progress?(1)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return Output(url: url, width: width, height: height,
                      format: configuration.format, byteCount: size)
    }

    // MARK: - Tiling

    /// Output rectangles, in image pixels.
    private func tileGrid(imageWidth: Int, imageHeight: Int) -> [(x: Int, y: Int, width: Int, height: Int)] {
        var tiles: [(Int, Int, Int, Int)] = []
        var y = 0
        while y < imageHeight {
            let h = min(Self.tileSide, imageHeight - y)
            var x = 0
            while x < imageWidth {
                let w = min(Self.tileSide, imageWidth - x)
                tiles.append((x, y, w, h))
                x += Self.tileSide
            }
            y += Self.tileSide
        }
        return tiles
    }

    /// Every padded tile is the same size, so the working surfaces are allocated
    /// once and reused. An edge tile keeps the full padded window and simply
    /// sits further into it, rather than shrinking and forcing a reallocation.
    private func paddedTileSize(imageWidth: Int, imageHeight: Int, padding: Int)
        -> (width: Int, height: Int) {
        (min(imageWidth, Self.tileSide + padding * 2),
         min(imageHeight, Self.tileSide + padding * 2))
    }

    private struct TileSurfaces {
        let source: MTLTexture
        /// Only allocated when a spatial effect needs a surface to read
        /// neighbours from.
        let graded: MTLTexture?
        let output: MTLTexture
    }

    private func makeTileSurfaces(size: (width: Int, height: Int), effectsActive: Bool) -> TileSurfaces? {
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage, _ storage: MTLStorageMode) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = usage
            descriptor.storageMode = storage
            return context.device.makeTexture(descriptor: descriptor)
        }
        guard let source = texture(.bgra8Unorm, [.shaderRead], .shared),
              let output = texture(.bgra8Unorm, [.shaderWrite, .shaderRead], .shared) else { return nil }
        var graded: MTLTexture?
        if effectsActive {
            guard let surface = texture(.rgba16Float, [.shaderRead, .shaderWrite], .private) else { return nil }
            graded = surface
        }
        return TileSurfaces(source: source, graded: graded, output: output)
    }

    private func renderTile(
        _ tile: (x: Int, y: Int, width: Int, height: Int),
        padded: (width: Int, height: Int),
        padding: Int,
        imageSize: CGSize,
        source: CVPixelBuffer,
        surfaces: TileSurfaces,
        halo: MTLTexture?,
        uniforms: inout GradeUniforms,
        lut: MTLTexture,
        curves: MTLTexture,
        effectsActive: Bool,
        into destination: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) throws {
        let imageWidth = Int(imageSize.width), imageHeight = Int(imageSize.height)
        // The padded window, clamped so it always lies inside the picture and
        // always has the same size.
        let originX = min(max(tile.x - padding, 0), max(0, imageWidth - padded.width))
        let originY = min(max(tile.y - padding, 0), max(0, imageHeight - padded.height))
        // Where the output rectangle sits inside that window.
        let cropX = tile.x - originX
        let cropY = tile.y - originY

        upload(source, into: surfaces.source, originX: originX, originY: originY,
               width: padded.width, height: padded.height)

        guard let command = context.commandQueue.makeCommandBuffer() else {
            throw GradeLabError.imageExportFailed(String(localized: "The GPU could not accept the export."))
        }
        command.label = "GradeLab still tile \(tile.x),\(tile.y)"

        // Grading. `tileInfo` is what makes the vignette, the grain and every
        // other frame-absolute stage see the whole picture rather than this tile.
        var tileInfo = SIMD4<Float>(Float(originX), Float(originY),
                                    Float(imageWidth), Float(imageHeight))
        let gradeTarget = effectsActive ? (surfaces.graded ?? surfaces.output) : surfaces.output
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.imageExportFailed(String(localized: "The GPU could not accept the export."))
        }
        encoder.setComputePipelineState(gradePipeline)
        encoder.setTexture(surfaces.source, index: 0)
        encoder.setTexture(gradeTarget, index: 2)
        encoder.setTexture(lut, index: 3)
        encoder.setTexture(curves, index: 6)
        encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        encoder.setBytes(&tileInfo, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        // Stills carry no masked local grades yet, but the grading kernels all
        // declare the stack, so every dispatch has to populate it.
        LocalGradeStack.empty.bind(encoder)
        dispatch(encoder, pipeline: gradePipeline, width: padded.width, height: padded.height)
        encoder.endEncoding()

        if effectsActive, let graded = surfaces.graded, let halo {
            var effectUniforms = FilmEffectsStage.uniforms(
                uniforms, size: (padded.width, padded.height), workingSpace: false)
            // The unsharp mask's radius is a fixed fraction of the picture, not
            // one output pixel, so the preview and this file are sharpened
            // identically instead of the export looking softer at a glance.
            effectUniforms.step = StillEffectGeometry.sharpenStep(
                imageSize: imageSize,
                surfaceSize: CGSize(width: padded.width, height: padded.height))
            guard let composite = command.makeComputeCommandEncoder() else {
                throw GradeLabError.imageExportFailed(String(localized: "The GPU could not accept the export."))
            }
            composite.setComputePipelineState(compositePipeline)
            composite.setTexture(graded, index: 0)
            composite.setTexture(halo, index: 1)
            composite.setTexture(surfaces.output, index: 2)
            composite.setBytes(&effectUniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            composite.setBytes(&tileInfo, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            dispatch(composite, pipeline: compositePipeline, width: padded.width, height: padded.height)
            composite.endEncoding()
        }

        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw GradeLabError.imageExportFailed(String(localized: "A tile of the image could not be rendered."))
        }

        // Read back only the central rectangle, straight into its place in the
        // finished picture. The padding, which is where a spatial effect would
        // have run out of neighbours, is discarded.
        let offset = tile.y * bytesPerRow + tile.x * 4
        surfaces.output.getBytes(
            destination.advanced(by: offset),
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(cropX, cropY, tile.width, tile.height),
            mipmapLevel: 0)
    }

    /// Copies one padded window out of the decoded picture and into the tile's
    /// source texture.
    private func upload(
        _ buffer: CVPixelBuffer, into texture: MTLTexture,
        originX: Int, originY: Int, width: Int, height: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let start = base.advanced(by: originY * stride + originX * 4)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: start,
            bytesPerRow: stride)
    }

    // MARK: - The whole-image halo

    /// Grades a reference-sized copy of the picture and blurs it, once.
    ///
    /// This is the single most important reason the tiles have no seams: no tile
    /// ever blurs anything. It also pins the glow radius to a fraction of the
    /// photograph, and to exactly the fraction the preview uses, because both are
    /// built at `StillEffectGeometry.blurLongEdge` from a copy at
    /// `StillEffectGeometry.referenceLongEdge`.
    private func makeHalo(
        sourceURL: URL, source: CVPixelBuffer, imageSize: CGSize, uniforms: GradeUniforms,
        lut: MTLTexture, curves: MTLTexture
    ) throws -> MTLTexture? {
        guard let effects else { return nil }
        // Sharpening alone needs no blur, but the composite kernel still has to
        // have a texture bound at every slot it declares. Every glow amount is
        // zero here, so nothing is read from it.
        guard uniforms.effectsB.x > 0 || uniforms.effectsB.y > 0 || uniforms.effectsB.z > 0 else {
            return emptyHalo()
        }
        let reference = StillEffectGeometry.referenceSize(for: imageSize)
        let width = Int(reference.width), height = Int(reference.height)

        // The reference copy is produced by Metal from the full-resolution
        // decode, not by a second decode, so it is the same pixels the tiles see.
        guard let full = context.packedTexture(from: source, pixelFormat: .bgra8Unorm) else {
            // The picture is larger than the device's texture limit. The halo
            // falls back to a decode at reference size, which is the same
            // picture at the same resolution.
            return try haloFromSecondDecode(sourceURL: sourceURL, imageSize: imageSize,
                                            uniforms: uniforms, lut: lut, curves: curves)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let graded = context.device.makeTexture(descriptor: descriptor),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        command.label = "GradeLab still halo"
        var grade = uniforms
        // Sampled rather than read, so the reference copy is a filtered
        // downsample of the whole picture.
        encoder.setComputePipelineState(downsampleGradePipeline)
        encoder.setTexture(full.texture, index: 0)
        encoder.setTexture(graded, index: 2)
        encoder.setTexture(lut, index: 3)
        encoder.setTexture(curves, index: 6)
        encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        LocalGradeStack.empty.bind(encoder)
        dispatch(encoder, pipeline: downsampleGradePipeline, width: width, height: height)
        encoder.endEncoding()
        let halo = effects.encodeBlur(source: graded, grade: uniforms, workingSpace: false,
                                      blurLongEdge: StillEffectGeometry.blurLongEdge, into: command)
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(full.reference) {}
        guard command.status == .completed else {
            throw GradeLabError.imageExportFailed(String(localized: "The finishing effects could not be prepared."))
        }
        return halo
    }

    /// For pictures wider or taller than the device's maximum texture: decode a
    /// reference-sized copy instead of downsampling the full one on the GPU.
    private func haloFromSecondDecode(
        sourceURL url: URL, imageSize: CGSize, uniforms: GradeUniforms,
        lut: MTLTexture, curves: MTLTexture
    ) throws -> MTLTexture? {
        guard let effects else { return nil }
        let reference = StillEffectGeometry.referenceSize(for: imageSize)
        let buffer = try ImageDecoder.decode(url: url, maximumLongEdge: Int(max(reference.width, reference.height)))
        guard let packed = context.packedTexture(from: buffer, pixelFormat: .bgra8Unorm) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: packed.texture.width, height: packed.texture.height,
            mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let graded = context.device.makeTexture(descriptor: descriptor),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var grade = uniforms
        encoder.setComputePipelineState(downsampleGradePipeline)
        encoder.setTexture(packed.texture, index: 0)
        encoder.setTexture(graded, index: 2)
        encoder.setTexture(lut, index: 3)
        encoder.setTexture(curves, index: 6)
        encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        LocalGradeStack.empty.bind(encoder)
        dispatch(encoder, pipeline: downsampleGradePipeline, width: graded.width, height: graded.height)
        encoder.endEncoding()
        let halo = effects.encodeBlur(source: graded, grade: uniforms, workingSpace: false,
                                      blurLongEdge: StillEffectGeometry.blurLongEdge, into: command)
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(packed.reference) {}
        return command.status == .completed ? halo : nil
    }

    /// A 1×1 black texture, for the case where the spatial stage runs but no
    /// glow is switched on.
    private func emptyHalo() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        var zero = SIMD4<UInt16>(0, 0, 0, 0)
        withUnsafeBytes(of: &zero) { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: 8)
        }
        return texture
    }

    /// `gradeToTextureBGRA`, which samples rather than reads and so doubles as
    /// the downsampler for the halo's reference copy. The same shared grading
    /// function, at a different resolution.
    private lazy var downsampleGradePipeline: MTLComputePipelineState = {
        // Built eagerly in `init` terms: a failure here would already have
        // failed the two pipelines above, which come from the same library.
        guard let function = context.library.makeFunction(name: "gradeToTextureBGRA"),
              let state = try? context.device.makeComputePipelineState(function: function) else {
            preconditionFailure("gradeToTextureBGRA is part of the shipped Metal library")
        }
        return state
    }()

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
        width: Int, height: Int
    ) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchThreads(
            MTLSize(width: max(1, width), height: max(1, height), depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }

    // MARK: - Encoding

    /// Writes the finished pixels through ImageIO.
    ///
    /// The colour space written is the one the picture was graded in, so a
    /// viewer that honours profiles shows what was on screen. Orientation is
    /// written as 1 because the decode already applied it — the file is upright,
    /// and claiming otherwise would rotate it twice.
    private func write(
        provider: CGDataProvider, width: Int, height: Int,
        bytesPerRow: Int, configuration: ImageExportConfiguration,
        project: ImageProject, directory: URL
    ) throws -> URL {
        guard let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: ImageDecoder.workingColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw GradeLabError.imageExportFailed(String(localized: "The graded pixels could not be assembled."))
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = ExportFileName.sanitized(project.displayName)
        let url = directory
            .appendingPathComponent("\(name)-graded-\(UUID().uuidString.prefix(6))")
            .appendingPathExtension(configuration.format.fileExtension)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, configuration.format.utType.identifier as CFString, 1, nil) else {
            throw GradeLabError.imageExportFailed(String(localized: "\(configuration.format.title) cannot be written on this device."))
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1
        ]
        if configuration.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] =
                min(max(configuration.quality, 0), 1)
        }
        // Capture metadata is carried; location is not. That matches what the
        // video export writes, and this is not the place to decide a new
        // privacy policy for the app.
        if let carried = carriedMetadata(from: project.sourceURL) {
            properties.merge(carried) { current, _ in current }
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw GradeLabError.imageExportFailed(String(localized: "The image could not be written."))
        }
        return url
    }

    /// The metadata worth carrying: what the camera was and how it was set.
    ///
    /// GPS is deliberately absent. The video export writes no source metadata at
    /// all, so carrying a photograph's location out of the app would be a new
    /// decision about someone's privacy taken inside a colour-grading feature.
    private func carriedMetadata(from url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        var carried: [CFString: Any] = [:]
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            // The stored orientation is rewritten, never copied: the pixels are
            // already upright.
            tiff[kCGImagePropertyTIFFOrientation] = 1
            carried[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            carried[kCGImagePropertyExifDictionary] = exif
        }
        return carried.isEmpty ? nil : carried
    }
}

/// Turns a project name into something safe to put on disk.
enum ExportFileName {
    static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "GradeLab" : String(trimmed.prefix(48))
    }
}
