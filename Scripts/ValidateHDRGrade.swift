import Foundation
import Metal
import simd

/// Host-only GPU regression check for the HDR grading and display path.
///
/// It compiles the real `Shaders.metal` and runs `applyGradeHDR` and the display
/// transform on extended-range values, because the property that matters most —
/// that a highlight above diffuse white survives every grading stage — cannot be
/// checked by reading the code. No simulator or device is required.
@main
struct ValidateHDRGrade {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required for shader validation")
        }
        let source = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let probe = """
        kernel void hdrProbe(device float4 *output [[buffer(0)]],
                             device const float3 *input [[buffer(1)]],
                             constant GradeUniforms &grade [[buffer(2)]],
                             constant HDRDisplayUniforms &hdr [[buffer(3)]],
                             constant uint &stage [[buffer(4)]],
                             texture3d<float, access::sample> lut [[texture(0)]],
                             texture2d<float, access::sample> curveLUT [[texture(1)]],
                             texture2d<float, access::sample> warpField [[texture(2)]],
                             uint i [[thread_position_in_grid]]) {
            float3 c = input[i];
            if (stage == 0) {                       // grading only
                output[i] = float4(applyGradeHDR(c, float2(0.5), grade, curveLUT, warpField), 1.0);
            } else if (stage == 1) {                // HLG signal -> working space
                output[i] = float4(toWorkingSpace(c, hdr), 1.0);
            } else if (stage == 2) {                // shaper round trip
                output[i] = float4(shaperToWorking(workingToShaper(c)), 1.0);
            } else if (stage == 3) {                // working -> HLG signal
                output[i] = float4(workingToSignal(c, hdr), 1.0);
            } else if (stage == 4) {                // HDR look stage
                output[i] = float4(applyLUTHDR(c, lut, grade.options.y), 1.0);
            } else if (stage == 5) {                // working -> HLG signal (encode)
                output[i] = float4(workingToSignal(c, hdr), 1.0);
            } else {                                // encode -> 10-bit codes -> decode
                float3 signal = workingToSignal(c, hdr);
                float3 ycc = hlgSignalToYCbCr2020(signal);
                // Through the exact 10-bit video-range quantisation the encoder sees.
                float yCode = round(clamp(64.0 + ycc.x * 876.0, 0.0, 1023.0));
                float cbCode = round(clamp(512.0 + ycc.y * 896.0, 0.0, 1023.0));
                float crCode = round(clamp(512.0 + ycc.z * 896.0, 0.0, 1023.0));
                float yy = (yCode - 64.0) / 876.0;
                float cb = (cbCode - 512.0) / 896.0;
                float cr = (crCode - 512.0) / 896.0;
                float3 back = float3(yy + 1.4746 * cr, yy - (0.2627 * 1.4746 / 0.6780) * cr - (0.0593 * 1.8814 / 0.6780) * cb, yy + 1.8814 * cb);
                output[i] = float4(back, 1.0);
            }
        }
        """
        let library = try device.makeLibrary(source: source + "\n" + probe, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "hdrProbe")!)

        let identityLUT = try LUTTextureFactory.makeIdentity(device: device, size: 33)
        let neutralCurves = CurveLUTLibrary(device: device)
        let neutralWarps = ColorWarpFieldLibrary(device: device)

        func run(_ colors: [SIMD3<Float>], grade: GradeSettings = .neutral, bypass: Bool = false,
                 stage: UInt32, lut: MTLTexture? = nil) throws -> [SIMD3<Float>] {
            let out = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * colors.count, options: .storageModeShared)!
            var inputs = colors
            let inBuf = device.makeBuffer(bytes: &inputs, length: MemoryLayout<SIMD3<Float>>.stride * colors.count, options: .storageModeShared)!
            var g = GradeUniforms(settings: grade, bypass: bypass)
            var h = HDRDisplayUniforms()
            var s = stage
            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(out, offset: 0, index: 0)
            enc.setBuffer(inBuf, offset: 0, index: 1)
            enc.setBytes(&g, length: MemoryLayout<GradeUniforms>.stride, index: 2)
            enc.setBytes(&h, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 3)
            enc.setBytes(&s, length: MemoryLayout<UInt32>.stride, index: 4)
            enc.setTexture(lut ?? identityLUT, index: 0)
            enc.setTexture(neutralCurves.texture(for: nil), index: 1)
            // A neutral warp field: this harness measures the extended-range
            // grade, so the warper must not be able to move a value.
            enc.setTexture(neutralWarps.texture(for: nil), index: 2)
            enc.dispatchThreads(MTLSize(width: colors.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(colors.count, 32), height: 1, depth: 1))
            enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            if let error = cmd.error { throw error }
            let p = out.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            return (0..<colors.count).map { SIMD3(p[$0].x, p[$0].y, p[$0].z) }
        }

        func delta(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            max(abs(a.x - b.x), max(abs(a.y - b.y), abs(a.z - b.z)))
        }

        let peak = Float(HDRColorSpace.peakInWorkingSpace)

        // Working-space samples: deep shadow, 18% grey, diffuse white, and
        // highlight levels that only exist because HDR is not clamped at 1.0.
        let samples: [SIMD3<Float>] = [
            SIMD3(repeating: 0.02), SIMD3(repeating: 0.18), SIMD3(repeating: 0.5),
            SIMD3(repeating: 1.0), SIMD3(repeating: 2.0), SIMD3(repeating: 3.0),
            SIMD3(repeating: peak), SIMD3(0.9, 0.35, 0.2), SIMD3(0.15, 1.8, 0.4)
        ]

        // 1 - HLG signal -> working space. Diffuse white is signal 0.75
        // (BT.2408) and must land on exactly 1.0; peak signal 1.0 gives the
        // scene-referred headroom above it.
        let converted = try run([SIMD3(repeating: 0.75), SIMD3(repeating: 1.0)], stage: 1)
        precondition(abs(converted[0].x - 1.0) < 0.002,
                     "HLG 0.75 must be diffuse white 1.0, got \(converted[0].x)")
        precondition(abs(converted[1].x - peak) < 0.01,
                     "HLG 1.0 must be \(peak), got \(converted[1].x)")
        print(String(format: "PASS signal -> working: HLG 0.75 -> %.4f, HLG 1.00 -> %.4f",
                     converted[0].x, converted[1].x))

        // Round trip back to signal, which is what both the display and the
        // encoder receive - so this is one transform verified once, not two.
        var signalWorst: Float = 0
        let signalProbe: [SIMD3<Float>] = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0].map { SIMD3(repeating: $0) }
        let backToWorking = try run(signalProbe, stage: 1)
        for (index, value) in try run(backToWorking, stage: 3).enumerated() {
            signalWorst = max(signalWorst, delta(value, signalProbe[index]))
        }
        precondition(signalWorst < 0.001, "signal round trip drifted \(signalWorst)")
        print(String(format: "PASS signal round trip: max error %.6f", signalWorst))

        // 2 - the shaper is exactly invertible, so curves and HSL cost no highlight detail.
        var shaperWorst: Float = 0
        for (input, output) in zip(samples, try run(samples, stage: 2)) {
            shaperWorst = max(shaperWorst, delta(input, output))
        }
        precondition(shaperWorst < 0.002, "shaper round trip lost \(shaperWorst)")
        print(String(format: "PASS shaper round trip: max error %.6f", shaperWorst))

        // 3 - a neutral grade must not disturb the image at all.
        var neutralWorst: Float = 0
        for (input, output) in zip(samples, try run(samples, stage: 0)) {
            neutralWorst = max(neutralWorst, delta(input, output))
        }
        precondition(neutralWorst < 0.01, "neutral grade drifted by \(neutralWorst)")
        print(String(format: "PASS neutral grade is identity: max error %.6f", neutralWorst))

        // 4 - THE point of the exercise: highlights above diffuse white survive
        // the whole grading chain instead of being clamped to 1.0.
        var settings = GradeSettings.neutral
        settings.contrast = 30
        settings.saturation = 20
        var advanced = AdvancedGrade.neutral
        advanced.curves[0].midtones = 0.58
        advanced.hsl[3].saturation = -30
        advanced.wheels[1].strength = 40
        advanced.wheels[1].hue = 210
        advanced.vignette = -40
        settings.advanced = advanced
        let graded = try run(samples, grade: settings, stage: 0)
        for (index, value) in graded.enumerated() where samples[index].x > 1.0 {
            precondition(value.max() > 1.05,
                         "highlight \(samples[index].x) was crushed to \(value.max()) by grading")
        }
        precondition(graded.contains { $0.max() > 2.0 }, "no highlight survived above 2.0")
        print(String(format: "PASS highlights survive grading: peak in %.3f -> out %.3f",
                     samples[6].x, graded[6].max()))

        // 5 - the controls actually do something.
        precondition(zip(graded, samples).contains { delta($0, $1) > 0.02 }, "grading had no effect")
        print("PASS grading controls have effect")

        // 6 - Original comparison returns the frame untouched, highlights included.
        var bypassWorst: Float = 0
        for (input, output) in zip(samples, try run(samples, grade: settings, bypass: true, stage: 0)) {
            bypassWorst = max(bypassWorst, delta(input, output))
        }
        precondition(bypassWorst < 0.0001, "bypass altered the frame by \(bypassWorst)")
        print("PASS Original comparison is untouched and unclamped")

        // The display transform is no longer ours: the drawable is HLG-tagged
        // with CAEDRMetadata.hlg and the system applies the OOTF and the
        // display's tone mapping, which is what makes the preview match Photos.

        // 8 - the look stage. An identity LUT at full strength must be exactly
        // identity at every level, including above diffuse white and below
        // black - otherwise the split at white is losing or inventing detail.
        var lookSettings = GradeSettings.neutral
        var lookAdvanced = AdvancedGrade.neutral
        lookAdvanced.lut = "Warm_Cinema.cube"
        lookAdvanced.lutIntensity = 100
        lookSettings.advanced = lookAdvanced
        var identityWorst: Float = 0
        for (input, output) in zip(samples, try run(samples, grade: lookSettings, stage: 4)) {
            identityWorst = max(identityWorst, delta(input, output))
        }
        precondition(identityWorst < 0.005,
                     "identity look altered the image by \(identityWorst) - the split at white is wrong")
        print(String(format: "PASS identity look through the HDR split: max error %.6f", identityWorst))

        // A real look must change the image, keep highlights above white, and
        // join continuously at diffuse white.
        let cube = try CubeLUTParser().parse(
            contentsOf: URL(fileURLWithPath: "dummy name/Resources/LUTs/Warm_Cinema.cube")
        )
        let warm = try LUTTextureFactory.makeTexture(from: cube, device: device)
        let looked = try run(samples, grade: lookSettings, stage: 4, lut: warm)
        precondition(zip(looked, samples).contains { delta($0, $1) > 0.02 }, "the look had no effect")
        for (index, value) in looked.enumerated() where samples[index].x > 1.0 {
            precondition(value.max() > 1.0,
                         "the look crushed highlight \(samples[index].x) to \(value.max())")
        }
        // Continuity across diffuse white: a hair either side must not jump.
        let join = try run([SIMD3(repeating: 0.999), SIMD3(repeating: 1.001)],
                           grade: lookSettings, stage: 4, lut: warm)
        precondition(delta(join[0], join[1]) < 0.01,
                     "the look is discontinuous at diffuse white: \(delta(join[0], join[1]))")
        print(String(format: "PASS look applied to HDR: white %.3f -> %.3f, peak %.3f -> %.3f, join step %.5f",
                     samples[3].x, looked[3].max(), samples[6].x, looked[6].max(), delta(join[0], join[1])))

        // 9 - the encode transform. Diffuse white and peak must land on the
        // HLG signal levels the specification defines, or the exported file
        // means something different from what we previewed.
        // Run at the nominal-gamma headroom, because that is what export uses:
        // the encoded file must be display-independent.
        let encoded = try run([SIMD3(repeating: 0.0), SIMD3(repeating: 1.0),
                               SIMD3(repeating: Float(HDRColorSpace.peakInWorkingSpace))],
                              stage: 5)
        precondition(abs(encoded[0].x - 0.0) < 0.002, "black must encode to signal 0")
        precondition(abs(encoded[1].x - 0.75) < 0.005,
                     "diffuse white must encode to HLG 0.75, got \(encoded[1].x)")
        precondition(abs(encoded[2].x - 1.0) < 0.005,
                     "peak must encode to HLG 1.0, got \(encoded[2].x)")
        print(String(format: "PASS encode: black %.4f, diffuse white %.4f (BT.2408 says 0.75), peak %.4f",
                     encoded[0].x, encoded[1].x, encoded[2].x))

        // 10 - full round trip through the real 10-bit video-range quantisation
        // the encoder receives. This is what catches a wrong matrix, a wrong
        // code range, or a transposed conversion: those survive an encode-only
        // test but not a return journey.
        let neutralSamples: [SIMD3<Float>] = [
            SIMD3(repeating: 0.05), SIMD3(repeating: 0.18), SIMD3(repeating: 0.5),
            SIMD3(repeating: 1.0), SIMD3(repeating: 2.5), SIMD3(repeating: 4.5),
            SIMD3(0.9, 0.35, 0.2), SIMD3(0.2, 0.7, 0.45)
        ]
        let forward = try run(neutralSamples, stage: 5)
        let round = try run(neutralSamples, stage: 6)
        var tripWorst: Float = 0
        for (index, value) in round.enumerated() {
            tripWorst = max(tripWorst, delta(value, forward[index]))
        }
        precondition(tripWorst < 0.004,
                     "encode/decode round trip drifted \(tripWorst) - check the matrix or code ranges")
        print(String(format: "PASS 10-bit YCbCr round trip: max error %.6f over %d samples",
                     tripWorst, neutralSamples.count))

        print("PASS: signal conversion, shaper, neutral identity, highlight survival, bypass, HDR looks, HLG encode")
    }
}
