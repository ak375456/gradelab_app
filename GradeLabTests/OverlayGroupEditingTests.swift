import XCTest
@testable import GradeLab

/// Editing several drawn layers at once.
///
/// Selecting four titles used to leave the canvas empty and collapse all four
/// onto one spot the moment Position Y moved, because every selected clip was
/// handed the same absolute value. Position is now applied as an OFFSET, and
/// the canvas draws the whole selection.
@MainActor
final class OverlayGroupEditingTests: XCTestCase {

    private func makeModel() throws -> EditorViewModel {
        let project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/group-editing.mov"),
                                   displayName: "Group", metadata: makeVideoMetadata(durationSeconds: 30))
        let model = try EditorViewModel(project: project)
        // A fresh model is preparing its sequence, and `canEditSelection` is
        // false until that finishes. This is the same door the export path uses
        // to stand the preview down, and it leaves the project editable.
        model.suspendPreviewForExport()
        return model
    }

    /// One title, placed at a known height, with real glyphs so it has bounds.
    @discardableResult
    private func addTitle(_ model: EditorViewModel, text: String, y: Double) throws -> UUID {
        model.addText()
        let id = try XCTUnwrap(model.selectedClipID)
        model.editText { $0.text = text }
        model.setAnimatableValue(.positionY, .number(y), immediate: true)
        XCTAssertEqual(try positionY(model, id), y, accuracy: 0.0001)
        return id
    }

    private func positionY(_ model: EditorViewModel, _ id: UUID) throws -> Double {
        guard case .text(let clip) = try XCTUnwrap(model.project.timeline.item(id: id)) else {
            throw XCTSkip("not a title")
        }
        return clip.transform.positionY
    }

    private func positionX(_ model: EditorViewModel, _ id: UUID) throws -> Double {
        guard case .text(let clip) = try XCTUnwrap(model.project.timeline.item(id: id)) else {
            throw XCTSkip("not a title")
        }
        return clip.transform.positionX
    }

    // MARK: - Position moves the group, it does not flatten it

    /// The reported bug: four stacked lines became one line.
    func testMovingSeveralTitlesKeepsTheSpaceBetweenThem() throws {
        let model = try makeModel()
        let top = try addTitle(model, text: "The", y: 0.2)
        let bottom = try addTitle(model, text: "Beauty", y: 0.6)

        model.selectClips([top, bottom])
        let before = try positionY(model, model.selectedClipID!)
        model.setAnimatableValue(.positionY, .number(before + 0.1), immediate: true)

        XCTAssertEqual(try positionY(model, top), 0.3, accuracy: 0.0001)
        XCTAssertEqual(try positionY(model, bottom), 0.7, accuracy: 0.0001)
        XCTAssertEqual(try positionY(model, bottom) - positionY(model, top), 0.4, accuracy: 0.0001,
                       "the gap between the lines has to survive the move")
    }

    /// A lone selection still writes the value it was given, absolutely.
    func testOneTitleStillTakesTheValueItIsGiven() throws {
        let model = try makeModel()
        let only = try addTitle(model, text: "The", y: 0.2)
        model.setAnimatableValue(.positionY, .number(0.83), immediate: true)
        XCTAssertEqual(try positionY(model, only), 0.83, accuracy: 0.0001)
    }

    /// Only position is spatial. "Make these all this size" still means one size.
    func testSizeIsStillWrittenToEveryTitle() throws {
        let model = try makeModel()
        let top = try addTitle(model, text: "The", y: 0.2)
        let bottom = try addTitle(model, text: "Beauty", y: 0.6)
        model.setAnimatableValue(.scale, .number(1.5), immediate: true)
        model.selectClips([top, bottom])
        model.setAnimatableValue(.scale, .number(2), immediate: true)

        for id in [top, bottom] {
            guard case .text(let clip) = try XCTUnwrap(model.project.timeline.item(id: id)) else { return }
            XCTAssertEqual(clip.transform.scale, 2, accuracy: 0.0001)
        }
    }

    // MARK: - Alignment

    private func unionBounds(_ model: EditorViewModel) throws -> CGRect {
        let canvas = model.previewCanvasSize
        let overlays = model.selectedOverlays(canvas: canvas)
        XCTAssertFalse(overlays.isEmpty, "the selection has to produce canvas geometry")
        return overlays.dropFirst().reduce(overlays[0].screenBounds(canvas: canvas)) {
            $0.union($1.screenBounds(canvas: canvas))
        }
    }

    func testCentringOneTitleLandsItOnTheMiddleOfTheCanvas() throws {
        let model = try makeModel()
        try addTitle(model, text: "Colour grading", y: 0.2)
        model.editText(immediate: true) { $0.transform.positionX = 0.2 }

        model.alignSelection(.centerVertically)
        model.alignSelection(.centerHorizontally)

        let canvas = model.previewCanvasSize
        let bounds = try unionBounds(model)
        XCTAssertEqual(bounds.midX, canvas.width/2, accuracy: 0.5)
        XCTAssertEqual(bounds.midY, canvas.height/2, accuracy: 0.5)
    }

    /// Centring FOUR lines centres the block, it does not stack them — which is
    /// exactly what centring each of them on its own would do.
    func testCentringSeveralTitlesCentresTheBlockAndKeepsItStacked() throws {
        let model = try makeModel()
        let ids = try [("The", 0.15), ("Beauty", 0.3), ("Of", 0.45), ("Colour grading", 0.6)]
            .map { try addTitle(model, text: $0.0, y: $0.1) }
        model.selectClips(Set(ids))

        model.alignSelection(.centerVertically)

        let canvas = model.previewCanvasSize
        XCTAssertEqual(try unionBounds(model).midY, canvas.height/2, accuracy: 0.5)
        let spacing = try zip(ids, ids.dropFirst()).map { try positionY(model, $1) - positionY(model, $0) }
        for gap in spacing {
            XCTAssertEqual(gap, 0.15, accuracy: 0.0001, "the lines must stay a block")
        }
    }

    /// Rotation and an off-centre anchor move the ink away from `positionX`, so
    /// alignment solves against the drawn bounds rather than the stored number.
    func testAlignmentMeasuresTheInk_NotTheStoredPosition() throws {
        let model = try makeModel()
        try addTitle(model, text: "Colour grading", y: 0.5)
        model.editText(immediate: true) {
            $0.transform.rotationDegrees = 30
            $0.transform.anchorX = 0.1
            $0.transform.anchorY = 0.9
        }

        model.alignSelection(.right)
        model.alignSelection(.bottom)

        let canvas = model.previewCanvasSize
        let bounds = try unionBounds(model)
        XCTAssertEqual(bounds.maxX, canvas.width, accuracy: 0.5)
        XCTAssertEqual(bounds.maxY, canvas.height, accuracy: 0.5)
    }

    func testAligningLeftAndTopPutsTheBlockInTheCorner() throws {
        let model = try makeModel()
        let ids = try [("The", 0.4), ("Beauty", 0.7)].map { try addTitle(model, text: $0.0, y: $0.1) }
        model.selectClips(Set(ids))

        model.alignSelection(.left)
        model.alignSelection(.top)

        let bounds = try unionBounds(model)
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.5)
    }

    // MARK: - Undo

    /// Undoing a group edit used to leave one layer selected, so the next edit
    /// silently applied to that one alone.
    func testUndoKeepsTheWholeSelection() throws {
        let model = try makeModel()
        let top = try addTitle(model, text: "The", y: 0.2)
        let bottom = try addTitle(model, text: "Beauty", y: 0.6)
        model.selectClips([top, bottom])

        model.editText(immediate: true) { $0.style.fontSize = 90 }
        XCTAssertEqual(model.selectedClipIDs, [top, bottom])

        model.undo()
        XCTAssertEqual(model.selectedClipIDs, [top, bottom],
                       "undo must not quietly drop the rest of the selection")
        XCTAssertEqual(model.selectedTextCount, 2)

        model.redo()
        XCTAssertEqual(model.selectedClipIDs, [top, bottom])
    }

    /// A clip the snapshot no longer holds is dropped, and the selection never
    /// ends up empty.
    func testUndoDropsOnlyWhatTheSnapshotLost() throws {
        let model = try makeModel()
        let keep = try addTitle(model, text: "The", y: 0.2)
        // Added bare, so a single undo is enough to take it back out again.
        model.addText()
        let added = try XCTUnwrap(model.selectedClipID)
        model.selectClips([keep, added])

        model.undo()
        XCTAssertFalse(model.selectedClipIDs.contains(added))
        XCTAssertFalse(model.selectedClipIDs.isEmpty, "something has to stay selected")
        XCTAssertEqual(model.project.timeline.item(id: added), nil)
    }

    // MARK: - Group drag geometry

    /// A mixed selection has no shared edit path, so the canvas shows it without
    /// offering a drag rather than swallowing one.
    func testATitleAndAShapeAreShownButNotDraggedTogether() throws {
        let model = try makeModel()
        let title = try addTitle(model, text: "The", y: 0.2)
        model.addShape()
        let shape = try XCTUnwrap(model.selectedClipID)

        model.selectClips([title, shape])
        XCTAssertFalse(model.selectionMovesAsAGroup)
        XCTAssertEqual(model.selectedOverlays(canvas: model.previewCanvasSize).count, 2)

        model.selectClips([title])
        XCTAssertFalse(model.selectionMovesAsAGroup, "one layer is not a group")
        XCTAssertTrue(model.canAlignSelection, "but one layer still aligns")
    }

    /// Alignment measures everything selected, so it refuses a selection it
    /// could only half move rather than shifting the primary layer alone.
    func testAlignmentIsRefusedOnASelectionItCouldOnlyHalfMove() throws {
        let model = try makeModel()
        let title = try addTitle(model, text: "The", y: 0.2)
        model.addShape()
        let shape = try XCTUnwrap(model.selectedClipID)
        model.selectClips([title, shape])
        XCTAssertFalse(model.canAlignSelection)

        let before = model.project.timeline
        model.alignSelection(.centerVertically)
        XCTAssertEqual(model.project.timeline, before, "nothing moves rather than one layer moving")
    }
}
