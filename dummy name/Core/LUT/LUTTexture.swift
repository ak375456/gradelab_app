@preconcurrency import Metal
import simd

/// Builds Metal 3D textures from parsed `.cube` data.
///
/// Layout follows the `.cube` ordering the generator writes and `CubeLUTParser`
/// preserves: **red fastest, blue slowest**, so entry `r + g * size + b * size²`
/// lands at texel `(r, g, b)`. A 3D texture stores x fastest, then y, then z,
/// which means the parsed values can be uploaded in file order without any
/// reshuffling — the file order *is* the texture order.
enum LUTTextureFactory {
    /// 16-bit normalized: the LUT domain is exactly 0...1, so unorm wastes no
    /// range, gives 65,536 levels per channel (far beyond any banding
    /// threshold), and supports hardware linear filtering on every Apple GPU —
    /// unlike 32-bit float, which is not filterable.
    static let pixelFormat: MTLPixelFormat = .rgba16Unorm

    static func makeTexture(from cube: CubeLUT, device: MTLDevice) throws -> MTLTexture {
        let size = try LookValidation.check(cube)
        return try makeTexture(values: cube.values, size: size, device: device)
    }

    /// A pass-through LUT, bound whenever no look is selected so the shader
    /// always has a valid texture to sample.
    ///
    /// Size matters more than it looks. A 2×2×2 identity is exact in real
    /// arithmetic, but Metal's linear filter interpolates with fixed-point
    /// weights (~1/256 of a texel), and across a texel that spans half the
    /// range that rounding becomes a visible ~0.002 shift. At size 17 a texel
    /// spans 1/16 of the range, so the same rounding is under 0.0002 — below
    /// 8-bit output precision — for 39 KB of memory.
    static func makeIdentity(device: MTLDevice, size: Int = 17) throws -> MTLTexture {
        precondition(size >= 2, "An identity LUT needs at least two samples per axis")
        var values: [SIMD3<Float>] = []
        values.reserveCapacity(size * size * size)
        let last = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values.append(SIMD3(Float(r) / last, Float(g) / last, Float(b) / last))
                }
            }
        }
        return try makeTexture(values: values, size: size, device: device)
    }

    private static func makeTexture(
        values: [SIMD3<Float>],
        size: Int,
        device: MTLDevice
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = pixelFormat
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        #if os(iOS)
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GradeLabError.invalidLUT("Metal could not allocate a 3D LUT texture.")
        }

        // Four channels because Metal has no filterable three-channel format;
        // alpha is unused and written as 1.
        var payload = [UInt16](repeating: 0, count: size * size * size * 4)
        for (index, value) in values.enumerated() {
            let base = index * 4
            payload[base] = quantize(value.x)
            payload[base + 1] = quantize(value.y)
            payload[base + 2] = quantize(value.z)
            payload[base + 3] = UInt16.max
        }

        let bytesPerPixel = MemoryLayout<UInt16>.size * 4
        payload.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: size * bytesPerPixel,
                bytesPerImage: size * size * bytesPerPixel
            )
        }
        return texture
    }

    private static func quantize(_ value: Float) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16(min(max(value, 0), 1) * Float(UInt16.max) + 0.5)
    }
}
