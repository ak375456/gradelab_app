@preconcurrency import Metal
import Foundation

// ---------------------------------------------------------------------------
// Curve lookup textures
//
// Spline maths never runs in a shader. Control points are sampled on the CPU
// into one small 2D texture - one row per curve, 1025 columns - and the GPU
// does a single filtered fetch per curve per pixel.
//
// Format is `r16Unorm`: 65,536 levels, far below any banding threshold at 10-bit
// output, and filterable on every Apple GPU. 32-bit float is not filterable
// (see `LUTTextureFactory`), and 16-bit float would quantise to about a quarter
// of a 10-bit code near white rather than a fortieth.
//
// Hue rows need no special sampler. The evaluator treats hue as a circle, so a
// periodic curve produces identical values at x = 0 and x = 1; sampling with
// plain clamp-to-edge addressing is then continuous across the red boundary,
// and there is no seam to hide.
// ---------------------------------------------------------------------------

enum CurveLUTFactory {
    static let pixelFormat: MTLPixelFormat = .r16Unorm
    static let width = CurveSampling.count
    static let height = CurveType.allCases.count

    /// A texture holding every curve in `curves`, neutral rows included so the
    /// shader can address a row by its fixed index.
    ///
    /// `rows` may be a whole multiple of `height`: one block of ten rows for the
    /// clip's global grade, then one block for each masked local grade. The
    /// shader reads the row count from the texture and offsets into its own
    /// block, so a clip with no masks produces exactly the ten-row texture it
    /// always did.
    static func makeTexture(
        rows: [[UInt16]],
        device: MTLDevice,
        label: String
    ) -> MTLTexture? {
        precondition(!rows.isEmpty && rows.count % height == 0,
                     "The curve LUT needs one row per curve type, per grading context")
        let rowCount = rows.count
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: rowCount, mipmapped: false)
        descriptor.usage = .shaderRead
        #if os(iOS)
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        var payload = [UInt16]()
        payload.reserveCapacity(width * rowCount)
        for row in rows { payload.append(contentsOf: row) }
        payload.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, rowCount),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width * MemoryLayout<UInt16>.size
            )
        }
        return texture
    }
}

/// Keeps curve textures ready for the render thread.
///
/// Two caches, because a drag changes one curve sixty times a second and
/// rebuilding all ten every frame would be wasted work:
///
///   - rows, keyed by the curve itself, so only the curve under the finger is
///     re-sampled;
///   - assembled textures, keyed by the whole set, so an unchanged grade during
///     playback costs one comparison and nothing else.
///
/// Textures are never mutated after upload. A change allocates a new one (20 KB)
/// and leaves the old for whichever command buffer still references it, so there
/// is no hazard between the CPU writing a curve and the GPU reading it.
final class CurveLUTLibrary: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var neutralTexture: MTLTexture?
    private var rowCache: [(curve: AdvancedCurve, samples: [UInt16])] = []
    private var textureCache: [(curves: [AdvancedCurves?], texture: MTLTexture)] = []
    /// Enough for the curve being dragged plus a few recently used grades. The
    /// caches exist to skip work, not to hold memory.
    private static let rowCacheLimit = 16
    private static let textureCacheLimit = 4

    init(device: MTLDevice) {
        self.device = device
        neutralTexture = CurveLUTFactory.makeTexture(
            rows: CurveType.allCases.map { CurveSampling.quantized(.neutral($0)) },
            device: device,
            label: "Neutral curves")
    }

    /// Render-thread safe. Always returns something bindable: the neutral table
    /// stands in if a texture cannot be allocated, and it cannot change a pixel.
    func texture(for curves: AdvancedCurves?) -> MTLTexture? {
        texture(for: [curves])
    }

    /// One texture for a whole grading context stack: the clip's global curves
    /// first, then one block per masked local grade, in the order the renderer
    /// composes them.
    ///
    /// Built here rather than as several textures because the grading functions
    /// take one curve texture and a row offset — which is what lets a masked
    /// local grade reuse the global curve code unchanged.
    func texture(for stack: [AdvancedCurves?]) -> MTLTexture? {
        guard !stack.isEmpty else { return neutralTexture }
        // Every block neutral: no grade in the stack has a single active curve
        // bit set, so nothing samples this texture at all and the shared
        // ten-row neutral table is the right thing to bind.
        if stack.allSatisfy({ $0?.isNeutral ?? true }) { return neutralTexture }
        lock.lock()
        defer { lock.unlock() }
        if let hit = textureCache.first(where: { $0.curves == stack })?.texture { return hit }

        var rows: [[UInt16]] = []
        rows.reserveCapacity(stack.count * CurveLUTFactory.height)
        for curves in stack {
            for type in CurveType.allCases {
                guard let curves else { rows.append(neutralRow(type)); continue }
                let curve = curves[type]
                if curve.isNeutral { rows.append(neutralRow(type)); continue }
                if let cached = rowCache.first(where: { $0.curve == curve })?.samples {
                    rows.append(cached); continue
                }
                let samples = CurveSampling.quantized(curve)
                rowCache.insert((curve, samples), at: 0)
                if rowCache.count > Self.rowCacheLimit { rowCache.removeLast() }
                rows.append(samples)
            }
        }
        guard let texture = CurveLUTFactory.makeTexture(
            rows: rows, device: device, label: "Curves") else { return neutralTexture }
        textureCache.insert((stack, texture), at: 0)
        if textureCache.count > Self.textureCacheLimit { textureCache.removeLast() }
        return texture
    }

    /// Neutral rows are shared: they are the same for every grade, so they are
    /// sampled once each and then copied.
    private var neutralRows: [Int: [UInt16]] = [:]
    private func neutralRow(_ type: CurveType) -> [UInt16] {
        if let existing = neutralRows[type.row] { return existing }
        let samples = CurveSampling.quantized(.neutral(type))
        neutralRows[type.row] = samples
        return samples
    }
}
