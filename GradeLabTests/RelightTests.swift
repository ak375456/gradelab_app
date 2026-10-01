import CoreGraphics
import XCTest
import simd
@testable import GradeLab

/// Model-level coverage for Relight: the document, its keyframes, the colour
/// science, the depth cache format, temporal stabilisation and the uniform
/// layout the shader reads. The GPU kernels themselves are exercised on
/// device; these pin down everything that decides what those kernels are given.
final class RelightTests: XCTestCase {

    private func seconds(_ value: Double) throws -> TimelineTime { try .seconds(value) }

    // MARK: - Persistence

    func testRelightSurvivesGradeSerialization() throws {
        var relight = RelightSettings()
        relight.lights = [RelightLight.starting(.point, name: "Key"),
                          RelightLight.starting(.directional, name: "Sun")]
        relight.strength = 0.8
        relight.form = 1.4
        var advanced = AdvancedGrade.neutral
        advanced.relight = relight
        var settings = GradeSettings.neutral
        settings.advanced = advanced

        let decoded = try JSONDecoder().decode(GradeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.advanced?.relight?.lights.map(\.name), ["Key", "Sun"])
        XCTAssertEqual(decoded.advanced?.relight?.lights.map(\.id), relight.lights.map(\.id))
    }

    func testGradeWithoutRelightStillDecodes() throws {
        let decoded = try JSONDecoder().decode(
            GradeSettings.self, from: JSONEncoder().encode(GradeSettings.neutral))
        XCTAssertNil(decoded.advanced?.relight)
    }

