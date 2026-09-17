import Foundation
import simd

/// The rules a `.cube` file must satisfy to be usable as a creative look.
///
/// One place for these checks, shared by the runtime importer (which rejects a
/// bad file before it is ever copied in) and the texture factory (which must
/// never upload one). If they diverged, a file could import cleanly and then
/// fail to render, or worse, render from the wrong place in the cube.
enum LookValidation {
    /// Largest `.cube` we will read. A 65-point LUT is roughly 7 MB of text, so
    /// this leaves generous headroom while refusing to load something enormous
    /// picked by mistake.
    static let maximumFileSize = 32 * 1024 * 1024

    /// Returns the cube's edge size, or throws with a reason a person can act on.
    @discardableResult
    static func check(_ cube: CubeLUT) throws -> Int {
        guard case .threeDimensional(let size) = cube.kind else {
            throw GradeLabError.invalidLUT(
                String(localized: "This is a 1D LUT. Looks need a 3D LUT — one with a LUT_3D_SIZE line.")
            )
        }
        guard cube.values.count == size * size * size else {
            throw GradeLabError.invalidLUT(
                String(localized: "This LUT says it is size \(size) but contains \(cube.values.count) entries instead of \(size * size * size).")
            )
        }
        // The shader samples the cube over 0...1. Rescaling for another domain is
        // not implemented, and applying it anyway would read every pixel from the
        // wrong place — a domain like this almost always means a log conversion LUT.
        guard cube.domainMinimum == SIMD3<Float>(repeating: 0),
              cube.domainMaximum == SIMD3<Float>(repeating: 1) else {
            throw GradeLabError.invalidLUT(
                String(localized: "This LUT uses a domain other than 0 to 1, which usually means it is a log or camera conversion LUT rather than a look.")
            )
        }
        for value in cube.values {
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
                throw GradeLabError.invalidLUT(String(localized: "This LUT contains values that are not numbers."))
            }
            guard value.min() >= 0, value.max() <= 1 else {
                throw GradeLabError.invalidLUT(String(localized: "This LUT contains values outside the 0 to 1 range."))
            }
        }
        return size
    }
}
