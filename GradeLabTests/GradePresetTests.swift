import XCTest
@testable import GradeLab

/// Grade presets: the whole grading state saved under a name.
///
/// The tests are grouped by the promise each one is protecting — that the state
/// survives the round trip exactly, that copies are independent, and that
/// deleting or editing a preset never reaches back into a clip.
final class GradePresetTests: XCTestCase {

    // MARK: - Fixtures

    /// A grade with something set in every part of the model, so a field that
    /// stops being persisted fails a test rather than going quietly missing.
    private func makeRichGrade() -> GradeSettings {
        var settings = GradeSettings.neutral
        settings.exposure = 0.35
        settings.contrast = 14
        settings.highlights = -10
        settings.shadows = 8
        settings.whites = 4
        settings.blacks = -6
        settings.temperature = 6
        settings.tint = -3
        settings.saturation = -7
        settings.vibrance = 12

        var advanced = AdvancedGrade.neutral
        advanced.normalizeCollections()

        var curves = AdvancedCurves.neutral
        // One of each shape: a mapping curve, a channel, a cyclic hue curve and
        // a linear-domain adjustment curve.
        curves[.master] = AdvancedCurve(type: .master, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.18),
            CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1)
        ])
        curves[.red] = AdvancedCurve(type: .red, points: [
            CurvePoint(x: 0, y: 0.02), CurvePoint(x: 1, y: 0.98)
        ])
        curves[.green] = AdvancedCurve(type: .green, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)
        ])
        curves[.blue] = AdvancedCurve(type: .blue, points: [
            CurvePoint(x: 0, y: 0.03), CurvePoint(x: 1, y: 1)
        ])
        curves[.hueVsHue] = AdvancedCurve(type: .hueVsHue, points: [
            CurvePoint(x: 0.1, y: 0), CurvePoint(x: 0.2, y: 0.35), CurvePoint(x: 0.3, y: 0)
        ])
        curves[.hueVsSaturation] = AdvancedCurve(type: .hueVsSaturation, points: [
            CurvePoint(x: 0.5, y: 0), CurvePoint(x: 0.6, y: -0.4), CurvePoint(x: 0.7, y: 0)
        ])
        curves[.hueVsLuma] = AdvancedCurve(type: .hueVsLuma, points: [
            CurvePoint(x: 0.55, y: 0), CurvePoint(x: 0.65, y: 0.25), CurvePoint(x: 0.75, y: 0)
        ])
        curves[.lumaVsSaturation] = AdvancedCurve(type: .lumaVsSaturation, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.3), CurvePoint(x: 1, y: 0)
        ])
        curves[.saturationVsSaturation] = AdvancedCurve(type: .saturationVsSaturation, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.62), CurvePoint(x: 1, y: 1)
        ])
        curves[.saturationVsLuma] = AdvancedCurve(type: .saturationVsLuma, points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.6, y: -0.2), CurvePoint(x: 1, y: 0)
        ])
        advanced.advancedCurves = curves

        for band in advanced.hsl.indices {
            advanced.hsl[band] = HueBand(
                hue: Float(band) - 4,
                saturation: Float(band) * 3,
                luminance: -Float(band) * 2
            )
        }
        advanced.wheels = [
            GradingWheel(hue: 210, strength: 24, brightness: -6),
            GradingWheel(hue: 40, strength: 12, brightness: 3),
            GradingWheel(hue: 30, strength: 30, brightness: 9)
        ]
        advanced.vignette = -12
        advanced.vignetteMidpoint = 44
        advanced.vignetteFeather = 61
        advanced.lut = "Warm_Cinema.cube"
        advanced.lutIntensity = 72
        advanced.effects = FilmEffects(fade: 7, sharpness: 21, bloom: 8, glow: 3, halation: 5, grain: 16)

        settings.advanced = advanced
        return settings
    }

    private func makeStore() -> (GradePresetStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradePresetTests-\(UUID().uuidString)", isDirectory: true)
        return (GradePresetStore(rootURL: root), root)
    }

    // MARK: - Save, reload and exact match

    /// 1-4: a preset saved now is the same preset after a restart, field for
    /// field. The store is read through a second instance, which is what a
    /// relaunch amounts to.
    func testPresetSurvivesSaveAndRestartExactly() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let grade = makeRichGrade()
        let preset = GradePreset(name: "My Night Look", gradeSettings: grade, isFavorite: true)
        try store.save([preset])

        let reloaded = try GradePresetStore(rootURL: root).load()
        XCTAssertEqual(reloaded.count, 1)
        let loaded = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(loaded.id, preset.id)
        XCTAssertEqual(loaded.name, "My Night Look")
        XCTAssertTrue(loaded.isFavorite)
        XCTAssertEqual(loaded.presetVersion, GradePreset.currentVersion)
        XCTAssertEqual(loaded.gradeSettings, grade, "The whole grading state must round-trip exactly")
    }

    /// 5-18: every individual part of the grade, checked by value rather than
    /// only through the struct's own equality, so a field that silently becomes
    /// a default is caught here.
    func testEveryGradingComponentSurvivesTheRoundTrip() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // Built once and kept: `CurvePoint` carries an identity, so comparing
        // against a second freshly built grade would compare different points.
        let grade = makeRichGrade()
        try store.save([GradePreset(name: "Tokyo", gradeSettings: grade)])
        let loaded = try XCTUnwrap(try GradePresetStore(rootURL: root).load().first).gradeSettings
        let advanced = try XCTUnwrap(loaded.advanced)

        // Light and colour.
        XCTAssertEqual(loaded.exposure, 0.35)
        XCTAssertEqual(loaded.contrast, 14)
        XCTAssertEqual(loaded.highlights, -10)
        XCTAssertEqual(loaded.shadows, 8)
        XCTAssertEqual(loaded.whites, 4)
        XCTAssertEqual(loaded.blacks, -6)
        XCTAssertEqual(loaded.temperature, 6)
        XCTAssertEqual(loaded.tint, -3)
        XCTAssertEqual(loaded.saturation, -7)
        XCTAssertEqual(loaded.vibrance, 12)

        // All ten curves, control point for control point — including the point
        // identities, so a curve is not rebuilt into an equivalent-looking one.
        let original = try XCTUnwrap(grade.advanced?.resolvedCurves)
        for type in CurveType.allCases {
            XCTAssertEqual(advanced.resolvedCurves[type].points, original[type].points,
                           "\(type.rawValue) control points must survive exactly")
            XCTAssertEqual(advanced.resolvedCurves[type].interpolation, original[type].interpolation)
        }
        XCTAssertEqual(advanced.curveMask, original.activeMask)

        // HSL: every band's three values.
        XCTAssertEqual(advanced.hsl.count, 8)
        for band in 0..<8 {
            XCTAssertEqual(advanced.hsl[band].hue, Float(band) - 4)
            XCTAssertEqual(advanced.hsl[band].saturation, Float(band) * 3)
            XCTAssertEqual(advanced.hsl[band].luminance, -Float(band) * 2)
        }

        // Wheels.
        XCTAssertEqual(advanced.wheels.count, 3)
        XCTAssertEqual(advanced.wheel(0), GradingWheel(hue: 210, strength: 24, brightness: -6))
        XCTAssertEqual(advanced.wheel(1), GradingWheel(hue: 40, strength: 12, brightness: 3))
        XCTAssertEqual(advanced.wheel(2), GradingWheel(hue: 30, strength: 30, brightness: 9))

        // Vignette.
        XCTAssertEqual(advanced.vignette, -12)
        XCTAssertEqual(advanced.vignetteMidpoint, 44)
        XCTAssertEqual(advanced.vignetteFeather, 61)

        // Look reference and strength.
        XCTAssertEqual(advanced.lut, "Warm_Cinema.cube")
        XCTAssertEqual(advanced.lutIntensity, 72)
        XCTAssertEqual(advanced.lutStrength, 72)

        // Finishing effects, all six.
        let effects = try XCTUnwrap(advanced.effects)
        XCTAssertEqual(effects.fade, 7)
        XCTAssertEqual(effects.sharpness, 21)
        XCTAssertEqual(effects.bloom, 8)
        XCTAssertEqual(effects.glow, 3)
        XCTAssertEqual(effects.halation, 5)
        XCTAssertEqual(effects.grain, 16)
    }

    /// An effect that is off must stay off rather than come back as something.
    func testDisabledEffectsStayDisabled() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var grade = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.effects = FilmEffects(fade: 0, sharpness: 0, bloom: 30, glow: 0, halation: 0, grain: 0)
        grade.advanced = advanced
        try store.save([GradePreset(name: "Bloom only", gradeSettings: grade)])
        let effects = try XCTUnwrap(try GradePresetStore(rootURL: root).load().first?.gradeSettings.advanced?.effects)
        XCTAssertEqual(effects.bloom, 30)
        XCTAssertEqual(effects.fade, 0)
        XCTAssertEqual(effects.glow, 0)
        XCTAssertEqual(effects.grain, 0)
        XCTAssertFalse(effects.isNeutral)
    }

    /// 24: an imported look is referenced by its stored filename, which is what
    /// `LUTStore` names the copy in Application Support — not a document-picker
    /// URL that stops resolving the moment the app restarts.
    func testImportedLookReferenceIsPersistentNotAPickerURL() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = LUTAsset.imported(resourceName: "Night_Market")
        var grade = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.lut = imported.id
        advanced.lutIntensity = 55
        grade.advanced = advanced
        try store.save([GradePreset(name: "Imported", gradeSettings: grade)])

        let loaded = try XCTUnwrap(try GradePresetStore(rootURL: root).load().first)
        XCTAssertEqual(loaded.lutIdentifier, "Night_Market.cube")
        XCTAssertEqual(loaded.gradeSettings.advanced?.lutIntensity, 55)
        // The identifier is a plain filename, resolved against the looks
        // directory rather than against a security-scoped URL.
        XCTAssertFalse(loaded.lutIdentifier?.contains("/") ?? true)
    }

    /// 25: a preset naming a look that is no longer installed still applies
    /// everything else, and substitutes nothing.
    func testMissingLookDropsOnlyTheLook() throws {
        let grade = makeRichGrade()
        let preset = GradePreset(name: "Gone", gradeSettings: grade)
        let installed = LUTAsset.allLooks.map(\.id)
        var missing = grade
        missing.advanced?.lut = "Definitely_Not_Installed_\(UUID().uuidString).cube"
        let missingPreset = GradePreset(name: "Gone", gradeSettings: missing)
        XCTAssertFalse(installed.contains(try XCTUnwrap(missingPreset.lutIdentifier)))

        let applied = missingPreset.withoutLook
        XCTAssertNil(applied.advanced?.lut, "No look must be substituted for the missing one")
        XCTAssertNil(applied.advanced?.lutIntensity)
        XCTAssertEqual(applied.exposure, grade.exposure)
        XCTAssertEqual(applied.advanced?.hsl, grade.advanced?.hsl)
        XCTAssertEqual(applied.advanced?.effects, grade.advanced?.effects)
        XCTAssertEqual(applied.advanced?.resolvedCurves, grade.advanced?.resolvedCurves)
        // The original record is untouched: dropping the look is a decision made
        // at apply time, not an edit to what was saved.
        XCTAssertEqual(preset.gradeSettings, grade)
    }

    // MARK: - Versioning

    /// A preset written before a field existed still loads, and the missing
    /// field takes its neutral default rather than failing the whole file.
    func testOlderPresetsWithoutNewFieldsStillLoad() throws {
        let json = """
        {"presets":[{"id":"\(UUID().uuidString)","name":"Legacy","gradeSettings":{"exposure":0.5,\
        "contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,"temperature":0,"tint":0,\
        "saturation":0,"vibrance":0}}]}
        """
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appendingPathComponent("presets.json"))

        let loaded = try XCTUnwrap(try store.load().first)
        XCTAssertEqual(loaded.name, "Legacy")
        XCTAssertEqual(loaded.gradeSettings.exposure, 0.5)
        XCTAssertNil(loaded.gradeSettings.advanced)
        XCTAssertFalse(loaded.isFavorite)
        XCTAssertEqual(loaded.presetVersion, 1)
    }

    // MARK: - Names

    func testNameValidationAndDefaults() {
        XCTAssertNil(GradePresetName.sanitize("   \n "))
        XCTAssertNil(GradePresetName.sanitize(""))
        XCTAssertEqual(GradePresetName.sanitize("  Tokyo  "), "Tokyo")
        XCTAssertEqual(
            GradePresetName.sanitize(String(repeating: "a", count: 500))?.count,
            GradePresetName.maximumLength
        )
        XCTAssertEqual(GradePresetName.unique(among: []), "My Preset")
        XCTAssertEqual(GradePresetName.unique(among: ["My Preset"]), "My Preset 2")
        XCTAssertEqual(GradePresetName.unique(among: ["My Preset", "My Preset 2"]), "My Preset 3")
        XCTAssertEqual(GradePresetName.copy(of: "Tokyo", among: ["Tokyo"]), "Tokyo Copy")
        XCTAssertEqual(GradePresetName.copy(of: "Tokyo", among: ["Tokyo", "Tokyo Copy"]), "Tokyo Copy 2")
    }

    func testSortingPutsFavouritesFirstThenMostRecentlyUpdated() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 900)
        let presets: [GradePreset] = [
            GradePreset(name: "Plain old", gradeSettings: .neutral, updatedAt: old),
            GradePreset(name: "Plain recent", gradeSettings: .neutral, updatedAt: recent),
            GradePreset(name: "Favourite old", gradeSettings: .neutral, updatedAt: old, isFavorite: true)
        ]
        XCTAssertEqual(presets.sortedForDisplay.map(\.name),
                       ["Favourite old", "Plain recent", "Plain old"])
    }

    // MARK: - Value semantics

    /// 22: editing the clip after applying must not reach back into the preset.
    func testEditingAClipAfterApplyingLeavesThePresetUnchanged() {
        let grade = makeRichGrade()
        let preset = GradePreset(name: "My Night Look", gradeSettings: grade)

        var clip = preset.gradeSettings          // apply
        clip.exposure = 1.0                      // then keep editing
        clip.advanced?.hsl[0].hue = 25
        clip.advanced?.effects?.grain = 90
        clip.advanced?.advancedCurves?[.master] = .neutral(.master)

        XCTAssertEqual(preset.gradeSettings.exposure, 0.35)
        XCTAssertEqual(preset.gradeSettings.advanced?.hsl[0].hue, -4)
        XCTAssertEqual(preset.gradeSettings.advanced?.effects?.grain, 16)
        XCTAssertFalse(preset.gradeSettings.advanced?.resolvedCurves[.master].isNeutral ?? true)
        XCTAssertEqual(preset.gradeSettings, grade)
    }

    /// The reverse direction: changing the preset later must not reach into a
    /// clip it was already applied to.
    func testUpdatingThePresetLeavesAlreadyGradedClipsAlone() {
        var preset = GradePreset(name: "My Night Look", gradeSettings: makeRichGrade())
        let clip = preset.gradeSettings
        preset.gradeSettings.exposure = -2
        preset.gradeSettings.advanced?.lut = nil
        XCTAssertEqual(clip.exposure, 0.35)
        XCTAssertEqual(clip.advanced?.lut, "Warm_Cinema.cube")
    }
}

