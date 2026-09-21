import XCTest
@testable import GradeLab

/// Pasting onto a clip that is already graded asks the user which of two things
/// they meant. These cover the one they have never been able to ask for before:
/// keep what is there and add the copied grade on top.
final class GradeStackingTests: XCTestCase {

    // MARK: - Sliders add

    func testSlidersAddAndTheOriginalIsKept() {
        var base = GradeSettings()
        base.exposure = 0.4
        base.saturation = 20

        var copied = GradeSettings()
        copied.exposure = 0.3
        copied.contrast = 15

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.exposure, 0.7, accuracy: 1e-5, "both exposures should count")
        XCTAssertEqual(stacked.contrast, 15, accuracy: 1e-5, "the copied grade's own change arrives")
        XCTAssertEqual(stacked.saturation, 20, accuracy: 1e-5, "the clip keeps what the copy never touched")
    }

    /// The exact case from the report: a clip with nothing but an exposure tweak
    /// must not lose it.
    func testAClipWithOnlyExposureKeepsItWhenTheCopiedGradeDoesNotTouchExposure() {
        var base = GradeSettings()
        base.exposure = -0.75

        var copied = GradeSettings()
        copied.temperature = 30

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.exposure, -0.75, accuracy: 1e-5)
        XCTAssertEqual(stacked.temperature, 30, accuracy: 1e-5)
    }

    func testAddedSlidersAreClampedToTheirOwnRange() {
        var base = GradeSettings()
        base.exposure = 1.8
        base.contrast = 80

        var copied = GradeSettings()
        copied.exposure = 1.5
        copied.contrast = 70

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.exposure, 2, accuracy: 1e-5, "exposure tops out at +2 stops")
        XCTAssertEqual(stacked.contrast, 100, accuracy: 1e-5)
    }

    func testNegativeAndPositiveCancelRatherThanOneWinning() {
        var base = GradeSettings()
        base.tint = 40
        var copied = GradeSettings()
        copied.tint = -40
        XCTAssertEqual(copied.stacked(onto: base).tint, 0, accuracy: 1e-5)
    }

    // MARK: - Shapes replace only where they are set

    func testACopiedLookReplacesTheOneOnTheClip() {
        var base = GradeSettings()
        base.advanced = AdvancedGrade()
        base.advanced?.lut = "existing"
        base.advanced?.lutIntensity = 60

        var copied = GradeSettings()
        copied.advanced = AdvancedGrade()
        copied.advanced?.lut = "copied"
        copied.advanced?.lutIntensity = 100

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.advanced?.lut, "copied")
        XCTAssertEqual(stacked.advanced?.lutIntensity, 100)
    }

    func testACopiedGradeWithNoLookLeavesTheClipsLookAlone() {
        var base = GradeSettings()
        base.advanced = AdvancedGrade()
        base.advanced?.lut = "existing"

        var copied = GradeSettings()
        copied.advanced = AdvancedGrade()
        copied.advanced?.vignette = 40

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.advanced?.lut, "existing")
        XCTAssertEqual(stacked.advanced?.vignette, 40)
    }

    func testAnHSLBandTheCopiedGradeNeverTouchedIsKept() {
        var base = GradeSettings()
        var baseAdvanced = AdvancedGrade()
        baseAdvanced.hsl[0] = HueBand(hue: 5, saturation: 30, luminance: 0)
        base.advanced = baseAdvanced

        var copied = GradeSettings()
        var copiedAdvanced = AdvancedGrade()
        copiedAdvanced.hsl[3] = HueBand(hue: -10, saturation: 0, luminance: 20)
        copied.advanced = copiedAdvanced

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.advanced?.band(0), HueBand(hue: 5, saturation: 30, luminance: 0))
        XCTAssertEqual(stacked.advanced?.band(3), HueBand(hue: -10, saturation: 0, luminance: 20))
    }

    func testACopiedWheelOverwritesTheSameWheelAndOnlyThatOne() {
        var base = GradeSettings()
        var baseAdvanced = AdvancedGrade()
        baseAdvanced.wheels[0] = GradingWheel(hue: 200, strength: 40, brightness: 5)
        baseAdvanced.wheels[2] = GradingWheel(hue: 30, strength: 20, brightness: 0)
        base.advanced = baseAdvanced

        var copied = GradeSettings()
        var copiedAdvanced = AdvancedGrade()
        copiedAdvanced.wheels[0] = GradingWheel(hue: 40, strength: 10, brightness: -3)
        copied.advanced = copiedAdvanced

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.advanced?.wheel(0), GradingWheel(hue: 40, strength: 10, brightness: -3))
        XCTAssertEqual(stacked.advanced?.wheel(2), GradingWheel(hue: 30, strength: 20, brightness: 0))
    }

    /// Curves are shapes, so a copied curve replaces the clip's curve of the
    /// same type — and leaves every other curve where it was.
    func testACopiedCurveReplacesOnlyItsOwnType() {
        var baseCurves = AdvancedCurves()
        var master = baseCurves[.master]
        master.points[1].y = 0.1
        baseCurves[.master] = master
        var red = baseCurves[.red]
        red.points[1].y = 0.9
        baseCurves[.red] = red

        var base = GradeSettings()
        var baseAdvanced = AdvancedGrade()
        baseAdvanced.advancedCurves = baseCurves
        base.advanced = baseAdvanced

        var copiedCurves = AdvancedCurves()
        var copiedMaster = copiedCurves[.master]
        copiedMaster.points[1].y = 0.55
        copiedCurves[.master] = copiedMaster

        var copied = GradeSettings()
        var copiedAdvanced = AdvancedGrade()
        copiedAdvanced.advancedCurves = copiedCurves
        copied.advanced = copiedAdvanced

        let resolved = copied.stacked(onto: base).advanced?.resolvedCurves
        XCTAssertEqual(resolved?[.master].points[1].y ?? 0, 0.55, accuracy: 1e-5)
        XCTAssertEqual(resolved?[.red].points[1].y ?? 0, 0.9, accuracy: 1e-5,
                       "a curve the copied grade never touched belongs to the clip")
    }

    /// A project saved before the advanced curves existed carries its shapes in
    /// the legacy three-anchor array. Merging has to go through the resolved
    /// form, or that clip's curve is dropped on the floor.
    func testALegacyCurveOnTheClipIsCarriedThroughTheMerge() {
        var base = GradeSettings()
        var baseAdvanced = AdvancedGrade()
        baseAdvanced.curves[0] = ToneCurve(shadows: 0.35, midtones: 0.5, highlights: 0.75)
        base.advanced = baseAdvanced

        var copied = GradeSettings()
        var copiedAdvanced = AdvancedGrade()
        copiedAdvanced.vignette = 25
        copied.advanced = copiedAdvanced

        let stacked = copied.stacked(onto: base)
        let resolved = stacked.advanced?.resolvedCurves
        XCTAssertFalse(resolved?.isNeutral ?? true, "the legacy curve must survive as a resolved curve")
        XCTAssertEqual(stacked.advanced?.curves, Array(repeating: ToneCurve(), count: 4),
                       "and the legacy array is cleared so it cannot contradict the resolved one")
    }

    // MARK: - The grading window stays with the picture

    /// A window is drawn around something in one picture. Carrying it to another
    /// clip points it at nothing, so adding on top keeps the clip's own.
    func testTheClipKeepsItsOwnGradingWindow() {
        var base = GradeSettings()
        var baseAdvanced = AdvancedGrade()
        baseAdvanced.mask = GradeMask(isEnabled: true, shape: .ellipse, centerX: 20, centerY: 80)
        base.advanced = baseAdvanced

        var copied = GradeSettings()
        var copiedAdvanced = AdvancedGrade()
        copiedAdvanced.mask = GradeMask(isEnabled: true, shape: .rectangle, centerX: 70, centerY: 10)
        copiedAdvanced.vignette = 30
        copied.advanced = copiedAdvanced

        let stacked = copied.stacked(onto: base)
        XCTAssertEqual(stacked.advanced?.mask?.centerX, 20)
        XCTAssertEqual(stacked.advanced?.mask?.shape, .ellipse)
    }

    func testAWindowFromTheCopiedGradeIsNotAdoptedByAnUngradedClip() {
        var copied = GradeSettings()
        var copiedAdvanced = AdvancedGrade()
        copiedAdvanced.mask = GradeMask(isEnabled: true, centerX: 70)
        copiedAdvanced.vignette = 30
        copied.advanced = copiedAdvanced

        let stacked = copied.stacked(onto: .neutral)
        XCTAssertNil(stacked.advanced?.mask)
        XCTAssertEqual(stacked.advanced?.vignette, 30)
    }

    // MARK: - Degenerate cases

    func testStackingANeutralGradeChangesNothing() {
        var base = GradeSettings()
        base.exposure = 0.5
        base.advanced = AdvancedGrade()
        base.advanced?.lut = "existing"
        XCTAssertEqual(GradeSettings.neutral.stacked(onto: base), base)
    }

    func testStackingOntoNeutralIsTheCopiedGrade() {
        var copied = GradeSettings()
        copied.exposure = 0.5
        copied.vibrance = 25
        XCTAssertEqual(copied.stacked(onto: .neutral), copied)
    }
}

