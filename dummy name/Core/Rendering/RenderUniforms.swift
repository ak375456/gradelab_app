import CoreGraphics
import CoreVideo
import simd

/// ABI-matched with `TransitionUniforms` in Shaders.metal. One cached pipeline
/// dispatches all authored transition types; the integer selects inexpensive
/// shader-side branches while progress remains deterministic for scrub/export.
struct TransitionUniforms: Sendable {
    var type: UInt32
    var progress: Float
    var aspectRatio: Float
    var padding: Float = 0

    init(_ transition: TimelineTransition, progress: Float, size: CGSize) {
        type = UInt32(transition.type.rawValue)
        self.progress = min(1, max(0, progress))
        aspectRatio = Float(size.width / max(1, size.height))
    }
}

/// Parameters for the HDR display path. Separate from `GradeUniforms` on
/// purpose: that struct's layout is shared byte-for-byte with the SDR shader
/// (`Scripts/ValidateGrade.swift` asserts the two sides agree), and widening it
/// would change the SDR path this work must leave alone.
struct HDRDisplayUniforms: Sendable {
    var params: SIMD4<Float>
    var transfer: SIMD4<Float>

    /// The HDR transform carries no display-dependent term any more: the drawable
    /// is HLG-tagged and the system applies the OOTF and the display's own tone
    /// mapping. Headroom is still read, but only to label the preview honestly.
    init() {
        params = SIMD4(
            Float(1.0 / HDRColorSpace.referenceWhiteSceneLight),
            Float(HDRColorSpace.referenceWhiteSceneLight),
            Float(HDRColorSpace.peakInWorkingSpace),
            0
        )
        transfer = .zero
    }
}

struct GradeUniforms: Sendable {
    // Layout intentionally uses SIMD4 exclusively so Swift and Metal stay 16-byte aligned.
    var lightA: SIMD4<Float>
    var lightB: SIMD4<Float>
    var color: SIMD4<Float>
    var options: SIMD4<Float>
    /// center x/y and width/height, all normalised to the source frame.
    /// These reuse two retired curve slots, preserving the shared 352-byte ABI.
    var gradeMaskA: SIMD4<Float>
    /// rotation in radians, feather, opacity, and packed shape/invert flags.
    /// opacity is -1 when the mask is disabled, meaning a full-frame grade.
    var gradeMaskB: SIMD4<Float>
    var reservedC: SIMD4<Float>
    var reservedD: SIMD4<Float>
    var hsl0: SIMD4<Float>
    var hsl1: SIMD4<Float>
    var hsl2: SIMD4<Float>
    var hsl3: SIMD4<Float>
    var hsl4: SIMD4<Float>
    var hsl5: SIMD4<Float>
    var hsl6: SIMD4<Float>
    var hsl7: SIMD4<Float>
    var shadowWheel: SIMD4<Float>
    var midtoneWheel: SIMD4<Float>
    var highlightWheel: SIMD4<Float>
    var vignette: SIMD4<Float>
    /// fade, grain, sharpen, grain seed
    var effectsA: SIMD4<Float>
    /// bloom, glow, halation, spare
    var effectsB: SIMD4<Float>

    /// Grain has to move, or it reads as dirt on the lens rather than as film.
    /// The seed comes from the frame's presentation time so preview and export
    /// produce the same pattern for the same frame.
    mutating func setGrainSeed(_ seconds: Double) {
        effectsA.w = Float((seconds * 60).truncatingRemainder(dividingBy: 4096))
    }

