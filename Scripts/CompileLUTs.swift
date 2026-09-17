import Foundation
import simd

/// Compiles `.cube` look sources into the `.gclut` files the app ships.
///
/// Built by `Scripts/compile-luts.sh` against the app's own `CubeLUTParser`,
/// `LookValidation` and `LUTBinary` rather than a second copy of them, for the
/// same reason `BundledLUTTests` runs the real parser: a look the app would
/// refuse must never be compiled into the bundle, and a rounding rule that
/// existed in two places would eventually differ in one of them.
///
/// Every file is verified after it is written — decoded back and compared
/// sample by sample against the parsed source — because the whole claim of this
/// format is that it is bit-exact, and an unverified claim of bit-exactness is
/// just a hope.
@main
struct CompileLUTs {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let checkOnly = arguments.contains("--check")
        arguments.removeAll { $0.hasPrefix("--") }
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data(
                "usage: compile-luts [--check] <source-directory> <output-directory>\n".utf8
            ))
            exit(2)
        }
        let sourceRoot = URL(fileURLWithPath: arguments[0])
        let outputRoot = URL(fileURLWithPath: arguments[1])

        let sources = try cubeFiles(under: sourceRoot)
        guard !sources.isEmpty else {
            FileHandle.standardError.write(Data("No .cube files under \(sourceRoot.path)\n".utf8))
            exit(1)
        }

        // Resources are flattened into the bundle root, so two looks with the
        // same filename in different subfolders would silently become one.
        var byName: [String: URL] = [:]
        for source in sources {
            if let existing = byName[source.lastPathComponent] {
                throw Failure("""
                    Two sources share the filename \(source.lastPathComponent):
                      \(existing.path)
                      \(source.path)
                    Resources are flattened into the bundle, so one would replace the other.
                    """)
            }
            byName[source.lastPathComponent] = source
        }

        if !checkOnly {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        }

        var sourceBytes = 0
        var compiledBytes = 0
        var stale: [String] = []
        var skipped: [String] = []

        for name in byName.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let source = byName[name]!
            let destination = outputRoot.appendingPathComponent("\(name).\(LUTBinary.fileExtension)")

            let cube = try CubeLUTParser().parse(contentsOf: source)
            let data: Data
            do {
                data = try LUTBinary.encode(cube)
            } catch let error as GradeLabError {
                // A file the app would refuse as a look is skipped rather than
                // failing the build: this folder is a drop-in, and the app has
                // always ignored what it cannot use. Not shipping it is the
                // point — a 1D curve sitting in the bundle was weight nobody
                // could ever load.
                skipped.append("\(name) — \(error.errorDescription ?? "\(error)")")
                continue
            }
            try verify(data, matches: cube, name: name)

            let sourceSize = (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sourceBytes += sourceSize
            compiledBytes += data.count

            if checkOnly {
                let existing = try? Data(contentsOf: destination)
                if existing != data { stale.append(name) }
            } else {
                try data.write(to: destination, options: .atomic)
            }
            let saved = sourceSize > 0 ? 100 - Double(data.count) / Double(sourceSize) * 100 : 0
            print(String(
                format: "  %-42s %7.2f MB -> %6.2f MB  (-%.0f%%)",
                (name as NSString).utf8String!,
                Double(sourceSize) / 1_048_576, Double(data.count) / 1_048_576, saved
            ))
        }

        if checkOnly {
            guard stale.isEmpty else {
                throw Failure("""
                    \(stale.count) compiled look(s) are missing or out of date:
                      \(stale.joined(separator: "\n  "))
                    Run Scripts/compile-luts.sh
                    """)
            }
            for note in skipped { print("  skipped \(note)") }
            print("\nAll \(byName.count - skipped.count) compiled looks are up to date.")
            return
        }

        // Anything left from a source that has since been renamed or deleted
        // would keep shipping, and would keep appearing in the look picker.
        let skippedNames = Set(skipped.map { $0.components(separatedBy: " — ")[0] })
        let expected = Set(byName.keys
            .filter { !skippedNames.contains($0) }
            .map { "\($0).\(LUTBinary.fileExtension)" })
        let orphans = (try? FileManager.default.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == LUTBinary.fileExtension && !expected.contains($0.lastPathComponent) } ?? []
        for orphan in orphans {
            try FileManager.default.removeItem(at: orphan)
            print("  removed orphan \(orphan.lastPathComponent)")
        }

        for note in skipped { print("  skipped \(note)") }
        print(String(
            format: "\n%d looks: %.1f MB of .cube -> %.1f MB compiled (-%.0f%%)",
            byName.count - skipped.count,
            Double(sourceBytes) / 1_048_576,
            Double(compiledBytes) / 1_048_576,
            100 - Double(compiledBytes) / Double(sourceBytes) * 100
        ))
    }

    /// Decodes what was just encoded and compares it against the source.
    ///
    /// The comparison is against `LUTBinary.quantize` of each parsed value,
    /// which is precisely what `LUTTextureFactory` would have uploaded from the
    /// `.cube`. Equality here is the guarantee that swapping the format cannot
    /// change a single rendered pixel.
    private static func verify(_ data: Data, matches cube: CubeLUT, name: String) throws {
        let decoded = try LUTBinary.decode(data, name: name)
        guard case .threeDimensional(let size) = cube.kind, decoded.size == size else {
            throw Failure("\(name): compiled grid size does not match the source.")
        }
        guard decoded.samples.count == cube.values.count * 3 else {
            throw Failure("\(name): compiled sample count does not match the source.")
        }
        for (index, value) in cube.values.enumerated() {
            let expected = (LUTBinary.quantize(value.x), LUTBinary.quantize(value.y), LUTBinary.quantize(value.z))
            let actual = (decoded.samples[index * 3], decoded.samples[index * 3 + 1], decoded.samples[index * 3 + 2])
            guard expected == actual else {
                throw Failure("\(name): entry \(index) changed — expected \(expected), got \(actual).")
            }
        }
    }

    private static func cubeFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "cube" {
            found.append(url)
        }
        return found
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
