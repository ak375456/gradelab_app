import CoreGraphics
import Foundation
@preconcurrency import Metal
import simd

// ---------------------------------------------------------------------------
// The masked local grade stack
//
// ABI-matched with `LocalGradeStack` in Shaders.metal. Everything is float4 so
// Swift and Metal agree on alignment without a packed attribute, and the whole
// block is built as a flat array of float4 words rather than a nested Swift
// struct, because Swift has no fixed-size arrays and a tuple of eight uniform
// structs would be unreadable at every use site.
//
// The block travels by `setBytes` on every grading pass, so it has to stay
// inside Metal's 4 KB inline-argument budget. That budget is what caps the
// number of live masks and the shared polygon pool - both are stated here
// rather than invented in the UI.
//
//   header   1 word    count, aspect, matte layer, spare
//   layers   8 x 18    one LocalGradeUniforms each
//   points   96        two polygon vertices per word
//   -------------------
//   241 words = 3,856 bytes
// ---------------------------------------------------------------------------

/// One masked layer, as the shader reads it.
///
/// The colour fields are deliberately named and ordered exactly as the matching
/// fields of `GradeUniforms`, because the Metal side grades both through one
/// templated core function. That is the mechanism that guarantees a local grade
/// is the same arithmetic as a global one rather than a second implementation
/// of it.
struct LocalGradeUniforms: Sendable {
    /// exposure EV, contrast, highlights, shadows
    var lightA: SIMD4<Float>
    /// whites, blacks, spare, spare
    var lightB: SIMD4<Float>
    /// temperature, tint, saturation, vibrance
    var color: SIMD4<Float>
    /// x unused (never bypassed), y unused (no local look), z active-curve mask,
    /// w first curve row for this layer in the shared curve texture
    var options: SIMD4<Float>
    /// centre x/y, width/height - normalised to the source frame
    var maskA: SIMD4<Float>
    /// rotation in radians, feather, strength, packed shape/invert flags
    var maskB: SIMD4<Float>
    /// corner radius, polygon first-vertex index, polygon vertex count, spare
    var maskC: SIMD4<Float>
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

    static let wordCount = 18

    /// - Parameters:
    ///   - layer: the authored layer, already evaluated for this frame.
    ///   - curveRow: the layer's first row in the shared curve lookup texture.
    ///   - pointOffset: where this layer's polygon starts in the shared pool.
    init(layer: MaskedGradeLayer, curveRow: Int, pointOffset: Int) {
        let settings = layer.localGrade
        let advanced = settings.advanced ?? .neutral
        let geometry = layer.geometry.clamped

        lightA = SIMD4(settings.exposure, settings.contrast / 100,
                       settings.highlights / 100, settings.shadows / 100)
        lightB = SIMD4(settings.whites / 100, settings.blacks / 100, 0, 0)
        color = SIMD4(settings.temperature / 100, settings.tint / 100,
                      settings.saturation / 100, settings.vibrance / 100)
        options = SIMD4(0, 0, Float(advanced.curveMask), Float(curveRow))

        maskA = SIMD4(Float(geometry.centerX), Float(geometry.centerY),
                      Float(geometry.width), Float(geometry.height))
        // Shape in bits 0-1, invert in bit 2. A polygon is shape 3, which the
        // shader reads as "use the vertex pool" rather than a primitive.
        let flags = geometry.shape.shaderCode + (geometry.isInverted ? 4 : 0)
        maskB = SIMD4(Float(geometry.rotationDegrees) * .pi / 180,
                      Float(geometry.feather),
                      Float(layer.resolvedStrength),
                      flags)
        // Corner radius is meaningless for a polygon and a pivot is meaningless
        // for a primitive, so the two share the outer slots of this word rather
        // than widening the block.
        if geometry.shape == .freehand {
            maskC = SIMD4(Float(geometry.pivotX), Float(pointOffset),
                          Float(geometry.points.count), Float(geometry.pivotY))
        } else {
            maskC = SIMD4(Float(geometry.cornerRadius), 0, 0, 0)
        }

        func band(_ index: Int) -> SIMD4<Float> {
            let value = advanced.band(index)
            return SIMD4(value.hue / 360, value.saturation / 100, value.luminance / 100,
                         HueBand.centers[index] / 360)
        }
        func wheel(_ index: Int) -> SIMD4<Float> {
            let value = advanced.wheel(index)
            return SIMD4(value.hue / 360, value.strength / 100, value.brightness / 100, 0)
        }
        hsl0 = band(0); hsl1 = band(1); hsl2 = band(2); hsl3 = band(3)
        hsl4 = band(4); hsl5 = band(5); hsl6 = band(6); hsl7 = band(7)
        shadowWheel = wheel(0); midtoneWheel = wheel(1); highlightWheel = wheel(2)
    }

