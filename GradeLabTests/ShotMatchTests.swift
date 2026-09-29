import XCTest
import simd
@testable import GradeLab

/// Shot Match, from the document's side.
///
/// The colour science is covered where it can be proved rather than asserted —
/// `Scripts/ValidateShotMatch.swift` runs the solver's forward model and the
/// real `applyGradeCore` over the same colours on the GPU and requires them to
/// agree. What is here is everything that decides whether the feature is
/// non-destructive, undoable and persistent, none of which needs a GPU and all
/// of which is easy to break by accident.
final class ShotMatchTests: XCTestCase {

    // MARK: - Fixtures

    /// A synthetic picture with a plausible tonal spread and colour around the
    /// wheel. Deterministic, so a failure is a regression rather than a draw.
    private func scene(seed: UInt64, count: Int = 8000) -> [SIMD3<Float>] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        return (0..<count).map { _ in
            let luma = min(max((next() + next() + next()) / 3 * 1.05, 0), 1)
            let wheel = ShotMatchColor.hueRGB(next())
            let tint = wheel - SIMD3(repeating: ShotMatchColor.luminance(wheel))
            return ShotMatchColor.toLinear(
                simd_clamp(SIMD3(repeating: luma) + tint * (next() * 0.45) * luma, .zero, .one))
        }
    }

    private func adjustment() -> ShotMatchAdjustment {
        var value = ShotMatchAdjustment.neutral
        value.exposure = 0.4
        value.temperature = -20
        value.tint = 8
        value.contrast = 15
        value.saturation = -12
        value.wheels[0] = GradingWheel(hue: 195, strength: 24, brightness: 0)
        return value
    }

    // MARK: - Applying a match

    /// A match adds to the grade that was already there rather than replacing
    /// it. This is the difference between "match this shot" and "throw away my
    /// grade and match this shot".
    func testAMatchAddsToTheGradeUnderneath() {
        var base = GradeSettings.neutral
        base.exposure = 0.2
        base.temperature = 10
        base.vibrance = 30

        let applied = adjustment().applied(to: base)
        XCTAssertEqual(applied.exposure, 0.6, accuracy: 1e-5, "stops add")
        XCTAssertEqual(applied.temperature, -10, accuracy: 1e-5, "white balance exponents add")
        XCTAssertEqual(applied.vibrance, 30, accuracy: 1e-5,
                       "a control the match never writes is left exactly as it was")
    }

    /// Saturation is a multiplier on distance from grey, so two of them
    /// multiply. Adding them would make a half-desaturated clip matched to a
    /// half-desaturated reference come out grey.
    func testSaturationComposesThroughItsMultiplier() {
        var base = GradeSettings.neutral
        base.saturation = -50
        var match = ShotMatchAdjustment.neutral
        match.saturation = -50

        let applied = match.applied(to: base)
        XCTAssertEqual(applied.saturation, -75, accuracy: 1e-4,
                       "0.5 x 0.5 is 0.25 of the original colour, not zero")
    }

    /// Two wheels in one tonal range compose as vectors, because that is what
    /// the shader does with them.
    func testOpposedWheelsCancelRatherThanAveraging() {
        var base = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.normalizeCollections()
        advanced.wheels[0] = GradingWheel(hue: 30, strength: 40, brightness: 0)
        base.advanced = advanced

        var match = ShotMatchAdjustment.neutral
        match.wheels[0] = GradingWheel(hue: 210, strength: 40, brightness: 0)

        let wheel = match.applied(to: base).advanced?.wheel(0) ?? GradingWheel()
        XCTAssertEqual(wheel.strength, 0, accuracy: 0.01,
                       "equal and opposite pushes leave the shadows untinted")
    }

    func testAlignedWheelsAddTheirStrength() {
        var base = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.normalizeCollections()
        advanced.wheels[2] = GradingWheel(hue: 45, strength: 20, brightness: 0)
        base.advanced = advanced

        var match = ShotMatchAdjustment.neutral
        match.wheels[2] = GradingWheel(hue: 45, strength: 25, brightness: 0)

        let wheel = match.applied(to: base).advanced?.wheel(2) ?? GradingWheel()
        XCTAssertEqual(wheel.strength, 45, accuracy: 0.05)
        XCTAssertEqual(wheel.hue, 45, accuracy: 0.05)
    }

    /// A match whose curve lands on a clip that already has one produces the
    /// two in sequence, not one of them.
    func testToneCurvesCompose() throws {
        var base = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        var curves = AdvancedCurves()
        curves[.master] = AdvancedCurve(type: .master, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)
        ])
        advanced.advancedCurves = curves
        base.advanced = advanced

        var match = ShotMatchAdjustment.neutral
        match.toneCurve = [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.6, y: 0.7), CurvePoint(x: 1, y: 1)
        ]

        let merged = match.applied(to: base).advanced?.resolvedCurves[.master]
        let evaluator = CurveEvaluator(try XCTUnwrap(merged))
        // Base takes 0.5 to 0.6; the match takes 0.6 to 0.7. Composed, 0.5 lands
        // near 0.7 — not at 0.6 (base only) and not at 0.55 (match only).
        XCTAssertEqual(evaluator.value(at: 0.5), 0.7, accuracy: 0.03,
                       "the merged curve is the base curve followed by the match's")
        XCTAssertEqual(evaluator.value(at: 0), 0, accuracy: 1e-4)
        XCTAssertEqual(evaluator.value(at: 1), 1, accuracy: 1e-4)
    }

    /// Every control the match writes stays inside the range its own slider
    /// travels, whatever the two pictures say.
    func testControlsAreClampedToTheirOwnRanges() {
        var huge = ShotMatchAdjustment.neutral
        huge.exposure = 9
        huge.temperature = 400
        huge.contrast = 900

        var base = GradeSettings.neutral
        base.exposure = 1.5
        base.temperature = 80

        let applied = huge.applied(to: base)
        XCTAssertEqual(applied.exposure, GradeParameter.exposure.range.upperBound)
        XCTAssertEqual(applied.temperature, GradeParameter.temperature.range.upperBound)
        XCTAssertEqual(applied.contrast, GradeParameter.contrast.range.upperBound)
    }

    // MARK: - Strength

    func testStrengthInterpolatesTheTransformRatherThanFadingTheResult() {
        let full = adjustment()
        let half = full.scaled(by: 0.5)
        XCTAssertEqual(half.exposure, full.exposure / 2, accuracy: 1e-5,
                       "stops are linear, so half the stops is half the move")
        XCTAssertEqual(half.temperature, full.temperature / 2, accuracy: 1e-5)
        XCTAssertEqual(half.wheels[0].strength, full.wheels[0].strength / 2, accuracy: 1e-5)
        XCTAssertEqual(half.wheels[0].hue, full.wheels[0].hue, accuracy: 1e-5,
                       "strength scales the push, never the direction it points")
        // Saturation interpolates through its multiplier: half of x0.88 is
        // x0.94, not x0.44.
        let expected = (pow(1 + full.saturation / 100, 0.5) - 1) * 100
        XCTAssertEqual(half.saturation, expected, accuracy: 1e-4)
    }

    func testZeroStrengthIsNeutralEvenThoughTheValuesAreRemembered() {
        let zero = adjustment().scaled(by: 0)
        XCTAssertTrue(zero.isNeutral)
        XCTAssertEqual(zero.applied(to: .neutral), .neutral)
    }

    func testAToneCurveInterpolatesTowardTheDiagonal() throws {
        var full = ShotMatchAdjustment.neutral
        full.toneCurve = [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)
        ]
        let half = try XCTUnwrap(full.scaled(by: 0.5).toneCurve)
        XCTAssertEqual(half[1].y, 0.6, accuracy: 1e-5,
                       "halfway between the solved 0.7 and the identity 0.5")
        XCTAssertTrue(full.scaled(by: 0).isNeutral,
                      "a curve scaled to nothing lies on the diagonal and is neutral")
    }

    // MARK: - Non-destructiveness

    /// The promise the whole design rests on: whatever happens to Strength,
    /// removing the match returns the grade that was there, exactly.
    func testRemovingAMatchRestoresTheExactGradeUnderneath() {
        var base = GradeSettings.neutral
        base.exposure = -0.3
        base.contrast = 22
        base.temperature = 14
        var advanced = AdvancedGrade.neutral
        advanced.normalizeCollections()
        advanced.wheels[1] = GradingWheel(hue: 300, strength: 18, brightness: 5)
        advanced.vignette = -40
        base.advanced = advanced

        var settings = ShotMatchSettings(
            reference: ShotMatchReference(
                source: .importedImage(fileName: "r.jpg"), displayName: "r",
                profile: ShotAnalyzer.empty(), isClipAverage: false, thumbnailFileName: nil),
            mode: .shot, components: .default, strength: 1,
            adjustment: adjustment(), confidence: .high, baseGrade: base)

        // Move the strength around the way a drag would.
        for strength in [Float(1), 0.25, 0.9, 0.05, 0.6] {
            settings.strength = strength
            _ = settings.resolvedGrade
        }
        settings.strength = 0
        XCTAssertEqual(settings.resolvedGrade, base,
                       "the base grade is stored, not reconstructed, so it cannot drift")
    }

    func testStrengthIsRebuiltFromTheBaseRatherThanAccumulated() {
        var settings = ShotMatchSettings(
            reference: ShotMatchReference(
                source: .importedImage(fileName: "r.jpg"), displayName: "r",
                profile: ShotAnalyzer.empty(), isClipAverage: false, thumbnailFileName: nil),
            mode: .shot, components: .default, strength: 0.5,
            adjustment: adjustment(), confidence: .high, baseGrade: .neutral)
        let once = settings.resolvedGrade
        settings.strength = 1
        _ = settings.resolvedGrade
        settings.strength = 0.5
        XCTAssertEqual(settings.resolvedGrade, once,
                       "returning to a strength returns to exactly the same numbers")
    }

    func testAHandEditAfterMatchingIsNoticed() {
        let settings = ShotMatchSettings(
            reference: ShotMatchReference(
                source: .importedImage(fileName: "r.jpg"), displayName: "r",
                profile: ShotAnalyzer.empty(), isClipAverage: false, thumbnailFileName: nil),
            mode: .shot, components: .default, strength: 1,
            adjustment: adjustment(), confidence: .high, baseGrade: .neutral)
        XCTAssertFalse(settings.isDetached(from: settings.resolvedGrade))
        var edited = settings.resolvedGrade
        edited.vibrance = 25
        XCTAssertTrue(settings.isDetached(from: edited),
                      "the panel has to be able to warn before Strength discards a hand edit")
    }

    // MARK: - Persistence

    func testAClipWithoutAMatchDecodesUnchanged() throws {
        // A project written before Shot Match existed has no such key. The
        // decode has to produce the clip it always was rather than failing.
        let json = """
        {"placement":{"id":"\(UUID().uuidString)","trackID":"\(UUID().uuidString)",
        "timelineStart":{"value":0,"timescale":600},"duration":{"value":600,"timescale":600},
        "isEnabled":true,"isLocked":false},
        "assetID":"\(UUID().uuidString)",
        "sourceRange":{"start":{"value":0,"timescale":600},"duration":{"value":600,"timescale":600}},
        "gradeSettings":{"exposure":0.25,"contrast":0,"highlights":0,"shadows":0,"whites":0,
        "blacks":0,"temperature":0,"tint":0,"saturation":0,"vibrance":0},
        "transform":{"positionX":0.5,"positionY":0.5,"anchorX":0.5,"anchorY":0.5,"scale":1,
        "widthScale":1,"heightScale":1,"rotationDegrees":0,"locksAspectRatio":true},
        "opacity":1,"blendMode":"normal"}
        """
        let clip = try JSONDecoder().decode(VideoClip.self, from: Data(json.utf8))
        XCTAssertNil(clip.shotMatch, "no match record, and no failure to decode")
        XCTAssertEqual(clip.gradeSettings.exposure, 0.25, accuracy: 1e-5)
    }

    func testAMatchRoundTripsThroughTheDocument() throws {
        let profile = ShotAnalyzer.profile(linearSamples: scene(seed: 11))
        let settings = ShotMatchSettings(
            reference: ShotMatchReference(
                source: .timelineClip(clipID: UUID(), seconds: 4.25),
                displayName: "A camera", profile: profile, isClipAverage: true,
                thumbnailFileName: nil),
            mode: .look, components: [.exposure, .whiteBalance], strength: 0.62,
            adjustment: adjustment(), confidence: .medium, baseGrade: .neutral)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ShotMatchSettings.self, from: data), settings)
    }

    /// A reference is kept as a measurement, not a picture, so a match survives
    /// the file it was made from being deleted.
    func testAProfileIsSmallEnoughToLiveInAProject() throws {
        let profile = ShotAnalyzer.profile(linearSamples: scene(seed: 4))
        let data = try JSONEncoder().encode(profile)
        XCTAssertLessThan(data.count, 4000, "a reference costs a few kilobytes, not a photograph")
        XCTAssertEqual(try JSONDecoder().decode(ShotProfile.self, from: data), profile)
    }

    // MARK: - Measurement

    /// A profile describes how a picture is TINTED, never what colour it is.
    /// Every chroma reading is normalised to unit luminance for exactly this
    /// reason: otherwise a bright shot and a dark shot of the same scene would
    /// be reported as differently coloured.
    func testChromaIsMeasuredIndependentlyOfBrightness() {
        let samples = scene(seed: 21)
        var brighter = ShotMatchTransform.neutral
        brighter.exposure = 1.0
        let base = ShotAnalyzer.profile(linearSamples: samples)
        let lifted = ShotAnalyzer.profile(
            linearSamples: ShotMatchForwardModel.apply(brighter, to: samples))

        XCTAssertEqual(simd_length(base.neutralBias.simd - lifted.neutralBias.simd), 0,
                       accuracy: 0.02, "a stop of exposure is not a colour cast")
        for zone in ShotZone.allCases {
            XCTAssertEqual(simd_length(base.zone(zone) - lifted.zone(zone)), 0, accuracy: 0.08,
                           "nor is it a change in how a tonal range is tinted")
        }
    }

    /// Exposure is measured from percentiles, not from a mean, so a large dark
    /// area cannot drag the reading.
    func testExposureIsMeasuredRobustly() {
        var samples = scene(seed: 31, count: 6000)
        // A third of the frame is a black curtain. The mean falls a long way;
        // the median barely moves.
        samples.append(contentsOf: [SIMD3<Float>](repeating: .zero, count: 3000))
        let withCurtain = ShotAnalyzer.profile(linearSamples: samples)
        let without = ShotAnalyzer.profile(linearSamples: scene(seed: 31, count: 6000))

        let correction = MatchSolver.exposureCorrection(current: withCurtain, reference: without)
        XCTAssertLessThan(abs(correction), 0.9,
                          "a black curtain is not an under-exposure of the whole shot")
    }

    /// Both ends of the range are found, and a picture that uses less of it is
    /// reported as using less of it.
    func testDynamicRangeIsReported() {
        let samples = scene(seed: 41)
        var flatter = ShotMatchTransform.neutral
        flatter.contrast = -0.5
        let full = ShotAnalyzer.profile(linearSamples: samples)
        let flat = ShotAnalyzer.profile(
            linearSamples: ShotMatchForwardModel.apply(flatter, to: samples))
        XCTAssertLessThan(flat.dynamicRangeStops, full.dynamicRangeStops - 0.5,
                          "a flattened picture uses measurably less of the range")
    }

    /// Whites used to begin so high in linear light, and move so little, that
    /// the control did nothing on a flat or Log-looking picture. It should
    /// visibly move an upper-tone pixel while leaving photographic middle grey
    /// alone; Highlights is the broader control for the range between them.
    func testWhitesIsVisibleOnFlatFootageWithoutMovingMiddleGrey() {
        var positive = ShotMatchTransform.neutral
        positive.whites = 1
        var negative = ShotMatchTransform.neutral
        negative.whites = -1

        let middle = SIMD3<Float>(repeating: 0.18)
        let flatWhite = SIMD3<Float>(repeating: 0.45)
        let raisedMiddle = ShotMatchForwardModel.applyTonalRange(positive, to: middle)
        let raisedWhite = ShotMatchForwardModel.applyTonalRange(positive, to: flatWhite)
        let loweredWhite = ShotMatchForwardModel.applyTonalRange(negative, to: flatWhite)

        XCTAssertEqual(raisedMiddle.x, middle.x, accuracy: 0.0001,
                       "Whites must not behave like a second Exposure control")
        XCTAssertGreaterThan(raisedWhite.x, flatWhite.x + 0.03,
                             "full positive Whites must be plainly visible on flat footage")
        XCTAssertLessThan(loweredWhite.x, flatWhite.x - 0.03,
                          "full negative Whites must be plainly visible on flat footage")
    }

    func testAnEmptyProfileIsNotUsable() {
        XCTAssertFalse(ShotAnalyzer.empty().isUsable)
        XCTAssertTrue(ShotAnalyzer.profile(linearSamples: scene(seed: 51, count: 1000)).isUsable)
    }

    /// Averaging frames across a shot, rather than trusting whichever one the
    /// playhead happened to be on.
    func testAClipAverageIsNotDominatedByOneFrame() throws {
        let samples = scene(seed: 61)
        let frames = (0..<5).map { index -> ShotProfile in
            var flicker = ShotMatchTransform.neutral
            // One frame of the five is two stops brighter — a passing headlight.
            flicker.exposure = index == 2 ? 2.0 : 0
            return ShotAnalyzer.profile(
                linearSamples: ShotMatchForwardModel.apply(flicker, to: samples))
        }
        let averaged = try XCTUnwrap(ShotAnalyzer.merged(frames))
        let steady = frames[0]
        let flash = frames[2]
        let toSteady = abs(averaged.percentile(ShotPercentile.p50)
                           - steady.percentile(ShotPercentile.p50))
        let toFlash = abs(averaged.percentile(ShotPercentile.p50)
                          - flash.percentile(ShotPercentile.p50))
        XCTAssertLessThan(toSteady, toFlash,
                          "four steady frames outvote one bright one")
    }

    // MARK: - Solving

    func testAShotMatchedToItselfIsLeftAlone() {
        let samples = scene(seed: 71)
        let profile = ShotAnalyzer.profile(linearSamples: samples)
        let solved = MatchSolver.solve(
            targetSamples: ShotSamples(linear: samples), target: profile,
            reference: profile, components: .all, mode: .shot).adjustment

        XCTAssertLessThan(abs(solved.exposure), 0.05)
        for value in [solved.temperature, solved.tint, solved.contrast, solved.saturation,
                      solved.blacks, solved.whites, solved.shadows, solved.highlights] {
            XCTAssertLessThan(abs(value), 2, "every control has a deadband")
        }
        XCTAssertNil(solved.toneCurve)
        XCTAssertTrue(solved.isNeutral || ShotMatchPanel.summary(solved).isEmpty,
                      "nothing worth showing in the panel either")
    }

    func testADisabledComponentIsNeverWritten() {
        let reference = ShotAnalyzer.profile(linearSamples: scene(seed: 81))
        var offset = ShotMatchTransform.neutral
        offset.exposure = -0.8
        offset.temperature = 0.3
        offset.contrast = -0.3
        let target = ShotMatchForwardModel.apply(offset, to: scene(seed: 81))

        let solved = MatchSolver.solve(
            targetSamples: ShotSamples(linear: target),
            target: ShotAnalyzer.profile(linearSamples: target),
            reference: reference, components: [.whiteBalance], mode: .shot).adjustment

        XCTAssertEqual(solved.exposure, 0)
        XCTAssertEqual(solved.contrast, 0)
        XCTAssertEqual(solved.saturation, 0)
        XCTAssertNil(solved.toneCurve)
        XCTAssertTrue(solved.wheels.allSatisfy { $0.strength == 0 })
        XCTAssertGreaterThan(abs(solved.temperature), 3, "the one that was allowed still ran")
    }

    /// A reference from another world is damped and is not reported as a
    /// confident match.
    func testAnExtremeReferenceIsDampedAndReported() {
        var night = ShotMatchTransform.neutral
        night.exposure = -3.2
        let nightSamples = ShotMatchForwardModel.apply(night, to: scene(seed: 91))
        var snow = ShotMatchTransform.neutral
        snow.exposure = 1.6
        snow.saturation = -0.6
        let snowProfile = ShotAnalyzer.profile(
            linearSamples: ShotMatchForwardModel.apply(snow, to: scene(seed: 92)))

        let solution = MatchSolver.solve(
            targetSamples: ShotSamples(linear: nightSamples),
            target: ShotAnalyzer.profile(linearSamples: nightSamples),
            reference: snowProfile, components: .all, mode: .shot)

        XCTAssertGreaterThan(solution.divergence, 0.25)
        XCTAssertNotEqual(solution.confidence, .high)
        XCTAssertNotNil(solution.confidence.advice, "a low confidence explains itself")
        XCTAssertLessThan(solution.adjustment.exposure, 1.9,
                          "the night interior is not opened up to the snowfield")
    }

    func testLookModeDoesNotRelightTheShot() {
        let reference = ShotAnalyzer.profile(linearSamples: scene(seed: 101))
        var dark = ShotMatchTransform.neutral
        dark.exposure = -1.5
        let target = ShotMatchForwardModel.apply(dark, to: scene(seed: 101))

        let look = MatchSolver.solve(
            targetSamples: ShotSamples(linear: target),
            target: ShotAnalyzer.profile(linearSamples: target),
            reference: reference, components: .all, mode: .look).adjustment
        XCTAssertLessThanOrEqual(abs(look.exposure),
                                 ShotMatchMode.look.exposureAuthority.limit + 1e-4)
    }

    /// The residual curve is smoothed and slope-limited, because a raw
    /// histogram match between two different scenes is a posterising machine.
    func testAResidualCurveIsMonotoneAndSlopeLimited() throws {
        var offset = ShotMatchTransform.neutral
        offset.contrast = -0.55
        offset.exposure = -0.5
        let target = ShotMatchForwardModel.apply(offset, to: scene(seed: 111))
        let solved = MatchSolver.solve(
            targetSamples: ShotSamples(linear: target),
            target: ShotAnalyzer.profile(linearSamples: target),
            reference: ShotAnalyzer.profile(linearSamples: scene(seed: 111)),
            components: .all, mode: .look).adjustment

        let points = try XCTUnwrap(solved.toneCurve)
        XCTAssertEqual(points.first?.y, 0, "the black point belongs to Blacks, not to the curve")
        XCTAssertEqual(points.last?.y, 1, "and the white point to Whites")
        for index in 1..<points.count {
            XCTAssertGreaterThanOrEqual(points[index].y, points[index - 1].y - 1e-6)
            let slope = (points[index].y - points[index - 1].y)
                / (points[index].x - points[index - 1].x)
            XCTAssertGreaterThanOrEqual(slope, MatchSolver.minimumCurveSlope - 1e-3,
                                        "no segment may crush a band of the picture flat")
            XCTAssertLessThanOrEqual(slope, MatchSolver.maximumCurveSlope + 1e-3,
                                     "nor stretch one until it bands")
        }
    }

    /// The white-balance inverse is exact, not fitted: these are the shader's
    /// own cone gains solved back into the two controls that produce them.
    func testWhiteBalanceInvertsItsOwnShaderModel() {
        for (temperature, tint) in [(0.35 as Float, -0.2 as Float), (-0.6, 0.45), (0.1, 0.05)] {
            let gains = ShotMatchColor.coneGains(temperature: temperature, tint: tint)
            let solved = ShotMatchColor.whiteBalance(forConeGains: gains)
            XCTAssertEqual(solved.temperature, temperature, accuracy: 1e-5)
            XCTAssertEqual(solved.tint, tint, accuracy: 1e-5)
        }
    }

    // MARK: - Panel

    func testThePanelListsWhatTheMatchWrote() {
        let rows = ShotMatchPanel.summary(adjustment())
        let names = rows.map(\.name)
        XCTAssertTrue(names.contains(GradeParameter.exposure.title))
        XCTAssertTrue(names.contains(GradeParameter.temperature.title))
        XCTAssertFalse(names.contains(GradeParameter.whites.title),
                       "a control the match never touched is not listed as if it had been")
        XCTAssertTrue(rows.contains { $0.name.contains("Shadow") },
                      "a wheel the match set is shown")
    }

    func testThePanelShowsNothingForANeutralMatch() {
        XCTAssertTrue(ShotMatchPanel.summary(.neutral).isEmpty)
    }

    /// Every component in the model is offered in the panel. A component added
    /// without a row would be permanently on with no way to switch it off.
    func testEveryComponentIsOffered() {
        let offered = ShotMatchPanel.componentRows.reduce(into: ShotMatchComponents()) {
            $0.insert($1.component)
        }
        XCTAssertEqual(offered, .all)
    }

    func testTheMatchToolIsNotOfferedToTheStillEditor() {
        // A still project has nowhere to record what a match was made from or
        // what grade was underneath it, which is what makes one undoable.
        XCTAssertFalse(GradePanel.localCapable.contains(.match),
                       "and a masked local grade has no reference of its own either")
    }
}