    func testLightWrittenByANewerBuildFallsBackToDefaults() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Lamp","type":"spot","futureValue":3}"#
        let light = try JSONDecoder().decode(RelightLight.self, from: Data(json.utf8))
        XCTAssertEqual(light.type, .spot)
        XCTAssertEqual(light.name, "Lamp")
        XCTAssertEqual(light.intensity, 100)
        XCTAssertTrue(light.isEnabled)
    }

    func testEmptyRelightIsNotActive() {
        var relight = RelightSettings()
        XCTAssertTrue(relight.isEmpty)
        XCTAssertFalse(relight.isActive)
        relight.lights = [RelightLight.starting(.point, name: "Key")]
        XCTAssertTrue(relight.isActive)
        relight.isEnabled = false
        XCTAssertFalse(relight.isActive)
    }

    func testDisabledAndZeroLightsDoNotReachTheGPU() {
        var off = RelightLight.starting(.point, name: "Off")
        off.isEnabled = false
        var zero = RelightLight.starting(.point, name: "Zero")
        zero.intensity = 0
        let on = RelightLight.starting(.spot, name: "On")
        let relight = RelightSettings(lights: [off, zero, on])
        XCTAssertEqual(relight.renderableLights.map(\.name), ["On"])
    }

    func testDuplicateHasANewIdentityAndKeepsEverythingElse() {
        var light = RelightLight.starting(.spot, name: "Key")
        light.intensity = 150
        let copy = light.duplicated(named: "Key copy")
        XCTAssertNotEqual(copy.id, light.id)
        XCTAssertEqual(copy.name, "Key copy")
        XCTAssertEqual(copy.intensity, 150)
        XCTAssertEqual(copy.type, .spot)
    }

    func testPresetReplacesLightsWithFreshIdentities() {
        let first = RelightPreset.softKey.applied(to: RelightSettings())
        let second = RelightPreset.softKey.applied(to: first)
        XCTAssertFalse(first.lights.isEmpty)
        XCTAssertTrue(first.isActive)
        XCTAssertTrue(Set(first.lights.map(\.id)).isDisjoint(with: second.lights.map(\.id)))
        for preset in RelightPreset.all {
            let applied = preset.applied(to: RelightSettings())
            XCTAssertLessThanOrEqual(applied.lights.count, RelightSettings.maximumLights, preset.title)
            XCTAssertTrue(applied.isActive, preset.title)
        }
    }

    func testNextLightNameSkipsTakenNames() {
        let relight = RelightSettings(lights: [RelightLight.starting(.point, name: "Light 2")])
        XCTAssertEqual(relight.nextLightName(), "Light 3")
    }

    // MARK: - Keyframes

    func testLightKeyframesEvaluateAtClipLocalTime() throws {
        var light = RelightLight.starting(.point, name: "Key")
        var animation = ClipAnimation()
        animation.update(.relightIntensity) { $0.set(.number(0), at: try! self.seconds(0)) }
        animation.update(.relightIntensity) { $0.set(.number(200), at: try! self.seconds(2)) }
        light.animation = animation
        let relight = RelightSettings(lights: [light])

        let middle = relight.evaluated(atLocal: try seconds(1))
        XCTAssertEqual(middle.lights[0].intensity, 100, accuracy: 0.001)
        // Evaluation never touches the authored value.
        XCTAssertEqual(relight.lights[0].intensity, light.intensity)
        XCTAssertTrue(relight.isAnimated)
    }

    func testAzimuthTakesTheShortWayRoundTheCircle() throws {
        var light = RelightLight.starting(.directional, name: "Sun")
        var animation = ClipAnimation()
        animation.update(.relightAzimuth) { $0.set(.number(350), at: try! self.seconds(0)) }
        animation.update(.relightAzimuth) { $0.set(.number(10), at: try! self.seconds(2)) }
        light.animation = animation

        let middle = light.evaluated(atLocal: try seconds(1))
        XCTAssertEqual(middle.azimuth, 0, accuracy: 0.001)
        let quarter = light.evaluated(atLocal: try seconds(0.5))
        XCTAssertEqual(quarter.azimuth, 355, accuracy: 0.001)
    }

    func testStrengthKeyframesAnimateTheWholeRelight() throws {
        var relight = RelightSettings(lights: [RelightLight.starting(.point, name: "Key")])
        var animation = ClipAnimation()
        animation.update(.relightStrength) { $0.set(.number(0), at: try! self.seconds(0)) }
        animation.update(.relightStrength) { $0.set(.number(1), at: try! self.seconds(4)) }
        relight.animation = animation
        XCTAssertEqual(relight.evaluated(atLocal: try seconds(1)).strength, 0.25, accuracy: 0.001)
    }

    func testRetimingScalesLightKeyframes() throws {
        var light = RelightLight.starting(.point, name: "Key")
        var animation = ClipAnimation()
        animation.update(.relightIntensity) { $0.set(.number(50), at: try! self.seconds(2)) }
        light.animation = animation
        let relight = RelightSettings(lights: [light]).retimed(by: 0.5)
        let time = try XCTUnwrap(relight.lights[0].animation?.track(.relightIntensity)?.keyframes.first?.time)
        XCTAssertEqual(time.seconds, 1, accuracy: 0.001)
    }

    func testTypeDecidesWhichPropertiesALightHas() {
        XCTAssertTrue(RelightLight.supports(.relightAzimuth, type: .directional))
        XCTAssertFalse(RelightLight.supports(.relightPositionX, type: .directional))
        XCTAssertTrue(RelightLight.supports(.relightConeAngle, type: .spot))
        XCTAssertFalse(RelightLight.supports(.relightConeAngle, type: .point))
        XCTAssertTrue(RelightLight.supports(.relightIntensity, type: .point))
    }

    // MARK: - Colour

    func testNeutralTemperatureIsWhite() {
        let rgb = RelightColorScience.temperatureRGB(kelvin: 6500)
        XCTAssertEqual(rgb.x, 1, accuracy: 0.02)
        XCTAssertEqual(rgb.y, 1, accuracy: 0.02)
        XCTAssertEqual(rgb.z, 1, accuracy: 0.02)
    }

    func testWarmIsRedderThanCoolAtTheSameLuminance() {
        let warm = RelightColorScience.temperatureRGB(kelvin: 3200)
        let cool = RelightColorScience.temperatureRGB(kelvin: 9000)
        XCTAssertGreaterThan(warm.x / warm.z, cool.x / cool.z)
        let weights = RelightColorScience.rec709Luma
        XCTAssertEqual(simd_dot(warm, weights), simd_dot(cool, weights), accuracy: 0.02)
    }

    func testIntensityResponseIsSignedAndPerceptual() {
        XCTAssertEqual(RelightStage.intensityResponse(100), 1, accuracy: 1e-9)
        XCTAssertEqual(RelightStage.intensityResponse(0), 0, accuracy: 1e-9)
        XCTAssertLessThan(RelightStage.intensityResponse(50), 0.5)
        XCTAssertEqual(RelightStage.intensityResponse(-100), -1, accuracy: 1e-9)
        XCTAssertEqual(RelightStage.intensityResponse(.nan), 0)
    }

    // MARK: - Direction disk

    func testDirectionDiskRoundTrips() {
        for (azimuth, elevation) in [(25.0, 35.0), (180.0, 0.0), (300.0, 70.0), (90.0, -40.0)] {
            let point = RelightDirectionDisk.point(azimuth: azimuth, elevation: elevation)
            let back = RelightDirectionDisk.angles(from: point)
            XCTAssertEqual(back.azimuth, azimuth, accuracy: 0.01)
            XCTAssertEqual(back.elevation, elevation, accuracy: 0.01)
        }
        // From the right sits on the right of the disk; from the top, on top.
        XCTAssertGreaterThan(RelightDirectionDisk.point(azimuth: 0, elevation: 0).x, 0.99)
        XCTAssertLessThan(RelightDirectionDisk.point(azimuth: 90, elevation: 0).y, -0.99)
    }

    // MARK: - Depth cache

    private func plane(_ width: Int, _ height: Int, value: UInt16, startsShot: Bool = false) -> RelightDepthPlane {
        RelightDepthPlane(width: width, height: height,
                          depth: [UInt16](repeating: value, count: width * height),
                          confidence: [UInt8](repeating: 200, count: width * height),
                          startsShot: startsShot, estimator: .structural, relief: 1.25)
    }

    func testDepthPlaneRoundTrips() throws {
        var depth: [UInt16] = []
        var confidence: [UInt8] = []
        for index in 0..<12 { depth.append(UInt16(index * 5000)); confidence.append(UInt8(index * 20)) }
        let original = RelightDepthPlane(width: 4, height: 3, depth: depth, confidence: confidence,
                                         startsShot: true, estimator: .coreML, relief: 1.8)
        let decoded = try RelightDepthPlane(decoding: original.encoded())
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 3)
        XCTAssertEqual(decoded.depth, depth)
        XCTAssertEqual(decoded.confidence, confidence)
        XCTAssertTrue(decoded.startsShot)
        XCTAssertEqual(decoded.estimator, .coreML)
        XCTAssertEqual(decoded.relief, 1.8, accuracy: 0.001)
    }

    func testCorruptDepthIsRejected() {
        XCTAssertThrowsError(try RelightDepthPlane(decoding: Data(repeating: 7, count: 40)))
    }

    func testStoreBlendsBetweenStoredFramesAndNeverAcrossACut() throws {
        let identifier = "relight-test-\(UUID().uuidString)"
        defer { RelightDepthStore.shared.remove(identifier: identifier) }
        let key = RelightDepthStore.Key(identifier: identifier, quality: .fast)
        try RelightDepthStore.shared.write(plane(4, 4, value: 1000), key: key, frame: 0)
        try RelightDepthStore.shared.write(plane(4, 4, value: 9000), key: key, frame: 4)

        let between = try XCTUnwrap(RelightDepthStore.shared.sample(
            identifier: identifier, preferring: .fast, position: 1))
        XCTAssertEqual(between.first.index, 0)
        XCTAssertEqual(between.second?.index, 4)
        XCTAssertEqual(between.phase, 0.25, accuracy: 0.001)

        // A cut at frame 8: frames before it never blend with it.
        try RelightDepthStore.shared.write(plane(4, 4, value: 20000, startsShot: true), key: key, frame: 8)
        let beforeCut = try XCTUnwrap(RelightDepthStore.shared.sample(
            identifier: identifier, preferring: .fast, position: 6))
        XCTAssertNil(beforeCut.second)
        XCTAssertEqual(beforeCut.first.index, 4)

        // Far from anything stored, nothing is claimed.
        XCTAssertNil(RelightDepthStore.shared.sample(identifier: identifier, preferring: .fast, position: 200))
        XCTAssertTrue(RelightDepthStore.shared.covers(identifier: identifier, quality: .fast, position: 2))
        XCTAssertFalse(RelightDepthStore.shared.covers(identifier: identifier, quality: .high, position: 2))
    }

    func testRewrittenFramesGetANewUploadKey() throws {
        let identifier = "relight-test-\(UUID().uuidString)"
        defer { RelightDepthStore.shared.remove(identifier: identifier) }
        let key = RelightDepthStore.Key(identifier: identifier, quality: .high)
        try RelightDepthStore.shared.write(plane(2, 2, value: 100), key: key, frame: 0)
        let before = try XCTUnwrap(RelightDepthStore.shared.sample(
            identifier: identifier, preferring: .high, position: 0)).first.cacheKey
        try RelightDepthStore.shared.write(plane(2, 2, value: 900), key: key, frame: 0)
        let after = try XCTUnwrap(RelightDepthStore.shared.sample(
            identifier: identifier, preferring: .high, position: 0))
        XCTAssertNotEqual(before, after.first.cacheKey)
        XCTAssertEqual(after.first.plane.depth.first, 900)
    }

    func testClearingOneQualityLeavesTheOther() throws {
        let identifier = "relight-test-\(UUID().uuidString)"
        defer { RelightDepthStore.shared.remove(identifier: identifier) }
        try RelightDepthStore.shared.write(plane(2, 2, value: 1), key: .init(identifier: identifier, quality: .fast), frame: 0)
        try RelightDepthStore.shared.write(plane(2, 2, value: 1), key: .init(identifier: identifier, quality: .high), frame: 0)
        RelightDepthStore.shared.clear(.init(identifier: identifier, quality: .fast))
        XCTAssertEqual(RelightDepthStore.shared.availableQuality(identifier: identifier, preferring: .fast), .high)
    }

    // MARK: - Temporal stabilisation

    func testAlignmentRecoversScaleAndOffset() {
        let estimate: [Float] = (0..<64).map { Float($0) / 63 }
        let predicted = estimate.map { 0.5 * $0 + 0.1 }
        let fit = RelightTemporalFusion.align(estimate: estimate, to: predicted,
                                              weights: [Float](repeating: 1, count: 64))
        XCTAssertEqual(fit.scale, 0.5, accuracy: 0.001)
        XCTAssertEqual(fit.offset, 0.1, accuracy: 0.001)
    }

    func testStillFramesCarryDepthUnchangedAndTrustIt() {
        let width = 8, height = 6
        let depth: [Float] = (0..<(width * height)).map { Float($0 % width) / Float(width) }
        let state = RelightTemporalFusion.fresh(estimate: depth, confidence: [Float](repeating: 0.9, count: depth.count),
                                                width: width, height: height)
        let still = RelightFlowField(width: width, height: height,
                                     vectors: [SIMD4<Float>](repeating: .zero, count: width * height))
        let carried = RelightTemporalFusion.propagate(state, forward: still, backward: still)
        for index in depth.indices {
            XCTAssertEqual(carried.state.depth[index], depth[index], accuracy: 1e-5)
        }
        XCTAssertGreaterThan(carried.reliability.min() ?? 0, 0.95)
    }

    func testAKeyframeCorrectsGraduallyRatherThanJumping() {
        let count = 16
        var state = RelightTemporalFusion.fresh(estimate: [Float](repeating: 0.2, count: count),
                                                confidence: [Float](repeating: 0.9, count: count),
                                                width: 4, height: 4)
        // A new estimate with a different shape: half the pixels nearer.
        let estimate: [Float] = (0..<count).map { $0 < count / 2 ? 0.2 : 0.8 }
        RelightTemporalFusion.fuse(&state, estimate: estimate,
                                   estimateConfidence: [Float](repeating: 0.9, count: count),
                                   reliability: [Float](repeating: 1, count: count),
                                   parameters: .high)
        let before = state.depth
        RelightTemporalFusion.settle(&state, reliability: nil, parameters: .high)
        // Moved toward the estimate, but only part of the way in one frame.
        let moved = zip(before, state.depth).map { abs($1 - $0) }.max() ?? 0
        XCTAssertGreaterThan(moved, 0)
        let gap = zip(state.depth, estimate).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(gap, 0.05)
    }

    func testNormalisationIsStableForAStaticScene() {
        let depth: [Float] = (0..<100).map { Float($0) / 99 }
        var state = RelightTemporalFusion.fresh(estimate: depth, confidence: [Float](repeating: 1, count: 100),
                                                width: 10, height: 10)
        let first = RelightTemporalFusion.normalized(&state, reset: true, parameters: .fast)
        let second = RelightTemporalFusion.normalized(&state, reset: false, parameters: .fast)
        XCTAssertEqual(first.depth, second.depth)
        XCTAssertEqual(first.confidence, second.confidence)
    }

    // MARK: - Shader layout

    func testUniformBlockMatchesTheShaderLayout() {
        let light = RelightLight.starting(.point, name: "Key")
        let settings = RelightSettings(lights: [light])
        let source = RelightSourceInfo(
            assetID: UUID(), cacheIdentifier: "layout", assetStart: .zero,
            frameDurationSeconds: 1.0 / 30, encodedSize: CGSize(width: 1920, height: 1080),
            displaySize: CGSize(width: 1920, height: 1080), orientation: .identity)
        let sample = RelightDepthSample(
            first: .init(index: 0, plane: plane(2, 2, value: 0), cacheKey: "layout"),
            second: nil, phase: 0, quality: .fast)
        let frame = RelightFrame(settings: settings, source: source, depth: sample, masks: [],
                                 maskAspect: 16.0 / 9.0, extendedRange: false, ceiling: 1,
                                 geometryLongEdge: 960, isLog2: false)
        let words = RelightStage.uniformWords(frame)
        XCTAssertEqual(words.count, 5 + 6 * RelightSettings.maximumLights)
        XCTAssertEqual(words[1].z, 1, "light count")
        XCTAssertEqual(words[5].w, RelightLightType.point.shaderCode, "first light's type")
        XCTAssertEqual(words[0].y, 1, accuracy: 1e-6, "strength")
        // Position: right of centre and above it, in frame heights.
        XCTAssertGreaterThan(words[5].x, 0)
        XCTAssertLessThan(words[5].y, 0)
    }

    func testFittedKeepsAspectAndNeverEnlarges() {
        let fitted = RelightStage.fitted((3840, 2160), longEdge: 960)
        XCTAssertEqual(fitted.width, 960)
        XCTAssertEqual(fitted.height, 540)
        let small = RelightStage.fitted((320, 180), longEdge: 960)
        XCTAssertEqual(small.width, 320)
        XCTAssertEqual(small.height, 180)
    }
}
