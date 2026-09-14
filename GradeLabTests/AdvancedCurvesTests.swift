import XCTest
@testable import GradeLab

/// Model-level coverage for the advanced curves: persistence, the legacy
/// migration, editing rules and the active mask. The GPU behaviour they drive
/// is covered by `Scripts/ValidateCurves.swift`, which runs the real shader.
final class AdvancedCurvesTests: XCTestCase {

    private func shaped() -> AdvancedCurves {
        var curves = AdvancedCurves()
        curves[.master] = AdvancedCurve(type: .master, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.18),
            CurvePoint(x: 0.7, y: 0.84), CurvePoint(x: 1, y: 1)
        ])
        curves[.hueVsSaturation] = AdvancedCurve(type: .hueVsSaturation, points: [
            CurvePoint(x: 0.25, y: 0), CurvePoint(x: 1.0 / 3.0, y: -0.5), CurvePoint(x: 0.42, y: 0)
        ])
        return curves
    }

    // MARK: - Persistence

    func testCurvesSurviveProjectSerialization() throws {
        let original = shaped()
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.advancedCurves = original
        settings.advanced = advanced

        let decoded = try JSONDecoder().decode(
            GradeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        let restored = try XCTUnwrap(decoded.advanced?.advancedCurves)
        XCTAssertEqual(restored[.master].points.map(\.y), [0, 0.18, 0.84, 1])
        XCTAssertEqual(restored[.hueVsSaturation].points.count, 3)
        // Point identity is stable across a save, so a selected point stays
        // selected rather than jumping to a different one.
        XCTAssertEqual(restored[.master].points.map(\.id), original[.master].points.map(\.id))
    }

    func testAProjectSavedBeforeAdvancedCurvesDecodes() throws {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.curves[0].midtones = 0.62
        settings.advanced = advanced

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(settings)) as? [String: Any])
        var nested = try XCTUnwrap(object["advanced"] as? [String: Any])
        nested.removeValue(forKey: "advancedCurves")
        object["advanced"] = nested
        let decoded = try JSONDecoder().decode(
            GradeSettings.self, from: try JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.advanced?.advancedCurves)
        // It still grades: the legacy data resolves into real curves.
        let resolved = try XCTUnwrap(decoded.advanced).resolvedCurves
        XCTAssertFalse(resolved.isNeutral)
        XCTAssertEqual(resolved[.master].interpolation, .linear)
        XCTAssertEqual(CurveEvaluator(resolved[.master]).value(at: 0.5), 0.62, accuracy: 1e-6)
    }

    func testNeutralCurvesStoreNothing() throws {
        var curves = AdvancedCurves()
        for type in CurveType.allCases { curves[type] = .neutral(type) }
        XCTAssertTrue(curves.isNeutral)
        XCTAssertEqual(curves.activeMask, 0)
        // And add nothing to the file.
        let encoded = try JSONEncoder().encode(curves)
        XCTAssertLessThan(encoded.count, 32)
    }

    func testResetAllClearsEveryCurve() {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.advancedCurves = shaped()
        settings.advanced = advanced
        settings.resetAll()
        XCTAssertEqual(settings, .neutral)
        XCTAssertTrue(settings.advanced?.resolvedCurves.isNeutral ?? true)
    }

    /// Copying a grade copies its curves, because they are part of the value.
    func testCopyingAGradeCarriesItsCurves() {
        let original = shaped()
        var source = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.advancedCurves = original
        source.advanced = advanced
        let copy = source
        XCTAssertEqual(copy.advanced?.advancedCurves, original)
        XCTAssertEqual(copy.advanced?.curveMask, source.advanced?.curveMask)
    }

    // MARK: - The active mask

    func testOnlyTouchedCurvesReachTheShader() {
        var curves = AdvancedCurves()
        XCTAssertEqual(curves.activeMask, 0)
        curves[.blue] = AdvancedCurve(type: .blue, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.65), CurvePoint(x: 1, y: 1)
        ])
        XCTAssertEqual(curves.activeMask, CurveType.blue.maskBit)
        curves[.hueVsLuma] = AdvancedCurve(type: .hueVsLuma, points: [
            CurvePoint(x: 0.6, y: 0), CurvePoint(x: 2.0 / 3.0, y: -0.5), CurvePoint(x: 0.75, y: 0)
        ])
        XCTAssertEqual(curves.activeMask,
                       CurveType.blue.maskBit | CurveType.hueVsLuma.maskBit)
        // Rows are distinct, or two curves would share a table row.
        XCTAssertEqual(Set(CurveType.allCases.map(\.row)).count, CurveType.allCases.count)
    }

    /// A curve dragged momentarily flat keeps its points; one that is reset
    /// goes away entirely.
    func testAFlatCurveIsKeptButAResetOneIsDiscarded() {
        var curves = AdvancedCurves()
        var curve = AdvancedCurve(type: .master, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)
        ])
        curves[.master] = curve
        XCTAssertEqual(curves[.master].points.count, 3, "A third point must survive being on the diagonal")
        XCTAssertEqual(curves.activeMask, 0, "A flat curve must not cost GPU work")
        curve.reset()
        curves[.master] = curve
        XCTAssertTrue(curves.isNeutral)
    }

    // MARK: - Editing rules

    func testEndpointsOfAToneCurveCannotBeRemovedOrSlid() {
        var curve = AdvancedCurve.neutral(.master)
        let first = curve.points[0].id
        XCTAssertFalse(curve.canRemovePoint(id: first))
        XCTAssertFalse(curve.removePoint(id: first))
        curve.movePoint(id: first, x: 0.5, y: 0.3)
        XCTAssertEqual(curve.points[0].x, 0, "An endpoint must keep its position on the input axis")
        XCTAssertEqual(curve.points[0].y, 0.3, accuracy: 1e-6, "but must still be liftable")
    }

    func testAPointCannotBeDraggedPastItsNeighbours() {
        var curve = AdvancedCurve.neutral(.master)
        let id = try! XCTUnwrap(curve.addPoint(x: 0.5, y: 0.5))
        curve.movePoint(id: id, x: 4, y: 0.5)
        let moved = try! XCTUnwrap(curve.points.first { $0.id == id })
        XCTAssertLessThan(moved.x, 1)
        XCTAssertGreaterThan(moved.x, 0)
        XCTAssertEqual(curve.points.map(\.x), curve.points.map(\.x).sorted())
    }

    func testValuesAreClampedToTheirCurveRange() {
        var mapping = AdvancedCurve.neutral(.master)
        _ = mapping.addPoint(x: 0.5, y: 9)
        XCTAssertEqual(mapping.points.first { $0.x == 0.5 }?.y, 1)
        var adjustment = AdvancedCurve.neutral(.hueVsHue)
        _ = adjustment.addPoint(x: 0.5, y: -9)
        XCTAssertEqual(adjustment.points.first?.y, -1)
    }

    func testTappingNextToAPointMovesItRatherThanStackingOnIt() {
        var curve = AdvancedCurve.neutral(.master)
        let id = curve.addPoint(x: 0.5, y: 0.4)
        let again = curve.addPoint(x: 0.5005, y: 0.9)
        XCTAssertEqual(id, again)
        XCTAssertEqual(curve.points.count, 3)
        XCTAssertEqual(curve.points.first { $0.id == id }?.y, 0.9)
    }

    // MARK: - Hue selection

    func testEyedropperSelectionSurroundsTheChosenHue() {
        var curve = AdvancedCurve.neutral(.hueVsSaturation)
        let centre = try! XCTUnwrap(curve.selectHue(2.0 / 3.0))   // blue
        XCTAssertEqual(curve.points.count, 3)
        let middle = try! XCTUnwrap(curve.points.first { $0.id == centre })
        XCTAssertEqual(middle.x, 2.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(middle.y, 0, "A fresh selection starts neutral")
        XCTAssertEqual(curve.points.filter { $0.y == 0 }.count, 3)
        // The shoulders sit ±20° away.
        let spread = curve.points.map(\.x).sorted()
        XCTAssertEqual(spread[2] - spread[0], 40.0 / 360.0, accuracy: 1e-5)
    }

    func testASelectionOnRedWrapsAroundBothEndsOfTheGraph() {
        var curve = AdvancedCurve.neutral(.hueVsHue)
        let centre = try! XCTUnwrap(curve.selectHue(0))
        curve.movePoint(id: centre, x: 0, y: 0.5)
        let evaluator = CurveEvaluator(curve)
        XCTAssertEqual(evaluator.value(at: 0), 0.5, accuracy: 1e-5)
        XCTAssertEqual(evaluator.value(at: 1), evaluator.value(at: 0), accuracy: 1e-6)
        XCTAssertGreaterThan(evaluator.value(at: 0.98), 0.05, "Hues below red must be affected")
        XCTAssertGreaterThan(evaluator.value(at: 0.02), 0.05, "Hues above red must be affected")
        XCTAssertEqual(evaluator.value(at: 0.5), 0, accuracy: 1e-4, "The opposite hue must not be")
    }

    func testPickingASecondNearbyHueReplacesTheFirstSelection() {
        var curve = AdvancedCurve.neutral(.hueVsHue)
        _ = curve.selectHue(0.5)
        XCTAssertEqual(curve.points.count, 3)
        for offset in stride(from: Float(0.005), through: 0.05, by: 0.005) {
            _ = curve.selectHue(0.5 + offset)
            XCTAssertEqual(curve.points.count, 3,
                           "A nearby pick must replace the last one, not silt up beside it")
        }
    }

    /// Re-picking near a colour the user has actually shaped must not throw
    /// that work away.
    func testANearbyPickLeavesAShapedSelectionAlone() {
        var curve = AdvancedCurve.neutral(.hueVsHue)
        let blue = try! XCTUnwrap(curve.selectHue(2.0 / 3.0))
        curve.movePoint(id: blue, x: 2.0 / 3.0, y: 0.6)
        _ = curve.selectHue(1.0 / 3.0)   // green, well away from blue
        XCTAssertNotNil(curve.points.first { $0.id == blue })
        XCTAssertEqual(curve.points.first { $0.id == blue }?.y, 0.6)
    }

    // MARK: - Sampling

    func testTheSampledTableMatchesTheEvaluator() {
        let curve = shaped()[.master]
        let evaluator = CurveEvaluator(curve)
        let samples = CurveSampling.samples(curve)
        XCTAssertEqual(samples.count, CurveSampling.count)
        for index in stride(from: 0, to: samples.count, by: 37) {
            let x = Float(index) / Float(CurveSampling.count - 1)
            XCTAssertEqual(samples[index], evaluator.value(at: x), accuracy: 1e-6)
        }
    }

    func testQuantisationIsFarBelowTenBitPrecision() {
        let curve = shaped()[.master]
        let exact = CurveSampling.samples(curve)
        let stored = CurveSampling.quantized(curve)
        // One 10-bit code is 1/1023. The table must be well inside that.
        for (index, value) in stored.enumerated() {
            XCTAssertEqual(Float(value) / Float(UInt16.max), exact[index], accuracy: 1.0 / 4000.0)
        }
    }
}
