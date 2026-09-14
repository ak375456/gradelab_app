import Metal
import XCTest
@testable import GradeLab

/// The scope analysis kernels, driven with known images.
///
/// These run the real shaders against textures whose correct answer is known by
/// construction, which is the only way to catch a scope that is plausible but
/// wrong — a mirrored vectorscope, a waveform that has become a histogram, a
/// parade with its channels transposed.
final class ScopeAnalysisTests: XCTestCase {
    private var context: MetalContext!
    private let side = 64

    override func setUpWithError() throws {
        try super.setUpWithError()
        context = try MetalContext()
    }

    // MARK: - Harness

    private func pipeline(_ name: String) throws -> MTLComputePipelineState {
        let function = try XCTUnwrap(context.library.makeFunction(name: name), "missing kernel \(name)")
        return try context.device.makeComputePipelineState(function: function)
    }

    /// An analysis texture whose colour is a function of normalised position, so
    /// a test can build a flat field or a horizontal ramp with one closure.
    private func analysisTexture(_ colour: (Double, Double) -> SIMD3<Double>) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(context.device.makeTexture(descriptor: descriptor))
        var pixels = [Float16](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let rgb = colour(Double(x) / Double(side - 1), Double(y) / Double(side - 1))
                let i = (y * side + x) * 4
                pixels[i] = Float16(rgb.x); pixels[i + 1] = Float16(rgb.y)
                pixels[i + 2] = Float16(rgb.z); pixels[i + 3] = 1
            }
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: side * 8)
        }
        return texture
    }

    private func uniforms(cells: Int = ScopeAnalyzer.vectorCells,
                          space: ScopeColorSpace = .rec709) -> ScopeUniforms {
        let k = space.lumaCoefficients
        return ScopeUniforms(
            width: UInt32(side), height: UInt32(side),
            bins: UInt32(ScopeAnalyzer.binCount), cells: UInt32(cells),
            intensity: 1, kR: k.r, kG: k.g, kB: k.b,
            chromaScale: Float(1 / space.fullSaturationRadius))
    }

    private func run(_ kernel: String, on texture: MTLTexture, count: Int,
                     uniforms u: ScopeUniforms) throws -> [UInt32] {
        let state = try pipeline(kernel)
        let buffer = try XCTUnwrap(context.device.makeBuffer(
            length: count * MemoryLayout<UInt32>.stride, options: .storageModeShared))
        memset(buffer.contents(), 0, buffer.length)
        var u = u
        let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(state)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<ScopeUniforms>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: side, height: side, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        return Array(UnsafeBufferPointer(
            start: buffer.contents().bindMemory(to: UInt32.self, capacity: count), count: count))
    }

    private func peakBin(_ bins: ArraySlice<UInt32>) -> Int {
        let base = bins.startIndex
        return (bins.indices.max { bins[$0] < bins[$1] } ?? base) - base
    }

    private func histogram(_ colour: SIMD3<Double>) throws -> [UInt32] {
        let texture = try analysisTexture { _, _ in colour }
        return try run("scopeHistogram", on: texture,
                       count: ScopeAnalyzer.binCount * 3, uniforms: uniforms())
    }

    private func channelPeaks(_ bins: [UInt32]) -> (r: Int, g: Int, b: Int) {
        let n = ScopeAnalyzer.binCount
        return (peakBin(bins[0..<n]), peakBin(bins[n..<(2 * n)]), peakBin(bins[(2 * n)..<(3 * n)]))
    }

    // MARK: - Histogram

    func testBlackCollectsAtTheBottomOfEveryChannel() throws {
        let peaks = channelPeaks(try histogram(.init(0, 0, 0)))
        XCTAssertEqual(peaks.r, 0); XCTAssertEqual(peaks.g, 0); XCTAssertEqual(peaks.b, 0)
    }

    func testWhiteCollectsAtTheTopOfEveryChannel() throws {
        let peaks = channelPeaks(try histogram(.init(1, 1, 1)))
        XCTAssertEqual(peaks.r, 255); XCTAssertEqual(peaks.g, 255); XCTAssertEqual(peaks.b, 255)
    }

    func testMidGreyPutsEveryChannelInTheSameMiddleBin() throws {
        let peaks = channelPeaks(try histogram(.init(0.5, 0.5, 0.5)))
        XCTAssertEqual(peaks.r, peaks.g); XCTAssertEqual(peaks.g, peaks.b)
        XCTAssertEqual(peaks.r, 128, accuracy: 2)
    }

    func testPureChannelsSeparate() throws {
        let red = channelPeaks(try histogram(.init(1, 0, 0)))
        XCTAssertEqual(red.r, 255); XCTAssertEqual(red.g, 0); XCTAssertEqual(red.b, 0)
        let green = channelPeaks(try histogram(.init(0, 1, 0)))
        XCTAssertEqual(green.g, 255); XCTAssertEqual(green.r, 0); XCTAssertEqual(green.b, 0)
        let blue = channelPeaks(try histogram(.init(0, 0, 1)))
        XCTAssertEqual(blue.b, 255); XCTAssertEqual(blue.r, 0); XCTAssertEqual(blue.g, 0)
    }

    func testEveryPixelIsCountedExactlyOncePerChannel() throws {
        let bins = try histogram(.init(0.4, 0.6, 0.8))
        let n = ScopeAnalyzer.binCount
        for channel in 0..<3 {
            let total = bins[(channel * n)..<((channel + 1) * n)].reduce(0, &+)
            XCTAssertEqual(Int(total), side * side, "channel \(channel) lost or duplicated samples")
        }
    }

    // MARK: - Waveform

    /// The point of a waveform: horizontal position is preserved. Black on the
    /// left and white on the right must read low on the left and high on the
    /// right — a histogram of the same frame could not tell the two apart.
    func testWaveformKeepsHorizontalPosition() throws {
        let texture = try analysisTexture { x, _ in x < 0.5 ? .init(0, 0, 0) : .init(1, 1, 1) }
        let bins = try run("scopeWaveform", on: texture,
                           count: side * ScopeAnalyzer.binCount, uniforms: uniforms())
        let n = ScopeAnalyzer.binCount
        XCTAssertEqual(peakBin(bins[0..<n]), 0, "the left edge should be black")
        let last = (side - 1) * n
        XCTAssertEqual(peakBin(bins[last..<(last + n)]), 255, "the right edge should be white")
    }

    func testWaveformFollowsAHorizontalRamp() throws {
        let texture = try analysisTexture { x, _ in .init(x, x, x) }
        let bins = try run("scopeWaveform", on: texture,
                           count: side * ScopeAnalyzer.binCount, uniforms: uniforms())
        let n = ScopeAnalyzer.binCount
        let peaks = (0..<side).map { peakBin(bins[($0 * n)..<(($0 + 1) * n)]) }
        XCTAssertEqual(peaks.first, 0)
        XCTAssertEqual(peaks.last, 255)
        for (left, right) in zip(peaks, peaks.dropFirst()) {
            XCTAssertLessThanOrEqual(left, right, "a rising ramp must not fall anywhere")
        }
    }

    /// A vertical ramp carries no horizontal information, so every column must
    /// hold the same spread. This is what fails if a waveform is accidentally
    /// implemented as a histogram.
    func testAVerticalRampSpreadsEveryColumnEqually() throws {
        let texture = try analysisTexture { _, y in .init(y, y, y) }
        let bins = try run("scopeWaveform", on: texture,
                           count: side * ScopeAnalyzer.binCount, uniforms: uniforms())
        let n = ScopeAnalyzer.binCount
        let occupied = (0..<side).map { column in
            bins[(column * n)..<((column + 1) * n)].filter { $0 > 0 }.count
        }
        XCTAssertEqual(Set(occupied).count, 1, "columns differ on an image with no horizontal variation")
        XCTAssertEqual(occupied[0], side, "each column should hold one level per row")
    }

    func testWaveformUsesTheWorkingSpaceLumaWeights() throws {
        // Pure green is the heaviest channel in Rec.709 (0.7152) and must read
        // far higher than pure blue (0.0722).
        let n = ScopeAnalyzer.binCount
        func level(_ rgb: SIMD3<Double>) throws -> Int {
            let texture = try analysisTexture { _, _ in rgb }
            let bins = try run("scopeWaveform", on: texture, count: side * n, uniforms: uniforms())
            return peakBin(bins[0..<n])
        }
        let green = try level(.init(0, 1, 0)), blue = try level(.init(0, 0, 1))
        XCTAssertEqual(green, Int((0.7152 * 255).rounded()), accuracy: 2)
        XCTAssertEqual(blue, Int((0.0722 * 255).rounded()), accuracy: 2)
    }

    // MARK: - Parade

    func testNeutralGreyAlignsTheThreeParadeChannels() throws {
        let texture = try analysisTexture { _, _ in .init(0.5, 0.5, 0.5) }
        let n = ScopeAnalyzer.binCount, plane = side * n
        let bins = try run("scopeParade", on: texture, count: plane * 3, uniforms: uniforms())
        let peaks = (0..<3).map { peakBin(bins[($0 * plane)..<($0 * plane + n)]) }
        XCTAssertEqual(peaks[0], peaks[1]); XCTAssertEqual(peaks[1], peaks[2])
    }

    /// A warm cast has to show as the red panel sitting above the blue one.
    func testAWarmCastSeparatesTheParadeChannels() throws {
        let texture = try analysisTexture { _, _ in .init(0.8, 0.5, 0.3) }
        let n = ScopeAnalyzer.binCount, plane = side * n
        let bins = try run("scopeParade", on: texture, count: plane * 3, uniforms: uniforms())
        let peaks = (0..<3).map { peakBin(bins[($0 * plane)..<($0 * plane + n)]) }
        XCTAssertGreaterThan(peaks[0], peaks[1], "red should sit above green on a warm frame")
        XCTAssertGreaterThan(peaks[1], peaks[2], "green should sit above blue on a warm frame")
    }

    func testParadeKeepsHorizontalPositionWithinEachChannel() throws {
        let texture = try analysisTexture { x, _ in x < 0.5 ? .init(0, 0, 0) : .init(1, 1, 1) }
        let n = ScopeAnalyzer.binCount, plane = side * n
        let bins = try run("scopeParade", on: texture, count: plane * 3, uniforms: uniforms())
        for channel in 0..<3 {
            let base = channel * plane
            XCTAssertEqual(peakBin(bins[base..<(base + n)]), 0, "channel \(channel) left edge")
            let last = base + (side - 1) * n
            XCTAssertEqual(peakBin(bins[last..<(last + n)]), 255, "channel \(channel) right edge")
        }
    }

    // MARK: - Vectorscope

    /// Measured at the production cell count: near the boundary a coarser grid
    /// quantises the angle by several degrees, which is not something the test
    /// should be reading as a bug.
    private func vectorAngle(_ colour: SIMD3<Double>,
                             cells: Int = ScopeAnalyzer.vectorCells) throws -> (angle: Double, radius: Double) {
        let texture = try analysisTexture { _, _ in colour }
        let bins = try run("scopeVectorscope", on: texture, count: cells * cells,
                           uniforms: uniforms(cells: cells))
        let index = bins.indices.max { bins[$0] < bins[$1] } ?? 0
        XCTAssertGreaterThan(bins[index], 0, "nothing was plotted")
        // Cell centre back to normalised scope coordinates.
        let x = (Double(index % cells) + 0.5) / Double(cells) * 2 - 1
        let y = (Double(index / cells) + 0.5) / Double(cells) * 2 - 1
        var degrees = atan2(y, x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return (degrees, (x * x + y * y).squareRoot())
    }

    func testNeutralSitsAtTheCentre() throws {
        for level in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let result = try vectorAngle(.init(level, level, level))
            XCTAssertLessThan(result.radius, 0.05,
                              "grey at \(level) should have no saturation, got radius \(result.radius)")
        }
    }

    /// Orientation. These angles are what a Rec.709 graticule expects, and they
    /// come out of the Cb/Cr transform rather than being dialled in: red near
    /// 104 degrees, and the complements opposite their primaries.
    func testPrimariesLandOnTheirGraticuleAngles() throws {
        // Angles derived from the Cb/Cr transform itself, not dialled in: red
        // near 103 degrees is where a Rec.709 graticule puts it.
        let expected: [(SIMD3<Double>, Double, String)] = [
            (.init(1, 0, 0), 102.91, "red"),
            (.init(0, 1, 0), 229.68, "green"),
            (.init(0, 0, 1), 354.76, "blue"),
            (.init(0, 1, 1), 282.91, "cyan"),
            (.init(1, 0, 1), 49.68, "magenta"),
            (.init(1, 1, 0), 174.76, "yellow")
        ]
        for (rgb, angle, name) in expected {
            let result = try vectorAngle(rgb)
            let delta = abs((result.angle - angle + 540).truncatingRemainder(dividingBy: 360) - 180)
            XCTAssertLessThan(delta, 2, "\(name) plotted at \(result.angle), expected \(angle)")
            XCTAssertGreaterThan(result.radius, 0.6, "\(name) should be far from the centre")
            // The graticule computes its target from the same transform, so the
            // trace and the box it should land in cannot drift apart.
            let target = ScopeColorSpace.rec709.scopePoint(rgb)
            var targetAngle = atan2(target.y, target.x) * 180 / .pi
            if targetAngle < 0 { targetAngle += 360 }
            XCTAssertEqual(targetAngle, angle, accuracy: 0.5, "graticule disagrees with the trace for \(name)")
        }
    }

    func testComplementsAreOppositeTheirPrimaries() throws {
        let pairs: [(SIMD3<Double>, SIMD3<Double>, String)] = [
            (.init(1, 0, 0), .init(0, 1, 1), "red/cyan"),
            (.init(0, 1, 0), .init(1, 0, 1), "green/magenta"),
            (.init(0, 0, 1), .init(1, 1, 0), "blue/yellow")
        ]
        for (a, b, name) in pairs {
            let first = try vectorAngle(a).angle, second = try vectorAngle(b).angle
            // Wrapped absolute difference: exactly opposite reads as 180.
            let separation = abs((first - second + 540).truncatingRemainder(dividingBy: 360) - 180)
            XCTAssertEqual(separation, 180, accuracy: 3, "\(name) are \(separation) degrees apart")
        }
    }

    /// Desaturating has to pull the trace in, which is the reading a colourist
    /// actually uses the scope for.
    func testLessSaturationPlotsCloserToTheCentre() throws {
        let strong = try vectorAngle(.init(0.9, 0.1, 0.1)).radius
        let weak = try vectorAngle(.init(0.6, 0.4, 0.4)).radius
        XCTAssertGreaterThan(strong, weak)
        XCTAssertLessThanOrEqual(strong, 1.0, "nothing may plot outside the boundary")
    }

    func testOutliersAreClampedToTheBoundary() throws {
        // Beyond the encodable range: the point is clamped, not allowed to
        // rescale the display.
        let result = try vectorAngle(.init(2, -1, -1))
        XCTAssertLessThanOrEqual(result.radius, 1.02)
    }
}

