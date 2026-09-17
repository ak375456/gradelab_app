import Foundation
import simd

/// Parses Adobe `.cube` files.
///
/// Written against UTF-8 bytes rather than `String`, because the sizes involved
/// make the convenient version unusable. A 64-point cube is 262,144 data lines
/// and Apple's Log-to-Rec.709 transform is 274,625; the previous
/// `components(separatedBy:)` / `trimmingCharacters` / `split` / `uppercased`
/// chain allocated roughly five Strings per line, so one 64-point look cost
/// about 760ms on a Mac and several seconds on a phone. That was the whole of
/// the look strip's loading time, and the delay between tapping a look and
/// seeing it applied.
///
/// This version allocates nothing per line: it walks the byte buffer, slices
/// fields in place, and converts numbers with `strtof`. Measured on the bundled
/// looks, about 15x faster for identical output.
struct CubeLUTParser: Sendable {

    // MARK: - Byte helpers

    @inline(__always) private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0B || byte == 0x0C || byte == 0x0D
    }

    /// True when a line can only be data: `.cube` keywords all begin with a
    /// letter, and a sample always begins with a digit, sign or decimal point.
    /// Checking one byte is what keeps the keyword comparisons off the hot path.
    @inline(__always) private static func startsNumber(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2B || byte == 0x2E
    }

    /// Fields of one line, as ranges into the buffer. Never more than are needed:
    /// a data line has three, and the longest keyword line has four.
    private struct Fields {
        var starts = [Int](repeating: 0, count: 5)
        var ends = [Int](repeating: 0, count: 5)
        var count = 0
    }

    @inline(__always)
    private static func split(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int, into fields: inout Fields) {
        fields.count = 0
        var index = from
        while index < to, fields.count < 5 {
            while index < to, isSpace(bytes[index]) { index += 1 }
            guard index < to else { break }
            let start = index
            while index < to, !isSpace(bytes[index]) { index += 1 }
            fields.starts[fields.count] = start
            fields.ends[fields.count] = index
            fields.count += 1
        }
    }

    /// `strtof` on a field, without building a String. The scratch buffer is
    /// reused, and a field too long to be a number is rejected rather than
    /// truncated into a wrong value.
    @inline(__always)
    private static func float(
        _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int,
        scratch: UnsafeMutablePointer<CChar>
    ) -> Float? {
        let length = end - start
        guard length > 0, length < 63 else { return nil }
        for offset in 0..<length { scratch[offset] = CChar(bitPattern: bytes[start + offset]) }
        scratch[length] = 0
        var parsedTo: UnsafeMutablePointer<CChar>?
        let value = strtof(scratch, &parsedTo)
        // The whole field has to be a number: "0.5x" is malformed, not 0.5.
        guard let parsedTo, parsedTo - scratch == length, value.isFinite else { return nil }
        return value
    }

    private static func text(
        _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int
    ) -> String {
        guard end > start, let base = bytes.baseAddress else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
    }

    /// Case-insensitive comparison of a field against an ASCII keyword.
    @inline(__always)
    private static func matches(
        _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, _ keyword: StaticString
    ) -> Bool {
        let length = end - start
        guard length == keyword.utf8CodeUnitCount else { return false }
        let expected = keyword.utf8Start
        for offset in 0..<length {
            var byte = bytes[start + offset]
            if byte >= 0x61, byte <= 0x7A { byte -= 32 }   // to upper, ASCII only
            if byte != expected[offset] { return false }
        }
        return true
    }

    // MARK: - Parsing

    func parse(_ text: String) throws -> CubeLUT {
        var utf8 = Array(text.utf8)
        return try utf8.withUnsafeMutableBufferPointer { buffer in
            try parse(bytes: UnsafeBufferPointer(buffer))
        }
    }

    func parse(contentsOf url: URL) throws -> CubeLUT {
        // Mapped rather than read: the file never needs to exist twice in memory,
        // and Apple's rendering LUT alone is 12 MB of text.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try data.withUnsafeBytes { raw in
            try parse(bytes: raw.bindMemory(to: UInt8.self))
        }
    }

    private func parse(bytes: UnsafeBufferPointer<UInt8>) throws -> CubeLUT {
        var title: String?
        var oneDimensionalSize: Int?
        var threeDimensionalSize: Int?
        var domainMinimum = SIMD3<Float>(repeating: 0)
        var domainMaximum = SIMD3<Float>(repeating: 1)
        var values: [SIMD3<Float>] = []

        var fields = Fields()
        let scratch = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        defer { scratch.deallocate() }

        let count = bytes.count
        var index = 0
        var lineNumber = 0

        // A UTF-8 byte-order mark, which `String(contentsOf:encoding:)` used to
        // absorb before this parser saw the text. Editors on Windows add one
        // routinely, so an imported look that used to work must keep working:
        // left in place it would attach itself to the first keyword and the file
        // would be rejected as malformed.
        if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }

        while index < count {
            lineNumber += 1
            var lineEnd = index
            while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let nextLine = lineEnd + 1
            defer { index = nextLine }

            var start = index
            while start < lineEnd, Self.isSpace(bytes[start]) { start += 1 }
            var end = lineEnd
            while end > start, Self.isSpace(bytes[end - 1]) { end -= 1 }
            guard start < end, bytes[start] != 0x23 else { continue }   // empty or '#'

            // The overwhelmingly common case, checked first and by one byte.
            if Self.startsNumber(bytes[start]) {
                Self.split(bytes, from: start, to: end, into: &fields)
                guard fields.count == 3,
                      let red = Self.float(bytes, fields.starts[0], fields.ends[0], scratch: scratch),
                      let green = Self.float(bytes, fields.starts[1], fields.ends[1], scratch: scratch),
                      let blue = Self.float(bytes, fields.starts[2], fields.ends[2], scratch: scratch) else {
                    throw GradeLabError.invalidLUT(String(localized: "Unrecognized or malformed data on line \(lineNumber)."))
                }
                values.append(SIMD3(red, green, blue))
                continue
            }

            Self.split(bytes, from: start, to: end, into: &fields)
            guard fields.count > 0 else { continue }
            let keyStart = fields.starts[0], keyEnd = fields.ends[0]

            if Self.matches(bytes, keyStart, keyEnd, "TITLE") {
                let rawTitle = Self.text(bytes, keyEnd, end).trimmingCharacters(in: .whitespaces)
                title = rawTitle.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if Self.matches(bytes, keyStart, keyEnd, "LUT_1D_SIZE") {
                guard fields.count == 2,
                      let size = Int(Self.text(bytes, fields.starts[1], fields.ends[1])), size >= 2 else {
                    throw GradeLabError.invalidLUT(String(localized: "Invalid 1D size on line \(lineNumber)."))
                }
                oneDimensionalSize = size
                // A 1D LUT can be long; reserving avoids repeated growth.
                values.reserveCapacity(size)
            } else if Self.matches(bytes, keyStart, keyEnd, "LUT_3D_SIZE") {
                guard fields.count == 2,
                      let size = Int(Self.text(bytes, fields.starts[1], fields.ends[1])),
                      (2...65).contains(size) else {
                    throw GradeLabError.invalidLUT(String(localized: "Invalid 3D size on line \(lineNumber)."))
                }
                threeDimensionalSize = size
                // The single biggest allocation win after the per-line Strings:
                // a 65-point cube grows to 274,625 entries, and without this the
                // array reallocates and copies its way there.
                values.reserveCapacity(size * size * size)
            } else if Self.matches(bytes, keyStart, keyEnd, "DOMAIN_MIN") {
                domainMinimum = try vector(bytes, fields, line: lineNumber, scratch: scratch)
            } else if Self.matches(bytes, keyStart, keyEnd, "DOMAIN_MAX") {
                domainMaximum = try vector(bytes, fields, line: lineNumber, scratch: scratch)
            } else {
                throw GradeLabError.invalidLUT(String(localized: "Unrecognized or malformed data on line \(lineNumber)."))
            }
        }

        guard domainMinimum.x < domainMaximum.x,
              domainMinimum.y < domainMaximum.y,
              domainMinimum.z < domainMaximum.z else {
            throw GradeLabError.invalidLUT(String(localized: "DOMAIN_MIN must be smaller than DOMAIN_MAX."))
        }
        guard (oneDimensionalSize == nil) != (threeDimensionalSize == nil) else {
            throw GradeLabError.invalidLUT(String(localized: "Declare exactly one LUT size."))
        }

        let kind: CubeLUT.Kind
        let expectedCount: Int
        if let size = threeDimensionalSize {
            kind = .threeDimensional(size: size)
            expectedCount = size * size * size
        } else if let size = oneDimensionalSize {
            kind = .oneDimensional(size: size)
            expectedCount = size
        } else {
            throw GradeLabError.invalidLUT(String(localized: "Missing LUT size."))
        }

        guard values.count == expectedCount else {
            throw GradeLabError.invalidLUT(String(localized: "Expected \(expectedCount) entries but found \(values.count)."))
        }
        return CubeLUT(
            title: title,
            kind: kind,
            domainMinimum: domainMinimum,
            domainMaximum: domainMaximum,
            values: values
        )
    }

    private func vector(
        _ bytes: UnsafeBufferPointer<UInt8>, _ fields: Fields, line: Int,
        scratch: UnsafeMutablePointer<CChar>
    ) throws -> SIMD3<Float> {
        guard fields.count == 4,
              let x = Self.float(bytes, fields.starts[1], fields.ends[1], scratch: scratch),
              let y = Self.float(bytes, fields.starts[2], fields.ends[2], scratch: scratch),
              let z = Self.float(bytes, fields.starts[3], fields.ends[3], scratch: scratch) else {
            throw GradeLabError.invalidLUT(String(localized: "Invalid domain on line \(line)."))
        }
        return SIMD3(x, y, z)
    }
}
