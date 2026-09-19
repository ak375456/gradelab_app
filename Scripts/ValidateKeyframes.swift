import Foundation
import CoreMedia

/// Host-runnable mirror of the core assertions in GradeLabTests/KeyframeTests.swift.
/// The XCTest suite is the canonical one, but running it needs a simulator; this runs on
/// the Mac so the evaluator, lifecycle rules and persistence can be verified on every change.
@main struct ValidateKeyframes {
    static var checks = 0

    static func main() throws {
        try authoring()
        try evaluation()
        try rotationAndColor()
        try trackEditing()
        try clipEvaluation()
        try frameRates()
        try lifecycle()
        try persistence()
        try playheadSnapping()
        try layerNames()
        print("PASS: \(checks) keyframe assertions — evaluation boundaries, linear/hold/easing, rotation turns, colour with independent alpha, duplicate-frame handling, non-destructive retiming, clip-local conversion, 23.976/29.97/59.94 timing, move/trim/extend/split/duplicate/delete lifecycle, validation, round-trip persistence, playhead snapping to keyframes and layer renaming.")
    }

    // MARK: - Assertions

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
    static func near(_ a: Double?, _ b: Double, _ message: String, tolerance: Double = 1e-9) {
        checks += 1
        let actual = a == nil ? "nil" : "\(a!)"
        precondition(a != nil && abs(a! - b) <= tolerance, "\(message) — got \(actual), expected \(b)")
    }
    static func throwsError(_ message: String, _ body: () throws -> Void) {
        checks += 1
        do { try body(); preconditionFailure("expected an error: \(message)") } catch {}
    }
    static func seconds(_ value: Double) -> TimelineTime { try! .seconds(value) }

    static func numbers(_ property: AnimatableProperty, _ points: [(Double, Double)],
                        _ mode: KeyframeInterpolation = .linear) -> AnimationTrack {
        AnimationTrack(property: property, keyframes: points.map {
            Keyframe(time: seconds($0.0), value: .number($0.1), interpolation: mode)
        })
    }

    // MARK: - Authoring rules