/// The colour-space maths the shader and the graticule share.
final class ScopeColorSpaceTests: XCTestCase {
    func testRec709CoefficientsSumToOne() {
        let k = ScopeColorSpace.rec709.lumaCoefficients
        XCTAssertEqual(Double(k.r + k.g + k.b), 1, accuracy: 1e-6)
        let hdr = ScopeColorSpace.hlgBT2020.lumaCoefficients
        XCTAssertEqual(Double(hdr.r + hdr.g + hdr.b), 1, accuracy: 1e-6)
    }

    func testAnHDRProjectIsMeasuredInItsOwnSignal() {
        XCTAssertEqual(ScopeColorSpace(.hdrHLG), .hlgBT2020)
        XCTAssertEqual(ScopeColorSpace(.sdr), .rec709)
        XCTAssertEqual(ScopeColorSpace(.sdrWide), .rec709)
        XCTAssertEqual(ScopeColorSpace.hlgBT2020.axisLabel, "HLG signal")
    }

    func testNeutralHasNoChroma() {
        for level in [0.0, 0.5, 1.0] {
            let c = ScopeColorSpace.rec709.chroma(.init(level, level, level))
            XCTAssertEqual(c.cb, 0, accuracy: 1e-9)
            XCTAssertEqual(c.cr, 0, accuracy: 1e-9)
        }
    }

