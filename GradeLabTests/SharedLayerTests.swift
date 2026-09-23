import XCTest
@testable import GradeLab

/// A row is a *sequence*, not a slot for one clip.
///
/// Two sounds, or two titles, belong on one row whenever they do not play at
/// the same time — which is how every other editor behaves and what the second
/// row was never needed for. These cover the move that puts them there, and the
/// rule that keeps them from landing on top of each other once they share it.
final class SharedLayerTests: XCTestCase {
    fileprivate func project(duration: Double = 10) -> VideoProject {
        .init(sourceURL: URL(fileURLWithPath: "/tmp/shared-layer.mov"),
              displayName: "Layers", metadata: makeVideoMetadata(durationSeconds: duration))
    }

    /// Two audio clips, each alone on its own row, as the app produces them.
    fileprivate func twoSounds() throws -> (VideoProject, first: UUID, second: UUID) {
        var p = project()
        let first = try AudioEditing.separate(p.timeline.firstVideoClip!.id, in: &p)
        // Trim the original to four seconds so there is room beside it.
        try AudioEditing.edit(first, operation: .trimEnd, to: .seconds(4), clamping: true, in: &p)
        let second = try AudioEditing.paste(p.timeline.audioClip(id: first)!, at: .zero,
                                            trackID: p.timeline.audioClip(id: first)!.placement.trackID, in: &p)
        XCTAssertNotEqual(p.timeline.audioClip(id: second)!.placement.trackID,
                          p.timeline.audioClip(id: first)!.placement.trackID)
        return (p, first, second)
    }

    func testSecondSoundJoinsAnOccupiedRowWhenItDoesNotOverlap() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        let rowsBefore = p.timeline.tracks.count

        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(6), in: &p)

        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.trackID, row)
        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.timelineStart, try .seconds(6))
        XCTAssertEqual(p.timeline.audioClip(id: first)?.placement.timelineStart, .zero)
        // The row it left behind was emptied, so it is gone.
        XCTAssertEqual(p.timeline.tracks.count, rowsBefore - 1)
        XCTAssertEqual(p.timeline.tracks.first { $0.id == row }?.items.count, 2)
        _ = try TimelineEditing.clips(in: p)
    }

    /// Butting one clip exactly against the end of another is the common case —
    /// the magnet snaps to that edge — and touching is not overlapping.
    func testSoundsMayTouchExactlyOnOneRow() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        let edge = try p.timeline.audioClip(id: first)!.placement.range.end

        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: edge, in: &p)

        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.trackID, row)
        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.timelineStart, edge)
        _ = try TimelineEditing.clips(in: p)
    }

    /// A busy row gets the clip a row of its own rather than an error: the drag
    /// preview and this frame-snapped result can disagree by less than a frame.
    func testBusyRowGivesTheClipItsOwnRowInstead() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        let rowsBefore = p.timeline.tracks.count

        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(2), in: &p)

        XCTAssertNotEqual(p.timeline.audioClip(id: second)?.placement.trackID, row)
        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.timelineStart, try .seconds(2))
        XCTAssertEqual(p.timeline.tracks.count, rowsBefore)
        _ = try TimelineEditing.clips(in: p)
    }

    /// Sound belongs under the picture, drawn layers over it — wherever the
    /// drop landed.
    func testNewRowsLandOnTheCorrectSideOfThePicture() throws {
        var (p, _, second) = try twoSounds()
        try TimelineEditing.moveToLayer(second, destinationTrackID: nil, newTrackIndex: 0, at: .seconds(6), in: &p)
        let audioRow = p.timeline.audioClip(id: second)!.placement.trackID
        let main = p.timeline.tracks.firstIndex { $0.kind == .mainVideo }!
        XCTAssertGreaterThan(p.timeline.tracks.firstIndex { $0.id == audioRow }!, main)
        _ = try TimelineEditing.clips(in: p)
    }

    func testTitlesShareARowThenSlideAgainstEachOther() throws {
        var p = project()
        let rowA = UUID(), rowB = UUID()
        let left = TextClip(placement: .init(id: UUID(), trackID: rowA, timelineStart: .zero, duration: try .seconds(3)), text: "A")
        let right = TextClip(placement: .init(id: UUID(), trackID: rowB, timelineStart: try .seconds(5), duration: try .seconds(3)), text: "B")
        p.timeline.tracks.insert(.init(id: rowA, name: "Text", kind: .text, items: [.text(left)]), at: 0)
        p.timeline.tracks.insert(.init(id: rowB, name: "Text", kind: .text, items: [.text(right)]), at: 0)

        try TimelineEditing.moveToLayer(right.id, destinationTrackID: rowA, at: .seconds(5), in: &p)
        XCTAssertEqual(p.timeline.item(id: right.id)?.placement.trackID, rowA)
        XCTAssertNil(p.timeline.tracks.first { $0.id == rowB })

        // Dragged left onto its neighbour it stops at the edge rather than
        // covering it.
        try OverlayEditing.edit(right.id, operation: .move, to: .seconds(1), in: &p)
        XCTAssertEqual(p.timeline.item(id: right.id)?.placement.timelineStart, try .seconds(3))
        XCTAssertFalse(TimelineEditing.overlaps(p.timeline.item(id: right.id)!,
                                                in: p.timeline.tracks.first { $0.id == rowA }!))
    }

    func testSoundDraggedAlongASharedRowStopsAtItsNeighbour() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(6), in: &p)

        // Far left, straight through the clip already there.
        try AudioEditing.edit(second, operation: .move, to: .zero, clamping: true, in: &p)
        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.timelineStart, try .seconds(4))
        _ = try TimelineEditing.clips(in: p)
    }

    /// The whole edit is assembled on a copy, so a refusal leaves the source row
    /// exactly as it was rather than half-emptied.
    func testALockedSourceRowRefusesTheMoveAtomically() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        let sourceRow = p.timeline.audioClip(id: second)!.placement.trackID
        p.timeline.tracks[p.timeline.tracks.firstIndex { $0.id == sourceRow }!].isLocked = true
        let before = p
        XCTAssertThrowsError(try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(6), in: &p))
        XCTAssertEqual(p, before)
    }

    /// A locked destination is declined the way a busy one is: the clip gets a
    /// row of its own instead of overwriting somebody's locked work.
    func testALockedDestinationGivesTheClipItsOwnRow() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        p.timeline.tracks[p.timeline.tracks.firstIndex { $0.id == row }!].isLocked = true

        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(6), in: &p)
        XCTAssertNotEqual(p.timeline.audioClip(id: second)?.placement.trackID, row)
        XCTAssertEqual(p.timeline.tracks.first { $0.id == row }?.items.count, 1)
        _ = try TimelineEditing.clips(in: p)
    }

    /// Kinds never mix: a sound dropped on a title row gets its own.
    func testASoundWillNotLandOnATitleRow() throws {
        var (p, _, second) = try twoSounds()
        let textRow = UUID()
        let title = TextClip(placement: .init(id: UUID(), trackID: textRow, timelineStart: .zero, duration: try .seconds(2)), text: "A")
        p.timeline.tracks.insert(.init(id: textRow, name: "Text", kind: .text, items: [.text(title)]), at: 0)

        try TimelineEditing.moveToLayer(second, destinationTrackID: textRow, at: .seconds(6), in: &p)
        XCTAssertNotEqual(p.timeline.audioClip(id: second)?.placement.trackID, textRow)
        XCTAssertEqual(p.timeline.tracks.first { $0.id == textRow }?.items.count, 1)
        _ = try TimelineEditing.clips(in: p)
    }

    /// The document survives a shared row, which is the part that would bite
    /// later: two clips on one track have to encode and decode as two.
    func testASharedRowRoundTrips() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(6), in: &p)
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(p)), p)
    }
}

