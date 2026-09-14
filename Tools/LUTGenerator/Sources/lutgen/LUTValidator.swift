import Foundation

/// Structural and numeric validation of a generated `.cube` file.
///
/// The parsing rules here mirror the app's `CubeLUTParser`: same keywords, same
/// "three finite floats per data line" rule, same domain ordering requirement
/// and same exact entry-count check. The app-side test
/// `GradeLabTests/BundledLUTTests.swift` runs the real parser over the same
/// files, so this tool stays useful without linking the app target.
struct LUTValidator {
    struct ParsedCube {
        var title: String?
        var size: Int
        var domainMin: [Double]
        var domainMax: [Double]
        var values: [RGB]
    }

    enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let text): return text }
        }
    }

    let expectedSize: Int

    func parse(_ text: String) throws -> ParsedCube {
        var title: String?
        var size: Int?
        var domainMin = [0.0, 0.0, 0.0]
        var domainMax = [1.0, 1.0, 1.0]
        var values: [RGB] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let keyword = parts.first else { continue }

            switch keyword.uppercased() {
            case "TITLE":
                title = line.dropFirst(keyword.count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let parsed = Int(parts[1]) else {
                    throw Failure.message("Line \(index + 1): malformed LUT_3D_SIZE.")
                }
                size = parsed
            case "DOMAIN_MIN":
                domainMin = try vector(parts, line: index + 1)
            case "DOMAIN_MAX":
                domainMax = try vector(parts, line: index + 1)
            default:
                guard parts.count == 3 else {
                    throw Failure.message("Line \(index + 1): expected exactly 3 values, found \(parts.count).")
                }
                let numbers = try parts.map { part -> Double in
                    guard let value = Double(part) else {
                        throw Failure.message("Line \(index + 1): '\(part)' is not a number.")
                    }
                    guard !value.isNaN else { throw Failure.message("Line \(index + 1): NaN value.") }
                    guard value.isFinite else { throw Failure.message("Line \(index + 1): infinite value.") }
                    return value
                }
                values.append(RGB(numbers[0], numbers[1], numbers[2]))
            }
        }

        guard let size else { throw Failure.message("Missing LUT_3D_SIZE.") }
        return ParsedCube(title: title, size: size, domainMin: domainMin, domainMax: domainMax, values: values)
    }

    /// Returns the human-readable checks that passed, or throws on the first failure.
    @discardableResult
    func validate(_ text: String) throws -> [String] {
        let cube = try parse(text)
        var report: [String] = []

        guard cube.size == expectedSize else {
            throw Failure.message("LUT_3D_SIZE is \(cube.size), expected \(expectedSize).")
        }
        report.append("LUT_3D_SIZE = \(cube.size)")

        let expectedCount = expectedSize * expectedSize * expectedSize
        guard cube.values.count == expectedCount else {
            throw Failure.message("Found \(cube.values.count) entries, expected \(expectedCount).")
        }
        report.append("entry count = \(cube.values.count)")
        report.append("every entry has 3 finite, non-NaN values")

        guard cube.domainMin == [0, 0, 0] else {
            throw Failure.message("DOMAIN_MIN is \(cube.domainMin), expected 0 0 0.")
        }
        guard cube.domainMax == [1, 1, 1] else {
            throw Failure.message("DOMAIN_MAX is \(cube.domainMax), expected 1 1 1.")
        }
        report.append("DOMAIN_MIN 0 0 0 / DOMAIN_MAX 1 1 1")

        for (index, value) in cube.values.enumerated() {
            for channel in [value.r, value.g, value.b] where channel < 0 || channel > 1 {
                throw Failure.message("Entry \(index) has out-of-range channel \(channel).")
            }
        }
        report.append("all channels within [0, 1]")

        guard cube.title?.isEmpty == false else { throw Failure.message("Missing TITLE.") }
        report.append("TITLE = \"\(cube.title ?? "")\"")

        report.append(try continuityReport(cube))
        return report
    }

    /// Walks the cube along each axis and reports the largest step between
    /// neighbouring samples. Large jumps are what show up on screen as banding,
    /// posterisation or a sudden hue break.
    private func continuityReport(_ cube: ParsedCube) throws -> String {
        let n = cube.size
        func sample(_ r: Int, _ g: Int, _ b: Int) -> RGB {
            cube.values[r + g * n + b * n * n]
        }
        // One input step is 1/32; a well-behaved creative look should not move
        // any channel by more than a few times that between adjacent samples.
        let limit = 4.0 / Double(n - 1)
        var worst = 0.0
        var worstLocation = ""
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let here = sample(r, g, b)
                    let neighbours = [
                        r + 1 < n ? sample(r + 1, g, b) : nil,
                        g + 1 < n ? sample(r, g + 1, b) : nil,
                        b + 1 < n ? sample(r, g, b + 1) : nil
                    ].compactMap { $0 }
                    for neighbour in neighbours {
                        let delta = max(
                            abs(neighbour.r - here.r),
                            max(abs(neighbour.g - here.g), abs(neighbour.b - here.b))
                        )
                        if delta > worst {
                            worst = delta
                            worstLocation = "(\(r),\(g),\(b))"
                        }
                    }
                }
            }
        }
        guard worst <= limit else {
            throw Failure.message(
                String(format: "Continuity: neighbouring step of %.4f at %@ exceeds %.4f.", worst, worstLocation, limit)
            )
        }
        return String(format: "continuity: largest neighbour step %.4f at %@ (limit %.4f)", worst, worstLocation, limit)
    }

    private func vector(_ parts: [String], line: Int) throws -> [Double] {
        guard parts.count == 4 else { throw Failure.message("Line \(line): domain needs 3 values.") }
        return try parts.dropFirst().map {
            guard let value = Double($0), value.isFinite else {
                throw Failure.message("Line \(line): invalid domain value '\($0)'.")
            }
            return value
        }
    }
}
