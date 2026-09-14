import Foundation
import simd

struct CubeLUTParser: Sendable {
    func parse(_ text: String) throws -> CubeLUT {
        var title: String?
        var oneDimensionalSize: Int?
        var threeDimensionalSize: Int?
        var domainMinimum = SIMD3<Float>(repeating: 0)
        var domainMaximum = SIMD3<Float>(repeating: 1)
        var values: [SIMD3<Float>] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard let keyword = parts.first else { continue }

            switch keyword.uppercased() {
            case "TITLE":
                let rawTitle = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                title = rawTitle.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_1D_SIZE":
                guard parts.count == 2, let size = Int(parts[1]), size >= 2 else {
                    throw GradeLabError.invalidLUT("Invalid 1D size on line \(index + 1).")
                }
                oneDimensionalSize = size
            case "LUT_3D_SIZE":
                guard parts.count == 2, let size = Int(parts[1]), (2...65).contains(size) else {
                    throw GradeLabError.invalidLUT("Invalid 3D size on line \(index + 1).")
                }
                threeDimensionalSize = size
            case "DOMAIN_MIN":
                domainMinimum = try parseVector(parts, line: index + 1)
            case "DOMAIN_MAX":
                domainMaximum = try parseVector(parts, line: index + 1)
            default:
                guard parts.count == 3,
                      let red = Float(parts[0]),
                      let green = Float(parts[1]),
                      let blue = Float(parts[2]),
                      red.isFinite, green.isFinite, blue.isFinite else {
                    throw GradeLabError.invalidLUT("Unrecognized or malformed data on line \(index + 1).")
                }
                values.append(SIMD3(red, green, blue))
            }
        }

        guard domainMinimum.x < domainMaximum.x,
              domainMinimum.y < domainMaximum.y,
              domainMinimum.z < domainMaximum.z else {
            throw GradeLabError.invalidLUT("DOMAIN_MIN must be smaller than DOMAIN_MAX.")
        }
        guard (oneDimensionalSize == nil) != (threeDimensionalSize == nil) else {
            throw GradeLabError.invalidLUT("Declare exactly one LUT size.")
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
            throw GradeLabError.invalidLUT("Missing LUT size.")
        }

        guard values.count == expectedCount else {
            throw GradeLabError.invalidLUT("Expected \(expectedCount) entries but found \(values.count).")
        }
        return CubeLUT(
            title: title,
            kind: kind,
            domainMinimum: domainMinimum,
            domainMaximum: domainMaximum,
            values: values
        )
    }

    func parse(contentsOf url: URL) throws -> CubeLUT {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    private func parseVector(_ parts: [String], line: Int) throws -> SIMD3<Float> {
        guard parts.count == 4,
              let x = Float(parts[1]),
              let y = Float(parts[2]),
              let z = Float(parts[3]),
              x.isFinite, y.isFinite, z.isFinite else {
            throw GradeLabError.invalidLUT("Invalid domain on line \(line).")
        }
        return SIMD3(x, y, z)
    }
}
