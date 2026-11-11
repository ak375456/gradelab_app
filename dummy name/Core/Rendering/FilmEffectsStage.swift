@preconcurrency import Metal
import CoreGraphics
import Foundation
import simd

/// Uniforms for the spatial effects. Matches `EffectUniforms` in EffectShaders.metal.
struct EffectUniforms: Sendable {
    var sharpness: Float = 0
    var bloom: Float = 0
    var glow: Float = 0
    var halation: Float = 0
    var bloomThreshold: Float = 0.62
    var extendedRange: Float = 0
    var step: SIMD2<Float> = .zero
    var clarity: Float = 0

    var needsGlow: Bool { bloom > 0 || glow > 0 || halation > 0 }
}

/// Spatial finishing effects applied to a graded frame.
///
/// One instance serves every path that needs it — preview, export and both
/// compositors — so the effects cannot look different in the exported file than
/// they did on screen. It caches blur textures, which are rebuilt
/// when the frame size changes and released when nothing is using them.
///
/// It never runs unless something asks for it: `GradeSettings` with no effects
/// leaves every path on its existing single-pass route.
final class FilmEffectsStage: @unchecked Sendable {
    /// The blur runs at a quarter of each edge. A glow is low-frequency by
    /// definition, so this is invisible in the result and sixteen times cheaper.
    static let blurDivisor = 4
    /// Two Gaussian pairs. One is too tight to read as a halo at this
    /// resolution; more than two costs passes for a difference nobody sees.
    static let blurIterations = 2
    /// A fixed long edge gives Clarity the same radius relative to the image
    /// in a smaller preview and a full-resolution export.
    static let clarityBlurLongEdge = StillEffectGeometry.blurLongEdge

    private let context: MetalContext
    private let prepare: MTLComputePipelineState
    private let blur: MTLComputePipelineState
    private let composite: MTLComputePipelineState
    private let lock = NSLock()
    private var blurTextures: (MTLTexture, MTLTexture)?
    private var clarityTextures: (MTLTexture, MTLTexture)?