    init(settings: GradeSettings, bypass: Bool) {
        lightA = SIMD4(
            settings.exposure,
            settings.contrast / 100,
            settings.highlights / 100,
            settings.shadows / 100
        )
        lightB = SIMD4(settings.whites / 100, settings.blacks / 100, 0, 0)
        color = SIMD4(
            settings.temperature / 100,
            settings.tint / 100,
            settings.saturation / 100,
            settings.vibrance / 100
        )
        let advanced = settings.advanced ?? .neutral
        // options.y is the creative-LUT strength, 0...1. It reuses a slot that
        // was already reserved, so the uniform layout and stride are unchanged.
        // options.z is the curve mask: one bit per curve that changes a pixel,
        // carried as a float because the block is all float4. Ten bits is far
        // inside the 24 a float represents exactly.
        options = SIMD4(
            bypass ? 1 : 0,
            advanced.lutStrength / 100,
            bypass ? 0 : Float(advanced.curveMask),
            0
        )
        let effects = bypass ? FilmEffects.neutral : advanced.resolvedEffects
        effectsA = SIMD4(effects.fade / 100, effects.grain / 100, effects.sharpness / 100, 0)
        effectsB = SIMD4(effects.bloom / 100, effects.glow / 100, effects.halation / 100, 0)
        func band(_ i: Int) -> SIMD4<Float> {
            let b = advanced.band(i)
            return SIMD4(b.hue / 360, b.saturation / 100, b.luminance / 100, HueBand.centers[i] / 360)
        }
        func wheel(_ i: Int) -> SIMD4<Float> {
            let w = advanced.wheel(i)
            return SIMD4(w.hue / 360, w.strength / 100, w.brightness / 100, 0)
        }
        let mask = advanced.resolvedMask
        gradeMaskA = SIMD4(mask.centerX / 100, mask.centerY / 100,
                           mask.width / 100, mask.height / 100)
        let flags: Float = (mask.shape == .rectangle ? 1 : 0) + (mask.isInverted ? 4 : 0)
        gradeMaskB = SIMD4(mask.rotation * .pi / 180, mask.feather / 100,
                           mask.isEnabled ? mask.opacity / 100 : -1, flags)
        reservedC = .zero; reservedD = .zero
        hsl0 = band(0); hsl1 = band(1); hsl2 = band(2); hsl3 = band(3)
        hsl4 = band(4); hsl5 = band(5); hsl6 = band(6); hsl7 = band(7)
        shadowWheel = wheel(0); midtoneWheel = wheel(1); highlightWheel = wheel(2)
        vignette = SIMD4(advanced.vignette / 100, advanced.vignetteMidpoint / 100, advanced.vignetteFeather / 100, 0)
    }
}

struct YUVUniforms: Sendable {
    var column0: SIMD4<Float>
    var column1: SIMD4<Float>
    var column2: SIMD4<Float>
    var offset: SIMD4<Float>

    static func make(for pixelBuffer: CVPixelBuffer, fallbackMatrix: String?) -> YUVUniforms {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isFullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        let isTenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange

        let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            nil
        )
        let matrixName = attachment.map(String.init(describing:)) ?? fallbackMatrix ?? "BT.709"

        let coefficients: (red: Float, blue: Float)
        if matrixName.contains("2020") {
            coefficients = (0.2627, 0.0593)
        } else if matrixName.contains("601") {
            coefficients = (0.299, 0.114)
        } else {
            coefficients = (0.2126, 0.0722)
        }

        let red = coefficients.red
        let blue = coefficients.blue
        let green = 1 - red - blue
        let componentMaximum: Float = isTenBit ? 1023 : 255
        let lumaBlackCode: Float = isTenBit ? 64 : 16
        let lumaVideoRange: Float = isTenBit ? 876 : 219
        let chromaNeutralCode: Float = isTenBit ? 512 : 128
        let chromaVideoRange: Float = isTenBit ? 896 : 224
        let yScale: Float = isFullRange ? 1 : componentMaximum / lumaVideoRange
        let chromaScale: Float = isFullRange ? 1 : componentMaximum / chromaVideoRange
        let redV = 2 * (1 - red) * chromaScale
        let blueU = 2 * (1 - blue) * chromaScale
        let greenU = -2 * blue * (1 - blue) / green * chromaScale
        let greenV = -2 * red * (1 - red) / green * chromaScale
        let yOffset: Float = isFullRange ? 0 : -(lumaBlackCode / componentMaximum)
        let chromaOffset = -(chromaNeutralCode / componentMaximum)

        var result = YUVUniforms(
            column0: SIMD4(yScale, yScale, yScale, 0),
            column1: SIMD4(0, greenU, blueU, 0),
            column2: SIMD4(redV, greenV, 0, 0),
            offset: SIMD4(yOffset, chromaOffset, chromaOffset, 0)
        )
        if isTenBit {
            // CV's 10-bit planes are left-aligned in r16Unorm. Correct the
            // texture normalisation before applying code-range offsets; using
            // 8-bit/video-range rules here brightens SDR overlays on Log.
            let unpack: Float = 65535.0 / 65472.0
            result.column0 *= unpack; result.column1 *= unpack; result.column2 *= unpack
            result.offset /= unpack
        }
        return result
    }
}