/// Dropping a clip back where it came from.
///
/// The row is keyed by identity: its name, height, waveform size, lock and
/// enabled flag all hang off that id. A move that rebuilt the row would quietly
/// reset every one of them, and a vertical drag that ends where it started is
/// the easiest gesture in the timeline to perform by accident.
extension SharedLayerTests {
    func testDroppingAClipBackOnItsOwnRowKeepsTheRow() throws {
        var p = project()
        let id = try AudioEditing.separate(p.timeline.firstVideoClip!.id, in: &p)
        let row = p.timeline.audioClip(id: id)!.placement.trackID
        let index = p.timeline.tracks.firstIndex { $0.id == row }!
        p.timeline.tracks[index].name = "Score"
        p.timeline.tracks[index].isEnabled = false
        let rowsBefore = p.timeline.tracks.count

        try TimelineEditing.moveToLayer(id, destinationTrackID: row, at: .seconds(2), in: &p)

        XCTAssertEqual(p.timeline.audioClip(id: id)?.placement.trackID, row)
        XCTAssertEqual(p.timeline.audioClip(id: id)?.placement.timelineStart, try .seconds(2))
        XCTAssertEqual(p.timeline.tracks.count, rowsBefore)
        let after = p.timeline.tracks.first { $0.id == row }
        XCTAssertEqual(after?.name, "Score")
        XCTAssertEqual(after?.isEnabled, false)
    }

    /// The same drop, on a row that has a neighbour: it stops against it rather
    /// than landing on top of it.
    func testDroppingBackOnASharedRowStillRespectsTheNeighbour() throws {
        var (p, first, second) = try twoSounds()
        let row = p.timeline.audioClip(id: first)!.placement.trackID
        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(6), in: &p)

        try TimelineEditing.moveToLayer(second, destinationTrackID: row, at: .seconds(1), in: &p)
        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.trackID, row)
        XCTAssertEqual(p.timeline.audioClip(id: second)?.placement.timelineStart, try .seconds(4))
        _ = try TimelineEditing.clips(in: p)
    }
}

