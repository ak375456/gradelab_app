import CoreMedia
import XCTest
@testable import GradeLab

final class KeyframeTests: XCTestCase {

    // MARK: - Helpers

    private func seconds(_ value: Double) throws -> TimelineTime { try .seconds(value) }

    private func track(_ property: AnimatableProperty = .opacity,
                       _ points: [(Double, Double)],
                       _ mode: KeyframeInterpolation = .linear) throws -> AnimationTrack {
        AnimationTrack(property: property, keyframes: try points.map {
            Keyframe(time: try seconds($0.0), value: .number($0.1), interpolation: mode)
        })
    }

    private func textProject(duration: Double = 10, textStart: Double = 2, textDuration: Double = 4) throws -> (VideoProject, UUID) {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Keyframes", metadata: makeVideoMetadata(durationSeconds: duration))
        let trackID = UUID()
        let clip = TextClip(placement: .init(id: UUID(), trackID: trackID,
                                             timelineStart: try seconds(textStart), duration: try seconds(textDuration)))
        project.timeline.tracks.insert(.init(id: trackID, name: "Text", kind: .text, items: [.text(clip)]), at: 0)
        return (project, clip.id)
    }

    private func text(_ project: VideoProject, _ id: UUID) -> TextClip {
        guard case .text(let clip) = project.timeline.item(id: id)! else { fatalError("not a text clip") }
        return clip
    }

    private func replace(_ clip: TextClip, in project: inout VideoProject) throws {
        try TextEditing.replace(clip.id, with: clip, in: &project)
    }

    // MARK: - Evaluation boundaries

    func testHoldsFirstValueBeforeAndLastValueAfter() throws {
        let track = try track(.opacity, [(1, 0.2), (3, 0.8)])
        XCTAssertEqual(track.value(at: .zero)?.number, 0.2)
        XCTAssertEqual(track.value(at: try seconds(0.999))?.number, 0.2)
        XCTAssertEqual(track.value(at: try seconds(1))?.number, 0.2)
        XCTAssertEqual(track.value(at: try seconds(3))?.number, 0.8)
        XCTAssertEqual(track.value(at: try seconds(99))?.number, 0.8)
    }

    func testSingleKeyframeIsConstantAndEmptyTrackHasNoValue() throws {
        let single = try track(.scale, [(4, 2.5)])
        for time in [0.0, 4, 100] {
            XCTAssertEqual(single.value(at: try seconds(time))?.number, 2.5)
        }
        XCTAssertNil(AnimationTrack(property: .scale).value(at: .zero))
    }

