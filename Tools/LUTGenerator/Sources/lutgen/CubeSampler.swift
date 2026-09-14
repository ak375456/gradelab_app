import Foundation

/// Trilinear sampling of a parsed cube, using the same index convention the
/// generator writes: `index = r + g * size + b * size * size` (red fastest).
///
/// This is the piece that proves the ordering: if the identity LUT is written
/// with one convention and read back with another, sampling a non-grey colour
/// returns its channels permuted and the identity test fails loudly.
struct CubeSampler {
    let size: Int
    let values: [RGB]

    init(_ cube: LUTValidator.ParsedCube) {
        self.size = cube.size
        self.values = cube.values
    }

    private func value(_ r: Int, _ g: Int, _ b: Int) -> RGB {
        values[r + g * size + b * size * size]
    }

    func sample(_ input: RGB) -> RGB {
        let last = Double(size - 1)
        func coordinate(_ v: Double) -> (low: Int, high: Int, fraction: Double) {
            let scaled = ColorMath.clamp(v) * last
            let low = min(Int(scaled), size - 1)
            let high = min(low + 1, size - 1)
            return (low, high, scaled - Double(low))
        }
        let x = coordinate(input.r), y = coordinate(input.g), z = coordinate(input.b)

        func lerpAlongRed(_ g: Int, _ b: Int) -> RGB {
            ColorMath.mix(value(x.low, g, b), value(x.high, g, b), x.fraction)
        }
        let low = ColorMath.mix(lerpAlongRed(y.low, z.low), lerpAlongRed(y.high, z.low), y.fraction)
        let high = ColorMath.mix(lerpAlongRed(y.low, z.high), lerpAlongRed(y.high, z.high), y.fraction)
        return ColorMath.mix(low, high, z.fraction)
    }
}
