import Foundation
import Metal
import simd

/// Host-only regression check for the creative LUT stage. It compiles the real
/// `Shaders.metal`, uploads real `.cube` files through the real texture factory,
/// and proves on the GPU that:
///
/// 1. an identity LUT changes nothing — which is what verifies that the file
///    ordering, the 3D texture layout and the shader's coordinate mapping all
///    agree, and would fail loudly if any one of them were transposed;
/// 2. grid-aligned inputs return exactly the values stored in the file;
/// 3. strength scales linearly between the source and the look;
/// 4. bypass (the Original comparison) skips the look entirely.
///
/// No simulator or app installation is required.
@main
struct ValidateLUT {
    static let lutDirectory = "LUTSources"

    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required for shader validation")
        }

        let source = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let probe = """
        kernel void lutProbe(device float4 *output [[buffer(0)]],
                             device const float3 *input [[buffer(1)]],
                             constant float &amount [[buffer(2)]],
                             texture3d<float, access::sample> lut [[texture(0)]],
                             uint i [[thread_position_in_grid]]) {
            output[i] = float4(applyLUT(input[i], lut, amount), 1.0);
        }

        kernel void stageProbe(device float4 *output [[buffer(0)]],
                               device const float3 *input [[buffer(1)]],
                               constant GradeUniforms &grade [[buffer(2)]],
                               texture3d<float, access::sample> lut [[texture(0)]],
                               texture2d<float, access::sample> curveLUT [[texture(1)]],
                               constant LocalGradeStack &locals [[buffer(3)]],
                               uint i [[thread_position_in_grid]]) {
            output[i] = float4(applyLookAndGrade(input[i], float2(0.5), grade, lut, curveLUT, locals), 1.0);
        }
        """
        let library = try device.makeLibrary(source: source + "\n" + probe, options: nil)
        let lutPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "lutProbe")!)
        let stagePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "stageProbe")!)
        let neutralCurves = CurveLUTLibrary(device: device)

        func run(
            _ pipeline: MTLComputePipelineState,
            colors: [SIMD3<Float>],
            texture: MTLTexture,
            uniform: UnsafeRawPointer,
            uniformLength: Int
        ) throws -> [SIMD3<Float>] {
            let outputBuffer = device.makeBuffer(
                length: MemoryLayout<SIMD4<Float>>.stride * colors.count,
                options: .storageModeShared
            )!
            var inputs = colors
            let inputBuffer = device.makeBuffer(
                bytes: &inputs,
                length: MemoryLayout<SIMD3<Float>>.stride * colors.count,
                options: .storageModeShared
            )!
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(outputBuffer, offset: 0, index: 0)
            encoder.setBuffer(inputBuffer, offset: 0, index: 1)
            encoder.setBytes(uniform, length: uniformLength, index: 2)
            encoder.setTexture(texture, index: 0)
            // Neutral curves: the look stage is what this harness measures, so
            // the curve table must not be able to move a value.
            encoder.setTexture(neutralCurves.texture(for: nil), index: 1)
            // `stageProbe` grades through the full pipeline, which takes the
            // masked-local-grade stack. No masks here: this measures the look.
            LocalGradeStack.empty.bind(encoder, index: 3)
            encoder.dispatchThreads(
                MTLSize(width: colors.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(colors.count, 32), height: 1, depth: 1)
            )
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let pointer = outputBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            return (0..<colors.count).map { SIMD3(pointer[$0].x, pointer[$0].y, pointer[$0].z) }
        }

        func sampleLUT(_ colors: [SIMD3<Float>], texture: MTLTexture, amount: Float) throws -> [SIMD3<Float>] {
            var strength = amount
            return try run(lutPipeline, colors: colors, texture: texture,
                           uniform: &strength, uniformLength: MemoryLayout<Float>.stride)
        }

        func difference(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            max(abs(a.x - b.x), max(abs(a.y - b.y), abs(a.z - b.z)))
        }

        // 16-bit unorm storage quantizes to 1/65535; trilinear filtering on the
        // GPU adds a little more. Anything beyond this is a real layout error,
        // not rounding.
        let tolerance: Float = 0.0005

        // MARK: 1 - Identity through the real texture path

        var probes: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.18, 0.18, 0.18), SIMD3(0.5, 0.5, 0.5),
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
            SIMD3(0, 1, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 0),
            SIMD3(0.76, 0.57, 0.47), SIMD3(0.36, 0.55, 0.80), SIMD3(0.28, 0.45, 0.20)
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            probes.append(SIMD3(
                Float.random(in: 0...1, using: &generator),
                Float.random(in: 0...1, using: &generator),
                Float.random(in: 0...1, using: &generator)
            ))
        }
        // At the shipped LUT size the round trip must be essentially exact.
        // A transposed axis would show up as a whole-channel swap, not rounding.
        let identity33 = try LUTTextureFactory.makeIdentity(device: device, size: 33)
        var worst: Float = 0
        for result in zip(probes, try sampleLUT(probes, texture: identity33, amount: 1)) {
            worst = max(worst, difference(result.0, result.1))
        }
        precondition(worst < tolerance, "Identity LUT altered the image by \(worst) — check ordering or texture layout")
        print(String(format: "PASS identity (size 33) through GPU: max error %.6f over %d colors", worst, probes.count))

        // The fallback bound when no look is selected. It is sampled only during
        // the brief window before a look finishes loading, so it needs to be
        // visually neutral rather than bit-exact — under half an 8-bit code.
        let fallback = try LUTTextureFactory.makeIdentity(device: device)
        var fallbackWorst: Float = 0
        for result in zip(probes, try sampleLUT(probes, texture: fallback, amount: 1)) {
            fallbackWorst = max(fallbackWorst, difference(result.0, result.1))
        }
        precondition(fallbackWorst < 1.0 / 512, "Identity fallback shifts colour by \(fallbackWorst)")
        print(String(format: "PASS identity fallback: max error %.6f (under half an 8-bit code)", fallbackWorst))

        // MARK: 2 - Every LUT in the resources tree

        // Walks LUTSources and its subfolders, so a `.cube` dropped into
        // Imported/ is checked by exactly the same rules as the generated ones.
        let fileManager = FileManager.default
        var files: [URL] = []
        if let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: lutDirectory),
            includingPropertiesForKeys: nil
        ) {
            for case let url as URL in walker where url.pathExtension.lowercased() == "cube" {
                files.append(url)
            }
        }
        files.sort { $0.lastPathComponent < $1.lastPathComponent }
        precondition(!files.isEmpty, "No .cube files found under \(lutDirectory)")

        let builtInNames = Set(LUTAsset.bundledCreativeLooks.map(\.filename))
        let parser = CubeLUTParser()
        var importedCount = 0

        for url in files {
            let filename = url.lastPathComponent
            let isBuiltIn = builtInNames.contains(filename)
            if !isBuiltIn { importedCount += 1 }
            let asset = LUTAsset.bundledLooks.first { $0.filename == filename }
                ?? LUTAsset(
                    name: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                    filename: filename,
                    category: "Imported",
                    summary: "Imported look.",
                    inputColorSpace: "Rec.709 / working SDR",
                    kind: .creative,
                    origin: .bundled
                )
            let cube = try parser.parse(contentsOf: url)
            guard case .threeDimensional(let size) = cube.kind else {
                fatalError("\(filename) is 1D; the look stage needs a 3D LUT")
            }
            if isBuiltIn {
                precondition(size == 33, "\(filename) is size \(size), expected 33")
            }
            precondition((2...65).contains(size), "\(filename) size \(size) is outside the supported 2...65")
            precondition(cube.values.count == size * size * size, "\(filename) entry count")
            precondition(
                cube.domainMinimum == SIMD3<Float>(repeating: 0) && cube.domainMaximum == SIMD3<Float>(repeating: 1),
                "\(filename) declares a domain other than 0...1, which the look stage cannot apply"
            )
            for (index, value) in cube.values.enumerated() {
                for channel in [value.x, value.y, value.z] {
                    precondition(channel.isFinite, "\(filename) entry \(index) is not finite")
                    precondition(channel >= 0 && channel <= 1, "\(filename) entry \(index) is out of range: \(channel)")
                }
            }

            let texture = try LUTTextureFactory.makeTexture(from: cube, device: device)

            // Grid-aligned inputs land exactly on a texel centre, so the GPU must
            // return the stored entry itself. Any transposition of red and blue
            // shows up here immediately.
            var gridInputs: [SIMD3<Float>] = []
            var expected: [SIMD3<Float>] = []
            let last = Float(size - 1)
            for b in stride(from: 0, to: size, by: 4) {
                for g in stride(from: 0, to: size, by: 4) {
                    for r in stride(from: 0, to: size, by: 4) {
                        gridInputs.append(SIMD3(Float(r) / last, Float(g) / last, Float(b) / last))
                        expected.append(cube.values[r + g * size + b * size * size])
                    }
                }
            }
            var gridWorst: Float = 0
            for (result, reference) in zip(try sampleLUT(gridInputs, texture: texture, amount: 1), expected) {
                gridWorst = max(gridWorst, difference(result, reference))
            }
            precondition(gridWorst < tolerance, "\(filename) grid mismatch \(gridWorst)")

            // Strength blends linearly between the source and the full look.
            let mixInputs = Array(probes.prefix(60))
            let full = try sampleLUT(mixInputs, texture: texture, amount: 1)
            let none = try sampleLUT(mixInputs, texture: texture, amount: 0)
            let half = try sampleLUT(mixInputs, texture: texture, amount: 0.5)
            var mixWorst: Float = 0
            var noneWorst: Float = 0
            for index in mixInputs.indices {
                noneWorst = max(noneWorst, difference(none[index], mixInputs[index]))
                mixWorst = max(mixWorst, difference(half[index], (mixInputs[index] + full[index]) * 0.5))
            }
            precondition(noneWorst < tolerance, "\(filename) at 0% changed the image by \(noneWorst)")
            precondition(mixWorst < tolerance, "\(filename) 50% is not a linear blend (\(mixWorst))")

            // Endpoint behaviour. Our own looks have to hold black and white;
            // an imported look is reported, not judged, because lifting or
            // rolling off the endpoints can be exactly what it is for.
            let corners = try sampleLUT([SIMD3(0, 0, 0), SIMD3(1, 1, 1)], texture: texture, amount: 1)
            if isBuiltIn {
                precondition(difference(corners[1], SIMD3(1, 1, 1)) < 0.002, "\(filename) does not hold white")
                if asset.name == "Soft Film" {
                    precondition(corners[0].x > 0.01 && corners[0].x < 0.08, "Soft Film black lift out of range")
                } else {
                    precondition(difference(corners[0], SIMD3(0, 0, 0)) < 0.002, "\(filename) does not hold black")
                }
            }

            // Smoothness. A LUT with large jumps between neighbouring samples
            // will band on real footage, so it is worth knowing before shipping.
            var neighbourWorst: Float = 0
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let here = cube.values[r + g * size + b * size * size]
                        if r + 1 < size {
                            neighbourWorst = max(neighbourWorst, difference(here, cube.values[(r + 1) + g * size + b * size * size]))
                        }
                        if g + 1 < size {
                            neighbourWorst = max(neighbourWorst, difference(here, cube.values[r + (g + 1) * size + b * size * size]))
                        }
                        if b + 1 < size {
                            neighbourWorst = max(neighbourWorst, difference(here, cube.values[r + g * size + (b + 1) * size * size]))
                        }
                    }
                }
            }
            let smoothnessLimit = 4 / Float(size - 1)
            let smoothness = neighbourWorst <= smoothnessLimit
                ? String(format: "smooth (%.4f)", neighbourWorst)
                : String(format: "MAY BAND (%.4f > %.4f)", neighbourWorst, smoothnessLimit)
            if isBuiltIn {
                precondition(neighbourWorst <= smoothnessLimit, "\(filename) jumps \(neighbourWorst) between samples")
            }

            print(String(
                format: "PASS %@ [%@]: size %d, %d entries, black %.3f, white %.3f, grid error %.6f, %@",
                asset.name, isBuiltIn ? "built-in" : "imported", size, cube.values.count,
                corners[0].x, corners[1].x, gridWorst, smoothness
            ))

            // MARK: 3 - The combined stage, and bypass

            var settings = GradeSettings.neutral
            var advanced = AdvancedGrade.neutral
            advanced.lut = asset.id
            settings.advanced = advanced
            precondition(advanced.lutStrength == 100, "A selected look defaults to full strength")

            var graded = GradeUniforms(settings: settings, bypass: false)
            let stageColors = Array(probes.prefix(40))
            let stage = try run(stagePipeline, colors: stageColors, texture: texture,
                                uniform: &graded, uniformLength: MemoryLayout<GradeUniforms>.stride)
            precondition(
                zip(stage, stageColors).contains { difference($0, $1) > 0.01 },
                "\(filename) had no effect through the full stage"
            )

            var bypassed = GradeUniforms(settings: settings, bypass: true)
            let bypass = try run(stagePipeline, colors: stageColors, texture: texture,
                                 uniform: &bypassed, uniformLength: MemoryLayout<GradeUniforms>.stride)
            var bypassWorst: Float = 0
            for index in stageColors.indices {
                bypassWorst = max(bypassWorst, difference(bypass[index], stageColors[index]))
            }
            precondition(bypassWorst < 0.0001, "Original comparison still applied the look (\(bypassWorst))")

            // A look must survive a save/load round trip.
            let decoded = try JSONDecoder().decode(GradeSettings.self, from: JSONEncoder().encode(settings))
            precondition(decoded == settings, "\(filename) did not survive encoding")
        }

        // Projects saved before looks existed must still decode.
        let legacy = """
        {"exposure":0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,\
        "temperature":0,"tint":0,"saturation":0,"vibrance":0,\
        "advanced":{"curves":[],"hsl":[],"wheels":[],"vignette":0,"vignetteMidpoint":50,"vignetteFeather":70}}
        """
        let restored = try JSONDecoder().decode(GradeSettings.self, from: Data(legacy.utf8))
        precondition(restored.advanced?.lut == nil, "Legacy projects must decode without a look")
        precondition(restored.advanced?.lutStrength == 0, "Legacy projects must apply no look")
        print("PASS legacy project decode without a look")

        print("Checked \(files.count) LUT file(s): \(files.count - importedCount) built-in, \(importedCount) imported")
        print("PASS: identity ordering, stored-entry accuracy, strength blending, endpoints, bypass, persistence")
    }
}