    /// The graticule's targets are computed with the same transform the shader
    /// plots with, so they must sit inside the boundary the shader clamps to.
    func testEveryTargetFitsInsideTheBoundary() {
        for space in [ScopeColorSpace.rec709, .hlgBT2020] {
            for target in ScopeGraticule.targets {
                let point = space.scopePoint(target.rgb)
                let radius = (point.x * point.x + point.y * point.y).squareRoot()
                XCTAssertLessThanOrEqual(radius, 1.0001, "\(target.name) is outside the circle")
                XCTAssertGreaterThan(radius, 0.5, "\(target.name) should be well out from centre")
            }
        }
    }

    func testAnalysisSizeKeepsAspectRatioAndShrinksLargeFrames() {
        let landscape = ScopeAnalyzer.analysisSize(width: 3840, height: 2160)
        XCTAssertEqual(landscape.width, 512)
        XCTAssertEqual(Double(landscape.width) / Double(landscape.height), 16.0 / 9, accuracy: 0.02)
        let portrait = ScopeAnalyzer.analysisSize(width: 2160, height: 3840)
        XCTAssertEqual(portrait.height, 512)
        XCTAssertGreaterThan(portrait.height, portrait.width, "portrait footage must stay portrait")
        // Already small: left alone rather than upscaled for no reason.
        XCTAssertEqual(ScopeAnalyzer.analysisSize(width: 320, height: 240).width, 320)
    }

