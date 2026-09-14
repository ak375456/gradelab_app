import Foundation
import Metal
import simd

/// Host-only regression harness for the advanced curves. No simulator, no
/// device: it evaluates the real `CurveEvaluator`, builds the real LUT texture,
/// compiles the real `Shaders.metal`, and runs colours through the real
/// `applyGrade`.
///
/// It does not test iPhone playback, hardware export or the UI.
@main
struct ValidateCurves {

    // MARK: - Helpers

    /// The hexcone conversion the shader uses, so measurements are made in the
    /// same space the curves work in.
    static func hsl(_ rgb: SIMD3<Float>) -> (h: Float, s: Float, l: Float) {
        let hi = max(rgb.x, max(rgb.y, rgb.z))
        let lo = min(rgb.x, min(rgb.y, rgb.z))
        let d = hi - lo
        let l = (hi + lo) * 0.5
        var h: Float = 0
        if d > 0.00001 {
            if hi == rgb.x { h = (rgb.y - rgb.z) / d }
            else if hi == rgb.y { h = 2 + (rgb.z - rgb.x) / d }
            else { h = 4 + (rgb.x - rgb.y) / d }
            h = (h / 6 + 1).truncatingRemainder(dividingBy: 1)
        }
        return (h, d / max(1 - abs(2 * l - 1), 0.00001), l)
    }

    /// Shortest signed distance between two hues, in turns.
    static func hueDelta(_ a: Float, _ b: Float) -> Float {
        var d = a - b
        if d > 0.5 { d -= 1 }
        if d < -0.5 { d += 1 }
        return d
    }

    static func curve(_ type: CurveType, _ points: [(Float, Float)]) -> AdvancedCurve {
        AdvancedCurve(type: type, points: points.map { CurvePoint(x: $0.0, y: $0.1) })
    }

    static func set(_ type: CurveType, _ points: [(Float, Float)]) -> AdvancedCurves {
        var curves = AdvancedCurves()
        curves[type] = curve(type, points)
        return curves
    }

    static func settings(_ curves: AdvancedCurves) -> GradeSettings {
        var grade = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.advancedCurves = curves
        grade.advanced = advanced
        return grade
    }

    // MARK: -

    static func main() throws {
        try checkInterpolation()
        try checkLegacyMigration()
        try checkCyclicWrapping()
        try checkGPU()
        print("PASS: interpolation, no overshoot, exact legacy migration, hue wrapping, "
            + "identity, master/R/G/B, hue-vs-hue/sat/luma, luma-vs-sat, sat-vs-sat, "
            + "sat-vs-luma, gradient smoothness")
    }

    // MARK: - Interpolation

    static func checkInterpolation() throws {
        // Identity must be exactly identity, or a "straight" curve tints the picture.
        for type in [CurveType.master, .red, .green, .blue, .saturationVsSaturation] {
            let evaluator = CurveEvaluator(.neutral(type))
            for i in 0...1000 {
                let x = Float(i) / 1000
                precondition(abs(evaluator.value(at: x) - x) < 1e-6, "\(type) identity drift at \(x)")
            }
        }
        // Neutral adjustment curves are flat zero.
        for type in [CurveType.hueVsHue, .hueVsSaturation, .hueVsLuma,
                     .lumaVsSaturation, .saturationVsLuma] {
            let evaluator = CurveEvaluator(.neutral(type))
            for i in 0...1000 {
                precondition(abs(evaluator.value(at: Float(i) / 1000)) < 1e-6, "\(type) not neutral")
            }
        }

        // The point of monotone cubic: a step in the control points must not
        // make the curve leave the box those points bound. Catmull-Rom would
        // undershoot below 0.2 and overshoot above 0.8 here.
        let step = curve(.master, [(0, 0), (0.4, 0.2), (0.6, 0.8), (1, 1)])
        let evaluator = CurveEvaluator(step)
        var previous = evaluator.value(at: 0)
        for i in 0...4000 {
            let x = Float(i) / 4000
            let y = evaluator.value(at: x)
            precondition(y >= -1e-6 && y <= 1 + 1e-6, "Overshoot outside 0...1 at \(x): \(y)")
            precondition(y >= previous - 1e-5, "Monotone input produced a non-monotone curve at \(x)")
            if x >= 0.4 && x <= 0.6 {
                precondition(y >= 0.2 - 1e-5 && y <= 0.8 + 1e-5, "Ringing inside the step at \(x)")
            }
            previous = y
        }

        // A flat segment must stay flat rather than bulging through its ends.
        let plateau = CurveEvaluator(curve(.master, [(0, 0), (0.3, 0.6), (0.7, 0.6), (1, 1)]))
        for i in 0...500 {
            let x = 0.3 + Float(i) / 500 * 0.4
            precondition(abs(plateau.value(at: x) - 0.6) < 1e-5, "Flat segment bulged at \(x)")
        }
    }