/// The question the menu asks before a paste, and what each answer does to the
/// clip, driven through the real view model.
@MainActor
final class PasteGradeConfirmationTests: XCTestCase {

    private func makeModel() throws -> EditorViewModel {
        let project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
                                   displayName: "Clip", metadata: makeMetadata(duration: 10))
        return try EditorViewModel(project: project)
    }

    override func tearDown() {
        GradeClipboard.shared.clear()
        super.tearDown()
    }

    func testAnUngradedClipIsNotAskedAbout() throws {
        let model = try makeModel()
        var copied = GradeSettings()
        copied.exposure = 0.5
        GradeClipboard.shared.copy(copied)

        XCTAssertTrue(model.canPasteGrade)
        XCTAssertFalse(model.pasteWouldOverwriteGrade, "there is nothing to lose, so there is nothing to ask")
    }

    /// The exact complaint: one changed slider is still a grade, and pasting
    /// over it without a word is what has to stop.
    func testAClipWithOneChangedSliderIsAskedAbout() throws {
        let model = try makeModel()
        model.globalSettings.exposure = 0.25

        var copied = GradeSettings()
        copied.contrast = 20
        GradeClipboard.shared.copy(copied)
        XCTAssertTrue(model.pasteWouldOverwriteGrade)

        // A neutral grade on the clipboard is the most destructive paste there
        // is — it resets the clip — so it is asked about too.
        GradeClipboard.shared.copy(GradeSettings())
        XCTAssertTrue(model.pasteWouldOverwriteGrade)
    }

    /// A window on its own changes no pixel. Asking about it would be a
    /// question with nothing behind it.
    func testADrawnWindowAloneIsNotTreatedAsAGrade() throws {
        let model = try makeModel()
        var advanced = AdvancedGrade()
        advanced.mask = GradeMask(isEnabled: true, centerX: 30)
        model.globalSettings.advanced = advanced
        var copied = GradeSettings()
        copied.exposure = 0.5
        GradeClipboard.shared.copy(copied)

        XCTAssertFalse(model.pasteWouldOverwriteGrade)
    }

    func testReplaceLeavesExactlyTheCopiedGrade() throws {
        let model = try makeModel()
        model.globalSettings.exposure = 0.25
        model.globalSettings.saturation = 40
        var copied = GradeSettings()
        copied.contrast = 20
        GradeClipboard.shared.copy(copied)

        model.pasteGrade(.replace)
        XCTAssertEqual(model.globalSettings, copied)
    }

    func testAddOnTopKeepsTheClipsOwnGrade() throws {
        let model = try makeModel()
        model.globalSettings.exposure = 0.25
        model.globalSettings.saturation = 40
        var copied = GradeSettings()
        copied.exposure = 0.25
        copied.contrast = 20
        GradeClipboard.shared.copy(copied)

        model.pasteGrade(.addOnTop)
        XCTAssertEqual(model.globalSettings.exposure, 0.5, accuracy: 1e-5)
        XCTAssertEqual(model.globalSettings.saturation, 40, accuracy: 1e-5)
        XCTAssertEqual(model.globalSettings.contrast, 20, accuracy: 1e-5)
    }

    /// Both answers have to be one undo, not two — the same promise every other
    /// grading action in the app makes.
    func testEitherAnswerIsASingleUndoStep() throws {
        for mode in [GradePasteMode.replace, .addOnTop] {
            let model = try makeModel()
            model.globalSettings.exposure = 0.25
            model.flushGradeHistory()
            let before = model.globalSettings

            var copied = GradeSettings()
            copied.contrast = 20
            GradeClipboard.shared.copy(copied)
            model.pasteGrade(mode)
            XCTAssertNotEqual(model.globalSettings, before, "\(mode)")

            model.undo()
            XCTAssertEqual(model.globalSettings, before, "\(mode) should undo in one step")
        }
    }
}
