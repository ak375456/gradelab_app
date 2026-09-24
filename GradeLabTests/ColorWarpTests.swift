import XCTest
@testable import GradeLab

/// Model and field-builder coverage for the Color Warper. The GPU behaviour
/// these drive — that an inactive warper is exactly identity, that a warp moves
/// a pixel, and that Preserve Luminance holds brightness — is covered by
/// `Scripts/ValidateGrade.swift`, which runs the real shader.
final class ColorWarpTests: XCTestCase {

    private func orangeToRed() -> ColorWarp {
        var warp = ColorWarp()
        warp.points = [
            ColorWarpPoint(mode: .hueSaturation, sourceX: 35.0 / 360, sourceY: 0.70,
                           targetX: 15.0 / 360, targetY: 0.82, radius: 0.18)
        ]
        return warp
    }

    // MARK: - Persistence

    func testWarpSurvivesProjectSerialization() throws {
        let original = orangeToRed()
        var advanced = AdvancedGrade.neutral
        advanced.colorWarp = original
        var settings = GradeSettings.neutral
        settings.advanced = advanced

        let decoded = try JSONDecoder().decode(
            GradeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        let restored = try XCTUnwrap(decoded.advanced?.colorWarp)
        XCTAssertEqual(restored.points.count, 1)
        // Point identity is stable across a save, so a selected handle stays
        // selected rather than jumping to a different one.
        XCTAssertEqual(restored.points.map(\.id), original.points.map(\.id))
        XCTAssertEqual(restored.points[0].targetY, 0.82, accuracy: 1e-6)
    }

    /// The whole point of storing it as an optional: a project saved before the
    /// warper existed has no key for it and must still decode.
    func testProjectWithoutWarpStillDecodes() throws {
        let legacy = Data(#"{"exposure":0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"temperature":0,"tint":0,"saturation":0,"vibrance":0}"#.utf8)
        let decoded = try JSONDecoder().decode(GradeSettings.self, from: legacy)
        XCTAssertNil(decoded.advanced?.colorWarp)
        XCTAssertEqual(decoded, .neutral)
    }

    /// A warp written by a build that stored fewer keys still loads: every key
    /// decodes optionally rather than failing the whole project.
    func testPartialWarpDecodesWithDefaults() throws {
        let partial = Data(#"{"points":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ColorWarp.self, from: partial)
        XCTAssertEqual(decoded.strength, 100)
        XCTAssertTrue(decoded.preservesLuminance)
        XCTAssertEqual(decoded.density, .medium)
    }

    // MARK: - Density is a display property

    /// The reason points store continuous coordinates instead of lattice
    /// indices. If this ever fails, changing the mesh resolution has started
    /// destroying work.
    func testChangingDensityLeavesEveryPointUntouched() {
        var warp = orangeToRed()
        warp.points.append(ColorWarpPoint(mode: .chromaLuma, sourceX: 0.3, sourceY: 0.2,
                                          targetX: 0.5, targetY: 0.45))
        let before = warp.points
        for density in ColorWarpDensity.allCases {
            warp.density = density
            XCTAssertEqual(warp.points, before, "Density \(density) moved a stored point")
        }
    }

    // MARK: - Neutrality

    func testRestingPointsAreNeutral() {
        var warp = ColorWarp()
        warp.points = [ColorWarpPoint(mode: .hueSaturation, sourceX: 0.1, sourceY: 0.5)]
        // Stored, so a handle placed by the eyedropper survives until it is
        // dragged — but inert, so nothing renders and nothing is gated.
        XCTAssertTrue(warp.hasPoints)
        XCTAssertTrue(warp.isNeutral)
        XCTAssertEqual(warp.activeMask, 0)
    }

    func testZeroStrengthIsNeutral() {
        var warp = orangeToRed()
        XCTAssertFalse(warp.isNeutral)
        warp.strength = 0
        XCTAssertTrue(warp.isNeutral)
    }

    func testActiveMaskNamesOnlyThePlanesInUse() {
        var warp = orangeToRed()
        XCTAssertEqual(warp.activeMask, ColorWarpMode.hueSaturation.maskBit)
        warp.points.append(ColorWarpPoint(mode: .chromaLuma, sourceX: 0.3, sourceY: 0.2,
                                          targetX: 0.5, targetY: 0.45))
        XCTAssertEqual(warp.activeMask,
                       ColorWarpMode.hueSaturation.maskBit | ColorWarpMode.chromaLuma.maskBit)
    }

    // MARK: - Hue is a circle

    func testHueDeltaTakesTheShortWayRound() {
        XCTAssertEqual(ColorWarpMath.wrappedDelta(from: 0.95, to: 0.05), 0.1, accuracy: 1e-6)
        XCTAssertEqual(ColorWarpMath.wrappedDelta(from: 0.05, to: 0.95), -0.1, accuracy: 1e-6)
        XCTAssertEqual(ColorWarpMath.wrap(-0.25), 0.75, accuracy: 1e-6)
    }

    func testPointAcrossTheRedBoundaryMovesTheShortWay() {
        let point = ColorWarpPoint(mode: .hueSaturation, sourceX: 0.97, sourceY: 0.6,
                                   targetX: 0.03, targetY: 0.6)
        XCTAssertEqual(point.displacement.x, 0.06, accuracy: 1e-6)
    }

    // MARK: - The field

    private func block(_ warp: ColorWarp, _ mode: ColorWarpMode) -> [Float16] {
        ColorWarpFieldFactory.block(for: warp.activePoints(mode), mode: mode)
    }

    private func sample(_ block: [Float16], column: Int, row: Int) -> SIMD2<Float> {
        let index = (row * ColorWarpFieldFactory.width + column) * ColorWarpFieldFactory.components
        return SIMD2(Float(block[index]), Float(block[index + 1]))
    }

    func testNoPointsProducesAnEmptyField() {
        let field = block(ColorWarp(), .hueSaturation)
        XCTAssertEqual(field.count, ColorWarpFieldFactory.samplesPerBlock)
        XCTAssertTrue(field.allSatisfy { $0 == 0 })
    }

    /// At a point's own source the field has to carry its full displacement,
    /// or the colour the user pointed at is not the colour that moves.
    func testFieldCarriesTheFullDisplacementAtItsSource() {
        let warp = orangeToRed()
        let point = warp.points[0]
        let field = block(warp, .hueSaturation)
        let column = Int((point.sourceX * Float(ColorWarpFieldFactory.width - 1)).rounded())
        let row = Int((point.sourceY * Float(ColorWarpFieldFactory.blockHeight - 1)).rounded())
        let value = sample(field, column: column, row: row)
        XCTAssertEqual(value.x, point.displacement.x, accuracy: 0.002)
        XCTAssertEqual(value.y, point.displacement.y, accuracy: 0.002)
    }

    /// Clamp-to-edge addressing is only continuous across the red boundary
    /// because the first and last columns hold the same hue. If they diverge a
    /// seam appears in every red in the picture.
    func testHuePlaneHasNoSeam() {
        var warp = ColorWarp()
        warp.points = [ColorWarpPoint(mode: .hueSaturation, sourceX: 0.0, sourceY: 0.6,
                                      targetX: 0.08, targetY: 0.7, radius: 0.3)]
        let field = block(warp, .hueSaturation)
        for row in stride(from: 0, to: ColorWarpFieldFactory.blockHeight, by: 8) {
            let first = sample(field, column: 0, row: row)
            let last = sample(field, column: ColorWarpFieldFactory.width - 1, row: row)
            XCTAssertEqual(first.x, last.x, accuracy: 1e-3, "Seam in row \(row)")
            XCTAssertEqual(first.y, last.y, accuracy: 1e-3, "Seam in row \(row)")
        }
    }

    /// The normalisation that stops two overlapping points stacking their
    /// moves. Without it the overlap displaces twice as far as either point
    /// asked for and leaves a discontinuity at its edge.
    func testOverlappingPointsDoNotOvershoot() {
        var warp = ColorWarp()
        warp.points = [
            ColorWarpPoint(mode: .hueSaturation, sourceX: 0.30, sourceY: 0.6,
                           targetX: 0.36, targetY: 0.6, radius: 0.3),
            ColorWarpPoint(mode: .hueSaturation, sourceX: 0.33, sourceY: 0.6,
                           targetX: 0.39, targetY: 0.6, radius: 0.3)
        ]
        let field = block(warp, .hueSaturation)
        let largest = warp.points.map { abs($0.displacement.x) }.max() ?? 0
        for column in 0..<ColorWarpFieldFactory.width {
            for row in stride(from: 0, to: ColorWarpFieldFactory.blockHeight, by: 4) {
                let value = sample(field, column: column, row: row)
                XCTAssertLessThanOrEqual(abs(value.x), largest + 1e-3,
                                         "Overshoot at \(column),\(row)")
            }
        }
    }

    /// The field must go to zero at the edge of a point's range, and get there
    /// smoothly. A step here is a visible hard boundary in the picture.
    func testInfluenceReachesZeroAtTheEdgeOfTheRange() {
        let point = ColorWarpPoint(mode: .hueSaturation, sourceX: 0.5, sourceY: 0.5,
                                   targetX: 0.6, targetY: 0.5, radius: 0.2)
        var warp = ColorWarp()
        warp.points = [point]
        let active = warp.activePoints(.hueSaturation)

        XCTAssertEqual(
            ColorWarpFieldFactory.displacement(at: 0.5 + 0.2, 0.5, points: active, mode: .hueSaturation).x,
            0, accuracy: 1e-6)
        XCTAssertEqual(
            ColorWarpFieldFactory.displacement(at: 0.5 + 0.4, 0.5, points: active, mode: .hueSaturation).x,
            0, accuracy: 1e-6)

        // Monotone decreasing from the centre out, with no step between samples.
        // `previous` starts empty rather than at zero: the first sample IS the
        // full displacement, so comparing it against nothing would read as a
        // step when it is simply where the falloff begins.
        var previous: Float?
        for step in 0...40 {
            let distance = Float(step) / 40 * 0.2
            let value = ColorWarpFieldFactory
                .displacement(at: 0.5 + distance, 0.5, points: active, mode: .hueSaturation).x
            if let previous {
                XCTAssertLessThanOrEqual(value, previous + 1e-6, "Influence rose at \(distance)")
                XCTAssertLessThan(abs(value - previous), 0.02, "Step in the falloff at \(distance)")
            }
            previous = value
        }
    }

    /// The editor draws its mesh with the gather function and the GPU table is
    /// built with the scatter one. They have to agree, or the deformation on
    /// screen is not the deformation being applied.
    func testGatheredFieldMatchesTheBuiltTable() {
        var warp = orangeToRed()
        warp.points.append(ColorWarpPoint(mode: .hueSaturation, sourceX: 0.55, sourceY: 0.8,
                                          targetX: 0.62, targetY: 0.55, radius: 0.22))
        let active = warp.activePoints(.hueSaturation)
        let field = block(warp, .hueSaturation)

        for column in stride(from: 0, to: ColorWarpFieldFactory.width, by: 7) {
            for row in stride(from: 0, to: ColorWarpFieldFactory.blockHeight, by: 5) {
                let x = Float(column) / Float(ColorWarpFieldFactory.width - 1)
                let y = Float(row) / Float(ColorWarpFieldFactory.blockHeight - 1)
                let gathered = ColorWarpFieldFactory
                    .displacement(at: x, y, points: active, mode: .hueSaturation)
                let stored = sample(field, column: column, row: row)
                XCTAssertEqual(stored.x, gathered.x, accuracy: 0.002, "at \(column),\(row)")
                XCTAssertEqual(stored.y, gathered.y, accuracy: 0.002, "at \(column),\(row)")
            }
        }
    }

    // MARK: - Picking

    func testPickerRefusesANeutralPixelOnTheHuePlane() {
        let grey = SIMD3<Float>(0.5, 0.5, 0.5)
        XCTAssertNil(ColorWarpPicker.position(of: grey, in: .hueSaturation))
        // Chroma/Luma takes it: "reduce chroma in the highlights" is a move onto
        // pixels that have almost none.
        XCTAssertNotNil(ColorWarpPicker.position(of: grey, in: .chromaLuma))
    }

    func testPickerLandsOnTheSampledHue() throws {
        // Pure orange, hue 30 degrees.
        let orange = SIMD3<Float>(1.0, 0.5, 0.0)
        let position = try XCTUnwrap(ColorWarpPicker.position(of: orange, in: .hueSaturation))
        XCTAssertEqual(position.x, 30.0 / 360, accuracy: 0.002)
        XCTAssertEqual(position.y, 1, accuracy: 0.002)
    }

    /// An HDR or Log readback is extended range, and a specular highlight can be
    /// well above 1. The planes are bounded, so the sample has to be clamped the
    /// same way the shader reaches them.
    func testPickerClampsExtendedRangeSamples() throws {
        let hot = SIMD3<Float>(6.0, 3.0, 0.0)
        let position = try XCTUnwrap(ColorWarpPicker.position(of: hot, in: .hueSaturation))
        XCTAssertTrue((0...1).contains(position.x))
        XCTAssertTrue((0...1).contains(position.y))
    }

    // MARK: - Pro gating

    func testAWarpThatChangesAPixelAsksForPro() {
        var advanced = AdvancedGrade.neutral
        advanced.colorWarp = orangeToRed()
        var settings = GradeSettings.neutral
        settings.advanced = advanced
        XCTAssertTrue(ProAccessPolicy.gradeRequirements(settings).contains(.colorWarper))
    }

    func testAWarpThatChangesNothingDoesNot() {
        var warp = ColorWarp()
        warp.points = [ColorWarpPoint(mode: .hueSaturation, sourceX: 0.1, sourceY: 0.5)]
        var advanced = AdvancedGrade.neutral
        advanced.colorWarp = warp
        var settings = GradeSettings.neutral
        settings.advanced = advanced
        XCTAssertFalse(ProAccessPolicy.gradeRequirements(settings).contains(.colorWarper))
    }

    // MARK: - Keyframes

    func testStrengthIsAnimatableAndReadsFullWhenAbsent() {
        var settings = GradeSettings.neutral
        XCTAssertEqual(settings.gradeNumber(.gradeColorWarpStrength), 100)

        var advanced = AdvancedGrade.neutral
        advanced.colorWarp = orangeToRed()
        settings.advanced = advanced
        settings.setGradeNumber(40, for: .gradeColorWarpStrength)
        XCTAssertEqual(settings.advanced?.colorWarp?.strength, 40)
        XCTAssertEqual(AnimatableProperty.gradeColorWarpStrength.gradeSlot?.panel, .warper)
    }

    /// Writing a strength onto a grade with no warp would leave a project
    /// carrying a warper with nothing in it.
    func testStrengthIsNotStoredWithoutAWarp() {
        var settings = GradeSettings.neutral
        settings.setGradeNumber(40, for: .gradeColorWarpStrength)
        XCTAssertNil(settings.advanced?.colorWarp)
    }
}
