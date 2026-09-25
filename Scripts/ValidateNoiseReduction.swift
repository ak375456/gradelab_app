import Foundation
import CoreVideo
import Metal
import simd

// ---------------------------------------------------------------------------
// Noise Reduction validation
//
// Host-only; no simulator, no app installation, no footage. It builds the
// SHIPPING shaders on this machine's GPU, drives the shipping
// `NoiseReductionStage` with synthetic frames whose noise and motion are known
// exactly, and measures what came out.
//
// Synthetic frames are the point rather than a compromise. A denoiser is judged
// on four things that are almost impossible to measure on real footage, because
// real footage does not come with a clean version of itself:
//
//   how much noise came out          needs the noise-free truth
//   whether detail survived          needs to know what the detail was
//   whether anything ghosted         needs to know where the object really was
//   whether the result is stable     needs two frames of identical content
//
// Here all four are known, so each one is a number with a threshold rather than
// an opinion about a picture. The thresholds are set where a human would start
// to object, not at the theoretical optimum.
// ---------------------------------------------------------------------------

@main
struct ValidateNoiseReduction {
    static var failures = 0

    static func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        let suffix = detail().isEmpty ? "" : "  — \(detail())"
        print("\(passed ? "  ok  " : "  FAIL") \(name)\(suffix)")
        if !passed { failures += 1 }
    }

    static let width = 256
    static let height = 192

    static func main() throws {
        print("Noise Reduction validation")
        let harness = try Harness()
        try harness.validateRoundTrip()
        try harness.validateTemporalReduction()
        try harness.validateGhosting()
        try harness.validateDetailPreservation()
        try harness.validateChromaSeparation()
        try harness.validateSceneCut()
        try harness.validateSpatialEdges()
        try harness.validateDetailRecovery()
        try harness.validateTemporalStability()
        try harness.validateDeterminism()
        try harness.validatePresetStrength()
        validateParameterMapping()

        if failures > 0 {
            print("\n\(failures) check(s) failed")
            exit(1)
        }
        print("\nAll checks passed")
    }

    // MARK: - Parameter mapping
    //
    // The slider curves are arithmetic and are checked as arithmetic: no GPU,
    // no frames, just the promises the UI makes about what its numbers mean.

    static func validateParameterMapping() {
        print("\nParameter mapping")
        let zero = NoiseReductionUniforms.strength(0)
        let full = NoiseReductionUniforms.strength(100)
        check("zero is zero", zero == 0)
        check("full is one", abs(full - 1) < 1e-5)
        // The promise the panel makes: the bottom third of the slider is fine
        // control, not a third of the maximum.
        let third = NoiseReductionUniforms.strength(30)
        check("the first third is gentle", third < 0.2, String(format: "30 -> %.3f", third))
        check("the curve rises", NoiseReductionUniforms.strength(70) > NoiseReductionUniforms.strength(50))

        // A radius has to mean the same fraction of the picture at any size, or
        // a grade judged at 1080p would be a different grade at 4K.
        let hd = NoiseReductionUniforms.spatialRadius(60, longEdge: 1920)
        let uhd = NoiseReductionUniforms.spatialRadius(60, longEdge: 3840)
        check("radius scales with the picture", uhd > hd * 1.8,
              String(format: "1080p %.1f px, 4K %.1f px", hd, uhd))
        check("radius is bounded", NoiseReductionUniforms.spatialRadius(100, longEdge: 7680) <= 24)

        // Every preset has to be something the engine will actually run, and
        // something the sliders can express.
        for preset in NoiseReduction.Preset.allCases {
            let value = preset.applied(to: .neutral)
            check("preset \(preset.rawValue) is active", value.isActive)
            check("preset \(preset.rawValue) is in range", value == value.clamped)
        }
        // Chroma Cleanup must leave luminance strictly alone: that is the only
        // thing it claims to do.
        let chroma = NoiseReduction.Preset.chromaCleanup.applied(to: .neutral)
        check("chroma cleanup leaves luma alone",
              chroma.temporalLuma == 0 && chroma.spatialLuma == 0)

        // Neutral must be provably incapable of changing a pixel, because every
        // render path skips the engine on exactly this test.
        check("neutral is inactive", !NoiseReduction.neutral.isActive)
        var enabledButZero = NoiseReduction.neutral
        enabledButZero.isTemporalEnabled = true
        enabledButZero.isSpatialEnabled = true
        check("switched on with no strength is inactive", !enabledButZero.isActive)
    }
}

// MARK: - Harness