    func testBinCapacityMatchesEachScopeLayout() {
        XCTAssertEqual(ScopeAnalyzer.binCapacity(.histogram, width: 512), 256 * 3)
        XCTAssertEqual(ScopeAnalyzer.binCapacity(.waveform, width: 512), 512 * 256)
        XCTAssertEqual(ScopeAnalyzer.binCapacity(.rgbParade, width: 512), 512 * 256 * 3)
        XCTAssertEqual(ScopeAnalyzer.binCapacity(.vectorscope, width: 512),
                       ScopeAnalyzer.vectorCells * ScopeAnalyzer.vectorCells)
    }

    func testPreferencesPersistButScopeDataDoesNot() {
        let defaults = UserDefaults(suiteName: "scope-tests")!
        defaults.removePersistentDomain(forName: "scope-tests")
        var settings = ScopeSettings()
        settings.isEnabled = true
        settings.type = .vectorscope
        settings.intensity = 1.8
        settings.save(to: defaults)
        let loaded = ScopeSettings.load(from: defaults)
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.type, .vectorscope)
        XCTAssertEqual(loaded.intensity, 1.8, accuracy: 0.0001)
        defaults.removePersistentDomain(forName: "scope-tests")
        XCTAssertFalse(ScopeSettings.load(from: defaults).isEnabled, "defaults to off")
    }
}