    var words: [SIMD4<Float>] {
        [lightA, lightB, color, options, maskA, maskB, maskC,
         hsl0, hsl1, hsl2, hsl3, hsl4, hsl5, hsl6, hsl7,
         shadowWheel, midtoneWheel, highlightWheel]
    }
}

/// Which mask, if any, the preview should show as a matte instead of a picture.
///
/// Editor-only. Export paths build their stack without ever naming one, so a
/// matte cannot reach a file: there is no flag to forget to clear.
enum MaskMatte: Equatable, Sendable {
    case none
    /// White where this layer grades, black where it does not, grey in feather.
    case layer(UUID)
}

/// The whole masked-grade stack for one clip, ready to bind.
struct LocalGradeStack: Sendable {
    static let maximumLayers = MaskedGradeLayer.maximumPerClip
    /// Two vertices per word. 192 vertices shared across every polygon on a clip.
    static let pointWords = 96
    static let maximumPoints = pointWords * 2
    static let wordCount = 1 + maximumLayers * LocalGradeUniforms.wordCount + pointWords

    private var words: [SIMD4<Float>]

    /// Nothing masked. Bound wherever a path has no masks to apply, so every
    /// pipeline always has buffer 8 populated.
    static let empty = LocalGradeStack(layers: [], aspect: 1, matte: .none)

    var isEmpty: Bool { words[0].x < 0.5 }

    /// - Parameters:
    ///   - layers: authored layers, already evaluated for this frame. Filtered
    ///     to the renderable ones here, in list order, so every render path
    ///     agrees on which masks are live and in what order they compose.
    ///   - aspect: the source frame's width / height. Rotation and feather are
    ///     measured in this aspect-corrected space, so a window rotates rigidly
    ///     instead of shearing on a non-square frame.
    ///   - matte: preview-only matte override.
    init(layers: [MaskedGradeLayer], aspect: Double, matte: MaskMatte = .none) {
        var words = [SIMD4<Float>](repeating: .zero, count: Self.wordCount)
        let live = Self.admitted(layers)

        var points: [SIMD2<Float>] = []
        var layerWords: [SIMD4<Float>] = []
        // Stored as 1 + index so that zero - and therefore an all-zero uniform
        // block - means "no matte" rather than "the first layer".
        var matteIndex: Float = 0

        for (index, layer) in live.enumerated() {
            let geometry = layer.geometry.clamped
            var offset = 0
            if geometry.shape == .freehand {
                offset = points.count
                points.append(contentsOf: geometry.points.map { SIMD2(Float($0.x), Float($0.y)) })
            }
            if case .layer(let id) = matte, id == layer.id { matteIndex = Float(index + 1) }
            layerWords.append(contentsOf: LocalGradeUniforms(
                layer: layer,
                curveRow: (index + 1) * CurveType.allCases.count,
                pointOffset: offset
            ).words)
        }

        words[0] = SIMD4(Float(live.count), Float(aspect.isFinite && aspect > 0 ? aspect : 1),
                         matteIndex, 0)
        for (index, word) in layerWords.enumerated() { words[1 + index] = word }

        let pointBase = 1 + Self.maximumLayers * LocalGradeUniforms.wordCount
        var word = 0
        while word < Self.pointWords {
            let first = points.indices.contains(word * 2) ? points[word * 2] : .zero
            let second = points.indices.contains(word * 2 + 1) ? points[word * 2 + 1] : .zero
            words[pointBase + word] = SIMD4(first.x, first.y, second.x, second.y)
            word += 1
        }
        self.words = words
    }