final class Harness {
    let device: MTLDevice
    let context: MetalContext
    let stage: NoiseReductionStage
    let readback: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("A Metal device is required")
        }
        self.device = device
        // The shipping shaders, both files, exactly as the app compiles them —
        // plus one probe kernel that copies a texture into a buffer, which is
        // the only thing here that is not in the app.
        let grading = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let noise = try String(contentsOfFile: "dummy name/Metal/NoiseReductionShaders.metal", encoding: .utf8)
        let probe = """

        kernel void validationReadback(
            texture2d<float, access::read> source [[texture(0)]],
            device float4 *out [[buffer(0)]],
            constant uint &stride [[buffer(1)]],
            uint2 p [[thread_position_in_grid]])
        {
            if (p.x >= source.get_width() || p.y >= source.get_height()) { return; }
            out[p.y * stride + p.x] = source.read(p);
        }
        """
        let library = try device.makeLibrary(source: grading + noise + probe, options: nil)
        context = try MetalContext(library: library)
        guard let stage = NoiseReductionStage(context: context) else {
            fatalError("The noise reduction stage could not be built on this device")
        }
        self.stage = stage
        guard let function = library.makeFunction(name: "validationReadback") else {
            fatalError("The validation probe could not be built")
        }
        readback = try device.makeComputePipelineState(function: function)
    }

    // MARK: Frames

    /// A deterministic normal deviate. Written out rather than taken from a
    /// system generator so a failure here is reproducible on any machine.
    struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) & 0xFFFFFFFFFFFFF) / Double(1 << 52)
        }
        /// Box–Muller, one value at a time. Not fast, and does not need to be.
        mutating func normal() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// An NV12 frame built from a closure over normalised luma and chroma.
    ///
    /// Video range, 8-bit, BT.709 — the format the SDR preview and export
    /// actually decode into, so this exercises the shipping `nrPrepareYUV`
    /// rather than a shortcut into the middle of the engine.
    func makeFrame(_ content: (Int, Int) -> (luma: Double, cb: Double, cr: Double)) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, ValidateNoiseReduction.width, ValidateNoiseReduction.height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attributes as CFDictionary, &buffer)
        guard let buffer else { fatalError("Could not allocate a test frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)

        for y in 0..<ValidateNoiseReduction.height {
            for x in 0..<ValidateNoiseReduction.width {
                let value = content(x, y).luma
                lumaBase[y * lumaStride + x] = UInt8(clamping: Int((16 + value * 219).rounded()))
            }
        }
        for y in 0..<chromaHeight {
            for x in 0..<chromaWidth {
                // One chroma sample per 2x2 luma block, averaged, as 4:2:0 is.
                var cb = 0.0, cr = 0.0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let sample = content(min(x * 2 + dx, ValidateNoiseReduction.width - 1),
                                             min(y * 2 + dy, ValidateNoiseReduction.height - 1))
                        cb += sample.cb; cr += sample.cr
                    }
                }
                chromaBase[y * chromaStride + x * 2] = UInt8(clamping: Int((128 + cb / 4 * 224).rounded()))
                chromaBase[y * chromaStride + x * 2 + 1] = UInt8(clamping: Int((128 + cr / 4 * 224).rounded()))
            }
        }
        return buffer
    }

    // MARK: Running

    func run(_ settings: NoiseReduction, current: CVPixelBuffer,
             neighbours: [NoiseFrame] = []) throws -> [SIMD4<Float>] {
        guard let command = context.commandQueue.makeCommandBuffer() else {
            fatalError("Could not create a command buffer")
        }
        guard let result = stage.encode(
            current: current, neighbours: neighbours, settings: settings,
            colorMode: .sdr, hdr: HDRDisplayUniforms(), fallbackMatrix: "BT.709",
            into: command) else {
            command.commit()
            fatalError("The stage refused a configuration the test expects it to run")
        }
        let count = result.texture.width * result.texture.height
        guard let buffer = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride,
                                             options: .storageModeShared),
              let encoder = command.makeComputeCommandEncoder() else {
            fatalError("Could not create the readback buffer")
        }
        var stride = UInt32(result.texture.width)
        encoder.setComputePipelineState(readback)
        encoder.setTexture(result.texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: result.texture.width, height: result.texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { fatalError("The engine failed on the GPU") }
        let pointer = buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    // MARK: Measuring

    /// A rectangle of the frame, as luminance.
    func region(_ pixels: [SIMD4<Float>], x: Range<Int>, y: Range<Int>) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(x.count * y.count)
        for row in y {
            for column in x {
                let pixel = pixels[row * ValidateNoiseReduction.width + column]
                values.append(Double(0.2126 * pixel.x + 0.7152 * pixel.y + 0.0722 * pixel.z))
            }
        }
        return values
    }

    func deviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - The checks

extension Harness {
    typealias Check = ValidateNoiseReduction

    /// Temporal-only settings. `luma` at 1 is the engine's own do-nothing
    /// baseline: it runs every pass and blends four ten-thousandths of the
    /// result, so a measurement against it isolates the reduction rather than
    /// the conversions around it.
    func temporal(luma: Float, chroma: Float = 0, frames: TemporalFrameCount = .five,
                  motionCompensated: Bool = true) -> NoiseReduction {
        var settings = NoiseReduction.neutral
        settings.isTemporalEnabled = true
        settings.frames = frames
        settings.temporalLuma = luma
        settings.temporalChroma = chroma
        settings.isMotionCompensated = motionCompensated
        settings.quality = .high
        return settings
    }