    // MARK: - Legacy migration

    /// The old shader evaluated a piecewise-linear ramp through five anchors.
    static func legacyCurveValue(_ x: Float, _ anchors: [Float]) -> Float {
        let points: [Float] = [0, anchors[0], anchors[1], anchors[2], 1]
        let t = min(max(x, 0), 1) * 4
        let i = min(Int(t), 3)
        return points[i] + (points[i + 1] - points[i]) * (t - Float(i))
    }

    static func checkLegacyMigration() throws {
        var tone = ToneCurve()
        tone.shadows = 0.12
        tone.midtones = 0.62
        tone.highlights = 0.88
        let migrated = AdvancedCurves(migratingLegacy: [tone, ToneCurve(), ToneCurve(), ToneCurve()])
        precondition(migrated[.master].interpolation == .linear, "Migration must stay linear to be exact")
        precondition(migrated[.red].isNeutral, "An untouched legacy channel must migrate to neutral")

        let evaluator = CurveEvaluator(migrated[.master])
        let anchors: [Float] = [tone.shadows, tone.midtones, tone.highlights]
        for i in 0...8192 {
            let x = Float(i) / 8192
            let expected = legacyCurveValue(x, anchors)
            precondition(abs(evaluator.value(at: x) - expected) < 1e-6,
                         "Legacy migration is not exact at \(x)")
        }

        // The legacy anchors land on whole samples, so the table reproduces the
        // ramp without rounding its corners.
        let samples = CurveSampling.samples(migrated[.master])
        precondition(samples.count == 1025)
        for (index, anchorX) in [(256, Float(0.25)), (512, 0.5), (768, 0.75)] {
            precondition(abs(samples[index] - legacyCurveValue(anchorX, anchors)) < 1e-6,
                         "Anchor \(anchorX) does not land on sample \(index)")
        }

        // A legacy set that was never touched must migrate to nothing at all.
        precondition(AdvancedCurves(migratingLegacy: Array(repeating: ToneCurve(), count: 4)).isNeutral)
    }

    // MARK: - Hue wrapping

    static func checkCyclicWrapping() throws {
        // A selection sitting on red: points either side of the 0/1 seam.
        let wrapped = curve(.hueVsHue, [(0.9, 0), (0.0, 0.5), (0.1, 0)])
        let evaluator = CurveEvaluator(wrapped)
        precondition(abs(evaluator.value(at: 0) - 0.5) < 1e-6, "Centre of a red selection is not at full value")
        precondition(abs(evaluator.value(at: 1) - evaluator.value(at: 0)) < 1e-6,
                     "Hue curve is discontinuous at the 0/1 boundary")
        // Both sides of the seam must be pulled, or red is only half selectable.
        precondition(evaluator.value(at: 0.97) > 0.05, "Hue just below red was not affected")
        precondition(evaluator.value(at: 0.03) > 0.05, "Hue just above red was not affected")
        precondition(abs(evaluator.value(at: 0.5)) < 1e-4, "The opposite hue must be untouched")

        // No jump anywhere, including across the seam.
        var previous = evaluator.value(at: 0)
        for i in 1...20000 {
            let y = evaluator.value(at: Float(i) / 20000)
            precondition(abs(y - previous) < 0.002, "Hue curve jumps at \(Float(i) / 20000)")
            previous = y
        }

        // And the sampled table wraps too: first and last entry are the same
        // value, which is what lets the shader use plain clamp addressing.
        let samples = CurveSampling.samples(wrapped)
        precondition(abs(samples[0] - samples[samples.count - 1]) < 1e-6, "LUT row does not wrap")
    }