/// The library: creating, renaming, duplicating, favouriting and deleting.
@MainActor
final class GradePresetLibraryTests: XCTestCase {
    private var root: URL!
    private var library: GradePresetLibrary!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradePresetLibraryTests-\(UUID().uuidString)", isDirectory: true)
        library = GradePresetLibrary(store: GradePresetStore(rootURL: root))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        library = nil
        super.tearDown()
    }

    private func grade(exposure: Float) -> GradeSettings {
        var settings = GradeSettings.neutral
        settings.exposure = exposure
        return settings
    }

    /// 1-2: saved, then present again in a freshly built library — which is
    /// what the next launch reads.
    func testSavingThenReloadingFromDisk() throws {
        XCTAssertTrue(library.isEmpty)
        try library.add(name: "My Night Look", gradeSettings: grade(exposure: 0.2))
        XCTAssertEqual(library.presets.map(\.name), ["My Night Look"])

        let reopened = GradePresetLibrary(store: GradePresetStore(rootURL: root))
        XCTAssertEqual(reopened.presets.map(\.name), ["My Night Look"])
        XCTAssertEqual(reopened.presets.first?.gradeSettings.exposure, 0.2)
    }

    func testEmptyNameIsRefused() {
        XCTAssertThrowsError(try library.add(name: "   ", gradeSettings: .neutral)) { error in
            XCTAssertEqual(error as? GradeLabError, .invalidPresetName)
        }
        XCTAssertTrue(library.isEmpty)
    }

    /// A duplicate name is allowed — identity is the UUID — but it must never
    /// overwrite the preset that already has it.
    func testDuplicateNamesNeverOverwrite() throws {
        let first = try library.add(name: "Tokyo", gradeSettings: grade(exposure: 0.1))
        let second = try library.add(name: "Tokyo", gradeSettings: grade(exposure: 0.9))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(library.presets.count, 2)
        XCTAssertEqual(library.preset(id: first.id)?.gradeSettings.exposure, 0.1)
        XCTAssertEqual(library.preset(id: second.id)?.gradeSettings.exposure, 0.9)
        XCTAssertEqual(library.suggestedName(), "My Preset")
    }

    /// 19: renaming keeps the identity and the grade.
    func testRenameKeepsIdentityAndGrade() throws {
        let preset = try library.add(name: "Old", gradeSettings: grade(exposure: 0.4))
        try library.rename(preset.id, to: "  New  ")
        let renamed = try XCTUnwrap(library.preset(id: preset.id))
        XCTAssertEqual(renamed.id, preset.id)
        XCTAssertEqual(renamed.name, "New")
        XCTAssertEqual(renamed.gradeSettings, preset.gradeSettings)
        XCTAssertThrowsError(try library.rename(preset.id, to: " "))
    }

    /// 20: a duplicate is an independent preset with a new identity.
    func testDuplicateCreatesAnIndependentPreset() throws {
        let original = try library.add(name: "Tokyo", gradeSettings: grade(exposure: 0.5))
        let copy = try XCTUnwrap(try library.duplicate(original.id))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Tokyo Copy")
        XCTAssertEqual(copy.gradeSettings, original.gradeSettings)

        try library.update(copy.id, gradeSettings: grade(exposure: -1))
        XCTAssertEqual(library.preset(id: original.id)?.gradeSettings.exposure, 0.5,
                       "Editing the copy must not touch the original")
    }

    /// 21: deleting removes the record and nothing else. The clip's grade is a
    /// value the timeline holds; the library has no way to reach it, and this
    /// pins that.
    func testDeleteDoesNotAlterAClipTheGradeWasAppliedTo() throws {
        let preset = try library.add(name: "My Night Look", gradeSettings: grade(exposure: 0.35))
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: makeVideoMetadata(durationSeconds: 5))
        let clipID = try XCTUnwrap(project.timeline.firstVideoClip?.id)
        XCTAssertTrue(project.timeline.setGrade(preset.gradeSettings, for: clipID))

        library.delete(preset.id)
        XCTAssertTrue(library.isEmpty)
        XCTAssertEqual(GradePresetLibrary(store: GradePresetStore(rootURL: root)).presets.count, 0)
        XCTAssertEqual(project.timeline.videoClip(id: clipID)?.gradeSettings.exposure, 0.35)
    }

    func testFavouritesSortFirst() throws {
        try library.add(name: "A", gradeSettings: .neutral)
        let b = try library.add(name: "B", gradeSettings: .neutral)
        library.toggleFavorite(b.id)
        XCTAssertEqual(library.presets.first?.id, b.id)
        library.toggleFavorite(b.id)
        XCTAssertFalse(try XCTUnwrap(library.preset(id: b.id)).isFavorite)
    }
}