    func spatial(luma: Float, chroma: Float = 0, radius: Float = 60,
                 recovery: Float = 0, protectsEdges: Bool = true,
                 protection: Float = 50) -> NoiseReduction {
        var settings = NoiseReduction.neutral
        settings.isSpatialEnabled = true
        settings.spatialLuma = luma
        settings.spatialChroma = chroma
        settings.radius = radius
        settings.detailRecovery = recovery
        settings.protectsEdges = protectsEdges
        settings.detailProtection = protection
        settings.quality = .high
        return settings
    }

    func window(_ frames: [CVPixelBuffer], current index: Int) -> [NoiseFrame] {
        frames.enumerated().compactMap { offset, buffer in
            offset == index ? nil : NoiseFrame(pixelBuffer: buffer, offset: offset - index)
        }
    }

    // MARK: 1. Nothing in, nothing out

    /// With the strengths at zero the engine has to be the identity.
    ///
    /// This is the check every other one rests on. The frame is taken apart
    /// into luma and chroma planes, filtered and put back together, and if that
    /// round trip is not exact then every measurement below is measuring the
    /// conversion rather than the reduction — and, more to the point, a clip
    /// with the module switched on but turned down would have its colour
    /// quietly altered.
    func validateRoundTrip() throws {
        print("\nConversion round trip")
        // Chroma is a constant, not a gradient. The engine samples the chroma
        // plane bilinearly — correctly, since 4:2:0 colour is half resolution —
        // so a varying chroma would be compared against a nearest-neighbour
        // expectation and this would measure the interpolation rather than the
        // transform. Luminance carries the gradient, at full resolution, where
        // the two agree exactly.
        let frame = makeFrame { x, _ in
            (luma: 0.08 + 0.84 * Double(x) / Double(Check.width), cb: 0.22, cr: -0.17)
        }
        // The smallest setting the engine will accept, which blends four
        // ten-thousandths of the filtered result.
        let pixels = try run(spatial(luma: 1), current: frame)

        // The truth, computed on the CPU from the same matrix the shader uses.
        let yuv = YUVUniforms.make(for: frame, fallbackMatrix: "BT.709")
        var worst = 0.0
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
        for y in stride(from: 4, to: Check.height - 4, by: 7) {
            for x in stride(from: 4, to: Check.width - 4, by: 5) {
                let sample = SIMD3<Float>(
                    Float(lumaBase[y * lumaStride + x]) / 255,
                    Float(chromaBase[(y / 2) * chromaStride + (x / 2) * 2]) / 255,
                    Float(chromaBase[(y / 2) * chromaStride + (x / 2) * 2 + 1]) / 255)
                let shifted = sample + SIMD3(yuv.offset.x, yuv.offset.y, yuv.offset.z)
                let expected = SIMD3(yuv.column0.x, yuv.column0.y, yuv.column0.z) * shifted.x
                    + SIMD3(yuv.column1.x, yuv.column1.y, yuv.column1.z) * shifted.y
                    + SIMD3(yuv.column2.x, yuv.column2.y, yuv.column2.z) * shifted.z
                let actual = pixels[y * Check.width + x]
                worst = max(worst, Double(abs(actual.x - expected.x)))
                worst = max(worst, Double(abs(actual.y - expected.y)))
                worst = max(worst, Double(abs(actual.z - expected.z)))
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        Check.check("planes round-trip to the decoded picture", worst < 0.004,
                    String(format: "worst channel error %.5f", worst))
    }

    // MARK: 2. It removes noise

    func validateTemporalReduction() throws {
        print("\nTemporal reduction, static camera")
        let sigma = 0.022
        let frames = (0..<5).map { index -> CVPixelBuffer in
            var noise = Noise(seed: UInt64(index) &+ 17)
            var values = [Double](repeating: 0, count: Check.width * Check.height)
            for i in values.indices { values[i] = 0.45 + noise.normal() * sigma }
            return makeFrame { x, y in (luma: values[y * Check.width + x], cb: 0, cr: 0) }
        }
        let neighbours = window(frames, current: 2)
        let baseline = try run(temporal(luma: 1), current: frames[2], neighbours: neighbours)
        let reduced = try run(temporal(luma: 100), current: frames[2], neighbours: neighbours)

        let area = (x: 32..<(Check.width - 32), y: 24..<(Check.height - 24))
        let before = deviation(region(baseline, x: area.x, y: area.y))
        let after = deviation(region(reduced, x: area.x, y: area.y))
        // Five independent samples of the same scene point average to 1/sqrt(5)
        // of the noise. Rejection and the detail weighting hold that back, so
        // the bar is set at a halving rather than at the theoretical 0.45.
        Check.check("five frames halve the noise", after < before * 0.5,
                    String(format: "%.4f -> %.4f  (%.0f%% removed)",
                           before, after, (1 - after / before) * 100))
        let drift = abs(mean(region(reduced, x: area.x, y: area.y))
                        - mean(region(baseline, x: area.x, y: area.y)))
        Check.check("brightness is unchanged", drift < 0.004, String(format: "%.5f", drift))

        // Alignment on a shot that is not moving must be free. There is nothing
        // for the search to find, and a search that invents motion out of grain
        // would quietly cost every tripod shot part of its reduction.
        let unaligned = try run(temporal(luma: 100, motionCompensated: false),
                                current: frames[2], neighbours: neighbours)
        let withoutMotion = deviation(region(unaligned, x: area.x, y: area.y))
        Check.check("alignment costs a static shot nothing", after < withoutMotion * 1.06,
                    String(format: "aligned %.4f, unaligned %.4f", after, withoutMotion))

        // Three frames must land between one and five, or the control is not
        // doing what it says.
        let three = try run(temporal(luma: 100, frames: .three),
                            current: frames[2], neighbours: neighbours)
        let middle = deviation(region(three, x: area.x, y: area.y))
        Check.check("three frames sit between one and five",
                    middle < before && middle > after,
                    String(format: "%.4f", middle))
    }

    // MARK: 3. It does not ghost

    /// A bright bar crossing a static background.
    ///
    /// The bar is somewhere different in every frame, so the places it has just
    /// left and is about to reach are the places a naive temporal filter leaves
    /// a trail. Nothing may appear there.
    func validateGhosting() throws {
        print("\nGhosting")
        let sigma = 0.015
        let barWidth = 24, step = 12, centre = 116
        func frame(_ index: Int) -> CVPixelBuffer {
            var noise = Noise(seed: UInt64(index) &+ 91)
            var values = [Double](repeating: 0, count: Check.width * Check.height)
            let start = centre + (index - 2) * step
            for y in 0..<Check.height {
                for x in 0..<Check.width {
                    let inBar = x >= start && x < start + barWidth
                    values[y * Check.width + x] = (inBar ? 0.85 : 0.32) + noise.normal() * sigma
                }
            }
            return makeFrame { x, y in (luma: values[y * Check.width + x], cb: 0, cr: 0) }
        }
        let frames = (0..<5).map(frame)
        let reduced = try run(temporal(luma: 100), current: frames[2],
                              neighbours: window(frames, current: 2))

        // Where the bar was one frame ago and is not now, and where it will be
        // next frame. Both must read as background.
        let rows = 40..<(Check.height - 40)
        let trailing = mean(region(reduced, x: (centre - step)..<(centre - 2), y: rows))
        let leading = mean(region(reduced, x: (centre + barWidth + 2)..<(centre + barWidth + step), y: rows))
        Check.check("no trail behind the bar", abs(trailing - 0.32) < 0.02,
                    String(format: "%.4f vs 0.32", trailing))
        Check.check("no ghost ahead of the bar", abs(leading - 0.32) < 0.02,
                    String(format: "%.4f vs 0.32", leading))
        // And the bar itself has to still be a bar.
        let bar = mean(region(reduced, x: (centre + 4)..<(centre + barWidth - 4), y: rows))
        Check.check("the bar keeps its brightness", abs(bar - 0.85) < 0.03,
                    String(format: "%.4f vs 0.85", bar))

        // Motion compensation, measured on a scene that actually moves. With
        // the frames aligned the noise averages away; without it every sample
        // is rejected as motion and the pass returns almost the frame it was
        // given. That difference is the whole feature.
        print("\nMotion compensation, moving camera")
        let shift = 6
        func panned(_ index: Int) -> CVPixelBuffer {
            var noise = Noise(seed: UInt64(index) &+ 301)
            var values = [Double](repeating: 0, count: Check.width * Check.height)
            let offset = Double((index - 2) * shift)
            for y in 0..<Check.height {
                for x in 0..<Check.width {
                    let u = Double(x) - offset
                    let pattern = 0.45 + 0.18 * sin(u / 13) * cos(Double(y) / 17)
                    values[y * Check.width + x] = pattern + noise.normal() * 0.02
                }
            }
            return makeFrame { x, y in (luma: values[y * Check.width + x], cb: 0, cr: 0) }
        }
        let moving = (0..<5).map(panned)
        let aligned = try run(temporal(luma: 100), current: moving[2],
                              neighbours: window(moving, current: 2))
        let unaligned = try run(temporal(luma: 100, motionCompensated: false),
                                current: moving[2], neighbours: window(moving, current: 2))
        let base = try run(temporal(luma: 1), current: moving[2],
                           neighbours: window(moving, current: 2))
        // Measured against the noise-free pattern rather than as a deviation:
        // on a scene with real structure, a smaller standard deviation could
        // just as easily mean the structure was flattened.
        func errorFromTruth(_ pixels: [SIMD4<Float>]) -> Double {
            var total = 0.0, count = 0
            for y in 40..<(Check.height - 40) {
                for x in 48..<(Check.width - 48) {
                    let truth = 0.45 + 0.18 * sin(Double(x) / 13) * cos(Double(y) / 17)
                    let pixel = pixels[y * Check.width + x]
                    let luma = Double(0.2126 * pixel.x + 0.7152 * pixel.y + 0.0722 * pixel.z)
                    total += (luma - truth) * (luma - truth); count += 1
                }
            }
            return (total / Double(count)).squareRoot()
        }
        let rawError = errorFromTruth(base)
        let alignedError = errorFromTruth(aligned)
        let unalignedError = errorFromTruth(unaligned)
        Check.check("aligned frames clean a moving scene", alignedError < rawError * 0.72,
                    String(format: "%.4f -> %.4f", rawError, alignedError))
        Check.check("alignment is what does it", alignedError < unalignedError * 0.85,
                    String(format: "aligned %.4f, unaligned %.4f", alignedError, unalignedError))
    }

    // MARK: 4. It keeps fine detail

    func validateDetailPreservation() throws {
        print("\nFine detail")
        let period = 8.0, amplitude = 0.13
        // A band of fine texture with plain picture either side, which is what
        // hair against a wall or grass against a sky actually looks like. The
        // frame matters: the noise floor is found by looking for the quietest
        // part of a neighbourhood, so a frame with nowhere quiet in it is the
        // hardest case there is. That case is measured separately below.
        let bandTop = Check.height / 3, bandBottom = Check.height * 2 / 3
        func striped(_ index: Int, everywhere: Bool = false) -> CVPixelBuffer {
            var noise = Noise(seed: UInt64(index) &+ 455)
            return makeFrame { x, y in
                let textured = everywhere || (y >= bandTop && y < bandBottom)
                let stripe = textured
                    ? 0.5 + amplitude * (sin(Double(x) * 2 * .pi / period) > 0 ? 1 : -1)
                    : 0.5
                return (luma: stripe + noise.normal() * 0.02, cb: 0, cr: 0)
            }
        }
        let frames = (0..<5).map { striped($0) }
        let area = (x: 40..<(Check.width - 40), y: (bandTop + 6)..<(bandBottom - 6))

        /// Half the peak-to-trough distance of the pattern, which is the
        /// amplitude that survived.
        func contrast(_ pixels: [SIMD4<Float>]) -> Double {
            var high: [Double] = [], low: [Double] = []
            for y in area.y {
                for x in area.x {
                    let pixel = pixels[y * Check.width + x]
                    let luma = Double(0.2126 * pixel.x + 0.7152 * pixel.y + 0.0722 * pixel.z)
                    // The two samples furthest from an edge of the pattern, so
                    // this measures the pattern rather than its transitions.
                    let phase = Double(x).truncatingRemainder(dividingBy: period)
                    if abs(phase - period * 0.25) < 0.6 { high.append(luma) }
                    if abs(phase - period * 0.75) < 0.6 { low.append(luma) }
                }
            }
            return (mean(high) - mean(low)) / 2
        }
        let baseline = try run(temporal(luma: 1), current: frames[2],
                               neighbours: window(frames, current: 2))
        let temporalResult = try run(temporal(luma: 100), current: frames[2],
                                     neighbours: window(frames, current: 2))
        let spatialResult = try run(spatial(luma: 100, radius: 30), current: frames[2])

        let reference = contrast(baseline)
        let afterTemporal = contrast(temporalResult)
        let afterSpatial = contrast(spatialResult)
        // The worst case: the same texture filling the frame edge to edge, so
        // there is nowhere for the noise floor to be measured from and the
        // engine cannot tell texture from grain. It still has to be usable.
        let wallToWall = (0..<5).map { striped($0, everywhere: true) }
        let hardBaseline = try run(spatial(luma: 1, radius: 30), current: wallToWall[2])
        let hardResult = try run(spatial(luma: 100, radius: 30), current: wallToWall[2])
        // Temporal reduction averages independent samples of the SAME detail,
        // so it has no reason to remove any of it. Anything much below this
        // means the frames are being mixed rather than combined.
        Check.check("temporal keeps the pattern", afterTemporal > reference * 0.9,
                    String(format: "%.4f -> %.4f (%.0f%% kept)",
                           reference, afterTemporal, afterTemporal / reference * 100))
        // Spatial reduction is a filter and will always cost something. Below
        // about two thirds it reads as waxy.
        Check.check("spatial keeps most of the pattern", afterSpatial > reference * 0.8,
                    String(format: "%.4f (%.0f%% kept)", afterSpatial, afterSpatial / reference * 100))
        let hardReference = contrast(hardBaseline), hardKept = contrast(hardResult)
        Check.check("and most of it with nowhere to measure from",
                    hardKept > hardReference * 0.6,
                    String(format: "%.0f%% kept", hardKept / hardReference * 100))
    }

    // MARK: 5. Colour and luminance are independent

    func validateChromaSeparation() throws {
        print("\nChroma")
        func speckled(_ index: Int) -> CVPixelBuffer {
            var noise = Noise(seed: UInt64(index) &+ 777)
            return makeFrame { _, _ in
                (luma: 0.4 + noise.normal() * 0.004,
                 cb: noise.normal() * 0.05,
                 cr: noise.normal() * 0.05)
            }
        }
        let frames = (0..<5).map(speckled)
        let neighbours = window(frames, current: 2)
        let area = (x: 32..<(Check.width - 32), y: 24..<(Check.height - 24))

        func chromaDeviation(_ pixels: [SIMD4<Float>]) -> Double {
            var blues: [Double] = [], reds: [Double] = []
            for y in area.y {
                for x in area.x {
                    let p = pixels[y * Check.width + x]
                    let luma = Double(0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z)
                    blues.append((Double(p.z) - luma) / 1.8556)
                    reds.append((Double(p.x) - luma) / 1.5748)
                }
            }
            return (deviation(blues) + deviation(reds)) / 2
        }

        let baseline = try run(temporal(luma: 1), current: frames[2], neighbours: neighbours)
        // Chroma alone, with the luminance control at zero.
        let cleaned = try run(temporal(luma: 0.0, chroma: 100), current: frames[2], neighbours: neighbours)
        let beforeChroma = chromaDeviation(baseline), afterChroma = chromaDeviation(cleaned)
        let beforeLuma = deviation(region(baseline, x: area.x, y: area.y))
        let afterLuma = deviation(region(cleaned, x: area.x, y: area.y))
        Check.check("colour speckle is removed", afterChroma < beforeChroma * 0.55,
                    String(format: "%.4f -> %.4f", beforeChroma, afterChroma))
        Check.check("luminance is left alone", afterLuma < beforeLuma * 1.15,
                    String(format: "%.5f -> %.5f", beforeLuma, afterLuma))
    }

    // MARK: 6. It never blends across a cut

    /// The last line of defence, below the two frame suppliers that refuse to
    /// offer a neighbour from another shot in the first place. Even handed one,
    /// nothing may come through.
    func validateSceneCut() throws {
        print("\nScene cut")
        var noise = Noise(seed: 31)
        let current = makeFrame { _, _ in (luma: 0.55 + noise.normal() * 0.02, cb: 0, cr: 0) }
        let otherShot = (0..<4).map { index -> CVPixelBuffer in
            var other = Noise(seed: UInt64(index) &+ 62)
            return makeFrame { _, _ in (luma: 0.12 + other.normal() * 0.02, cb: 0.4, cr: -0.3) }
        }
        let neighbours = [
            NoiseFrame(pixelBuffer: otherShot[0], offset: -2),
            NoiseFrame(pixelBuffer: otherShot[1], offset: -1),
            NoiseFrame(pixelBuffer: otherShot[2], offset: 1),
            NoiseFrame(pixelBuffer: otherShot[3], offset: 2)
        ]
        let result = try run(temporal(luma: 100, chroma: 100), current: current, neighbours: neighbours)
        let area = (x: 32..<(Check.width - 32), y: 24..<(Check.height - 24))
        let level = mean(region(result, x: area.x, y: area.y))
        Check.check("the other shot contributes nothing", abs(level - 0.55) < 0.015,
                    String(format: "%.4f vs 0.55", level))
    }

    // MARK: 7. Spatial reduction respects edges

    func validateSpatialEdges() throws {
        print("\nSpatial reduction")
        var noise = Noise(seed: 5150)
        let boundary = Check.width / 2
        let frame = makeFrame { x, _ in
            (luma: (x < boundary ? 0.22 : 0.78) + noise.normal() * 0.025, cb: 0, cr: 0)
        }
        let baseline = try run(spatial(luma: 1), current: frame)
        let filtered = try run(spatial(luma: 100, radius: 70), current: frame)
        let unprotected = try run(spatial(luma: 100, radius: 70, protectsEdges: false), current: frame)

        let flat = (x: 20..<(boundary - 24), y: 24..<(Check.height - 24))
        let before = deviation(region(baseline, x: flat.x, y: flat.y))
        let after = deviation(region(filtered, x: flat.x, y: flat.y))
        Check.check("flat areas are cleaned", after < before * 0.62,
                    String(format: "%.4f -> %.4f (%.0f%% removed)",
                           before, after, (1 - after / before) * 100))

        // Four pixels either side of the boundary. A filter that reached across
        // it would pull these two numbers together.
        func edgeContrast(_ pixels: [SIMD4<Float>]) -> Double {
            let rows = 24..<(Check.height - 24)
            let right = mean(region(pixels, x: (boundary + 2)..<(boundary + 6), y: rows))
            let left = mean(region(pixels, x: (boundary - 6)..<(boundary - 2), y: rows))
            return right - left
        }
        let reference = edgeContrast(baseline)
        let kept = edgeContrast(filtered)
        Check.check("the edge stays where it was", kept > reference * 0.92,
                    String(format: "%.4f -> %.4f (%.0f%% kept)",
                           reference, kept, kept / reference * 100))
        Check.check("edge protection is what keeps it",
                    kept >= edgeContrast(unprotected) - 1e-4,
                    String(format: "protected %.4f, unprotected %.4f", kept, edgeContrast(unprotected)))
    }

    // MARK: 8. Detail recovery returns detail, not noise

    func validateDetailRecovery() throws {
        print("\nDetail recovery")
        var noise = Noise(seed: 8080)
        // Heavy noise and texture only a little above it: the case where the
        // filter genuinely has to remove detail to remove the grain, which is
        // the only case recovery exists for. On a clean picture with strong
        // texture the filter keeps the texture and there is nothing to put
        // back — which the Fine detail checks above already measure.
        let period = 6.0, grain = 0.05, texture = 0.08
        // Textured above, flat below, so one frame answers both halves of the
        // question: did the detail come back, and did the noise come back with
        // it.
        // A textured band with flat picture either side of it, which is what a
        // real frame looks like and what the noise floor's erosion needs: a
        // frame textured edge to edge has nowhere to measure its own noise
        // from, and neither would a photograph of nothing but grass.
        let bandTop = Check.height / 3, bandBottom = Check.height * 2 / 3
        let frame = makeFrame { x, y in
            let textured = y >= bandTop && y < bandBottom
            let base = textured
                ? 0.5 + texture * (sin(Double(x) * 2 * .pi / period) > 0 ? 1 : -1)
                : 0.5
            return (luma: base + noise.normal() * grain, cb: 0, cr: 0)
        }
        func contrast(_ pixels: [SIMD4<Float>]) -> Double {
            var high: [Double] = [], low: [Double] = []
            for y in (bandTop + 6)..<(bandBottom - 6) {
                for x in 40..<(Check.width - 40) {
                    let p = pixels[y * Check.width + x]
                    let luma = Double(0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z)
                    let phase = Double(x).truncatingRemainder(dividingBy: period)
                    if abs(phase - period * 0.25) < 0.6 { high.append(luma) }
                    if abs(phase - period * 0.75) < 0.6 { low.append(luma) }
                }
            }
            return (mean(high) - mean(low)) / 2
        }
        let flat = (x: 40..<(Check.width - 40), y: (bandBottom + 8)..<(Check.height - 16))
        // Detail Protection is deliberately at zero. With it at its default the
        // filter leaves this texture almost untouched, which is the right
        // answer and leaves recovery nothing to recover — so the control that
        // is under test here is the one that has to be switched off to see it.
        let without = try run(spatial(luma: 100, radius: 100, recovery: 0, protection: 0), current: frame)
        let with = try run(spatial(luma: 100, radius: 100, recovery: 100, protection: 0), current: frame)

        let plain = contrast(without), recovered = contrast(with)
        Check.check("recovery brings detail back", recovered > plain * 1.05,
                    String(format: "%.4f -> %.4f", plain, recovered))
        let plainNoise = deviation(region(without, x: flat.x, y: flat.y))
        let recoveredNoise = deviation(region(with, x: flat.x, y: flat.y))
        // Coring is the whole reason this is not a sharpen: below the noise
        // floor the residual is discarded, so a flat area gets nothing back.
        Check.check("and leaves the noise out", recoveredNoise < plainNoise * 1.5,
                    String(format: "%.5f -> %.5f", plainNoise, recoveredNoise))
    }

    // MARK: 9. The result is steady over time

    /// Two consecutive frames of a scene that is not moving must denoise to
    /// nearly the same picture. A filter that is individually excellent and
    /// frame-to-frame unstable reads as a crawling, shimmering surface, and is
    /// worse to watch than the noise it removed.
    func validateTemporalStability() throws {
        print("\nTemporal stability")
        let frames = (0..<6).map { index -> CVPixelBuffer in
            var noise = Noise(seed: UInt64(index) &+ 1201)
            return makeFrame { x, y in
                (luma: 0.4 + 0.1 * sin(Double(x) / 21) + noise.normal() * 0.022, cb: 0, cr: 0)
            }
        }
        let first = try run(temporal(luma: 100), current: frames[2],
                            neighbours: window(Array(frames[0...4]), current: 2))
        let second = try run(temporal(luma: 100), current: frames[3],
                             neighbours: window(Array(frames[1...5]), current: 2))
        let rawFirst = try run(temporal(luma: 1), current: frames[2],
                               neighbours: window(Array(frames[0...4]), current: 2))
        let rawSecond = try run(temporal(luma: 1), current: frames[3],
                                neighbours: window(Array(frames[1...5]), current: 2))
        let area = (x: 32..<(Check.width - 32), y: 24..<(Check.height - 24))

        func flicker(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double {
            let left = region(a, x: area.x, y: area.y), right = region(b, x: area.x, y: area.y)
            return deviation(zip(left, right).map { $0 - $1 })
        }
        let before = flicker(rawFirst, rawSecond)
        let after = flicker(first, second)
        Check.check("consecutive frames land in the same place", after < before * 0.55,
                    String(format: "%.4f -> %.4f", before, after))
    }

    // MARK: 10. It is the same every time

    /// Export must not change between runs, and the picture that was graded
    /// must be the picture that is written.
    func validateDeterminism() throws {
        print("\nDeterminism")
        let frames = (0..<5).map { index -> CVPixelBuffer in
            var noise = Noise(seed: UInt64(index) &+ 909)
            return makeFrame { x, y in
                (luma: 0.4 + 0.2 * sin(Double(x + y) / 15) + noise.normal() * 0.02,
                 cb: noise.normal() * 0.02, cr: 0)
            }
        }
        var settings = temporal(luma: 70, chroma: 80)
        settings.isSpatialEnabled = true
        settings.spatialLuma = 40
        settings.spatialChroma = 60
        settings.detailRecovery = 35
        let neighbours = window(frames, current: 2)
        let first = try run(settings, current: frames[2], neighbours: neighbours)
        let second = try run(settings, current: frames[2], neighbours: neighbours)
        Check.check("two runs are bit-identical", first == second)

        // And the Quality switch must change how long it takes, not what it is.
        var preview = settings
        preview.quality = .preview
        let coarse = try run(preview, current: frames[2], neighbours: neighbours)
        var worst = 0.0
        for index in first.indices {
            worst = max(worst, Double(abs(first[index].x - coarse[index].x)))
        }
        Check.check("preview quality is the same picture", worst < 0.06,
                    String(format: "worst difference %.4f", worst))
    }

    // MARK: 11. What the presets actually deliver

    /// Every other measurement in this file drives a strength of 100, which
    /// proves the engine CAN denoise. It says nothing about what a user gets,
    /// because nobody types 100 — they press a preset.
    ///
    /// That gap is not academic: it is how a build shipped where every check
    /// here passed and the presets removed almost nothing. So this section
    /// measures the shipping presets on a frame with a flat area, real texture
    /// and colour noise, and holds each one to what its own description claims.
    func validatePresetStrength() throws {
        print("\nPreset strength")
        // A scene with somewhere to measure noise (the flat left half),
        // somewhere to measure detail (the textured right half) and colour
        // noise throughout. Five frames of it, static, with independent noise —
        // so a temporal stage has everything in its favour and whatever it
        // fails to remove is the calibration rather than the circumstances.
        let sigma = 0.020, chromaSigma = 0.030
        let split = Check.width / 2
        func content(_ x: Int, _ y: Int) -> Double {
            x < split
                ? 0.42
                : 0.42 + 0.085 * sin(Double(x) / 3.1) * cos(Double(y) / 2.7)
        }
        let frames = (0..<5).map { index -> CVPixelBuffer in
            var noise = Noise(seed: UInt64(index) &+ 1301)
            return makeFrame { x, y in
                (luma: content(x, y) + noise.normal() * sigma,
                 cb: 0.12 + noise.normal() * chromaSigma,
                 cr: -0.09 + noise.normal() * chromaSigma)
            }
        }
        let neighbours = window(frames, current: 2)
        let flat = (x: 16..<(split - 16), y: 24..<(Check.height - 24))
        let textured = (x: (split + 16)..<(Check.width - 16), y: 24..<(Check.height - 24))

        // The engine's own do-nothing baseline: every pass runs, four
        // ten-thousandths of the result is blended, so this isolates the
        // reduction from the conversions on either side of it.
        var reference = NoiseReduction.neutral
        reference.isTemporalEnabled = true
        reference.isSpatialEnabled = true
        reference.temporalLuma = 1; reference.spatialLuma = 1
        reference.quality = .high
        let baseline = try run(reference, current: frames[2], neighbours: neighbours)
        let noiseFloor = deviation(region(baseline, x: flat.x, y: flat.y))
        let detailFloor = deviation(region(baseline, x: textured.x, y: textured.y))

        // What each preset has to remove from the flat area, and the least
        // texture it may leave behind. The floors come from what the names
        // promise: "a gentle pass" may be gentle, "high ISO and heavily lifted
        // shadows" may not be.
        let expected: [(NoiseReduction.Preset, removed: Double, detail: Double)] = [
            (.light, 0.20, 0.80),
            (.medium, 0.40, 0.72),
            (.strong, 0.60, 0.60),
            (.lowLight, 0.60, 0.60)
        ]
        for (preset, minimumRemoved, minimumDetail) in expected {
            var settings = preset.applied(to: .neutral)
            settings.quality = .high
            let pixels = try run(settings, current: frames[2], neighbours: neighbours)
            let removed = 1 - deviation(region(pixels, x: flat.x, y: flat.y)) / noiseFloor
            let kept = deviation(region(pixels, x: textured.x, y: textured.y)) / detailFloor
            Check.check("\(preset.rawValue) removes what it promises", removed >= minimumRemoved,
                        String(format: "%.0f%% removed, floor %.0f%%",
                               removed * 100, minimumRemoved * 100))
            Check.check("\(preset.rawValue) keeps the texture", kept >= minimumDetail,
                        String(format: "%.0f%% kept, floor %.0f%%", kept * 100, minimumDetail * 100))
        }

        // Chroma Cleanup: colour noise goes, luminance is untouched. Measured
        // rather than trusted, because it is the one preset whose whole claim is
        // about what it does NOT do.
        var cleanup = NoiseReduction.Preset.chromaCleanup.applied(to: .neutral)
        cleanup.quality = .high
        let cleaned = try run(cleanup, current: frames[2], neighbours: neighbours)
        let lumaAfter = deviation(region(cleaned, x: flat.x, y: flat.y))
        Check.check("chromaCleanup leaves luminance where it was",
                    abs(lumaAfter - noiseFloor) < noiseFloor * 0.12,
                    String(format: "%.4f -> %.4f", noiseFloor, lumaAfter))
    }
}