    // MARK: - GPU

    static func checkGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required for curve validation")
        }
        let source = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let probe = """
        kernel void curveProbe(device float4 *output [[buffer(0)]],
                               device const float3 *input [[buffer(1)]],
                               constant GradeUniforms &grade [[buffer(2)]],
                               texture2d<float, access::sample> curveLUT [[texture(0)]],
                               uint i [[thread_position_in_grid]]) {
            output[i] = float4(applyGrade(input[i], float2(0.5), grade, curveLUT), 1.0);
        }
        """
        let library = try device.makeLibrary(source: source + "\n" + probe, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "curveProbe")!)
        let curveLibrary = CurveLUTLibrary(device: device)

        func render(_ colors: [SIMD3<Float>], _ curves: AdvancedCurves) throws -> [SIMD3<Float>] {
            var uniforms = GradeUniforms(settings: settings(curves), bypass: false)
            var inputs = colors
            let outputBuffer = device.makeBuffer(
                length: MemoryLayout<SIMD4<Float>>.stride * colors.count, options: .storageModeShared)!
            let inputBuffer = device.makeBuffer(
                bytes: &inputs, length: MemoryLayout<SIMD3<Float>>.stride * colors.count,
                options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(outputBuffer, offset: 0, index: 0)
            encoder.setBuffer(inputBuffer, offset: 0, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 2)
            encoder.setTexture(curveLibrary.texture(for: curves), index: 0)
            encoder.dispatchThreads(MTLSize(width: colors.count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(colors.count, 64), height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let pointer = outputBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            return (0..<colors.count).map { SIMD3(pointer[$0].x, pointer[$0].y, pointer[$0].z) }
        }

        // Red, yellow, green, cyan, blue, magenta, mid grey, dark grey.
        let wheel: [SIMD3<Float>] = [
            SIMD3(0.85, 0.10, 0.10), SIMD3(0.85, 0.85, 0.10), SIMD3(0.10, 0.85, 0.10),
            SIMD3(0.10, 0.85, 0.85), SIMD3(0.10, 0.10, 0.85), SIMD3(0.85, 0.10, 0.85),
            SIMD3(0.50, 0.50, 0.50), SIMD3(0.12, 0.12, 0.12)
        ]
        let names = ["red", "yellow", "green", "cyan", "blue", "magenta", "grey", "dark grey"]
        let red = 0, green = 2, blue = 4, grey = 6

        // --- Identity -------------------------------------------------------
        // Straight curves, present but untouched, must change nothing.
        var identity = AdvancedCurves()
        for type in CurveType.allCases { identity[type] = .neutral(type) }
        precondition(identity.isNeutral, "A set of neutral curves must store nothing")
        let untouched = try render(wheel, identity)
        for (index, colour) in wheel.enumerated() {
            for c in 0..<3 {
                precondition(abs(untouched[index][c] - colour[c]) < 0.002,
                             "Identity curves changed \(names[index])")
            }
        }

        // --- Master ---------------------------------------------------------
        let sCurve = try render(wheel, set(.master, [(0, 0), (0.25, 0.15), (0.75, 0.85), (1, 1)]))
        precondition(sCurve[grey].x > wheel[grey].x, "S-curve did not lift the midtone above centre")
        precondition(sCurve[7].x < wheel[7].x - 0.01, "S-curve did not deepen the shadow")
        // A grey stays grey: the master curve must not introduce a colour cast.
        for c in 1..<3 {
            precondition(abs(sCurve[grey][c] - sCurve[grey].x) < 0.002, "Master curve tinted a neutral")
            precondition(abs(sCurve[7][c] - sCurve[7].x) < 0.002, "Master curve tinted a shadow neutral")
        }

        // --- Red / Green / Blue --------------------------------------------
        let lift: [(Float, Float)] = [(0, 0), (0.5, 0.65), (1, 1)]
        let drop: [(Float, Float)] = [(0, 0), (0.5, 0.35), (1, 1)]
        let redUp = try render([wheel[grey]], set(.red, lift))[0]
        precondition(redUp.x > wheel[grey].x + 0.02, "Red curve did not add red")
        precondition(abs(redUp.y - wheel[grey].y) < 0.003 && abs(redUp.z - wheel[grey].z) < 0.003,
                     "Red curve moved another channel")
        let greenDown = try render([wheel[grey]], set(.green, drop))[0]
        precondition(greenDown.y < wheel[grey].y - 0.02, "Green curve did not remove green")
        precondition(abs(greenDown.x - wheel[grey].x) < 0.003 && abs(greenDown.z - wheel[grey].z) < 0.003,
                     "Green curve moved another channel")
        let blueUp = try render([wheel[grey]], set(.blue, lift))[0]
        precondition(blueUp.z > wheel[grey].z + 0.02, "Blue curve did not add blue")

        // --- Hue vs Hue -----------------------------------------------------
        // Blue sits at 240°, which is 2/3 of the way round.
        let blueShift = try render(wheel, set(.hueVsHue, [(0.5, 0), (2.0 / 3.0, 0.5), (0.8, 0)]))
        let shifted = hueDelta(hsl(blueShift[blue]).h, hsl(wheel[blue]).h)
        // +0.5 on a hue curve is +30°, which is 1/12 of a turn.
        precondition(abs(shifted - 1.0 / 12.0) < 0.012, "Blue moved \(shifted * 360)° rather than 30°")
        for index in [red, green] {
            precondition(abs(hueDelta(hsl(blueShift[index]).h, hsl(wheel[index]).h)) < 0.006,
                         "\(names[index]) moved while only blue was selected")
        }

        // A selection on red pulls both ends of the graph.
        let redShift = try render(wheel, set(.hueVsHue, [(0.9, 0), (0.0, 0.5), (0.1, 0)]))
        precondition(abs(hueDelta(hsl(redShift[red]).h, hsl(wheel[red]).h) - 1.0 / 12.0) < 0.012,
                     "A selection on red did not shift red")
        // 345° and 15° are the same distance from red on either side of the seam.
        let seam: [SIMD3<Float>] = [SIMD3(0.85, 0.10, 0.29), SIMD3(0.85, 0.29, 0.10)]
        let seamOut = try render(seam, set(.hueVsHue, [(0.9, 0), (0.0, 0.5), (0.1, 0)]))
        let below = hueDelta(hsl(seamOut[0]).h, hsl(seam[0]).h)
        let above = hueDelta(hsl(seamOut[1]).h, hsl(seam[1]).h)
        precondition(below > 0.01 && above > 0.01, "One side of the 0/360 seam was not affected")
        precondition(abs(below - above) < 0.012, "The seam is not symmetric: \(below) vs \(above)")

        // --- Hue vs Saturation ----------------------------------------------
        let greenFlat = try render(wheel, set(.hueVsSaturation, [(0.2, 0), (1.0 / 3.0, -0.6), (0.45, 0)]))
        precondition(hsl(greenFlat[green]).s < hsl(wheel[green]).s * 0.6, "Green did not desaturate")
        for index in [red, blue] {
            precondition(abs(hsl(greenFlat[index]).s - hsl(wheel[index]).s) < 0.02,
                         "\(names[index]) saturation moved while only green was selected")
        }

        // --- Hue vs Luma ------------------------------------------------------
        let blueDark = try render(wheel, set(.hueVsLuma, [(0.5, 0), (2.0 / 3.0, -0.7), (0.8, 0)]))
        precondition(hsl(blueDark[blue]).l < hsl(wheel[blue]).l - 0.05, "Blue did not darken")
        for index in [red, green] {
            precondition(abs(hsl(blueDark[index]).l - hsl(wheel[index]).l) < 0.02,
                         "\(names[index]) brightness moved while only blue was selected")
        }

        // --- Luma vs Saturation ----------------------------------------------
        // Same hue, four brightnesses. Only the darkest should desaturate.
        let ramp: [SIMD3<Float>] = [
            SIMD3(0.16, 0.04, 0.04), SIMD3(0.40, 0.10, 0.10),
            SIMD3(0.65, 0.16, 0.16), SIMD3(0.90, 0.22, 0.22)
        ]
        let shadowsFlat = try render(ramp, set(.lumaVsSaturation, [(0, -0.8), (0.35, 0), (1, 0)]))
        precondition(hsl(shadowsFlat[0]).s < hsl(ramp[0]).s * 0.7, "Shadow saturation was not reduced")
        precondition(abs(hsl(shadowsFlat[3]).s - hsl(ramp[3]).s) < 0.02, "Highlight saturation moved")

        // --- Saturation vs Saturation -----------------------------------------
        // Same hue and brightness, rising saturation.
        let sats: [SIMD3<Float>] = (1...5).map { step in
            let s = Float(step) * 0.2
            return SIMD3(0.5 + 0.4 * s, 0.5 - 0.4 * s, 0.5 - 0.4 * s)
        }
        let limited = try render(sats, set(.saturationVsSaturation,
                                           [(0, 0), (0.4, 0.4), (1, 0.6)]))
        precondition(hsl(limited[4]).s < hsl(sats[4]).s * 0.85, "High saturation was not compressed")
        precondition(abs(hsl(limited[0]).s - hsl(sats[0]).s) < 0.03, "Low saturation was disturbed")

        // --- Saturation vs Luma ------------------------------------------------
        let satDark = try render(wheel, set(.saturationVsLuma, [(0, 0), (0.5, 0), (1, -0.8)]))
        precondition(hsl(satDark[red]).l < hsl(wheel[red]).l - 0.03, "Saturated colour did not darken")
        for c in 0..<3 {
            precondition(abs(satDark[grey][c] - untouched[grey][c]) < 0.004,
                         "A neutral grey moved under a saturation-keyed curve")
        }

        // --- Gradient smoothness ------------------------------------------------
        // A shaped curve over a fine ramp must not step or posterise. The
        // largest jump between neighbouring steps is compared against the
        // largest the curve's own slope can justify.
        let steps = 512
        let gradient = (0..<steps).map { i -> SIMD3<Float> in
            let v = Float(i) / Float(steps - 1)
            return SIMD3(v, v, v)
        }
        let graded = try render(gradient, set(.master, [(0, 0), (0.3, 0.12), (0.7, 0.88), (1, 1)]))
        var largest: Float = 0
        for i in 1..<steps { largest = max(largest, abs(graded[i].x - graded[i - 1].x)) }
        // The curve's steepest slope is about 2.3x, so a 1/511 input step can
        // legitimately move about 0.0045. Anything much beyond that is a step
        // in the table rather than in the picture.
        precondition(largest < 0.008, "Gradient stepped by \(largest) - the table is too coarse")

        // And a hue sweep must not band as it crosses a selection's edges.
        let sweep = (0..<720).map { i -> SIMD3<Float> in
            let h = Float(i) / 720
            let base = abs(((h * 6 + SIMD3<Float>(0, 4, 2)).truncatingRemainder(6)) - 3)
            return 0.5 + 0.35 * (simd_clamp(base - 1, SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)) - 0.5) * 2
        }
        let swept = try render(sweep, set(.hueVsHue, [(0.9, 0), (0.0, 0.5), (0.1, 0)]))
        var largestHueJump: Float = 0
        for i in 1..<sweep.count {
            largestHueJump = max(largestHueJump, abs(hueDelta(hsl(swept[i]).h, hsl(swept[i - 1]).h)))
        }
        precondition(largestHueJump < 0.01,
                     "Hue sweep jumped by \(largestHueJump * 360)° between neighbouring hues")
    }
}

private extension SIMD3 where Scalar == Float {
    func truncatingRemainder(_ divisor: Float) -> SIMD3<Float> {
        SIMD3(x.truncatingRemainder(dividingBy: divisor),
              y.truncatingRemainder(dividingBy: divisor),
              z.truncatingRemainder(dividingBy: divisor))
    }
}
