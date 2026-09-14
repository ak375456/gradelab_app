import Metal
import XCTest
@testable import GradeLab

/// The finishing effects, checked where each one is actually computed.
final class FilmEffectsModelTests: XCTestCase {
    func testAClipWithNoEffectsStoresNothing() throws {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: makeVideoMetadata(durationSeconds: 5))
        XCTAssertNil(project.timeline.firstVideoClip?.gradeSettings.advanced?.effects)
        XCTAssertTrue(AdvancedGrade.neutral.resolvedEffects.isNeutral)
    }

    func testProjectsSavedBeforeEffectsDecodeWithNone() throws {
        let json = #"{"curves":[],"hsl":[],"wheels":[],"vignette":0,"vignetteMidpoint":50,"vignetteFeather":70}"#
        let grade = try JSONDecoder().decode(AdvancedGrade.self, from: Data(json.utf8))
        XCTAssertNil(grade.effects)
        XCTAssertTrue(grade.resolvedEffects.isNeutral)
    }

    func testEffectsSurviveSaveAndReload() throws {
        var grade = AdvancedGrade.neutral
        var effects = FilmEffects.neutral
        effects.bloom = 40; effects.halation = 25; effects.grain = 60
        grade.effects = effects
        let reloaded = try JSONDecoder().decode(AdvancedGrade.self, from: try JSONEncoder().encode(grade))
        XCTAssertEqual(reloaded.effects?.bloom, 40)
        XCTAssertEqual(reloaded.effects?.halation, 25)
        XCTAssertEqual(reloaded.effects?.grain, 60)
    }

    func testOutOfRangeValuesAreClamped() {
        var grade = AdvancedGrade.neutral
        grade.effects = FilmEffects(fade: 500, sharpness: -10, bloom: .nan,
                                    glow: 0, halation: 0, grain: 0)
        let resolved = grade.resolvedEffects
        XCTAssertEqual(resolved.fade, 100)
        XCTAssertEqual(resolved.sharpness, 0)
        XCTAssertEqual(resolved.bloom, 0)
    }

    /// Which effects need the post-grade pass decides whether every render path
    /// stays on its cheap single-pass route.
    func testOnlySpatialEffectsAskForTheExtraPass() {
        XCTAssertFalse(FilmEffects.neutral.needsStage)
        var perPixel = FilmEffects.neutral
        perPixel.fade = 50; perPixel.grain = 50
        XCTAssertFalse(perPixel.needsStage, "fade and grain are computed in the grading functions")
        var sharpen = FilmEffects.neutral
        sharpen.sharpness = 20
        XCTAssertTrue(sharpen.needsStage)
        XCTAssertFalse(sharpen.needsBlur, "a one-pixel unsharp mask does not need the blur pyramid")
        for keyPath in [\FilmEffects.bloom, \FilmEffects.glow, \FilmEffects.halation] {
            var effects = FilmEffects.neutral
            effects[keyPath: keyPath] = 30
            XCTAssertTrue(effects.needsBlur)
            XCTAssertTrue(effects.needsStage)
        }
    }

    /// The uniforms are what every shader reads, and the stage skips itself
    /// based on them.
    func testUniformsCarryTheEffectsAndBypassClearsThem() {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.effects = FilmEffects(fade: 100, sharpness: 50, bloom: 25,
                                       glow: 10, halation: 75, grain: 40)
        settings.advanced = advanced
        let uniforms = GradeUniforms(settings: settings, bypass: false)
        XCTAssertEqual(uniforms.effectsA.x, 1, accuracy: 0.0001, "fade")
        XCTAssertEqual(uniforms.effectsA.y, 0.4, accuracy: 0.0001, "grain")
        XCTAssertEqual(uniforms.effectsA.z, 0.5, accuracy: 0.0001, "sharpen")
        XCTAssertEqual(uniforms.effectsB.x, 0.25, accuracy: 0.0001, "bloom")
        XCTAssertEqual(uniforms.effectsB.y, 0.1, accuracy: 0.0001, "glow")
        XCTAssertEqual(uniforms.effectsB.z, 0.75, accuracy: 0.0001, "halation")
        XCTAssertTrue(FilmEffectsStage.isActive(uniforms))

        // Hold-to-compare has to show the untouched frame, effects included.
        let bypassed = GradeUniforms(settings: settings, bypass: true)
        XCTAssertEqual(bypassed.effectsA, .zero)
        XCTAssertEqual(bypassed.effectsB, .zero)
        XCTAssertFalse(FilmEffectsStage.isActive(bypassed))
    }

    /// Grain has to move between frames or it reads as dirt on the lens, and it
    /// has to be the SAME movement in preview and export or the two would differ.
    func testGrainSeedFollowsThePresentationTime() {
        var first = GradeUniforms(settings: .neutral, bypass: false)
        var second = first
        first.setGrainSeed(1.0)
        second.setGrainSeed(1.0 + 1.0 / 30.0)
        XCTAssertNotEqual(first.effectsA.w, second.effectsA.w, "consecutive frames must differ")
        var repeated = GradeUniforms(settings: .neutral, bypass: false)
        repeated.setGrainSeed(1.0)
        XCTAssertEqual(repeated.effectsA.w, first.effectsA.w, "the same frame must give the same grain")
    }
}