/// 23: applying a preset is an ordinary grade write, so it takes the same undo
/// path every slider does. This exercises that path — record, undo, redo —
/// without a Metal device.
final class GradePresetUndoTests: XCTestCase {
    func testApplyingAPresetUndoesAndRedoesAsOneAction() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: makeVideoMetadata(durationSeconds: 5))
        let clipID = try XCTUnwrap(project.timeline.firstVideoClip?.id)

        // Grade A: what the clip looked like before.
        var gradeA = GradeSettings.neutral
        gradeA.exposure = 1.2
        gradeA.contrast = -30
        XCTAssertTrue(project.timeline.setGrade(gradeA, for: clipID))

        var preset = GradeSettings.neutral
        preset.exposure = 0.2
        preset.contrast = 14
        var advanced = AdvancedGrade.neutral
        advanced.lut = "Warm_Cinema.cube"
        advanced.lutIntensity = 72
        preset.advanced = advanced

        var history = TimelineHistory()
        let before = project
        var after = project
        XCTAssertTrue(after.timeline.setGrade(preset, for: clipID))
        history.record("Apply Preset", before: before, after: after)
        project = after
        XCTAssertEqual(project.timeline.videoClip(id: clipID)?.gradeSettings, preset)

        project = try XCTUnwrap(history.undo())
        XCTAssertEqual(project.timeline.videoClip(id: clipID)?.gradeSettings, gradeA,
                       "Undo must return exactly to the grade that was there before")

        project = try XCTUnwrap(history.redo())
        XCTAssertEqual(project.timeline.videoClip(id: clipID)?.gradeSettings, preset)
        XCTAssertEqual(project.timeline.videoClip(id: clipID)?.gradeSettings.advanced?.lutIntensity, 72)
    }

    /// Applying replaces the grade rather than merging into it: what was there
    /// before must not survive in any part of the result.
    func testApplyingReplacesTheWholeGradingState() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: makeVideoMetadata(durationSeconds: 5))
        let clipID = try XCTUnwrap(project.timeline.firstVideoClip?.id)

        var busy = GradeSettings.neutral
        busy.exposure = 1.2
        var busyAdvanced = AdvancedGrade.neutral
        busyAdvanced.normalizeCollections()
        busyAdvanced.hsl[3].saturation = 60
        busyAdvanced.lut = "Teal_Orange.cube"
        busyAdvanced.effects = FilmEffects(fade: 0, sharpness: 0, bloom: 0, glow: 0, halation: 0, grain: 80)
        busy.advanced = busyAdvanced
        XCTAssertTrue(project.timeline.setGrade(busy, for: clipID))

        var preset = GradeSettings.neutral
        preset.exposure = 0.2
        XCTAssertTrue(project.timeline.setGrade(preset, for: clipID))

        let result = try XCTUnwrap(project.timeline.videoClip(id: clipID)?.gradeSettings)
        XCTAssertEqual(result, preset)
        XCTAssertNil(result.advanced, "Nothing from the previous grade may survive")
    }
}
