import Foundation
import Metal
import simd

// ---------------------------------------------------------------------------
// Shot Match validation
//
// Host-only; no simulator or app installation required. Two halves:
//
//  1. **The forward model against the real shader.** `MatchSolver` solves by
//     predicting what `applyGradeCore` will do to a picture. If that prediction
//     and the shader ever disagree, every number the feature produces is wrong
//     in a way no amount of looking at the UI would explain — so the two are
//     run over the same colours, on this machine's GPU, with the shipping
//     `Shaders.metal`, and required to agree. Retuning a grading stage without
//     updating the model fails here rather than in someone's grade.
//
//  2. **The solver against pictures it should and should not match.** A shot
//     matched to itself must do nothing. A shot pushed off by a known grade
//     must come back. A reference from a different world must be damped and
//     must not be reported as a confident match.
// ---------------------------------------------------------------------------

@main
struct ValidateShotMatch {
    static var failures = 0

    static func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        let suffix = detail().isEmpty ? "" : "  — \(detail())"
        print("\(passed ? "  ok  " : "  FAIL") \(name)\(suffix)")
        if !passed { failures += 1 }
    }

    static func main() throws {
        print("Shot Match validation")
        try validateForwardModelAgainstShader()
        validateSolver()
        validatePersistence()
        if failures > 0 {
            print("\n\(failures) check(s) failed")
            exit(1)
        }
        print("\nAll checks passed")
    }

    // MARK: - 1. The model is the shader

    static func validateForwardModelAgainstShader() throws {
        print("\nForward model vs. Shaders.metal")
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required for shader validation")
        }
        let source = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        // `applyGrade` rather than `applyGradeCore` so the probe goes through
        // the function the picture goes through. With no fade, no vignette and
        // no grain the finishing stage is the identity, which the first check
        // below proves rather than assumes.
        let probe = """
        kernel void shotMatchProbe(device float4 *output [[buffer(0)]],
                                   device const float4 *input [[buffer(2)]],
                                   constant GradeUniforms &grade [[buffer(1)]],
                                   texture2d<float, access::sample> curveLUT [[texture(0)]],
                                   texture2d<float, access::sample> warpField [[texture(1)]],
                                   uint i [[thread_position_in_grid]]) {
            output[i] = float4(applyGrade(input[i].rgb, float2(0.5), grade, curveLUT, warpField), 1.0);
        }
        """
        let library = try device.makeLibrary(source: source + "\n" + probe, options: nil)
        let pipeline = try device.makeComputePipelineState(
            function: library.makeFunction(name: "shotMatchProbe")!)
        let curves = CurveLUTLibrary(device: device)
        let warps = ColorWarpFieldLibrary(device: device)

        // Colours spread across the range and around the wheel, including the
        // near-black and near-white ends where the tonal masks live.
        let encodedInputs: [SIMD3<Float>] = [
            SIMD3(0.30, 0.50, 0.70), SIMD3(0.80, 0.30, 0.20), SIMD3(0.05, 0.05, 0.05),
            SIMD3(0.92, 0.92, 0.92), SIMD3(0.18, 0.42, 0.22), SIMD3(0.66, 0.60, 0.35),
            SIMD3(0.12, 0.09, 0.30), SIMD3(0.50, 0.50, 0.50)
        ]

        func onGPU(_ settings: GradeSettings) throws -> [SIMD3<Float>] {
            let count = encodedInputs.count
            let inBuffer = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride,
                                             options: .storageModeShared)!
            let outBuffer = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride,
                                              options: .storageModeShared)!
            let pointer = inBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            for (index, colour) in encodedInputs.enumerated() {
                pointer[index] = SIMD4(colour.x, colour.y, colour.z, 1)
            }
            var uniforms = GradeUniforms(settings: settings, bypass: false)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(outBuffer, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 1)
            encoder.setBuffer(inBuffer, offset: 0, index: 2)
            encoder.setTexture(curves.texture(for: settings.advanced?.resolvedCurves), index: 0)
            encoder.setTexture(warps.texture(for: settings.advanced?.resolvedColorWarp), index: 1)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: count, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let result = outBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            return (0..<count).map { SIMD3(result[$0].x, result[$0].y, result[$0].z) }
        }

        func onCPU(_ adjustment: ShotMatchAdjustment) -> [SIMD3<Float>] {
            var transform = ShotMatchTransform.neutral
            transform.exposure = adjustment.exposure
            transform.temperature = adjustment.temperature / 100
            transform.tint = adjustment.tint / 100
            transform.contrast = adjustment.contrast / 100
            transform.highlights = adjustment.highlights / 100
            transform.shadows = adjustment.shadows / 100
            transform.whites = adjustment.whites / 100
            transform.blacks = adjustment.blacks / 100
            transform.saturation = adjustment.saturation / 100
            transform.wheels = adjustment.wheels.map {
                ShotMatchWheel(hue: $0.hue / 360, strength: $0.strength / 100,
                               brightness: $0.brightness / 100)
            }
            return encodedInputs.map { encoded in
                let linear = ShotMatchColor.toLinear(encoded)
                let graded = ShotMatchForwardModel.apply(transform, to: linear)
                return simd_clamp(ShotMatchColor.toEncoded(graded), .zero, .one)
            }
        }

        // Each case exercises one stage on its own, then several together — a
        // stage that is individually right and wrong in combination is exactly
        // what an ordering mistake looks like.
        var warmWheels = ShotMatchAdjustment.neutral
        warmWheels.wheels = [
            GradingWheel(hue: 195, strength: 35, brightness: 0),
            GradingWheel(hue: 40, strength: 12, brightness: 0),
            GradingWheel(hue: 55, strength: 28, brightness: 0)
        ]
        var everything = ShotMatchAdjustment.neutral
        everything.exposure = 0.42
        everything.temperature = -24
        everything.tint = 9
        everything.contrast = 31
        everything.highlights = -18
        everything.shadows = 14
        everything.whites = -22
        everything.blacks = 11
        everything.saturation = -13
        everything.wheels = warmWheels.wheels

        let cases: [(String, ShotMatchAdjustment)] = [
            ("neutral is the identity", .neutral),
            ("exposure", { var a = ShotMatchAdjustment.neutral; a.exposure = 0.75; return a }()),
            ("temperature and tint", { var a = ShotMatchAdjustment.neutral; a.temperature = -38; a.tint = 17; return a }()),
            ("contrast", { var a = ShotMatchAdjustment.neutral; a.contrast = 45; return a }()),
            ("tonal range", { var a = ShotMatchAdjustment.neutral
                              a.highlights = -30; a.shadows = 25; a.whites = -20; a.blacks = 15; return a }()),
            ("saturation", { var a = ShotMatchAdjustment.neutral; a.saturation = -35; return a }()),
            ("wheels", warmWheels),
            ("everything at once", everything)
        ]

        for (name, adjustment) in cases {
            let settings = adjustment.applied(to: .neutral)
            let gpu = try onGPU(settings)
            let cpu = onCPU(adjustment)
            var worst: Float = 0
            for (a, b) in zip(gpu, cpu) { worst = max(worst, simd_reduce_max(simd_abs(a - b))) }
            // A code value of 255 is 0.0039. Half of one is well inside what
            // 32-bit float and a round trip through HSL can account for, and is
            // far below anything that could change a grading decision.
            check(name, worst < 0.002, String(format: "worst channel error %.5f", worst))
        }

        // The same, with a residual tone curve, which reaches the GPU as a LUT
        // row rather than as a uniform — so it is the one stage where the model
        // could agree on the maths and still disagree on the plumbing.
        var withCurve = ShotMatchAdjustment.neutral
        withCurve.contrast = 12
        withCurve.toneCurve = [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.20),
            CurvePoint(x: 0.5, y: 0.52), CurvePoint(x: 0.75, y: 0.80), CurvePoint(x: 1, y: 1)
        ]
        let curveGPU = try onGPU(withCurve.applied(to: .neutral))
        var curveTransform = ShotMatchTransform.neutral
        curveTransform.contrast = 0.12
        curveTransform.toneCurve = MatchSolver.denseCurve(withCurve.toneCurve!)
        let curveCPU = encodedInputs.map { encoded in
            simd_clamp(ShotMatchColor.toEncoded(ShotMatchForwardModel.apply(
                curveTransform, to: ShotMatchColor.toLinear(encoded))), .zero, .one)
        }
        var curveWorst: Float = 0
        for (a, b) in zip(curveGPU, curveCPU) { curveWorst = max(curveWorst, simd_reduce_max(simd_abs(a - b))) }
        // Looser than the rest on purpose: the GPU reads this curve from a
        // 1025-sample 16-bit row with linear filtering between samples, while
        // the model evaluates the spline directly. A quantisation step is
        // 1/65535, and the sampling difference across a steep segment is worth
        // a few of them.
        check("tone curve", curveWorst < 0.004, String(format: "worst channel error %.5f", curveWorst))

        // Composition: a match applied on top of an existing grade must be the
        // same transform as the two in sequence, for every control where the
        // pipeline allows it to be.
        var base = GradeSettings.neutral
        base.exposure = 0.3
        base.temperature = 15
        base.tint = -6
        base.contrast = 20
        var second = ShotMatchAdjustment.neutral
        second.exposure = -0.45
        second.temperature = -28
        second.tint = 11
        second.contrast = 18
        let merged = try onGPU(second.applied(to: base))
        var expected = GradeSettings.neutral
        expected.exposure = base.exposure + second.exposure
        expected.temperature = base.temperature + second.temperature
        expected.tint = base.tint + second.tint
        expected.contrast = base.contrast + second.contrast
        let sequential = try onGPU(expected)
        var mergeWorst: Float = 0
        for (a, b) in zip(merged, sequential) { mergeWorst = max(mergeWorst, simd_reduce_max(simd_abs(a - b))) }
        check("match composes onto an existing grade", mergeWorst < 0.0005,
              String(format: "worst channel error %.6f", mergeWorst))

        // Two wheels in the same tonal range have to compose as vectors. Adding
        // their strengths and averaging their hues would put the result
        // somewhere neither of them points.
        let opposed = ShotMatchAdjustment.composed(
            GradingWheel(hue: 30, strength: 40, brightness: 0),
            with: GradingWheel(hue: 210, strength: 40, brightness: 0))
        check("opposed wheels cancel", opposed.strength < 0.01,
              String(format: "strength %.4f", opposed.strength))
        let stacked = ShotMatchAdjustment.composed(
            GradingWheel(hue: 30, strength: 20, brightness: 0),
            with: GradingWheel(hue: 30, strength: 25, brightness: 0))
        check("aligned wheels add", abs(stacked.strength - 45) < 0.01 && abs(stacked.hue - 30) < 0.01,
              String(format: "hue %.2f strength %.2f", stacked.hue, stacked.strength))
    }

    // MARK: - 2. The solver

    /// A synthetic picture: a plausible tonal distribution with colour spread
    /// around the wheel. Deterministic, so a regression is a real change rather
    /// than a different draw.
    static func makeScene(seed: UInt64, count: Int = 30_000) -> [SIMD3<Float>] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        return (0..<count).map { _ in
            let luma = min(max((next() + next() + next()) / 3 * 1.05, 0), 1)
            let saturation = next() * 0.45
            let wheel = ShotMatchColor.hueRGB(next())
            let tint = wheel - SIMD3(repeating: ShotMatchColor.luminance(wheel))
            let encoded = simd_clamp(SIMD3(repeating: luma) + tint * saturation * luma, .zero, .one)
            return ShotMatchColor.toLinear(encoded)
        }
    }

    static func transform(_ adjustment: ShotMatchAdjustment) -> ShotMatchTransform {
        var t = ShotMatchTransform.neutral
        t.exposure = adjustment.exposure
        t.temperature = adjustment.temperature / 100
        t.tint = adjustment.tint / 100
        t.contrast = adjustment.contrast / 100
        t.highlights = adjustment.highlights / 100
        t.shadows = adjustment.shadows / 100
        t.whites = adjustment.whites / 100
        t.blacks = adjustment.blacks / 100
        t.saturation = adjustment.saturation / 100
        t.wheels = adjustment.wheels.map {
            ShotMatchWheel(hue: $0.hue / 360, strength: $0.strength / 100, brightness: $0.brightness / 100)
        }
        if let points = adjustment.toneCurve { t.toneCurve = MatchSolver.denseCurve(points) }
        return t
    }

    static func validateSolver() {
        print("\nSolver")
        let reference = makeScene(seed: 7)
        let referenceProfile = ShotAnalyzer.profile(linearSamples: reference)

        // A shot that is a known grade away from the reference.
        var offset = ShotMatchTransform.neutral
        offset.exposure = -0.9
        offset.temperature = 0.28
        offset.tint = -0.12
        offset.contrast = -0.35
        offset.saturation = -0.30
        let target = ShotMatchForwardModel.apply(offset, to: reference)
        let targetProfile = ShotAnalyzer.profile(linearSamples: target)

        let solution = MatchSolver.solve(
            targetSamples: ShotSamples(linear: target), target: targetProfile,
            reference: referenceProfile, components: .all, mode: .shot)
        let a = solution.adjustment

        // What is asserted is the PICTURE, not the parameters. The inverse of a
        // grade is not unique — exposure and contrast trade against each other,
        // and in the pipeline's order they do not even commute — so requiring
        // the solver to rediscover the exact numbers that made the target would
        // be asserting an arbitrary one of many correct answers.
        let matched = ShotAnalyzer.profile(
            linearSamples: ShotMatchForwardModel.apply(transform(a), to: target))

        func toneError(_ profile: ShotProfile) -> Float {
            [ShotPercentile.p10, ShotPercentile.p50, ShotPercentile.p90].map { index in
                abs(log2(max(profile.linearPercentile(index), 1e-4)
                         / max(referenceProfile.linearPercentile(index), 1e-4)))
            }.max() ?? 0
        }
        let toneBefore = toneError(targetProfile), toneAfter = toneError(matched)
        check("tone error collapses", toneAfter < 0.12 && toneAfter < toneBefore * 0.2,
              String(format: "%.3f → %.3f stops", toneBefore, toneAfter))

        let castBefore = simd_length(targetProfile.neutralBias.simd - referenceProfile.neutralBias.simd)
        let castAfter = simd_length(matched.neutralBias.simd - referenceProfile.neutralBias.simd)
        check("colour cast collapses", castAfter < castBefore * 0.3,
              String(format: "%.4f → %.4f", castBefore, castAfter))

        let satBefore = abs(targetProfile.medianSaturation - referenceProfile.medianSaturation)
        let satAfter = abs(matched.medianSaturation - referenceProfile.medianSaturation)
        check("saturation collapses", satAfter < satBefore * 0.3,
              String(format: "%.4f → %.4f", satBefore, satAfter))
        check("a close match reports high confidence", solution.confidence == .high,
              solution.confidence.rawValue)
        check("every control stays inside its own range",
              abs(a.exposure) <= 2 && abs(a.temperature) <= 100 && abs(a.tint) <= 100
                && abs(a.contrast) <= 100 && abs(a.saturation) <= 100
                && a.wheels.allSatisfy { $0.strength <= 100 }, "")

        // Matching a shot to itself has to do nothing at all. This is the check
        // that catches a solver quietly correcting sampling noise: every
        // control has a deadband, and this is what proves it.
        let identity = MatchSolver.solve(
            targetSamples: ShotSamples(linear: reference), target: referenceProfile,
            reference: referenceProfile, components: .all, mode: .shot).adjustment
        let sliders = [abs(identity.temperature), abs(identity.tint), abs(identity.contrast),
                       abs(identity.saturation), abs(identity.blacks), abs(identity.whites),
                       abs(identity.shadows), abs(identity.highlights)]
        check("a shot matched to itself is left alone",
              abs(identity.exposure) < 0.05 && sliders.max()! < 2
                && identity.wheels.allSatisfy { $0.strength < 2 } && identity.toneCurve == nil,
              String(format: "exposure %+.3f, largest slider %.2f", identity.exposure, sliders.max()!))

        // Components are a permission, not a hint.
        let colourOnly = MatchSolver.solve(
            targetSamples: ShotSamples(linear: target), target: targetProfile,
            reference: referenceProfile, components: [.whiteBalance, .saturation], mode: .shot).adjustment
        check("a disabled component is never written",
              colourOnly.exposure == 0 && colourOnly.contrast == 0 && colourOnly.blacks == 0
                && colourOnly.whites == 0 && colourOnly.shadows == 0 && colourOnly.highlights == 0
                && colourOnly.toneCurve == nil
                && colourOnly.wheels.allSatisfy { $0.strength == 0 }, "")
        check("an enabled component is still solved",
              abs(colourOnly.temperature) > 3 && abs(colourOnly.saturation) > 3,
              String(format: "temperature %.1f saturation %.1f", colourOnly.temperature, colourOnly.saturation))

        // Strength.
        check("half strength is half the transform",
              abs(a.scaled(by: 0.5).exposure - a.exposure / 2) < 1e-5, "")
        check("zero strength is neutral", a.scaled(by: 0).isNeutral, "")
        check("full strength is unchanged", a.scaled(by: 1) == a, "")

        // Look mode holds exposure back by design.
        let look = MatchSolver.solve(
            targetSamples: ShotSamples(linear: target), target: targetProfile,
            reference: referenceProfile, components: .all, mode: .look).adjustment
        check("look mode does not relight the shot",
              abs(look.exposure) <= ShotMatchMode.look.exposureAuthority.limit + 1e-4,
              String(format: "%+.3f stops", look.exposure))

        // A reference from another world: damped, and not called confident.
        var night = ShotMatchTransform.neutral; night.exposure = -3.2
        let nightSamples = ShotMatchForwardModel.apply(night, to: makeScene(seed: 99))
        let nightProfile = ShotAnalyzer.profile(linearSamples: nightSamples)
        var snow = ShotMatchTransform.neutral; snow.exposure = 1.6; snow.saturation = -0.6
        let snowProfile = ShotAnalyzer.profile(
            linearSamples: ShotMatchForwardModel.apply(snow, to: makeScene(seed: 5)))
        let extreme = MatchSolver.solve(
            targetSamples: ShotSamples(linear: nightSamples), target: nightProfile,
            reference: snowProfile, components: .all, mode: .shot)
        check("a wildly different reference is damped",
              extreme.divergence > 0.25 && extreme.adjustment.exposure < 1.9,
              String(format: "divergence %.2f, exposure %+.2f stops",
                     extreme.divergence, extreme.adjustment.exposure))
        check("a wildly different reference is not called confident",
              extreme.confidence != .high, extreme.confidence.rawValue)

        // The residual curve may never be the thing that crushes or bands a
        // picture, whatever the two histograms say.
        if let points = a.toneCurve {
            var monotone = true, slopeLegal = true
            for index in 1..<points.count {
                if points[index].y < points[index - 1].y - 1e-6 { monotone = false }
                let slope = (points[index].y - points[index - 1].y)
                    / (points[index].x - points[index - 1].x)
                if slope < MatchSolver.minimumCurveSlope - 1e-3
                    || slope > MatchSolver.maximumCurveSlope + 1e-3 { slopeLegal = false }
            }
            check("the residual curve is monotone", monotone, "")
            check("the residual curve's slope is limited", slopeLegal, "")
            check("the residual curve leaves the endpoints alone",
                  points.first!.y == 0 && points.last!.y == 1, "")
        }

        // Averaging several frames of a shot, rather than trusting one.
        let frames = (0..<5).map { index -> ShotProfile in
            var flicker = ShotMatchTransform.neutral
            flicker.exposure = Float(index - 2) * 0.35
            return ShotAnalyzer.profile(
                linearSamples: ShotMatchForwardModel.apply(flicker, to: reference))
        }
        if let averaged = ShotAnalyzer.merged(frames) {
            let middle = frames[2]
            let gap = abs(log2(max(averaged.linearPercentile(ShotPercentile.p50), 1e-4)
                               / max(middle.linearPercentile(ShotPercentile.p50), 1e-4)))
            check("a clip average lands near its middle frame", gap < 0.35,
                  String(format: "%.3f stops apart", gap))
            check("a clip average pools every frame's samples",
                  averaged.sampleCount == frames.reduce(0) { $0 + $1.sampleCount }, "")
        } else {
            check("a clip average is produced", false, "merged returned nil")
        }
    }

    // MARK: - 3. Persistence

    static func validatePersistence() {
        print("\nPersistence")
        let profile = ShotAnalyzer.profile(linearSamples: makeScene(seed: 3, count: 4000))
        do {
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(ShotProfile.self, from: data)
            check("a profile round-trips", decoded == profile, "\(data.count) bytes")
            // The point of keeping the profile rather than the picture: a match
            // has to survive the reference file being moved or deleted.
            check("a profile is small enough to live in a project", data.count < 4000,
                  "\(data.count) bytes")
        } catch {
            check("a profile round-trips", false, "\(error)")
        }

        var adjustment = ShotMatchAdjustment.neutral
        adjustment.exposure = 0.32
        adjustment.temperature = -18
        adjustment.wheels[0] = GradingWheel(hue: 195, strength: 22, brightness: 0)
        adjustment.toneCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]
        let settings = ShotMatchSettings(
            reference: ShotMatchReference(
                source: .importedImage(fileName: "reference.jpg"),
                displayName: "Reference", profile: profile, isClipAverage: false,
                thumbnailFileName: nil),
            mode: .look, components: .default, strength: 0.75,
            adjustment: adjustment, confidence: .medium, baseGrade: .neutral)
        do {
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(ShotMatchSettings.self, from: data)
            check("a saved match round-trips", decoded == settings, "\(data.count) bytes")
        } catch {
            check("a saved match round-trips", false, "\(error)")
        }

        // Reset has to return the exact grade that was there before, not one
        // reconstructed by subtracting the match back out.
        var base = GradeSettings.neutral
        base.exposure = 0.2
        base.saturation = 12
        base.temperature = 8
        var withBase = settings
        withBase.baseGrade = base
        withBase.strength = 1
        let applied = withBase.resolvedGrade
        check("a match adds to the grade underneath it",
              applied.exposure > base.exposure && applied.temperature < base.temperature,
              String(format: "exposure %.2f → %.2f, temperature %.0f → %.0f",
                     base.exposure, applied.exposure, base.temperature, applied.temperature))
        withBase.strength = 0
        check("zero strength is exactly the grade that was there before",
              withBase.resolvedGrade == base, "")
        check("an untouched grade is not reported as hand-edited",
              !withBase.isDetached(from: base), "")
        var edited = base
        edited.vibrance = 30
        check("a hand edit after matching is noticed", withBase.isDetached(from: edited), "")
    }
}
