import CoreText
import XCTest
@testable import GradeLab

/// `offsetValue` — the relative write a group move is made of.
///
/// It carries a COMPOSITION time rather than a clip-local one. The clips in a
/// multiple selection start at different points on the timeline, so one shared
/// local time would address the wrong frame of every clip but the first.
final class AnimatedOffsetTests: XCTestCase {

    private func seconds(_ value: Double) throws -> TimelineTime { try .seconds(value) }

    private func title(start: Double, duration: Double = 4) throws -> TextClip {
        TextClip(placement: .init(id: UUID(), trackID: UUID(),
                                  timelineStart: try seconds(start), duration: try seconds(duration)),
                 text: "Title")
    }

    func testAnUnanimatedLayerShiftsItsBaseValueAndGainsNoAnimation() throws {
        var clip = try title(start: 2)
        clip.transform.positionY = 0.25

        clip.offsetValue(.positionY, by: 0.3, atComposition: try seconds(3))

        XCTAssertEqual(clip.transform.positionY, 0.55, accuracy: 0.0001)
        XCTAssertNil(clip.animation, "a move must not start animating the layer")
    }

    /// The base value shifts wherever the playhead is, because there is no frame
    /// to be inside of.
    func testAnUnanimatedLayerMovesEvenWithThePlayheadElsewhere() throws {
        var clip = try title(start: 2)
        clip.offsetValue(.positionY, by: -0.1, atComposition: try seconds(20))
        XCTAssertEqual(clip.transform.positionY, 0.4, accuracy: 0.0001)
    }

    func testAnAnimatedLayerWritesAKeyframeAtItsOwnLocalTime() throws {
        var clip = try title(start: 2, duration: 4)
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .positionY, keyframes: [
                Keyframe(time: try seconds(0), value: .number(0.2), interpolation: .linear),
                Keyframe(time: try seconds(4), value: .number(0.6), interpolation: .linear)
            ])
        ])

        // Composition 4s on a clip starting at 2s is local 2s: half way, 0.4.
        clip.offsetValue(.positionY, by: 0.1, atComposition: try seconds(4))

        let track = try XCTUnwrap(clip.animation?.track(.positionY))
        let written = try XCTUnwrap(track.keyframe(at: try seconds(2)))
        XCTAssertEqual(written.value.number ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(track.keyframes.count, 3, "a keyframe is inserted, the ends are left alone")
        XCTAssertEqual(clip.transform.positionY, 0.5, accuracy: 0.0001,
                       "the base value is untouched while the property animates")
    }

    /// Two layers starting at different points, moved by one composition time,
    /// each land on the frame that is actually on screen. This is the case a
    /// shared clip-local time would get wrong.
    func testTwoLayersStartingApartEachResolveTheirOwnFrame() throws {
        func ramp() throws -> ClipAnimation {
            ClipAnimation(tracks: [AnimationTrack(property: .positionY, keyframes: [
                Keyframe(time: try seconds(0), value: .number(0), interpolation: .linear),
                Keyframe(time: try seconds(4), value: .number(1), interpolation: .linear)
            ])])
        }
        var early = try title(start: 0, duration: 4); early.animation = try ramp()
        var late = try title(start: 2, duration: 4); late.animation = try ramp()

        let now = try seconds(3)
        early.offsetValue(.positionY, by: 0.1, atComposition: now)
        late.offsetValue(.positionY, by: 0.1, atComposition: now)

        // Early is 3s in: 0.75 -> 0.85. Late is 1s in: 0.25 -> 0.35.
        XCTAssertEqual(try XCTUnwrap(early.animation?.track(.positionY)?.keyframe(at: try seconds(3))).value.number ?? 0,
                       0.85, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(late.animation?.track(.positionY)?.keyframe(at: try seconds(1))).value.number ?? 0,
                       0.35, accuracy: 0.0001)
        XCTAssertNil(late.animation?.track(.positionY)?.keyframe(at: try seconds(3)),
                     "the late layer must not be written at the early one's local time")
    }

    /// An animated property on a clip the playhead has left has no frame to
    /// write to, so it is left exactly as it was.
    func testAnAnimatedLayerOutsideThePlayheadIsLeftAlone() throws {
        var clip = try title(start: 2, duration: 4)
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .positionY, keyframes: [
                Keyframe(time: try seconds(0), value: .number(0.2), interpolation: .linear)
            ])
        ])
        let before = clip

        clip.offsetValue(.positionY, by: 0.3, atComposition: try seconds(20))

        XCTAssertEqual(clip, before)
    }

    /// The invariant alignment solves against: position is the last translation
    /// in the placement matrix, so the drawn bounds follow it one for one
    /// whatever the anchor, scale and rotation are.
    func testScreenBoundsFollowPositionOneForOne() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        var clip = try title(start: 0)
        clip.style.fontSize = 140
        clip.transform.rotationDegrees = 22
        clip.transform.anchorX = 0.15
        clip.transform.anchorY = 0.8
        clip.transform.scale = 1.4

        let before = CanvasOverlay(clip, canvas: canvas).screenBounds(canvas: canvas)
        clip.transform.positionX += 0.25
        clip.transform.positionY -= 0.1
        let after = CanvasOverlay(clip, canvas: canvas).screenBounds(canvas: canvas)

        XCTAssertEqual(after.minX - before.minX, 0.25*canvas.width, accuracy: 0.01)
        XCTAssertEqual(after.minY - before.minY, -0.1*canvas.height, accuracy: 0.01)
        XCTAssertEqual(after.width, before.width, accuracy: 0.01)
        XCTAssertEqual(after.height, before.height, accuracy: 0.01)
    }
}