/// One layer's placement and mixing parameters for the HDR compositor.
///
/// The transform is stored as the canvas-pixel → source-uv mapping the kernel
/// needs, derived from the very same `CGAffineTransform` the SDR compositor
/// hands Core Image, so the two paths cannot put a layer in different places.
struct HDRLayerUniforms: Sendable {
    // SIMD4 rows for the same reason `YUVUniforms` uses them: Swift and Metal
    // then agree on alignment without a packed attribute.
    var row0: SIMD4<Float>
    var row1: SIMD4<Float>
    var params: SIMD4<Float>
    /// Track matte parameters. `x` is 1 when coverage is `1 - sourceAlpha`
    /// rather than `sourceAlpha`; the remaining three are spare, and are where
    /// the luma readings will go rather than a fourth vector.
    var matte: SIMD4<Float>

    /// - Parameters:
    ///   - transform: source → canvas, in Core Image's bottom-left coordinates.
    ///   - sourceSize: the source texture's pixel size.
    ///   - canvasSize: the render canvas' pixel size.
    ///   - matteInverted: whether this layer's track matte keeps it where the
    ///     matte source is transparent rather than where it is opaque.
    init(
        transform: CGAffineTransform,
        sourceSize: CGSize,
        canvasSize: CGSize,
        opacity: Double,
        blendAmount: Double = 0,
        sourceIsSDR: Bool = false,
        premultiplied: Bool = false,
        matteInverted: Bool = false
    ) {
        // Canvas pixel (top-left origin) → Core Image canvas point → source
        // point → normalised source coordinate with the row order flipped back.
        let toCanvasPoints = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvasSize.height)
        let toSourcePoints = transform.inverted()
        let toNormalized = CGAffineTransform(
            a: 1 / max(sourceSize.width, 1), b: 0,
            c: 0, d: -1 / max(sourceSize.height, 1),
            tx: 0, ty: 1
        )
        let m = toCanvasPoints.concatenating(toSourcePoints).concatenating(toNormalized)
        row0 = SIMD4(Float(m.a), Float(m.c), Float(m.tx), 0)
        row1 = SIMD4(Float(m.b), Float(m.d), Float(m.ty), 0)
        params = SIMD4(
            Float(min(max(opacity, 0), 1)),
            Float(min(max(blendAmount, 0), 1)),
            sourceIsSDR ? 1 : 0,
            premultiplied ? 1 : 0
        )
        matte = SIMD4(matteInverted ? 1 : 0, 0, 0, 0)
    }
}

/// Geometry shared by the SDR alpha pass and the HDR compositor. Two aligned
/// vectors keep the Swift/Metal layout unambiguous.
struct LayerMaskUniforms: Sendable {
    var geometry: SIMD4<Float>
    var options: SIMD4<Float>

    init(_ authored: LayerMask?) {
        let mask = (authored ?? .disabled).clamped
        geometry = SIMD4(
            Float(mask.centerX), Float(mask.centerY),
            Float(mask.width), Float(mask.height)
        )
        let shape: Float
        switch mask.shape {
        case .ellipse: shape = 0
        case .rectangle: shape = 1
        case .linear: shape = 2
        }
        let flags = shape + (mask.isInverted ? 4 : 0)
        options = SIMD4(
            Float(mask.rotationDegrees * .pi / 180), Float(mask.feather),
            mask.isEnabled ? 1 : -1, flags
        )
    }
}

/// Parameters shared by matte generation and the alpha-application pass.
struct BackgroundRemovalUniforms: Sendable {
    var keyColor: SIMD4<Float>
    var controls: SIMD4<Float>
    var edge: SIMD4<Float>

    init(_ authored: BackgroundRemovalSettings) {
        let settings = authored.clamped
        let key = settings.colorKey
        keyColor = SIMD4(Float(key.color.red), Float(key.color.green), Float(key.color.blue), 1)
        // Chroma distance tops out below one. These ranges make the friendly
        // 0...100 controls useful without exposing color-space units.
        controls = SIMD4(Float(key.similarity / 200), Float(max(0.002, key.smoothness / 300)),
                         Float(key.spill / 100), settings.mode == .colorKey ? 1 : 0)
        edge = SIMD4(Float(settings.feather / 4_000), Float(settings.edgeShift / 3_000),
                     settings.isInverted ? 1 : 0, settings.isEnabled ? 1 : 0)
    }
}
