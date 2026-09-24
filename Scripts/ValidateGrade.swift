import Foundation
import Metal

/// Host-only regression check; no simulator or app installation required.
@main
struct ValidateGrade {
    static func main() throws {
        var settings = GradeSettings.neutral
        let oldData = try JSONEncoder().encode(settings)
        let oldSettings = try JSONDecoder().decode(GradeSettings.self, from: oldData)
        precondition(oldSettings.advanced == nil)
        var config = ExportConfiguration.maximumQuality
        config.resolution = .fullHD
        let size = config.dimensions(width: 2160, height: 3840)
        precondition(size.width == 1080 && size.height == 1920)
        config.resolution = .custom
        config.customLongEdge = 1000
        precondition(config.dimensions(width: 1920, height: 1080).height == 562)

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required for shader validation")
        }
        let source = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let probe = """
        kernel void layoutProbe(device uint *output [[buffer(0)]]) {
            output[0] = uint(sizeof(GradeUniforms));
        }

        kernel void gradeProbe(device float4 *output [[buffer(0)]],
                               constant GradeUniforms &grade [[buffer(1)]],
                               texture2d<float, access::sample> curveLUT [[texture(0)]],
                               texture2d<float, access::sample> warpField [[texture(1)]],
                               uint i [[thread_position_in_grid]]) {
            float3 colors[4] = {float3(0.3, 0.5, 0.7), float3(0.8, 0.3, 0.2), float3(0.05), float3(0.9)};
            output[i] = float4(applyGrade(colors[i], float2(0.0), grade, curveLUT, warpField), 1.0);
        }

        kernel void maskProbe(device float *output [[buffer(0)]],
                              constant GradeUniforms &grade [[buffer(1)]],
                              uint i [[thread_position_in_grid]]) {
            float2 points[3] = {float2(0.5, 0.5), float2(0.79, 0.5), float2(0.95, 0.95)};
            output[i] = gradeMaskWeight(points[i], grade);
        }
        """
        let library = try device.makeLibrary(source: source + "\n" + probe, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "gradeProbe")!)
        let maskPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "maskProbe")!)
        // The uniform block is memcpy'd from Swift into the shader, so the two
        // sides agreeing on its size is the thing worth asserting - not a magic
        // number that goes stale the next time a slot is added.
        do {
            let layoutPipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "layoutProbe")!)
            let buffer = device.makeBuffer(length: 16, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(layoutPipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            let shaderSize = Int(buffer.contents().assumingMemoryBound(to: UInt32.self).pointee)
            precondition(
                MemoryLayout<GradeUniforms>.stride == shaderSize,
                "GradeUniforms is \(MemoryLayout<GradeUniforms>.stride) bytes in Swift and \(shaderSize) in Metal"
            )
        }
        let curveLibrary = CurveLUTLibrary(device: device)
        let warpLibrary = ColorWarpFieldLibrary(device: device)
        func render(_ grade: GradeSettings, bypass: Bool = false) throws -> [SIMD4<Float>] {
            let buffer = device.makeBuffer(length: 64, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            var uniforms = GradeUniforms(settings: grade, bypass: bypass)
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 1)
            encoder.setTexture(curveLibrary.texture(for: bypass ? nil : grade.advanced?.resolvedCurves), index: 0)
            encoder.setTexture(warpLibrary.texture(for: bypass ? nil : grade.advanced?.resolvedColorWarp), index: 1)
            encoder.dispatchThreads(MTLSize(width: 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: 4))
        }
        let original: [SIMD4<Float>] = [SIMD4(0.3,0.5,0.7,1), SIMD4(0.8,0.3,0.2,1), SIMD4(0.05,0.05,0.05,1), SIMD4(0.9,0.9,0.9,1)]
        let neutral = try render(.neutral)
        for i in 0..<4 { for c in 0..<4 { precondition(abs(neutral[i][c] - original[i][c]) < 0.002, "Neutral drift") } }

        func renderMask(_ mask: GradeMask?) throws -> [Float] {
            var advanced = AdvancedGrade.neutral
            advanced.mask = mask
            var maskedSettings = GradeSettings.neutral
            maskedSettings.advanced = advanced == .neutral ? nil : advanced
            var uniforms = GradeUniforms(settings: maskedSettings, bypass: false)
            let output = device.makeBuffer(length: 3 * MemoryLayout<Float>.stride, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(maskPipeline)
            encoder.setBuffer(output, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 1)
            encoder.dispatchThreads(MTLSize(width: 3, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 3, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: 3))
        }
        let fullFrameMask = try renderMask(nil)
        precondition(fullFrameMask.allSatisfy { abs($0 - 1) < 0.0001 }, "Disabled mask changed full-frame grade")
        let ellipse = try renderMask(GradeMask(isEnabled: true, feather: 0, opacity: 100))
        precondition(ellipse[0] > 0.99 && ellipse[1] > 0.99 && ellipse[2] < 0.01,
                     "Ellipse mask geometry is wrong")
        let inverted = try renderMask(GradeMask(isEnabled: true, feather: 0, opacity: 100, isInverted: true))
        precondition(inverted[0] < 0.01 && inverted[2] > 0.99, "Mask inversion is wrong")
        var sCurve = AdvancedCurves()
        sCurve[.master] = AdvancedCurve(type: .master, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.18),
            CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1)
        ])
        // A warp that pulls blue toward purple and lifts its saturation. The
        // source sits on the blue in the first probe colour, so it has to move.
        var blueToPurple = ColorWarp()
        blueToPurple.points = [
            ColorWarpPoint(mode: .hueSaturation, sourceX: 0.58, sourceY: 0.6,
                           targetX: 0.72, targetY: 0.78, radius: 0.25)
        ]
        var blueHueShift = AdvancedCurves()
        blueHueShift[.hueVsHue] = AdvancedCurve(type: .hueVsHue, points: [
            CurvePoint(x: 0.5, y: 0), CurvePoint(x: 2.0 / 3.0, y: 0.5), CurvePoint(x: 0.8, y: 0)
        ])
        let changes: [(inout AdvancedGrade) -> Void] = [
            // Legacy three-slider data, which now reaches the GPU by being
            // migrated into control points rather than through the uniforms.
            { $0.curves[0].midtones = 0.75 },
            { $0.advancedCurves = sCurve },
            { $0.advancedCurves = blueHueShift },
            { $0.hsl[0].hue = 30; $0.hsl[0].saturation = -50 },
            { $0.wheels[1].strength = 80; $0.wheels[1].hue = 220 },
            { $0.vignette = -80 },
            // Drag the blues a sixth of the way round the wheel and out.
            { $0.colorWarp = blueToPurple }
        ]
        for change in changes {
            var advanced = AdvancedGrade.neutral
            change(&advanced); settings.advanced = advanced
            let altered = try render(settings)
            precondition(zip(altered, neutral).contains { a, b in abs(a.x-b.x)+abs(a.y-b.y)+abs(a.z-b.z) > 0.01 }, "Control had no effect")
            let bypass = try render(settings, bypass: true)
            for i in 0..<4 { for c in 0..<4 { precondition(abs(bypass[i][c] - original[i][c]) < 0.0001, "Bypass drift") } }
            let decoded = try JSONDecoder().decode(GradeSettings.self, from: JSONEncoder().encode(settings))
            precondition(decoded == settings)
        }
        // The warper has to be EXACTLY identity in the two states that mean
        // "off", not merely close: a neutral field is bound on every frame of
        // every project that has never opened the panel, and a strength of zero
        // is what the slider's left end promises.
        for neutralWarp in [ColorWarp(), { var w = blueToPurple; w.strength = 0; return w }()] {
            var advanced = AdvancedGrade.neutral
            advanced.colorWarp = neutralWarp
            var warpSettings = GradeSettings.neutral
            warpSettings.advanced = advanced
            let rendered = try render(warpSettings)
            for i in 0..<4 {
                for c in 0..<4 {
                    precondition(abs(rendered[i][c] - neutral[i][c]) < 0.0001,
                                 "An inactive Color Warper changed a pixel")
                }
            }
        }

        // Preserve Luminance has to hold brightness while the hue moves. Checked
        // on a saturated blue, which is the worst case: purple is markedly
        // brighter, so an unprotected move is visible immediately.
        func warpLuma(preserving: Bool) throws -> Float {
            var warp = blueToPurple
            warp.preservesLuminance = preserving
            var advanced = AdvancedGrade.neutral
            advanced.colorWarp = warp
            var warpSettings = GradeSettings.neutral
            warpSettings.advanced = advanced
            let rendered = try render(warpSettings)[0]
            return 0.2126 * rendered.x + 0.7152 * rendered.y + 0.0722 * rendered.z
        }
        let sourceLuma = 0.2126 * neutral[0].x + 0.7152 * neutral[0].y + 0.0722 * neutral[0].z
        let held = try warpLuma(preserving: true)
        let loose = try warpLuma(preserving: false)
        precondition(abs(held - sourceLuma) < 0.01,
                     "Preserve Luminance let brightness drift by \(abs(held - sourceLuma))")
        precondition(abs(loose - sourceLuma) > abs(held - sourceLuma),
                     "Preserve Luminance made no difference")

        print("PASS: legacy decode, uniform layout, export dimensions, GPU neutral identity, local mask geometry/inversion, legacy+advanced curves/HSL/wheels/vignette effects, original bypass, advanced persistence, color warp effect/identity/luminance")
    }
}