/// The spatial stage, run against known images.
final class FilmEffectsStageTests: XCTestCase {
    private var context: MetalContext!
    private var stage: FilmEffectsStage!
    private let side = 64

    override func setUpWithError() throws {
        try super.setUpWithError()
        context = try MetalContext()
        stage = try XCTUnwrap(FilmEffectsStage(context: context))
    }

    private func texture(_ colour: (Double, Double) -> SIMD3<Double>) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let texture = try XCTUnwrap(context.device.makeTexture(descriptor: d))
        var pixels = [Float16](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let rgb = colour(Double(x) / Double(side - 1), Double(y) / Double(side - 1))
                let i = (y * side + x) * 4
                pixels[i] = Float16(rgb.x); pixels[i+1] = Float16(rgb.y)
                pixels[i+2] = Float16(rgb.z); pixels[i+3] = 1
            }
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: side * 8)
        }
        return texture
    }

    private func run(_ source: MTLTexture, effects: FilmEffects,
                     workingSpace: Bool = false) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let destination = try XCTUnwrap(context.device.makeTexture(descriptor: d))
        var advanced = AdvancedGrade.neutral
        advanced.effects = effects
        var settings = GradeSettings.neutral
        settings.advanced = advanced
        let grade = GradeUniforms(settings: settings, bypass: false)
        let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        XCTAssertTrue(stage.encode(source: source, destination: destination,
                                   grade: grade, workingSpace: workingSpace, into: command))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        return destination
    }

    private func read(_ texture: MTLTexture, x: Int, y: Int) -> SIMD3<Double> {
        var pixels = [Float16](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: side * 8,
                             from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        let i = (y * side + x) * 4
        return .init(Double(pixels[i]), Double(pixels[i+1]), Double(pixels[i+2]))
    }

    func testAFlatFrameWithNoEffectsComesBackUnchanged() throws {
        let source = try texture { _, _ in .init(0.4, 0.5, 0.6) }
        let out = try run(source, effects: .neutral)
        let pixel = read(out, x: 32, y: 32)
        XCTAssertEqual(pixel.x, 0.4, accuracy: 0.002)
        XCTAssertEqual(pixel.y, 0.5, accuracy: 0.002)
        XCTAssertEqual(pixel.z, 0.6, accuracy: 0.002)
    }

    /// Bloom is light spreading out of bright areas, so it has to brighten what
    /// is NEXT to a highlight, not the highlight itself.
    func testBloomBrightensAroundAHighlightAndNotAFlatDarkFrame() throws {
        var effects = FilmEffects.neutral
        effects.bloom = 100
        let spot = try texture { x, y in
            let d = ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)).squareRoot()
            return d < 0.12 ? .init(1, 1, 1) : .init(0.05, 0.05, 0.05)
        }
        let out = try run(spot, effects: effects)
        let nearby = read(out, x: 32, y: 46).x       // just outside the spot
        let far = read(out, x: 2, y: 2).x            // opposite corner
        XCTAssertGreaterThan(nearby, 0.05 + 0.02, "bloom did not spread out of the highlight")
        XCTAssertGreaterThan(nearby, far, "bloom should fall off with distance")

        let dark = try texture { _, _ in .init(0.05, 0.05, 0.05) }
        let unchanged = try run(dark, effects: effects)
        XCTAssertEqual(read(unchanged, x: 32, y: 32).x, 0.05, accuracy: 0.01,
                       "a frame with no highlight has nothing to bloom")
    }

    /// Halation is red by nature: light scatters off the back of the film base
    /// and re-exposes the emulsion, and the long wavelengths get there.
    func testHalationHalosRed() throws {
        var effects = FilmEffects.neutral
        effects.halation = 100
        let spot = try texture { x, y in
            let d = ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)).squareRoot()
            return d < 0.12 ? .init(1, 1, 1) : .init(0.05, 0.05, 0.05)
        }
        let out = try run(spot, effects: effects)
        let nearby = read(out, x: 32, y: 46)
        XCTAssertGreaterThan(nearby.x, nearby.z, "the halo should be red-weighted, not neutral")
        XCTAssertGreaterThan(nearby.x, 0.05 + 0.02)
    }

    /// Sharpening is local contrast: it must lift the light side of an edge and
    /// leave a flat area alone.
    func testSharpeningActsOnEdgesAndNotOnFlatAreas() throws {
        var effects = FilmEffects.neutral
        effects.sharpness = 100
        let edge = try texture { x, _ in x < 0.5 ? .init(0.3, 0.3, 0.3) : .init(0.7, 0.7, 0.7) }
        let out = try run(edge, effects: effects)
        let lightSide = read(out, x: 32, y: 32).x
        let flat = read(out, x: 60, y: 32).x
        XCTAssertGreaterThan(lightSide, 0.7, "the bright side of the edge should be lifted")
        XCTAssertEqual(flat, 0.7, accuracy: 0.01, "a flat area has no edge to sharpen")
    }

    /// HDR values run above diffuse white, and clamping them here would throw
    /// away the range the whole HDR pipeline exists to keep.
    func testWorkingSpaceHighlightsAreNotClamped() throws {
        var effects = FilmEffects.neutral
        effects.sharpness = 10
        let bright = try texture { _, _ in .init(3.5, 3.5, 3.5) }
        let out = try run(bright, effects: effects, workingSpace: true)
        XCTAssertGreaterThan(read(out, x: 32, y: 32).x, 3.0,
                             "an HDR highlight was clipped to diffuse white")
        let sdr = try run(bright, effects: effects, workingSpace: false)
        XCTAssertEqual(read(sdr, x: 32, y: 32).x, 1.0, accuracy: 0.01,
                       "an SDR display signal has a ceiling and should reach it")
    }
}

/// The Swift and Metal declarations of `GradeUniforms` are separate files, and
/// a field added to one but not the other makes every shader read the rest of
/// the struct at the wrong offset. This is the check that catches that.
final class GradeUniformLayoutTests: XCTestCase {
    func testEveryFieldIsAccountedFor() {
        // 22 SIMD4<Float> fields at 16 bytes each.
        XCTAssertEqual(MemoryLayout<GradeUniforms>.stride, 22 * 16)
        XCTAssertEqual(MemoryLayout<GradeUniforms>.stride % 16, 0, "SIMD4 alignment")
    }

    func testTheEffectFieldsAreTheLastTwo() {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.effects = FilmEffects(fade: 100, sharpness: 0, bloom: 0,
                                       glow: 0, halation: 0, grain: 0)
        settings.advanced = advanced
        var uniforms = GradeUniforms(settings: settings, bypass: false)
        withUnsafeBytes(of: &uniforms) { raw in
            let floats = raw.bindMemory(to: Float.self)
            // effectsA is field 21 of 22, so its x sits at offset 20 * 4.
            XCTAssertEqual(floats[20 * 4], 1, "fade is not where the shader reads it")
        }
    }
}
