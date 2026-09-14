import Foundation

// Usage: swift run --package-path Tools/LUTGenerator lutgen [output-directory]
// Defaults to the app's bundled LUT resources folder, resolved from this file's
// location so the tool works regardless of the current working directory.

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // lutgen
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // LUTGenerator
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // repository root

let arguments = Array(CommandLine.arguments.dropFirst())
let outputDirectory = arguments.first.map { URL(fileURLWithPath: $0) }
    ?? repositoryRoot.appendingPathComponent("dummy name/Resources/LUTs")

let generator = LUTGenerator(size: LUTCatalog.size)
let validator = LUTValidator(expectedSize: LUTCatalog.size)

func fail(_ message: String) -> Never {
    print("FAILED: \(message)")
    exit(1)
}

// MARK: - Representative colours

let probes: [(String, RGB)] = [
    ("black", RGB(0, 0, 0)),
    ("18% grey", RGB(all: 0.18)),
    ("50% grey", RGB(all: 0.5)),
    ("white", RGB(1, 1, 1)),
    ("red", RGB(1, 0, 0)),
    ("green", RGB(0, 1, 0)),
    ("blue", RGB(0, 0, 1)),
    ("cyan", RGB(0, 1, 1)),
    ("magenta", RGB(1, 0, 1)),
    ("yellow", RGB(1, 1, 0)),
    ("skin (warm)", RGB(0.76, 0.57, 0.47)),
    ("sky (blue)", RGB(0.36, 0.55, 0.80)),
    ("foliage (green)", RGB(0.28, 0.45, 0.20))
]

func format(_ color: RGB) -> String {
    String(format: "%.4f %.4f %.4f", color.r, color.g, color.b)
}

// MARK: - Identity verification

print("== Identity verification (ordering, indexing, interpolation) ==")
let identityText = generator.makeCubeText(name: LUTCatalog.identity.name, transform: LUTCatalog.identity.transform)
do {
    try validator.validate(identityText)
} catch {
    fail("identity LUT failed validation: \(error)")
}
let identityCube = try validator.parse(identityText)
let sampler = CubeSampler(identityCube)

var identityWorstError = 0.0
var randomGenerator = SystemRandomNumberGenerator()
var identityProbes = probes.map { $0.1 }
for _ in 0..<200 {
    identityProbes.append(RGB(
        Double.random(in: 0...1, using: &randomGenerator),
        Double.random(in: 0...1, using: &randomGenerator),
        Double.random(in: 0...1, using: &randomGenerator)
    ))
}
for input in identityProbes {
    let output = sampler.sample(input)
    let delta = max(abs(output.r - input.r), max(abs(output.g - input.g), abs(output.b - input.b)))
    identityWorstError = max(identityWorstError, delta)
}
// 1e-5 covers the six-decimal text rounding in the written file.
guard identityWorstError < 1e-5 else {
    fail(String(format: "identity round-trip error %.6f — check LUT ordering, indexing or interpolation", identityWorstError))
}
print(String(format: "  identity round-trip over %d samples: max error %.7f  ✓", identityProbes.count, identityWorstError))
print("  ordering confirmed: index = r + g * size + b * size * size (red fastest)")
print("  identity LUT is NOT written to the resources folder.\n")

// MARK: - Generate, validate, report

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
print("Output directory: \(outputDirectory.path)\n")

for definition in LUTCatalog.definitions {
    print("== \(definition.name) (\(definition.filename)) ==")
    print("  type: \(definition.type)  category: \(definition.category)")
    print("  input: \(definition.inputColorSpace)")

    let text = generator.makeCubeText(name: definition.name, transform: definition.transform)
    do {
        for line in try validator.validate(text) {
            print("  ✓ \(line)")
        }
    } catch {
        fail("\(definition.name): \(error)")
    }

    let url = try generator.write(definition, to: outputDirectory)

    // Reload from disk and validate the bytes we actually shipped.
    let onDisk = try String(contentsOf: url, encoding: .utf8)
    do {
        try validator.validate(onDisk)
        print("  ✓ file on disk re-parsed and re-validated")
    } catch {
        fail("\(definition.filename) failed validation after writing: \(error)")
    }

    print("  transformation table:")
    for (label, input) in probes {
        print("    \(label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(format(input))  ->  \(format(definition.transform(input)))")
    }
    print("  wrote \(url.lastPathComponent)\n")
}

print("All LUTs generated and validated.")