    func testLinearInterpolationIsExactAtMidpointAndEndpoints() throws {
        let track = try track(.positionX, [(2, 0), (6, 1)])
        XCTAssertEqual(track.value(at: try seconds(2))?.number, 0)
        XCTAssertEqual(track.value(at: try seconds(4))!.number!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(track.value(at: try seconds(5))!.number!, 0.75, accuracy: 1e-12)
        XCTAssertEqual(track.value(at: try seconds(6))?.number, 1)
    }

    func testHoldStepsExactlyAtTheNextKeyframe() throws {
        let track = try track(.opacity, [(1, 0), (3, 1)], .hold)
        XCTAssertEqual(track.value(at: try seconds(1))?.number, 0)
        XCTAssertEqual(track.value(at: try seconds(2.9999))?.number, 0)
        // The change lands exactly on the keyframe time, never a frame early or late.
        XCTAssertEqual(track.value(at: try seconds(3))?.number, 1)
    }

    func testEasingsAreMonotoneStayInRangeAndDifferFromLinear() throws {
        for mode in [KeyframeInterpolation.easeIn, .easeOut, .easeInOut] {
            let eased = try track(.opacity, [(0, 0), (4, 1)], mode)
            let linear = try track(.opacity, [(0, 0), (4, 1)], .linear)
            var previous = -1.0
            for step in 0...40 {
                let value = eased.value(at: try seconds(Double(step) / 10))!.number!
                XCTAssertGreaterThanOrEqual(value, previous, "\(mode) is not monotone")
                XCTAssertTrue((0...1).contains(value), "\(mode) left the property range: \(value)")
                previous = value
            }
            XCTAssertEqual(eased.value(at: .zero)?.number, 0)
            XCTAssertEqual(eased.value(at: try seconds(4))?.number, 1)
            XCTAssertNotEqual(eased.value(at: try seconds(1))!.number!,
                              linear.value(at: try seconds(1))!.number!, accuracy: 1e-9)
        }
        // Ease In starts slow, Ease Out starts fast.
        let easeIn = try track(.opacity, [(0, 0), (4, 1)], .easeIn).value(at: try seconds(1))!.number!
        let easeOut = try track(.opacity, [(0, 0), (4, 1)], .easeOut).value(at: try seconds(1))!.number!
        XCTAssertLessThan(easeIn, 0.25)
        XCTAssertGreaterThan(easeOut, 0.25)
    }

    func testEachSegmentUsesItsOwnLeftKeyframeMode() throws {
        var track = AnimationTrack(property: .opacity, keyframes: [
            Keyframe(time: try seconds(0), value: .number(0), interpolation: .hold),
            Keyframe(time: try seconds(2), value: .number(0.5), interpolation: .linear),
            Keyframe(time: try seconds(4), value: .number(1), interpolation: .linear)
        ])
        XCTAssertEqual(track.value(at: try seconds(1))?.number, 0, "hold segment must not interpolate")
        XCTAssertEqual(track.value(at: try seconds(3))!.number!, 0.75, accuracy: 1e-12)
        track.setInterpolation(.hold, at: try seconds(2))
        XCTAssertEqual(track.value(at: try seconds(3))?.number, 0.5)
    }

    // MARK: - Rotation and color

    func testRotationThroughFullTurnsIsNotWrappedAway() throws {
        let spin = try track(.rotation, [(0, 0), (4, 720)])
        XCTAssertEqual(spin.value(at: try seconds(1))!.number!, 180, accuracy: 1e-9)
        XCTAssertEqual(spin.value(at: try seconds(2))!.number!, 360, accuracy: 1e-9)
        XCTAssertEqual(spin.value(at: try seconds(4))!.number!, 720, accuracy: 1e-9)
        // A 0 -> 360 authored rotation must remain real motion, not a no-op.
        let turn = try track(.rotation, [(0, 0), (2, 360)])
        XCTAssertEqual(turn.value(at: try seconds(1))!.number!, 180, accuracy: 1e-9)
        XCTAssertNotEqual(turn.value(at: try seconds(1))!.number!, 0)
    }

    func testColorInterpolatesComponentwiseWithIndependentAlpha() throws {
        let track = AnimationTrack(property: .textColor, keyframes: [
            Keyframe(time: .zero, value: .color(.init(red: 0, green: 0, blue: 0, alpha: 1))),
            Keyframe(time: try seconds(2), value: .color(.init(red: 1, green: 0.5, blue: 0.25, alpha: 0)))
        ])
        let mid = track.value(at: try seconds(1))!.color!
        XCTAssertEqual(mid.red, 0.5, accuracy: 1e-12)
        XCTAssertEqual(mid.green, 0.25, accuracy: 1e-12)
        XCTAssertEqual(mid.blue, 0.125, accuracy: 1e-12)
        // Alpha is interpolated independently: a fade out must not darken the colour.
        XCTAssertEqual(mid.alpha, 0.5, accuracy: 1e-12)
    }

    // MARK: - Track editing

    func testDuplicateFramesAreReplacedNotAppended() throws {
        var track = AnimationTrack(property: .opacity)
        track.set(.number(0.1), at: try seconds(1))
        track.set(.number(0.9), at: try seconds(1))
        XCTAssertEqual(track.keyframes.count, 1)
        XCTAssertEqual(track.keyframes[0].value.number, 0.9)
        // Equal times expressed in different timescales are the same frame.
        track.set(.number(0.4), at: try TimelineTime(value: 240_000, timescale: 240_000))
        XCTAssertEqual(track.keyframes.count, 1)
        XCTAssertEqual(track.keyframes[0].value.number, 0.4)
    }

    func testDecodingRepairsUnsortedAndDuplicateKeyframes() throws {
        let json = """
        {"property":"opacity","keyframes":[
          {"time":{"value":2,"timescale":1},"value":{"number":{"_0":0.9}},"interpolation":"linear"},
          {"time":{"value":1,"timescale":1},"value":{"number":{"_0":0.1}},"interpolation":"linear"},
          {"time":{"value":2,"timescale":1},"value":{"number":{"_0":0.5}},"interpolation":"linear"}]}
        """.data(using: .utf8)!
        let track = try JSONDecoder().decode(AnimationTrack.self, from: json)
        XCTAssertEqual(track.keyframes.map { $0.time.seconds }, [1, 2])
        XCTAssertEqual(track.keyframes[1].value.number, 0.5)
    }

    func testUnknownInterpolationRecoversToLinear() throws {
        let json = """
        {"time":{"value":1,"timescale":1},"value":{"number":{"_0":0.5}},"interpolation":"bounceCubic"}
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Keyframe.self, from: json).interpolation, .linear)
    }

    func testValuesAreClampedToThePropertyRange() throws {
        var track = AnimationTrack(property: .opacity)
        track.set(.number(9), at: .zero)
        track.set(.number(-4), at: try seconds(1))
        XCTAssertEqual(track.keyframes[0].value.number, 1)
        XCTAssertEqual(track.keyframes[1].value.number, 0)
    }

    func testInsertedKeyframeInheritsTheCurveOfTheSegmentItLandsIn() throws {
        var track = AnimationTrack(property: .opacity, keyframes: [
            Keyframe(time: .zero, value: .number(0), interpolation: .easeInOut),
            Keyframe(time: try seconds(4), value: .number(1), interpolation: .easeInOut)
        ])
        track.set(.number(0.5), at: try seconds(2))
        XCTAssertEqual(track.keyframes[1].interpolation, .easeInOut,
                       "inserting inside an eased span must not silently turn it linear")
    }

    func testRetimingClampsInsteadOfDestroyingANeighbour() throws {
        var track = try track(.opacity, [(1, 0), (2, 0.5), (3, 1)])
        let spacing = try TimelineTime(value: 1, timescale: 30)
        let landed = track.move(from: try seconds(2), to: try seconds(5), minimumSpacing: spacing)
        XCTAssertEqual(track.keyframes.count, 3, "a neighbour was destroyed")
        XCTAssertEqual(landed!.seconds, try seconds(3).subtracting(spacing).seconds, accuracy: 1e-9)
        XCTAssertEqual(track.keyframes.map { $0.value.number }, [0, 0.5, 1])
        // Ordering is preserved after the clamp.
        XCTAssertTrue(zip(track.keyframes, track.keyframes.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    func testRemovingOnePropertyLeavesOthersIntact() throws {
        var animation = ClipAnimation()
        animation.update(.opacity) { $0.set(.number(0.5), at: .zero) }
        animation.update(.scale) { $0.set(.number(2), at: .zero) }
        animation.removeAnimation(of: .opacity)
        XCTAssertNil(animation.track(.opacity))
        XCTAssertEqual(animation.track(.scale)?.keyframes.count, 1)
    }

    // MARK: - Clip evaluation

    func testEvaluationLeavesUnanimatedPropertiesAtTheirBaseValue() throws {
        var clip = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: try seconds(4)))
        clip.transform.scale = 1.75
        clip.opacity = 0.4
        var animation = ClipAnimation()
        animation.update(.opacity) { track in
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: try! .seconds(2))
        }
        clip.animation = animation
        let evaluated = clip.evaluated(atLocal: try seconds(1))
        XCTAssertEqual(evaluated.opacity, 0.5, accuracy: 1e-12)
        XCTAssertEqual(evaluated.transform.scale, 1.75, "an unanimated property must keep its base value")
        // Authored state is untouched by evaluation.
        XCTAssertEqual(clip.opacity, 0.4)
    }

    func testVideoMaskGeometryAndLocalGradeWindowAnimateThroughTheSharedEngine() throws {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Animated masks",
                                   metadata: makeVideoMetadata(durationSeconds: 4))
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.layerMask = LayerMask(isEnabled: true, shape: .linear, centerX: 0)
        var grade = AdvancedGrade.neutral
        grade.mask = GradeMask(isEnabled: true)
        clip.gradeSettings.advanced = grade

        var animation = ClipAnimation()
        animation.update(.layerMaskPositionX) { track in
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: try! .seconds(4))
        }
        animation.update(.localMaskFeather) { track in
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: try! .seconds(4))
        }
        clip.animation = animation

        let middle = clip.evaluated(atLocal: try seconds(2))
        XCTAssertEqual(middle.resolvedLayerMask.centerX, 0.5, accuracy: 1e-12)
        XCTAssertEqual(middle.gradeSettings.advanced?.resolvedMask.feather ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(clip.resolvedLayerMask.centerX, 0, "evaluation must not mutate authored data")
        XCTAssertTrue(VideoClip.supports(.layerMaskPositionX))
        XCTAssertTrue(VideoClip.supports(.localMaskFeather))
    }

    func testCompositionTimeIsConvertedThroughClipStartAndOffset() throws {
        var clip = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: try seconds(5), duration: try seconds(4)))
        var animation = ClipAnimation()
        animation.update(.opacity) { track in
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: try! .seconds(4))
        }
        clip.animation = animation
        // Clip-local zero is timeline 5s.
        XCTAssertEqual(clip.evaluated(at: try seconds(5)).opacity, 0)
        XCTAssertEqual(clip.evaluated(at: try seconds(7)).opacity, 0.5, accuracy: 1e-12)
        XCTAssertEqual(clip.evaluated(at: try seconds(9)).opacity, 1)
        // Moving the clip moves its animation with it, unchanged.
        var moved = clip
        moved.placement.timelineStart = try seconds(20)
        XCTAssertEqual(moved.evaluated(at: try seconds(22)).opacity, 0.5, accuracy: 1e-12)
    }

    func testFractionalFrameRatesLandExactlyOnKeyframes() throws {
        // 23.976, 29.97 and 59.94 all use 1001/n frame durations.
        for timescale: Int32 in [24_000, 30_000, 60_000] {
            let frame = try TimelineTime(value: 1001, timescale: timescale)
            var time = TimelineTime.zero
            for _ in 0..<10 { time = try time.adding(frame) }
            var track = AnimationTrack(property: .opacity)
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: time)
            // Exactly on the tenth frame, with no rounding slack anywhere in the chain.
            XCTAssertEqual(track.value(at: time)?.number, 1, "timescale \(timescale)")
            XCTAssertNotNil(track.index(at: time), "timescale \(timescale) lost frame identity")
            var half = TimelineTime.zero
            for _ in 0..<5 { half = try half.adding(frame) }
            XCTAssertEqual(track.value(at: half)!.number!, 0.5, accuracy: 1e-12)
        }
    }

    // MARK: - Authoring rules

    private func clip(_ duration: Double = 4) throws -> TextClip {
        TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: try seconds(duration)))
    }

    func testUnanimatedEditChangesTheBaseValueAndCreatesNoAnimation() throws {
        var clip = try clip()
        clip.setValue(.number(0.3), of: .opacity, atLocal: try seconds(1))
        XCTAssertEqual(clip.opacity, 0.3)
        XCTAssertNil(clip.animation, "changing an unanimated value must not start animating it")
    }

    func testDiamondAddsAKeyframeHoldingTheVisibleValueAndTouchesNoOtherProperty() throws {
        var clip = try clip()
        clip.opacity = 0.3
        clip.transform.scale = 1.5
        clip.toggleKeyframe(.opacity, atLocal: try seconds(1))
        XCTAssertEqual(clip.animation?.track(.opacity)?.keyframes.count, 1)
        XCTAssertEqual(clip.animation?.track(.opacity)?.keyframes[0].value.number, 0.3)
        XCTAssertNil(clip.animation?.track(.scale), "adding one keyframe created another property's")
        XCTAssertEqual(clip.transform.scale, 1.5)
    }

    func testAnimatedEditWritesAKeyframeInsteadOfTheBaseValue() throws {
        var clip = try clip()
        clip.opacity = 0.3
        clip.toggleKeyframe(.opacity, atLocal: try seconds(1))
        clip.setValue(.number(1), of: .opacity, atLocal: try seconds(3))
        XCTAssertEqual(clip.animation?.track(.opacity)?.keyframes.count, 2)
        XCTAssertEqual(clip.opacity, 0.3, "an animated edit must leave the base value alone")
        XCTAssertEqual(clip.evaluated(atLocal: try seconds(2)).opacity, 0.65, accuracy: 1e-12)
    }

    func testInsertingBetweenKeyframesStartsFromTheEvaluatedValue() throws {
        var clip = try clip()
        clip.opacity = 0.3
        clip.toggleKeyframe(.opacity, atLocal: try seconds(1))
        clip.setValue(.number(1), of: .opacity, atLocal: try seconds(3))
        let before = clip.evaluated(atLocal: try seconds(2)).opacity
        clip.toggleKeyframe(.opacity, atLocal: try seconds(2))
        XCTAssertEqual(try XCTUnwrap(clip.animation?.track(.opacity)?.keyframe(at: try seconds(2))?.value.number),
                       before, accuracy: 1e-12)
        XCTAssertEqual(clip.evaluated(atLocal: try seconds(2)).opacity, before, accuracy: 1e-12,
                       "inserting a keyframe changed the rendered frame")
    }

    func testAnimatedEditWithNoLocalTimeIsRefused() throws {
        var clip = try clip()
        clip.toggleKeyframe(.opacity, atLocal: .zero)
        XCTAssertFalse(clip.setValue(.number(0.9), of: .opacity, atLocal: nil),
                       "an animated edit outside the clip must be refused, not written somewhere arbitrary")
    }

    func testRemovingKeyframesAndAnimationKeepsTheVisibleValue() throws {
        var clip = try clip()
        clip.opacity = 0.2
        clip.toggleKeyframe(.opacity, atLocal: try seconds(1))
        clip.toggleKeyframe(.opacity, atLocal: try seconds(1))
        XCTAssertNil(clip.animation)
        XCTAssertEqual(clip.opacity, 0.2, "removing the last keyframe lost the visible value")

        var animated = clip
        animated.opacity = 0
        animated.toggleKeyframe(.opacity, atLocal: .zero)
        animated.setValue(.number(1), of: .opacity, atLocal: try seconds(4))
        var kept = animated
        kept.removeAnimation(of: .opacity, atLocal: try seconds(2))
        XCTAssertNil(kept.animation)
        XCTAssertEqual(kept.opacity, 0.5, accuracy: 1e-12, "remove animation must keep what is on screen")

        var reset = animated
        reset.resetProperty(.opacity)
        XCTAssertNil(reset.animation)
        XCTAssertEqual(reset.opacity, 1, "reset must restore the documented default")
    }

    func testRemoveAllAnimationHoldsEveryPropertyAtItsVisibleValue() throws {
        var clip = try clip()
        clip.opacity = 0
        clip.toggleKeyframe(.opacity, atLocal: .zero)
        clip.setValue(.number(1), of: .opacity, atLocal: try seconds(4))
        clip.toggleKeyframe(.scale, atLocal: .zero)
        clip.setValue(.number(3), of: .scale, atLocal: try seconds(4))
        clip.removeAllAnimation(atLocal: try seconds(2))
        XCTAssertNil(clip.animation)
        XCTAssertEqual(clip.opacity, 0.5, accuracy: 1e-12)
        XCTAssertEqual(clip.transform.scale, 2, accuracy: 1e-12)
    }

    func testVideoClipsUseTheSameRulesThroughTheSameOperation() throws {
        var video = VideoClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: try seconds(1), duration: try seconds(5)),
                              assetID: UUID(), sourceRange: .init(start: .zero, duration: try seconds(5)))
        video.apply(.toggleKeyframe(.scale, atLocal: .zero))
        video.apply(.setValue(.scale, .number(3), atLocal: try seconds(4)))
        XCTAssertEqual(video.evaluated(at: try seconds(3)).transform.scale, 2, accuracy: 1e-12)
        XCTAssertEqual(video.transform.scale, 1, "video animation overwrote the base transform")
        XCTAssertEqual(video.visibleKeyframes(.scale).count, 2)
        XCTAssertEqual(video.visibleKeyframes(.scale)[1].timeline.seconds, 5, accuracy: 1e-9)
    }

    func testKeyframesHiddenByATrimAreNotOfferedForNavigation() throws {
        var clip = try clip()
        clip.toggleKeyframe(.opacity, atLocal: try seconds(1))
        clip.setValue(.number(1), of: .opacity, atLocal: try seconds(3))
        clip.animation?.startOffset = try seconds(2)
        clip.placement.duration = try seconds(1)
        XCTAssertEqual(clip.animation?.track(.opacity)?.keyframes.count, 2, "a trim discarded keyframes")
        XCTAssertTrue(clip.visibleKeyframes(.opacity).isEmpty, "navigation offered a keyframe hidden by a trim")
    }

    // MARK: - Clip lifecycle

    func testSplitReproducesTheOriginalAtEveryRetainedTime() throws {
        var (project, id) = try textProject(textStart: 2, textDuration: 4)
        var source = text(project, id)
        var animation = ClipAnimation()
        animation.update(.opacity) { track in
            track.set(.number(0), at: .zero, interpolation: .easeInOut)
            track.set(.number(1), at: try! .seconds(4))
        }
        source.animation = animation
        try replace(source, in: &project)

        let rightID = try TextEditing.split(id, at: try seconds(4), in: &project)
        let left = text(project, id), right = text(project, rightID)
        XCTAssertEqual(left.animation?.track(.opacity)?.keyframes, source.animation?.track(.opacity)?.keyframes)
        XCTAssertEqual(right.animation?.track(.opacity)?.keyframes, source.animation?.track(.opacity)?.keyframes,
                       "the split rewrote the right half's curve instead of moving its window")
        XCTAssertEqual(try XCTUnwrap(right.animation?.startOffset.seconds), 2, accuracy: 1e-9,
                       "the right half restarted from the first keyframe")
        for step in 0...80 {
            let time = try seconds(2 + Double(step) * 0.05)
            let whole = source.evaluated(at: time).opacity
            let piece = (time.seconds < 4 ? left : right).evaluated(at: time).opacity
            XCTAssertEqual(piece, whole, accuracy: 1e-9, "split changed the animation at \(time.seconds)s")
        }
    }

    func testTrimmingHidesAnimationAndExtendingRestoresIt() throws {
        var (project, id) = try textProject(textStart: 2, textDuration: 4)
        var source = text(project, id)
        var animation = ClipAnimation()
        animation.update(.opacity) { track in
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: try! .seconds(4))
        }
        source.animation = animation
        try replace(source, in: &project)

        try TextEditing.edit(id, operation: .trimStart, to: try seconds(3), in: &project)
        let trimmed = text(project, id)
        XCTAssertEqual(try XCTUnwrap(trimmed.animation?.startOffset.seconds), 1, accuracy: 1e-9)
        XCTAssertEqual(trimmed.animation?.track(.opacity)?.keyframes.count, 2, "a head trim discarded keyframes")
        XCTAssertEqual(trimmed.evaluated(at: try seconds(3)).opacity,
                       source.evaluated(at: try seconds(3)).opacity, accuracy: 1e-9)

        try TextEditing.edit(id, operation: .trimStart, to: try seconds(2), in: &project)
        let restored = text(project, id)
        XCTAssertEqual(try XCTUnwrap(restored.animation?.startOffset.seconds), 0, accuracy: 1e-9)
        XCTAssertEqual(restored.evaluated(at: try seconds(2)).opacity,
                       source.evaluated(at: try seconds(2)).opacity, accuracy: 1e-9)
    }

    func testMovingCarriesAnimationAndPastingIsIndependent() throws {
        var (project, id) = try textProject(textStart: 2, textDuration: 4)
        var source = text(project, id)
        var animation = ClipAnimation()
        animation.update(.opacity) { track in
            track.set(.number(0), at: .zero)
            track.set(.number(1), at: try! .seconds(4))
        }
        source.animation = animation
        try replace(source, in: &project)

        var moved = source
        moved.placement.timelineStart = try seconds(6)
        try replace(moved, in: &project)
        XCTAssertEqual(text(project, id).evaluated(at: try seconds(8)).opacity,
                       source.evaluated(at: try seconds(4)).opacity, accuracy: 1e-9)

        let copyID = try TextEditing.paste(text(project, id), at: try seconds(20), in: &project)
        var copy = text(project, copyID)
        copy.animation?.update(.opacity) { $0.set(.number(0.25), at: .zero) }
        try replace(copy, in: &project)
        XCTAssertEqual(text(project, id).animation?.track(.opacity)?.keyframes.first?.value.number, 0,
                       "editing a pasted copy changed the original")
        XCTAssertEqual(text(project, copyID).animation?.track(.opacity)?.keyframes.first?.value.number, 0.25)
    }

    // MARK: - Layer names

    func testLayerNamesAreSanitizedNotRejected() {
        XCTAssertEqual(TimelineTrack.sanitizedName("  Titles  ", kind: .text), "Titles")
        XCTAssertEqual(TimelineTrack.sanitizedName("Lower   third", kind: .text), "Lower third")
        XCTAssertEqual(TimelineTrack.sanitizedName("Two\nlines\there", kind: .text), "Two lines here")
        XCTAssertEqual(TimelineTrack.sanitizedName("   ", kind: .mainVideo), "Main Video")
        XCTAssertEqual(TimelineTrack.sanitizedName("", kind: .audio), "Audio")
        XCTAssertEqual(TimelineTrack.sanitizedName(String(repeating: "x", count: 500), kind: .text).count, 60)
        XCTAssertEqual(TimelineTrack.sanitizedName("Café ünïcode 😀", kind: .text), "Café ünïcode 😀")
    }

    func testRenamingALayerChangesNothingElse() throws {
        var (project, id) = try textProject()
        let before = project
        let trackID = text(project, id).placement.trackID
        let index = try XCTUnwrap(project.timeline.tracks.firstIndex { $0.id == trackID })
        project.timeline.tracks[index].name = TimelineTrack.sanitizedName("Opening title", kind: .text)
        XCTAssertEqual(project.timeline.tracks[index].items, before.timeline.tracks[index].items)
        XCTAssertEqual(project.timeline.duration, before.timeline.duration)
        XCTAssertEqual(project.needsLayerCompositor, before.needsLayerCompositor,
                       "renaming must not change which render path the project takes")
        let reopened = try JSONDecoder().decode(VideoProject.self, from: try JSONEncoder().encode(project))
        XCTAssertEqual(reopened.timeline.tracks[index].name, "Opening title")
    }

    // MARK: - Persistence and compatibility

    func testProjectsWithoutAnimationStillDecodeAndStayUnanimated() throws {
        let (project, id) = try textProject()
        let data = try JSONEncoder().encode(project)
        // A document written before keyframes existed simply has no animation key.
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("\"animation\""))
        let reopened = try JSONDecoder().decode(VideoProject.self, from: data)
        XCTAssertFalse(reopened.timeline.hasAnimation)
        XCTAssertNil(text(reopened, id).animation)
    }

    func testAnimationSurvivesASaveAndReopenExactly() throws {
        var (project, id) = try textProject()
        var clip = text(project, id)
        var animation = ClipAnimation(startOffset: try seconds(0.5))
        animation.update(.positionX) { track in
            track.set(.number(0.1), at: .zero, interpolation: .easeInOut)
            track.set(.number(0.9), at: try! .seconds(3), interpolation: .hold)
        }
        animation.update(.textColor) { $0.set(.color(.init(red: 1, green: 0, blue: 0, alpha: 0.5)), at: .zero) }
        clip.animation = animation
        try replace(clip, in: &project)

        let reopened = try JSONDecoder().decode(VideoProject.self, from: try JSONEncoder().encode(project))
        let restored = text(reopened, id)
        XCTAssertEqual(restored.animation, animation)
        XCTAssertEqual(restored.animation?.startOffset.seconds, 0.5)
        XCTAssertEqual(restored.animation?.track(.positionX)?.keyframes[0].interpolation, .easeInOut)
        XCTAssertEqual(restored.animation?.track(.positionX)?.keyframes[1].interpolation, .hold)
        XCTAssertEqual(restored.animation?.track(.textColor)?.keyframes[0].value.color?.alpha, 0.5)
        XCTAssertTrue(reopened.timeline.hasAnimation)
    }

    func testAnimationForcesTheLayerCompositor() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Compositor", metadata: makeVideoMetadata(durationSeconds: 10))
        XCTAssertFalse(project.needsLayerCompositor, "baseline single clip should use the fast path")
        XCTAssertNotNil(project.singleSourceClip)
        var clip = project.timeline.firstVideoClip!
        var animation = ClipAnimation()
        // Base transform stays identity: only the animation makes this need compositing.
        animation.update(.scale) { track in
            track.set(.number(1), at: .zero)
            track.set(.number(2), at: try! .seconds(2))
        }
        clip.animation = animation
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        XCTAssertTrue(project.needsLayerCompositor, "animation would be silently dropped on the fast path")
        XCTAssertNil(project.singleSourceClip)
    }

    func testMalformedAnimationIsRejectedWithAReadableReason() throws {
        var (project, id) = try textProject()
        var clip = text(project, id)
        // A colour value on a numeric property cannot be rendered.
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .scale, keyframes: [Keyframe(time: .zero, value: .color(.white))])
        ])
        try replace(clip, in: &project)
        XCTAssertThrowsError(try project.validate()) { error in
            XCTAssertTrue("\(error)".contains("Scale"), "unhelpful message: \(error)")
        }

        var outOfRange = text(project, id)
        outOfRange.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .fontSize, keyframes: [Keyframe(time: .zero, value: .number(999_999))])
        ])
        var second = project
        try TextEditing.replace(id, with: outOfRange, in: &second)
        XCTAssertThrowsError(try second.validate())

    }

    func testVideoClipsRejectTextOnlyProperties() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Video", metadata: makeVideoMetadata(durationSeconds: 10))
        var clip = project.timeline.firstVideoClip!
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .fontSize, keyframes: [Keyframe(time: .zero, value: .number(40))])
        ])
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        XCTAssertThrowsError(try project.validate())
        XCTAssertFalse(VideoClip.supports(.fontSize))
        XCTAssertTrue(VideoClip.supports(.scale))
        XCTAssertTrue(TextClip.supports(.fontSize))
    }
}