/// The rule the timeline applies while a clip is in the air, separated from the
/// geometry that decides which row a finger is over. This is the half that says
/// whether a row will take the clip at all — the half the old code never asked
/// for sound or titles, because it refused them a vertical drag outright.
final class LayerDropPolicyTests: XCTestCase {
    private func audioClip(start: Double, duration: Double, track: UUID) throws -> AudioClip {
        AudioClip(placement: .init(id: UUID(), trackID: track, timelineStart: try .seconds(start),
                                   duration: try .seconds(duration)),
                  assetID: UUID(), sourceRange: .init(start: .zero, duration: try .seconds(duration)))
    }

    private func row(_ items: [TimelineItem], kind: TimelineTrack.Kind = .audio,
                     id: UUID = UUID(), locked: Bool = false) -> TimelineTrack {
        .init(id: id, name: "Row", kind: kind, isLocked: locked, items: items)
    }

    func testARowTakesASecondClipBesideTheFirstButNotOverIt() throws {
        let id = UUID()
        let sitting = try audioClip(start: 0, duration: 4, track: id)
        let track = row([.audio(sitting)], id: id)
        let moving = try XCTUnwrap(TimelineDisplayClip(.audio(audioClip(start: 0, duration: 3, track: UUID()))))

        XCTAssertTrue(TimelineCanvas.canDrop(moving, kind: .audio, on: track, startingAt: 4))
        XCTAssertTrue(TimelineCanvas.canDrop(moving, kind: .audio, on: track, startingAt: 9))
        XCTAssertFalse(TimelineCanvas.canDrop(moving, kind: .audio, on: track, startingAt: 2))
        XCTAssertFalse(TimelineCanvas.canDrop(moving, kind: .audio, on: track, startingAt: 3.9))
        // Ending exactly where the sitting clip begins is touching, not overlapping.
        let later = row([.audio(try audioClip(start: 3, duration: 4, track: id))], id: id)
        XCTAssertTrue(TimelineCanvas.canDrop(moving, kind: .audio, on: later, startingAt: 0))
    }

    func testARowRefusesAnotherKindAndALockedRow() throws {
        let id = UUID()
        let moving = try XCTUnwrap(TimelineDisplayClip(.audio(audioClip(start: 0, duration: 3, track: UUID()))))
        XCTAssertFalse(TimelineCanvas.canDrop(moving, kind: .audio, on: row([], kind: .text, id: id), startingAt: 0))
        XCTAssertFalse(TimelineCanvas.canDrop(moving, kind: .audio, on: row([], id: id, locked: true), startingAt: 0))
        XCTAssertTrue(TimelineCanvas.canDrop(moving, kind: .audio, on: row([], id: id), startingAt: 0))
    }

    /// The main row packs from zero, so a clip dropped on it is inserted
    /// between its neighbours — nothing there is ever "busy".
    func testTheMainRowIsAlwaysOpenToAVideoClip() throws {
        let id = UUID()
        let sitting = VideoClip(placement: .init(id: UUID(), trackID: id, timelineStart: .zero, duration: try .seconds(8)),
                                assetID: UUID(), sourceRange: .init(start: .zero, duration: try .seconds(8)))
        let main = row([.video(sitting)], kind: .mainVideo, id: id)
        let moving = try XCTUnwrap(TimelineDisplayClip(.video(sitting)))
        XCTAssertTrue(TimelineCanvas.canDrop(moving, kind: .videoOverlay, on: main, startingAt: 2))
    }

    func testNewRowsAreKeptOnTheCorrectSideOfThePicture() {
        let tracks: [TimelineTrack] = [
            .init(id: UUID(), name: "Text", kind: .text),
            .init(id: UUID(), name: "Main Video", kind: .mainVideo),
            .init(id: UUID(), name: "Audio", kind: .audio),
        ]
        // Sound dropped at the very top still lands under the picture.
        XCTAssertEqual(TimelineCanvas.clampedInsertion(0, kind: .audio, in: tracks), 2)
        // A title dropped at the very bottom still lands over it.
        XCTAssertEqual(TimelineCanvas.clampedInsertion(3, kind: .text, in: tracks), 1)
        XCTAssertEqual(TimelineCanvas.clampedInsertion(0, kind: .videoOverlay, in: tracks), 0)
        XCTAssertEqual(TimelineCanvas.clampedInsertion(1, kind: .audio, in: tracks), 2)
    }

    func testEveryClipKindKnowsItsRow() throws {
        let track = UUID()
        let audio = try XCTUnwrap(TimelineDisplayClip(.audio(audioClip(start: 0, duration: 1, track: track))))
        let text = try XCTUnwrap(TimelineDisplayClip(.text(TextClip(placement: .init(
            id: UUID(), trackID: track, timelineStart: .zero, duration: try .seconds(1))))))
        XCTAssertEqual(TimelineCanvas.movingTrackKind(audio), .audio)
        XCTAssertEqual(TimelineCanvas.movingTrackKind(text), .text)
    }
}