    init?(context: MetalContext) {
        self.context = context
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = context.library.makeFunction(name: name) else { return nil }
            return try? context.device.makeComputePipelineState(function: function)
        }
        guard let prepare = pipeline("effectPrepare"),
              let blur = pipeline("effectBlur"),
              let composite = pipeline("effectComposite") else { return nil }
        self.prepare = prepare
        self.blur = blur
        self.composite = composite
    }

    /// Effect amounts from a clip's grade, as the shader wants them.
    ///
    /// `workingSpace` is true for HDR, where values run above diffuse white and
    /// the result must not be clamped.
    static func uniforms(_ grade: GradeUniforms, size: (width: Int, height: Int),
                         workingSpace: Bool) -> EffectUniforms {
        EffectUniforms(
            sharpness: grade.effectsA.z,
            bloom: grade.effectsB.x,
            glow: grade.effectsB.y,
            halation: grade.effectsB.z,
            bloomThreshold: 0.62,
            extendedRange: workingSpace ? 1 : 0,
            step: SIMD2(1 / Float(max(size.width, 1)), 1 / Float(max(size.height, 1))),
            clarity: grade.effectsB.w)
    }

    /// True when the stage would change anything.
    static func isActive(_ grade: GradeUniforms) -> Bool {
        grade.effectsA.z > 0 || grade.effectsB != .zero
    }

    func releaseResources() {
        lock.lock()
        blurTextures = nil
        clarityTextures = nil
        lock.unlock()
    }

    /// The size the blur pyramid is built at.
    ///
    /// `longEdge` nil is video's rule and is left exactly as it was: a quarter of
    /// each edge of whatever surface is being processed. A still passes an
    /// explicit long edge instead, because its blur has to mean the same thing
    /// in a phone-sized preview and in a full-resolution export — the reach of
    /// the Gaussian is a fixed number of blur texels, so pinning the blur's size
    /// is what pins the radius as a fraction of the picture.
    static func blurSize(width: Int, height: Int, longEdge: Int?) -> (width: Int, height: Int) {
        guard let longEdge, longEdge > 0, width > 0, height > 0 else {
            return (max(1, width / blurDivisor), max(1, height / blurDivisor))
        }
        let scale = Double(longEdge) / Double(max(width, height))
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    /// Builds the blur pyramid over a whole graded frame and hands it back.
    ///
    /// Used by the still-image export, which grades the full picture in tiles but
    /// must not blur it in tiles: a per-tile halo would stop at the tile's edge
    /// and its radius would shrink as the export grew. The halo is built once,
    /// over the whole image, and every tile composites against it.
    ///
    /// The textures are allocated here and returned rather than cached, so this
    /// never disturbs the pair `encode` is reusing for the tiles.
    func encodeBlur(
        source: MTLTexture,
        grade: GradeUniforms,
        workingSpace: Bool,
        blurLongEdge: Int,
        into command: MTLCommandBuffer
    ) -> MTLTexture? {
        let size = Self.blurSize(width: source.width, height: source.height, longEdge: blurLongEdge)
        let uniforms = Self.uniforms(grade, size: (source.width, source.height), workingSpace: workingSpace)
        guard let pair = makeTextures(width: size.width, height: size.height) else { return nil }
        return encodeBlur(source: source, pair: pair, uniforms: uniforms, into: command)
    }

    private func encodeBlur(
        source: MTLTexture,
        pair: (MTLTexture, MTLTexture),
        uniforms: EffectUniforms,
        into command: MTLCommandBuffer
    ) -> MTLTexture? {
        let (first, second) = pair
        let width = first.width, height = first.height
        var blurUniforms = uniforms
        blurUniforms.step = SIMD2(1 / Float(width), 1 / Float(height))
        guard let seedEncoder = command.makeComputeCommandEncoder() else { return nil }
        seedEncoder.setComputePipelineState(prepare)
        seedEncoder.setTexture(source, index: 0)
        seedEncoder.setTexture(first, index: 1)
        seedEncoder.setBytes(&blurUniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        Self.dispatch(seedEncoder, pipeline: prepare, width: width, height: height)
        seedEncoder.endEncoding()

        var read = first, write = second
        for _ in 0..<Self.blurIterations {
            for direction in [SIMD2<Float>(1, 0), SIMD2<Float>(0, 1)] {
                var direction = direction
                guard let encoder = command.makeComputeCommandEncoder() else { return nil }
                encoder.setComputePipelineState(blur)
                encoder.setTexture(read, index: 0)
                encoder.setTexture(write, index: 1)
                encoder.setBytes(&blurUniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
                encoder.setBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                Self.dispatch(encoder, pipeline: blur, width: width, height: height)
                encoder.endEncoding()
                swap(&read, &write)
            }
        }
        return read
    }

    private func textures(width: Int, height: Int, forClarity: Bool = false) -> (MTLTexture, MTLTexture)? {
        lock.lock(); defer { lock.unlock() }
        if let existing = forClarity ? clarityTextures : blurTextures,
           existing.0.width == width, existing.0.height == height {
            return existing
        }
        guard let pair = makeTextures(width: width, height: height) else { return nil }
        if forClarity { clarityTextures = pair } else { blurTextures = pair }
        return pair
    }

    private func makeTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let first = context.device.makeTexture(descriptor: descriptor),
              let second = context.device.makeTexture(descriptor: descriptor) else { return nil }
        return (first, second)
    }

    /// Encodes the stage into `command`. Nothing is committed and nothing is
    /// waited on: the caller owns the command buffer, so this can sit inside a
    /// pass that is already being built.
    @discardableResult
    func encode(
        source: MTLTexture,
        destination: MTLTexture,
        grade: GradeUniforms,
        workingSpace: Bool,
        blurLongEdge: Int? = nil,
        into command: MTLCommandBuffer
    ) -> Bool {
        var uniforms = Self.uniforms(
            grade, size: (source.width, source.height), workingSpace: workingSpace)
        var halo: MTLTexture?
        if uniforms.needsGlow {
            let size = Self.blurSize(width: source.width, height: source.height, longEdge: blurLongEdge)
            guard let pair = textures(width: size.width, height: size.height),
                  let blurred = encodeBlur(source: source, pair: pair, uniforms: uniforms,
                                           into: command) else { return false }
            halo = blurred
        }

        var clarityBase: MTLTexture?
        if uniforms.clarity > 0 {
            let size = Self.blurSize(width: source.width, height: source.height,
                                     longEdge: Self.clarityBlurLongEdge)
            if let halo, halo.width == size.width, halo.height == size.height {
                clarityBase = halo
            } else {
                guard let pair = textures(width: size.width, height: size.height, forClarity: true),
                      let blurred = encodeBlur(source: source, pair: pair, uniforms: uniforms,
                                               into: command) else { return false }
                clarityBase = blurred
            }
        }

        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(composite)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(halo ?? source, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.setTexture(clarityBase ?? source, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        Self.dispatch(encoder, pipeline: composite, width: destination.width, height: destination.height)
        encoder.endEncoding()
        return true
    }

    private static func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchPreviewThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }
}


/// How the spatial finishing effects are sized for a still image.
///
/// Video renders them at whatever surface is in front of it, which is fine
/// because a frame is remade sixty times a second and only ever seen at one
/// size. A photograph is seen at two very different sizes — a preview a few
/// hundred points wide and an export that may be 48 megapixels — and the same
/// grade has to produce the same picture in both.
///
/// So the still path fixes two numbers instead of deriving them from the
/// surface: the effects run over a reference-sized copy of the picture, and the
/// blur is built at a fixed long edge. The Gaussian's reach is a fixed number of
/// blur texels, so a fixed blur size makes the glow a fixed fraction of the
/// photograph at any output resolution — which is exactly what stops a
/// full-resolution export from getting a halo four times tighter than the one
/// that was judged on screen.
enum StillEffectGeometry {
    /// Long edge of the surface the effects are composed over. Also the size the
    /// export's whole-image halo is built from, so preview and export blur the
    /// same picture at the same resolution.
    static let referenceLongEdge = 2048
    /// Long edge of the blur pyramid.
    static let blurLongEdge = 512

    /// `image` fitted inside the reference long edge, never enlarged.
    static func referenceSize(for image: CGSize) -> CGSize {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(1, CGFloat(referenceLongEdge) / longest)
        return CGSize(width: max(1, (image.width * scale).rounded()),
                      height: max(1, (image.height * scale).rounded()))
    }

    /// The unsharp mask's radius, as a fraction of the picture rather than a
    /// pixel count.
    ///
    /// Sharpening is the one spatial effect whose radius is naturally in real
    /// pixels, and leaving it there would mean the preview and the exported file
    /// were sharpened differently — the preview by one of its own pixels, the
    /// export by one of a great many more. Preview and export matching is worth
    /// more here than a one-pixel radius is, so the radius is one texel of the
    /// reference size in both, which is a fixed fraction of the image.
    static func sharpenStep(imageSize: CGSize, surfaceSize: CGSize) -> SIMD2<Float> {
        let reference = referenceSize(for: imageSize)
        let x = Float(imageSize.width / max(reference.width, 1)) / Float(max(surfaceSize.width, 1))
        let y = Float(imageSize.height / max(reference.height, 1)) / Float(max(surfaceSize.height, 1))
        return SIMD2(x.isFinite ? x : 0, y.isFinite ? y : 0)
    }
}
