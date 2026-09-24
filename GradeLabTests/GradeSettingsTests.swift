import XCTest
@testable import GradeLab

final class GradeSettingsTests: XCTestCase {
    func testLegacySettingsDecodeWithoutAdvancedFields() throws {
        let data = try JSONEncoder().encode(GradeSettings.neutral)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "advanced")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(GradeSettings.self, from: legacy).advanced)
    }

    func testAdvancedGradePersistenceAndReset() throws {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.curves[1].midtones = 0.6
        advanced.hsl[2].hue = 15
        advanced.wheels[0].strength = 30
        advanced.vignette = -40
        advanced.mask = GradeMask(isEnabled: true, shape: .rectangle, centerX: 35,
                                  centerY: 62, width: 48, height: 30,
                                  rotation: 18, feather: 12, opacity: 80,
                                  isInverted: true)
        settings.advanced = advanced
        XCTAssertEqual(try JSONDecoder().decode(GradeSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.resetAll()
        XCTAssertEqual(settings, .neutral)
        XCTAssertEqual(MemoryLayout<GradeUniforms>.stride, 368, "Uniform layout must not drift from the shader")
    }

    func testLegacyAdvancedGradeDecodesWithoutMask() throws {
        let json = #"{"curves":[],"hsl":[],"wheels":[],"vignette":0,"vignetteMidpoint":50,"vignetteFeather":70}"#
        let advanced = try JSONDecoder().decode(AdvancedGrade.self, from: Data(json.utf8))
        XCTAssertNil(advanced.mask)
        XCTAssertFalse(advanced.resolvedMask.isEnabled)
    }

    func testMaskUniformsReuseReservedSlotsWithoutChangingLayout() {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.mask = GradeMask(isEnabled: true, shape: .rectangle, centerX: 25,
                                  centerY: 75, width: 50, height: 20,
                                  rotation: 90, feather: 40, opacity: 65,
                                  isInverted: true)
        settings.advanced = advanced
        let uniforms = GradeUniforms(settings: settings, bypass: false)

        XCTAssertEqual(MemoryLayout<GradeUniforms>.stride, 368)
        XCTAssertEqual(uniforms.gradeMaskA.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(uniforms.gradeMaskA.y, 0.75, accuracy: 0.0001)
        XCTAssertEqual(uniforms.gradeMaskA.z, 0.50, accuracy: 0.0001)
        XCTAssertEqual(uniforms.gradeMaskA.w, 0.20, accuracy: 0.0001)
        XCTAssertEqual(uniforms.gradeMaskB.x, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(uniforms.gradeMaskB.y, 0.40, accuracy: 0.0001)
        XCTAssertEqual(uniforms.gradeMaskB.z, 0.65, accuracy: 0.0001)
        XCTAssertEqual(uniforms.gradeMaskB.w, 5, "rectangle + inverted flags")
        XCTAssertEqual(GradeUniforms(settings: .neutral, bypass: false).gradeMaskB.z, -1)
    }

    func testMaskAloneDoesNotCountAsAVisibleCreativeChange() {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.mask = GradeMask(isEnabled: true)
        settings.advanced = advanced
        XCTAssertFalse(settings.hasCreativeChangeIgnoringMask)

        settings.exposure = 0.5
        XCTAssertTrue(settings.hasCreativeChangeIgnoringMask)

        settings.exposure = 0
        settings.advanced?.vignette = -20
        XCTAssertTrue(settings.hasCreativeChangeIgnoringMask)
    }

    func testNeutralGradeContainsOnlyIdentityValues() {
        let settings = GradeSettings.neutral

        for parameter in GradeParameter.allCases {
            XCTAssertEqual(settings[keyPath: parameter.keyPath], parameter.neutralValue)
            XCTAssertTrue(parameter.range.contains(parameter.neutralValue))
        }
    }

    func testResetAffectsOnlySelectedControl() {
        var settings = GradeSettings(
            exposure: 1.25,
            contrast: 24,
            highlights: -18,
            shadows: 12,
            whites: 8,
            blacks: -7,
            temperature: 16,
            tint: -9,
            saturation: 22,
            vibrance: 31
        )

        settings.reset(.contrast)

        XCTAssertEqual(settings.contrast, 0)
        XCTAssertEqual(settings.exposure, 1.25)
        XCTAssertEqual(settings.vibrance, 31)
    }

    func testResetAllRestoresIdentityGrade() {
        var settings = GradeSettings.neutral
        settings.exposure = -1.75
        settings.temperature = 80

        settings.resetAll()

        XCTAssertEqual(settings, .neutral)
    }

    func testSettingsRoundTripThroughProjectSerialization() throws {
        let settings = GradeSettings(
            exposure: 0.72,
            contrast: 18,
            highlights: -22,
            shadows: 14,
            whites: 4,
            blacks: -6,
            temperature: 11,
            tint: -3,
            saturation: 16,
            vibrance: 28
        )

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GradeSettings.self, from: encoded)

        XCTAssertEqual(decoded, settings)
    }

    func testControlRangesMatchTheEditorContract() {
        XCTAssertEqual(GradeParameter.exposure.range, -2 ... 2)
        XCTAssertEqual(GradeParameter.exposure.step, 0.01)

        for parameter in GradeParameter.allCases where parameter != .exposure {
            XCTAssertEqual(parameter.range, -100 ... 100)
            XCTAssertEqual(parameter.step, 1)
        }
    }
}
