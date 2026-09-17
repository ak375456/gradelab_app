import Foundation
import simd

/// GradeLab's compiled look format: the 16-bit samples the GPU already wants,
/// written straight to disk.
///
/// A `.cube` file is ASCII, and that was most of what the app shipped — 73 MB
/// of text describing 15 MB of numbers. Apple's Log-to-Rec.709 transform alone
/// was 12 MB of it, 275,000 lines that had to be parsed into floats and
/// quantised on every cold start before a Log project could show a frame.
///
/// The compiled form removes both costs at once. `LUTTextureFactory` uploads
/// `rgba16Unorm`, so storing `round(value * 65535)` is not a lossy shortcut: it
/// is exactly the number that reached the texture before, which makes the
/// conversion bit-exact rather than merely close. Loading afterwards is a
/// length check and a copy.
///
/// Layout, little-endian throughout:
///
///     offset  size  field
///     0       4     magic, "GLUT"
///     4       2     format version
///     6       2     grid edge size, 2...65
///     8       4     entry count, which must equal size³
///     12      4     reserved, written as zero
///     16      n     size³ × 3 × UInt16, red fastest
///
/// Red-fastest ordering is inherited from `.cube` deliberately: it is already
/// the order a 3D texture wants, so the payload uploads without reshuffling.
///
/// The domain is not stored. `LookValidation` refuses anything but 0...1, so a
/// compiled look has no other domain to describe — the compiler rejects such a
/// file rather than writing a header that could imply otherwise.
enum LUTBinary {
    static let fileExtension = "gclut"
    static let version: UInt16 = 1
    static let headerSize = 16
    private static let magic = Array("GLUT".utf8)

    /// Largest compiled look we will read: a 65-point cube is 65³ × 6 bytes,
    /// about 1.6 MB, so this refuses anything that cannot be one.
    static var maximumFileSize: Int { headerSize + 65 * 65 * 65 * 3 * 2 }

    /// The exact quantisation `LUTTextureFactory` applies before upload.
    ///
    /// Shared rather than copied so a compiled look and a parsed `.cube` cannot
    /// drift apart: if this rounding ever changed on one side only, the same
    /// look would render differently depending on which form it was loaded
    /// from, which is the kind of difference nobody would think to look for.
    @inline(__always)
    static func quantize(_ value: Float) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16(min(max(value, 0), 1) * Float(UInt16.max) + 0.5)
    }

    /// A decoded look, still in storage form. Kept as flat `UInt16` rather than
    /// `SIMD3<Float>` because the only consumer is the texture upload, and
    /// converting to float here would undo the point of the format.
    struct Compiled: Equatable, Sendable {
        let size: Int
        /// `size³ × 3`, red fastest.
        let samples: [UInt16]
    }

    // MARK: - Writing

    /// Compiles a parsed `.cube`. Validation runs first, so an unusable LUT is
    /// refused at build time rather than shipped and discovered on a phone.
    static func encode(_ cube: CubeLUT) throws -> Data {
        let size = try LookValidation.check(cube)
        var samples = [UInt16]()
        samples.reserveCapacity(cube.values.count * 3)
        for value in cube.values {
            samples.append(quantize(value.x))
            samples.append(quantize(value.y))
            samples.append(quantize(value.z))
        }

        var data = Data(capacity: headerSize + samples.count * 2)
        data.append(contentsOf: magic)
        data.append(contentsOf: withUnsafeBytes(of: version.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(size).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(cube.values.count).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        // Every Apple platform is little-endian, so the in-memory array already
        // matches the format and can be copied whole.
        samples.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        return data
    }

    // MARK: - Reading

    static func decode(contentsOf url: URL) throws -> Compiled {
        // Mapped for the same reason the `.cube` parser maps: the file never
        // needs to exist twice in memory.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data, name: url.lastPathComponent)
    }

    static func decode(_ data: Data, name: String = "look") throws -> Compiled {
        guard data.count >= headerSize else {
            throw GradeLabError.invalidLUT(String(localized: "\(name) is too short to be a compiled look."))
        }
        return try data.withUnsafeBytes { raw -> Compiled in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes[0] == magic[0], bytes[1] == magic[1],
                  bytes[2] == magic[2], bytes[3] == magic[3] else {
                throw GradeLabError.invalidLUT(String(localized: "\(name) is not a compiled look."))
            }
            // Read field by field rather than by overlaying a struct: the header
            // is not naturally aligned inside a mapped file, and loading a
            // misaligned `UInt32` directly is undefined behaviour.
            let storedVersion = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
            guard storedVersion == version else {
                throw GradeLabError.invalidLUT(
                    String(localized: "\(name) was compiled by a different version of GradeLab.")
                )
            }
            let size = Int(UInt16(bytes[6]) | UInt16(bytes[7]) << 8)
            guard (2...65).contains(size) else {
                throw GradeLabError.invalidLUT(String(localized: "\(name) declares an unusable grid size of \(size)."))
            }
            let count = Int(
                UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
            )
            guard count == size * size * size else {
                throw GradeLabError.invalidLUT(
                    String(localized: "\(name) says it is size \(size) but holds \(count) entries instead of \(size * size * size).")
                )
            }
            // A truncated file would otherwise read past the mapping, or build a
            // texture from whatever followed it.
            let expectedBytes = count * 3 * MemoryLayout<UInt16>.size
            guard data.count == headerSize + expectedBytes else {
                throw GradeLabError.invalidLUT(
                    String(localized: "\(name) is \(data.count) bytes but a size \(size) look needs \(headerSize + expectedBytes).")
                )
            }

            var samples = [UInt16](repeating: 0, count: count * 3)
            samples.withUnsafeMutableBytes { destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(
                    start: raw.baseAddress! + headerSize, count: expectedBytes
                ))
            }
            return Compiled(size: size, samples: samples)
        }
    }
}