    static func authoring() throws {
        // An unanimated property changes its BASE value and creates no animation.
        var clip = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: seconds(4)))
        clip.setValue(.number(0.3), of: .opacity, atLocal: seconds(1))
        near(clip.opacity, 0.3, "an unanimated property must change its base value")
        check(clip.animation == nil, "changing an unanimated value must not create animation")

        // The diamond adds a keyframe holding what is on screen.
        clip.toggleKeyframe(.opacity, atLocal: seconds(1))
        check(clip.animation?.track(.opacity)?.keyframes.count == 1, "the diamond did not add a keyframe")
        near(clip.animation?.track(.opacity)?.keyframes[0].value.number, 0.3, "the first keyframe must hold the visible value")
        check(clip.animation?.track(.scale) == nil, "adding one keyframe touched another property")

        // Once animated, changing the value writes a keyframe at the playhead instead.
        clip.setValue(.number(1), of: .opacity, atLocal: seconds(3))
        check(clip.animation?.track(.opacity)?.keyframes.count == 2, "an animated edit did not add a keyframe")
        near(clip.opacity, 0.3, "an animated edit must not overwrite the base value")
        near(clip.evaluated(atLocal: seconds(2)).opacity, 0.65, "the new keyframe did not animate")

        // Inserting between existing keyframes starts from the EVALUATED value.
        var inserted = clip
        inserted.toggleKeyframe(.opacity, atLocal: seconds(2))
        near(inserted.animation?.track(.opacity)?.keyframe(at: seconds(2))?.value.number, 0.65,
             "an inserted keyframe must start from the evaluated value, not a stale base value")
        near(inserted.evaluated(atLocal: seconds(2)).opacity, 0.65, "inserting a keyframe changed the rendered frame")

        // An animated edit with no valid local time is refused rather than silently
        // writing an out-of-range keyframe.
        var outside = clip
        check(!outside.setValue(.number(0.9), of: .opacity, atLocal: nil), "an animated edit outside the clip must be refused")

        // Removing the last keyframe keeps the value that was on screen.
        var single = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: seconds(4)))
        single.opacity = 0.2
        single.toggleKeyframe(.opacity, atLocal: seconds(1))
        single.toggleKeyframe(.opacity, atLocal: seconds(1))
        check(single.animation == nil, "removing the only keyframe left empty animation behind")
        near(single.opacity, 0.2, "removing the last keyframe lost the visible value")

        // Remove animation keeps what is on screen; reset restores the default.
        var kept = clip
        kept.removeAnimation(of: .opacity, atLocal: seconds(2))
        check(kept.animation == nil, "remove animation left tracks behind")
        near(kept.opacity, 0.65, "remove animation must keep the value you can see")
        var reset = clip
        reset.resetProperty(.opacity)
        check(reset.animation == nil, "reset left animation behind")
        near(reset.opacity, 1, "reset must restore the documented default")

        // Remove-all holds every animated property at its visible value.
        var many = clip
        many.setValue(.number(2), of: .scale, atLocal: nil)
        many.toggleKeyframe(.scale, atLocal: .zero)
        many.setValue(.number(4), of: .scale, atLocal: seconds(4))
        many.removeAllAnimation(atLocal: seconds(2))
        check(many.animation == nil, "remove all left animation behind")
        near(many.opacity, 0.65, "remove all lost the opacity that was on screen")
        near(many.transform.scale, 3, "remove all lost the scale that was on screen")

        // Video clips use the identical rules through the same reified operation.
        var video = VideoClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: seconds(1), duration: seconds(5)),
                              assetID: UUID(), sourceRange: .init(start: .zero, duration: seconds(5)))
        video.apply(.toggleKeyframe(.scale, atLocal: .zero))
        video.apply(.setValue(.scale, .number(3), atLocal: seconds(4)))
        near(video.evaluated(at: seconds(3)).transform.scale, 2, "video transform animation is not evaluated")
        near(video.transform.scale, 1, "video animation overwrote the base transform")
        check(video.visibleKeyframes(.scale).count == 2, "video keyframes are not reported to the UI")
        near(video.visibleKeyframes(.scale)[1].timeline.seconds, 5, "video keyframe timeline mapping is wrong")
        // A keyframe at exactly the clip's end is one frame past the last rendered frame
        // and must not be offered for navigation.
        var atEnd = video
        atEnd.placement.duration = seconds(4)
        check(atEnd.visibleKeyframes(.scale).count == 1, "a keyframe past the clip's last frame was offered")
        video.apply(.resetProperty(.scale))
        check(video.animation == nil, "video reset left animation behind")

        // Keyframes hidden by a trim are excluded from navigation but not destroyed.
        var trimmed = clip
        trimmed.animation?.startOffset = seconds(2)
        trimmed.placement.duration = seconds(1)
        check(trimmed.animation?.track(.opacity)?.keyframes.count == 2, "a trim discarded keyframes")
        check(trimmed.visibleKeyframes(.opacity).isEmpty, "navigation offered a keyframe hidden by a trim")
    }

    // MARK: - Evaluation

    static func evaluation() throws {
        let track = numbers(.opacity, [(1, 0.2), (3, 0.8)])
        near(track.value(at: .zero)?.number, 0.2, "before the first keyframe holds its value")
        near(track.value(at: seconds(1))?.number, 0.2, "at the first keyframe")
        near(track.value(at: seconds(2))?.number, 0.5, "linear midpoint")
        near(track.value(at: seconds(3))?.number, 0.8, "at the last keyframe")
        near(track.value(at: seconds(99))?.number, 0.8, "after the last keyframe holds its value")

        let single = numbers(.scale, [(4, 2.5)])
        for time in [0.0, 4, 100] { near(single.value(at: seconds(time))?.number, 2.5, "one keyframe is constant") }
        check(AnimationTrack(property: .scale).value(at: .zero) == nil, "an empty track has no value")

        let hold = numbers(.opacity, [(1, 0), (3, 1)], .hold)
        near(hold.value(at: seconds(2.9999))?.number, 0, "hold does not interpolate")
        near(hold.value(at: seconds(3))?.number, 1, "hold steps exactly at the next keyframe")

        for mode in [KeyframeInterpolation.easeIn, .easeOut, .easeInOut] {
            let eased = numbers(.opacity, [(0, 0), (4, 1)], mode)
            var previous = -1.0
            for step in 0...40 {
                let value = eased.value(at: seconds(Double(step) / 10))!.number!
                check(value >= previous, "\(mode) is not monotone")
                check((0...1).contains(value), "\(mode) left the property range at \(value)")
                previous = value
            }
            near(eased.value(at: .zero)?.number, 0, "\(mode) starts at the first value")
            near(eased.value(at: seconds(4))?.number, 1, "\(mode) ends at the last value")
        }
        check(numbers(.opacity, [(0, 0), (4, 1)], .easeIn).value(at: seconds(1))!.number! < 0.25, "Ease In starts slow")
        check(numbers(.opacity, [(0, 0), (4, 1)], .easeOut).value(at: seconds(1))!.number! > 0.25, "Ease Out starts fast")

        var mixed = AnimationTrack(property: .opacity, keyframes: [
            Keyframe(time: seconds(0), value: .number(0), interpolation: .hold),
            Keyframe(time: seconds(2), value: .number(0.5), interpolation: .linear),
            Keyframe(time: seconds(4), value: .number(1), interpolation: .linear)
        ])
        near(mixed.value(at: seconds(1))?.number, 0, "each segment uses its own left mode")
        near(mixed.value(at: seconds(3))?.number, 0.75, "the linear segment still interpolates")
        mixed.setInterpolation(.hold, at: seconds(2))
        near(mixed.value(at: seconds(3))?.number, 0.5, "changing one keyframe's mode changes only its segment")
    }

    static func rotationAndColor() throws {
        let spin = numbers(.rotation, [(0, 0), (4, 720)])
        near(spin.value(at: seconds(1))?.number, 180, "two full turns interpolate continuously")
        near(spin.value(at: seconds(2))?.number, 360, "360 is a real value, not a wrap to zero")
        let turn = numbers(.rotation, [(0, 2), (2, 362)])
        near(turn.value(at: seconds(1))?.number, 182, "a full turn is not cancelled by wrapping")

        let colors = AnimationTrack(property: .textColor, keyframes: [
            Keyframe(time: .zero, value: .color(.init(red: 0, green: 0, blue: 0, alpha: 1))),
            Keyframe(time: seconds(2), value: .color(.init(red: 1, green: 0.5, blue: 0.25, alpha: 0)))
        ])
        let mid = colors.value(at: seconds(1))!.color!
        near(mid.red, 0.5, "red interpolates component-wise in sRGB")
        near(mid.green, 0.25, "green interpolates component-wise in sRGB")
        near(mid.blue, 0.125, "blue interpolates component-wise in sRGB")
        near(mid.alpha, 0.5, "alpha is interpolated independently, not premultiplied")
    }

    static func trackEditing() throws {
        var track = AnimationTrack(property: .opacity)
        track.set(.number(0.1), at: seconds(1))
        track.set(.number(0.9), at: seconds(1))
        check(track.keyframes.count == 1, "a duplicate frame replaces rather than appends")
        track.set(.number(0.4), at: try TimelineTime(value: 240_000, timescale: 240_000))
        check(track.keyframes.count == 1, "equal times in different timescales are the same frame")
        near(track.keyframes[0].value.number, 0.4, "the replacement value is kept")

        var clamping = AnimationTrack(property: .opacity)
        clamping.set(.number(9), at: .zero)
        clamping.set(.number(-4), at: seconds(1))
        near(clamping.keyframes[0].value.number, 1, "values clamp to the property range")
        near(clamping.keyframes[1].value.number, 0, "values clamp to the property range")

        var eased = AnimationTrack(property: .opacity, keyframes: [
            Keyframe(time: .zero, value: .number(0), interpolation: .easeInOut),
            Keyframe(time: seconds(4), value: .number(1), interpolation: .easeInOut)
        ])
        eased.set(.number(0.5), at: seconds(2))
        check(eased.keyframes[1].interpolation == .easeInOut, "inserting inside an eased span keeps the curve")

        var retimed = numbers(.opacity, [(1, 0), (2, 0.5), (3, 1)])
        let spacing = try TimelineTime(value: 1, timescale: 30)
        let landed = retimed.move(from: seconds(2), to: seconds(5), minimumSpacing: spacing)
        check(retimed.keyframes.count == 3, "retiming destroyed a neighbouring keyframe")
        near(landed?.seconds, try seconds(3).subtracting(spacing).seconds, "retiming clamps one frame short of its neighbour")
        check(zip(retimed.keyframes, retimed.keyframes.dropFirst()).allSatisfy { $0.time < $1.time }, "retiming left the track unsorted")

        var animation = ClipAnimation()
        animation.update(.opacity) { $0.set(.number(0.5), at: .zero) }
        animation.update(.scale) { $0.set(.number(2), at: .zero) }
        animation.removeAnimation(of: .opacity)
        check(animation.track(.opacity) == nil, "removing one property's animation")
        check(animation.track(.scale)?.keyframes.count == 1, "removing one property left another intact")

        let unknown = """
        {"time":{"value":1,"timescale":1},"value":{"number":{"_0":0.5}},"interpolation":"bounceCubic"}
        """.data(using: .utf8)!
        let recovered = try JSONDecoder().decode(Keyframe.self, from: unknown).interpolation
        check(recovered == .linear, "an unknown interpolation mode must recover to linear, not fail the open")

        let messy = """
        {"property":"opacity","keyframes":[
          {"time":{"value":2,"timescale":1},"value":{"number":{"_0":0.9}}},
          {"time":{"value":1,"timescale":1},"value":{"number":{"_0":0.1}}},
          {"time":{"value":2,"timescale":1},"value":{"number":{"_0":0.5}}}]}
        """.data(using: .utf8)!
        let repaired = try JSONDecoder().decode(AnimationTrack.self, from: messy)
        check(repaired.keyframes.map { $0.time.seconds } == [1, 2], "decoding sorts and dedupes keyframes")
        near(repaired.keyframes[1].value.number, 0.5, "the last duplicate wins")
    }

    static func clipEvaluation() throws {
        var clip = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: seconds(5), duration: seconds(4)))
        clip.transform.scale = 1.75
        clip.opacity = 0.4
        var animation = ClipAnimation()
        animation.update(.opacity) { track in
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: seconds(4))
        }
        clip.animation = animation

        near(clip.evaluated(at: seconds(5)).opacity, 0, "clip-local zero is the clip's start on the timeline")
        near(clip.evaluated(at: seconds(7)).opacity, 0.5, "midpoint of the animated span")
        near(clip.evaluated(at: seconds(9)).opacity, 1, "end of the animated span")
        near(clip.evaluated(at: seconds(7)).transform.scale, 1.75, "an unanimated property keeps its base value")
        near(clip.opacity, 0.4, "evaluation must not mutate authored state")

        var moved = clip
        moved.placement.timelineStart = seconds(20)
        near(moved.evaluated(at: seconds(22)).opacity, 0.5, "animation moves with the clip")

        var offset = clip
        offset.animation?.startOffset = seconds(2)
        near(offset.evaluated(at: seconds(5)).opacity, 0.5, "a start offset shifts which window the clip reads")
    }

    static func frameRates() throws {
        for timescale: Int32 in [24_000, 30_000, 60_000] {
            let frame = try TimelineTime(value: 1001, timescale: timescale)
            var tenth = TimelineTime.zero, fifth = TimelineTime.zero
            for step in 0..<10 {
                tenth = try tenth.adding(frame)
                if step < 5 { fifth = try fifth.adding(frame) }
            }
            var track = AnimationTrack(property: .opacity)
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: tenth)
            near(track.value(at: tenth)?.number, 1, "frame \(timescale) landed exactly on the last keyframe")
            check(track.index(at: tenth) != nil, "timescale \(timescale) lost exact frame identity")
            near(track.value(at: fifth)?.number, 0.5, "timescale \(timescale) midpoint")
        }
    }

    // MARK: - Clip lifecycle

    static func textProject(textStart: Double = 2, textDuration: Double = 4) -> (VideoProject, UUID) {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Keyframes", metadata: makeKeyframeMetadata())
        let trackID = UUID()
        var clip = TextClip(placement: .init(id: UUID(), trackID: trackID,
                                             timelineStart: seconds(textStart), duration: seconds(textDuration)))
        var animation = ClipAnimation()
        // 0 -> 1 across the whole four-second clip.
        animation.update(.opacity) { track in
            track.set(.number(0), at: .zero, interpolation: .easeInOut)
            track.set(.number(1), at: seconds(textDuration))
        }
        clip.animation = animation
        project.timeline.tracks.insert(.init(id: trackID, name: "Text", kind: .text, items: [.text(clip)]), at: 0)
        return (project, clip.id)
    }

    static func text(_ project: VideoProject, _ id: UUID) -> TextClip {
        guard case .text(let clip) = project.timeline.item(id: id)! else { preconditionFailure("not text") }
        return clip
    }

    static func lifecycle() throws {
        // Move: animation follows the clip.
        var (project, id) = textProject()
        let original = text(project, id)
        var moved = original
        moved.placement.timelineStart = seconds(6)
        try OverlayEditing.replace(id, with: moved, in: &project)
        near(text(project, id).evaluated(at: seconds(8)).opacity,
             original.evaluated(at: seconds(4)).opacity, "moving a clip moved its animation with it")

        // Split: both halves must reproduce the original at every retained time.
        (project, id) = textProject()
        let source = text(project, id)
        let rightID = try OverlayEditing.split(id, at: seconds(4), in: &project)
        let left = text(project, id), right = text(project, rightID)
        check(left.animation?.track(.opacity)?.keyframes == source.animation?.track(.opacity)?.keyframes,
              "the split rewrote the left keyframes")
        check(right.animation?.track(.opacity)?.keyframes == source.animation?.track(.opacity)?.keyframes,
              "the split rewrote the right keyframes")
        near(right.animation?.startOffset.seconds, 2, "the right half must not restart from the first keyframe")
        for time in stride(from: 2.0, to: 5.99, by: 0.05) {
            let whole = source.evaluated(at: seconds(time)).opacity
            let piece = (time < 4 ? left : right).evaluated(at: seconds(time)).opacity
            near(piece, whole, "split changed the animation at \(time)s", tolerance: 1e-9)
        }

        // Trim the head: hidden keyframes are preserved and restored by extending again.
        (project, id) = textProject()
        try OverlayEditing.edit(id, operation: .trimStart, to: seconds(3), in: &project)
        let trimmed = text(project, id)
        near(trimmed.animation?.startOffset.seconds, 1, "a head trim advances the animation offset")
        check(trimmed.animation?.track(.opacity)?.keyframes.count == 2, "a head trim discarded keyframes")
        near(trimmed.evaluated(at: seconds(3)).opacity, source.evaluated(at: seconds(3)).opacity,
             "a head trim shifted the animation in time")
        try OverlayEditing.edit(id, operation: .trimStart, to: seconds(2), in: &project)
        let restored = text(project, id)
        near(restored.animation?.startOffset.seconds, 0, "extending the head restored the hidden animation")
        near(restored.evaluated(at: seconds(2)).opacity, source.evaluated(at: seconds(2)).opacity,
             "extending the head did not restore the original values")

        // Trim the tail: the animation clock is untouched.
        (project, id) = textProject()
        try OverlayEditing.edit(id, operation: .trimEnd, to: seconds(4), in: &project)
        let shortened = text(project, id)
        near(shortened.animation?.startOffset.seconds, 0, "a tail trim must not move the animation")
        near(shortened.evaluated(at: seconds(3)).opacity, source.evaluated(at: seconds(3)).opacity,
             "a tail trim changed retained values")

        // Duplicate: independent animation data.
        (project, id) = textProject()
        let copyID = try OverlayEditing.paste(text(project, id), at: seconds(20), in: &project)
        var copy = text(project, copyID)
        copy.animation?.update(.opacity) { $0.set(.number(0.25), at: .zero) }
        try OverlayEditing.replace(copyID, with: copy, in: &project)
        near(text(project, id).animation?.track(.opacity)?.keyframes.first?.value.number, 0,
             "editing a pasted copy changed the original")
        near(text(project, copyID).animation?.track(.opacity)?.keyframes.first?.value.number, 0.25,
             "the pasted copy did not keep its own edit")
        check(copyID != id, "paste must produce a new identity")

        // Delete: the clip and its animation go together.
        try OverlayEditing.delete(copyID, in: &project)
        check(project.timeline.item(id: copyID) == nil, "deleting a clip left it behind")
        check(project.timeline.hasAnimation, "deleting a copy removed the original's animation")
        try OverlayEditing.delete(id, in: &project)
        check(!project.timeline.hasAnimation, "deleting the last animated clip left animation behind")
    }

    /// The playhead magnet must catch keyframes the same way it catches cuts and markers.
    static func playheadSnapping() throws {
        let (project, id) = textProject()
        let clip = text(project, id)
        // The clip runs 2s-6s with keyframes at local 0 and 4, so the second one sits exactly
        // at the end and is correctly hidden.
        check(clip.visibleKeyframeSeconds == [2], "only keyframes inside the clip should be offered")

        // Widen it to 2s-7s so both keyframes (2s and 6s) are inside, and 6s is clear of
        // every clip edge — otherwise edge snapping would mask the keyframe magnet.
        var wide = clip
        wide.placement.duration = seconds(5)
        var widened = project
        try OverlayEditing.replace(id, with: wide, in: &widened)
        let display = widened.timeline.items.compactMap(TimelineDisplayClip.init)
        let both = text(widened, id).visibleKeyframeSeconds
        check(both == [2, 6], "expected keyframes at 2s and 6s, got \(both)")

        // Within tolerance the playhead lands exactly on the keyframe...
        near(TimelineEditing.snapPlayhead(6.05, clips: display, markers: [], keyframes: both, tolerance: 0.2),
             6, "the playhead did not snap to a keyframe")
        // ...and outside it the scrub stays free.
        near(TimelineEditing.snapPlayhead(6.5, clips: display, markers: [], keyframes: both, tolerance: 0.2),
             6.5, "the keyframe magnet is too greedy")
        // Passing no keyframes preserves the previous behaviour exactly.
        near(TimelineEditing.snapPlayhead(6.05, clips: display, markers: [], tolerance: 0.2),
             6.05, "keyframe snapping leaked into callers that pass none")
        // Clip edges still win when they are nearer.
        near(TimelineEditing.snapPlayhead(2.02, clips: display, markers: [], keyframes: both, tolerance: 0.2),
             2, "clip-edge snapping regressed")
    }

    /// Layer names are user-editable display text, so they must survive a round trip and
    /// never reach the document in a shape that renders as an empty or runaway row.
    static func layerNames() throws {
        check(TimelineTrack.sanitizedName("  Titles  ", kind: .text) == "Titles", "surrounding whitespace was not trimmed")
        check(TimelineTrack.sanitizedName("Lower   third", kind: .text) == "Lower third", "runs of spaces were not collapsed")
        check(TimelineTrack.sanitizedName("Two\nlines\there", kind: .text) == "Two lines here", "newlines and tabs were not flattened")
        check(TimelineTrack.sanitizedName("   ", kind: .mainVideo) == "Main Video", "an empty name must fall back to the default")
        check(TimelineTrack.sanitizedName("", kind: .audio) == "Audio", "an empty name must fall back to the default")
        check(TimelineTrack.sanitizedName(String(repeating: "x", count: 500), kind: .text).count == 60, "a runaway name was not capped")
        check(TimelineTrack.sanitizedName("Café ünïcode 😀", kind: .text) == "Café ünïcode 😀", "non-ASCII names must be preserved")

        // Renaming changes nothing else about the project, and survives a save and reopen.
        var (project, id) = textProject()
        let before = project
        let trackID = text(project, id).placement.trackID
        let index = project.timeline.tracks.firstIndex { $0.id == trackID }!
        project.timeline.tracks[index].name = TimelineTrack.sanitizedName("Opening title", kind: .text)
        check(project.timeline.tracks[index].items == before.timeline.tracks[index].items, "renaming altered the layer's clips")
        check(project.timeline.duration == before.timeline.duration, "renaming altered the timeline duration")
        check(project.needsLayerCompositor == before.needsLayerCompositor, "renaming changed the render path")
        let reopened = try JSONDecoder().decode(VideoProject.self, from: try JSONEncoder().encode(project))
        check(reopened.timeline.tracks[index].name == "Opening title", "a renamed layer did not survive a reopen")
        check(text(reopened, id).animation == text(project, id).animation, "renaming disturbed the layer's animation")
    }

    static func persistence() throws {
        // A project written before keyframes existed has no animation key and reopens unchanged.
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Plain", metadata: makeKeyframeMetadata())
        let plain = try JSONEncoder().encode(project)
        check(!String(data: plain, encoding: .utf8)!.contains("\"animation\""),
              "an unanimated project must not write animation keys")
        let reopened = try JSONDecoder().decode(VideoProject.self, from: plain)
        check(!reopened.timeline.hasAnimation, "a plain project reopened as animated")
        check(reopened.needsLayerCompositor == false, "a plain project should keep the fast preview path")

        // Animation alone must force the compositing path, or it would be silently dropped.
        var clip = project.timeline.firstVideoClip!
        var animation = ClipAnimation()
        animation.update(.scale) { track in
            track.set(.number(1), at: .zero)
            track.set(.number(2), at: seconds(2))
        }
        clip.animation = animation
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        check(project.needsLayerCompositor, "animation must force the layer compositor")
        check(project.singleSourceClip == nil, "an animated clip must not take the single-source fast path")

        // Exact round trip, including interpolation modes and the start offset.
        let (animated, id) = textProject()
        var withColor = text(animated, id)
        withColor.animation?.update(.textColor) {
            $0.set(.color(.init(red: 1, green: 0, blue: 0, alpha: 0.5)), at: .zero)
        }
        withColor.animation?.startOffset = seconds(0.5)
        var document = animated
        try OverlayEditing.replace(id, with: withColor, in: &document)
        let restored = try JSONDecoder().decode(VideoProject.self, from: try JSONEncoder().encode(document))
        check(text(restored, id).animation == withColor.animation, "animation did not survive a save and reopen exactly")
        check(text(restored, id).animation?.track(.opacity)?.keyframes[0].interpolation == .easeInOut,
              "interpolation modes were lost")
        near(text(restored, id).animation?.track(.textColor)?.keyframes[0].value.color?.alpha, 0.5, "colour alpha was lost")

        // Malformed animation is refused with a readable reason, not a renderer crash.
        var broken = document
        var bad = text(broken, id)
        bad.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .scale, keyframes: [Keyframe(time: .zero, value: .color(.white))])
        ])
        try OverlayEditing.replace(id, with: bad, in: &broken)
        throwsError("a colour value on a numeric property") { try broken.validate() }

        var outOfRange = document
        var big = text(outOfRange, id)
        big.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .fontSize, keyframes: [Keyframe(time: .zero, value: .number(999_999))])
        ])
        try OverlayEditing.replace(id, with: big, in: &outOfRange)
        throwsError("an out-of-range keyframe") { try outOfRange.validate() }

        var wrongClip = project
        var video = wrongClip.timeline.firstVideoClip!
        video.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .fontSize, keyframes: [Keyframe(time: .zero, value: .number(40))])
        ])
        try TimelineEditing.replace(video.id, with: [video], in: &wrongClip)
        throwsError("a text-only property on a video clip") { try wrongClip.validate() }
        check(!VideoClip.supports(.fontSize), "video clips must not claim text properties")
        check(VideoClip.supports(.scale), "video clips must support the shared transform")
        check(TextClip.supports(.fontSize), "text clips must support font size")
    }
}

func makeKeyframeMetadata() -> VideoMetadata {
    VideoMetadata(fileName: "clip.mov", durationSeconds: 30, encodedWidth: 1920, encodedHeight: 1080,
                  displayWidth: 1920, displayHeight: 1080, preferredTransform: .init(.identity),
                  nominalFrameRate: 30, minimumFrameDurationSeconds: 1.0/30.0, codec: "HEVC", codecFourCC: "hvc1",
                  estimatedBitrate: 12_000_000, fileSize: 4_000_000, hasAudio: true, videoTrackCount: 1,
                  audioTrackCount: 1, colorPrimaries: "BT.709", transferFunction: "BT.709", yCbCrMatrix: "BT.709",
                  logTransferFunction: nil, isHDR: false, bitDepth: 8, creationDate: nil)
}