/// The font list the Font panel builds.
final class FontRegistryListTests: XCTestCase {

    /// Each family appears exactly once — one basic face, not a row per weight.
    func testEveryFamilyIsListedOnce() {
        let entries = FontRegistry.shared.entries()
        XCTAssertFalse(entries.isEmpty)
        let families = entries.map(\.family)
        XCTAssertEqual(Set(families).count, families.count)
        XCTAssertFalse(entries.contains { $0.id.hasPrefix(".") }, "private faces stay out of the list")
    }

    /// The rank now comes from the DESCRIPTOR's traits rather than from
    /// instantiating every face. A silent failure to read that dictionary would
    /// rank everything zero and pick alphabetically - which means the bold or
    /// oblique cut, since those sort first inside a family.
    func testEachFamilyIsRepresentedByItsPlainestFace() throws {
        let entries = FontRegistry.shared.entries()
        let helvetica = try XCTUnwrap(entries.first { $0.family == "Helvetica" },
                                      "Helvetica is always installed")
        XCTAssertEqual(helvetica.id, "Helvetica")

        for entry in entries {
            let traits = CTFontGetSymbolicTraits(CTFontCreateWithName(entry.id as CFString, 32, nil))
            guard traits.contains(.boldTrait) || traits.contains(.italicTrait) else { continue }
            // A bold or italic face is only acceptable when the family has no
            // plainer one — some display families ship a single slanted cut.
            let plain = FontRegistry.shared.variant(entry.id, bold: false, italic: false)
            XCTAssertNil(plain, "\(entry.family) is listed as \(entry.id) although a plain cut exists")
        }
    }

    /// Sorted for display, and the same every time it is asked for — the list is
    /// cached now, and a cache that returned a different order per keystroke
    /// would make the search results jump around.
    func testTheListIsStableAndSorted() {
        let first = FontRegistry.shared.entries()
        let second = FontRegistry.shared.entries()
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.name),
                       first.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// The whole point of the cache: the second build costs nothing, so typing
    /// in the search field cannot stall.
    func testTheSecondBuildIsServedFromTheCache() {
        _ = FontRegistry.shared.entries()
        let start = Date()
        for _ in 0..<200 { _ = FontRegistry.shared.entries() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5,
                          "200 reads of a cached list must be effectively free")
    }
}