    /// The layers that actually reach the GPU: renderable, in list order, inside
    /// the layer budget, and inside the shared polygon pool. One implementation,
    /// used both to write the uniforms and to build the curve texture, because a
    /// disagreement between those two would have a mask reading another mask's
    /// curves.
    ///
    /// A freehand mask whose vertices will not fit what the pool has left is
    /// dropped whole rather than drawn with a truncated outline.
    static func admitted(_ layers: [MaskedGradeLayer]) -> [MaskedGradeLayer] {
        var usedPoints = 0
        var result: [MaskedGradeLayer] = []
        for layer in layers.renderable {
            let needed = layer.geometry.shape == .freehand ? layer.geometry.points.count : 0
            guard usedPoints + needed <= maximumPoints else { continue }
            usedPoints += needed
            result.append(layer)
        }
        return result
    }

    /// The curve rows this stack expects in the shared curve texture: the global
    /// grade first, then one block per live layer. Built alongside the stack so
    /// the row indices written into the uniforms cannot drift from the texture.
    static func curveRows(settings: GradeSettings, layers: [MaskedGradeLayer], bypass: Bool) -> [AdvancedCurves?] {
        var rows: [AdvancedCurves?] = [bypass ? nil : settings.advanced?.resolvedCurves]
        guard !bypass else { return rows }
        for layer in admitted(layers) {
            rows.append(layer.localGrade.advanced?.resolvedCurves)
        }
        return rows
    }

    var byteCount: Int { words.count * MemoryLayout<SIMD4<Float>>.stride }

    func bind(_ encoder: MTLComputeCommandEncoder, index: Int = LocalGradeStack.bufferIndex) {
        words.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
    }

    func bindFragment(_ encoder: MTLRenderCommandEncoder, index: Int = LocalGradeStack.bufferIndex) {
        words.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: index) }
    }

    /// Buffer slot for the stack, free in every grading function. The transition
    /// kernel grades two clips at once and takes its second stack at `bufferIndex + 1`.
    static let bufferIndex = 8
    static let incomingBufferIndex = 9
}

/// Everything one clip's grade needs on the GPU, resolved once.
///
/// Built in a single place because the pieces are coupled: the curve row each
/// masked layer samples from is decided by which layers are live, and the same
/// decision has to produce the curve texture. Splitting those apart is how a
/// mask would end up reading another mask's curves.
struct GradeProgram: Sendable {
    var uniforms: GradeUniforms
    var locals: LocalGradeStack
    /// One entry per curve block: global first, then the live masked layers.
    var curveRows: [AdvancedCurves?]
    var lookIdentifier: String?

    init(
        settings: GradeSettings,
        masks: [MaskedGradeLayer] = [],
        bypass: Bool = false,
        aspect: Double = 1,
        matte: MaskMatte = .none
    ) {
        uniforms = GradeUniforms(settings: settings, bypass: bypass)
        // "Show Original" bypasses the masked grades too: a full before has to
        // be a full before.
        let live = bypass ? [] : masks
        locals = LocalGradeStack(layers: live, aspect: aspect, matte: bypass ? .none : matte)
        curveRows = LocalGradeStack.curveRows(settings: settings, layers: live, bypass: bypass)
        lookIdentifier = bypass ? nil : settings.advanced?.lut
    }

    mutating func setGrainSeed(_ seconds: Double) { uniforms.setGrainSeed(seconds) }
}

extension CGSize {
    /// Frame aspect for mask geometry. Falls back to square rather than to a
    /// division by zero; a mask is then unrotated-correct and still lands in the
    /// right place, because position and size never depend on aspect.
    var maskAspect: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width / height)
    }
}
