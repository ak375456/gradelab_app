import Foundation
import CoreGraphics

/// Which way a wipe matte travels across the title, in the text's own layout
/// space rather than the canvas — so a rotated title still wipes along its
/// own reading direction.
enum TextWipeDirection: Sendable, Equatable {
    case leftToRight, rightToLeft, topToBottom, bottomToTop
}

/// One glyph cluster's own animation at this instant.
///
/// Offsets are in layout points, so they scale with the font rather than the
/// canvas. Derived every frame from the text and the clock; never persisted.
struct TextGlyphState: Equatable, Sendable {
    var opacity: Double = 1
    var scale: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var rotationDegrees: Double = 0

    static let neutral = TextGlyphState()
    var isNeutral: Bool { self == .neutral }
}

/// Everything a preset asks the RENDERER for, as opposed to what it folds into
/// the clip's own fields.
///
/// Position, scale, rotation, opacity and tracking are not here: those are
/// written straight onto the resolved `TextClip`, which costs nothing because
/// the raster cache already ignores transform and opacity.
struct TextRenderEffects: Equatable, Sendable {
    /// Gaussian radius in layout points.
    var blurRadius: Double = 0
    /// 0 hides the title, 1 shows all of it.
    var wipeProgress: Double = 1
    var wipeDirection: TextWipeDirection = .leftToRight
    /// One entry per grapheme cluster of the case-mapped string, or nil when
    /// nothing animates per glyph — which is the fast path and stays cached.
    var glyphStates: [TextGlyphState]?

    static let none = TextRenderEffects()
    var isNone: Bool { self == .none }
    var wipes: Bool { wipeProgress < 0.999 }
    var blurs: Bool { blurRadius > 0.01 }
}

/// A title, as it should actually be drawn at one moment.
struct ResolvedTextClip: Equatable, Sendable {
    var clip: TextClip
    var effects: TextRenderEffects = .none
}

/// Turns animation presets into a contribution on top of whatever the manual
/// keyframes already decided.
///
/// The contract that makes presets and keyframes coexist: every contribution is
/// RELATIVE and reaches neutral at the end of its window. A Slide In does not
/// say "x goes 0.2 → 0.5", it says "x is offset by -0.3, easing to 0" — so the
/// title lands exactly on whatever position the user authored or keyframed,
/// whatever that turns out to be.
///
/// Everything here is a pure function of clip-local time. Nothing is random,
/// nothing integrates a frame delta, nothing is stored between frames, so a
/// paused frame, a scrub and an export all produce the same picture.
enum TextAnimator {

    /// Whole-title contribution. Offsets are normalized canvas units, scale and
    /// opacity are multipliers, tracking is in layout points.
    struct Contribution: Equatable, Sendable {
        var offsetX: Double = 0
        var offsetY: Double = 0
        var scale: Double = 1
        var rotationDegrees: Double = 0
        var opacity: Double = 1
        var tracking: Double = 0
        var effects = TextRenderEffects.none
    }

    // MARK: - Windows

    /// How long In and Out actually get on a clip of this length.
    ///
    /// A half-second In and a half-second Out do not fit in a 0.6s title, so
    /// both are scaled by the same factor rather than overlapping or being
    /// silently clipped. 0.6s with 0.5 + 0.5 authored becomes 0.3 + 0.3.
    static func windows(_ settings: TextAnimationSettings, duration: Double)
        -> (incoming: Double, outgoing: Double) {
        guard duration > 0 else { return (0, 0) }
        var incoming = settings.incoming == nil ? 0 : max(0, settings.incomingDuration.seconds)
        var outgoing = settings.outgoing == nil ? 0 : max(0, settings.outgoingDuration.seconds)
        incoming = min(incoming, duration)
        outgoing = min(outgoing, duration)
        let total = incoming + outgoing
        if total > duration, total > 0 {
            let fit = duration / total
            incoming *= fit
            outgoing *= fit
        }
        return (incoming, outgoing)
    }

    // MARK: - Entry point

    /// `elapsed` is seconds from the title's VISIBLE start, so a trim shortens
    /// the animation with the clip instead of leaving it anchored to content
    /// that has been cut away. `duration` is the visible length.
    static func contribution(
        _ settings: TextAnimationSettings,
        elapsed: Double,
        duration: Double,
        fontSize: Double,
        clusters: Int
    ) -> Contribution {
        guard !settings.isEmpty, duration > 0 else { return .init() }
        let strength = min(max(settings.strength, 0), 1)
        let window = windows(settings, duration: duration)
        let time = min(max(elapsed, 0), duration)

        var result = Contribution()
        var states: [TextGlyphState]?

        // In, easing to neutral.
        var inProgress = 1.0
        if let preset = settings.incoming, window.incoming > 0 {
            inProgress = min(max(time / window.incoming, 0), 1)
            apply(preset, progress: inProgress, into: &result, states: &states,
                  strength: strength, fontSize: fontSize, clusters: clusters,
                  duration: window.incoming)
        }

        // Out, leaving neutral. Applied after In so a clip short enough for the
        // two to meet ends on the exit rather than the entrance.
        var outProgress = 0.0
        if let preset = settings.outgoing, window.outgoing > 0 {
            let start = duration - window.outgoing
            outProgress = min(max((time - start) / window.outgoing, 0), 1)
            if outProgress > 0 {
                apply(preset, progress: outProgress, into: &result, states: &states,
                      strength: strength, fontSize: fontSize, clusters: clusters,
                      duration: window.outgoing)
            }
        }

        // Loop, weighted so it can never fight the entrance or the exit: it is
        // silent while In is still arriving and while Out is already leaving,
        // and full in between. The PHASE keeps running throughout, so the loop
        // does not restart when it becomes audible.
        if let preset = settings.loop {
            let weight = inProgress * (1 - outProgress)
            if weight > 0.0001 {
                applyLoop(preset, elapsed: time, speed: settings.loopSpeed, weight: weight,
                          into: &result, states: &states,
                          strength: strength, fontSize: fontSize, clusters: clusters)
            }
        }

        if let states, states.contains(where: { !$0.isNeutral }) {
            result.effects.glyphStates = states
        }
        return result
    }

    // MARK: - Easing

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func easeIn(_ t: Double) -> Double { t * t * t }
    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func clamp01(_ t: Double) -> Double { min(max(t, 0), 1) }

    /// The state a title holds at the far end of an entrance — or the state it
    /// travels to at the far end of an exit. One description serves both, which
    /// is why Slide Up In and Slide Up Out are the same three numbers.
    private struct Extreme {
        var offsetX: Double = 0
        var offsetY: Double = 0
        var scale: Double = 1
        var rotationDegrees: Double = 0
        var opacity: Double = 1
        var tracking: Double = 0
        var blur: Double = 0

        /// Strength scales AMPLITUDE — distance, overshoot, angle, tracking,
        /// blur. Not opacity: a fade is a fade.
        func scaled(by strength: Double) -> Extreme {
            var value = self
            value.offsetX *= strength
            value.offsetY *= strength
            value.scale = 1 + (scale - 1) * strength
            value.rotationDegrees *= strength
            value.tracking *= strength
            value.blur *= strength
            return value
        }
    }

    /// Mixes an extreme towards neutral. A weight of 1 is the full extreme and 0
    /// is untouched — exactly what an entrance ends on and an exit starts from.
    ///
    /// Motion and fade are weighted SEPARATELY on purpose. Motion wants to
    /// decelerate in and accelerate out, which is what sells the movement; run
    /// opacity on those same curves and a fade spends most of its window
    /// invisible or nearly opaque and then jumps. Opacity gets a symmetric
    /// curve so it is genuinely half faded at the half way point.
    private static func blend(_ extreme: Extreme, motion: Double, fade: Double,
                              into result: inout Contribution) {
        result.offsetX += extreme.offsetX * motion
        result.offsetY += extreme.offsetY * motion
        result.scale *= lerp(1, extreme.scale, motion)
        result.rotationDegrees += extreme.rotationDegrees * motion
        result.tracking += extreme.tracking * motion
        result.effects.blurRadius += extreme.blur * motion
        result.opacity *= lerp(1, extreme.opacity, fade)
    }

    // MARK: - In and Out

    private static func apply(
        _ preset: TextAnimationPreset,
        progress: Double,
        into result: inout Contribution,
        states: inout [TextGlyphState]?,
        strength: Double,
        fontSize: Double,
        clusters: Int,
        duration: Double
    ) {
        let entering = preset.slot == .incoming
        // An entrance is "far away at 0, home at 1"; an exit is the mirror. One
        // number therefore drives both: how much of the extreme is showing.
        let progress = clamp01(progress)

        switch preset {
        case .typewriterIn:
            states = merge(states, typewriter(clusters: clusters, progress: progress, revealing: true))
            return
        case .characterPopIn:
            states = merge(states, characterStagger(clusters: clusters, progress: progress,
                                                    strength: strength, fontSize: fontSize,
                                                    popping: true, revealing: true))
            return
        case .characterFadeOut:
            states = merge(states, characterStagger(clusters: clusters, progress: progress,
                                                    strength: strength, fontSize: fontSize,
                                                    popping: false, revealing: false))
            return
        case .wipeIn:
            result.effects.wipeProgress = min(result.effects.wipeProgress, easeInOut(progress))
            result.effects.wipeDirection = .leftToRight
            return
        case .wipeOut:
            // Exits from the other side, so the title is swept away rather than
            // appearing to un-wipe back the way it came in.
            result.effects.wipeProgress = min(result.effects.wipeProgress, 1 - easeInOut(progress))
            result.effects.wipeDirection = .rightToLeft
            return
        case .popIn, .popOut:
            // Overshoot is not a straight line between two states, so Pop has
            // its own curve rather than an `Extreme`.
            let t = entering ? progress : 1 - progress
            let curve = popScale(t)
            result.scale *= 1 + (curve - 1) * strength
            result.opacity *= clamp01(t / 0.45)
            return
        default:
            break
        }

        let extreme = self.extreme(for: preset, fontSize: fontSize).scaled(by: strength)
        // Entrances decelerate into place; exits accelerate away.
        let motion = entering ? 1 - easeOut(progress) : easeIn(progress)
        let fade = entering ? 1 - easeInOut(progress) : easeInOut(progress)
        blend(extreme, motion: motion, fade: fade, into: &result)
    }

    /// Where a title sits at the far end of its entrance or exit.
    private static func extreme(for preset: TextAnimationPreset, fontSize: Double) -> Extreme {
        // Normalized canvas units for travel, so the motion reads the same on
        // any canvas. Layout points for tracking and blur, so they follow the
        // type size instead of the frame.
        let slide = 0.25
        let rise = 0.07
        let track = fontSize * 0.6
        let blur = fontSize * 0.28

        switch preset {
        case .fadeIn, .fadeOut:
            return Extreme(opacity: 0)
        case .slideUpIn, .slideUpOut:
            // positionY grows downwards, so an entrance from below is +.
            return Extreme(offsetY: preset == .slideUpIn ? slide : -slide, opacity: 0)
        case .slideDownIn, .slideDownOut:
            return Extreme(offsetY: preset == .slideDownIn ? -slide : slide, opacity: 0)
        case .slideLeftIn, .slideLeftOut:
            // "Left" names the direction of travel: in from the right, out to the left.
            return Extreme(offsetX: preset == .slideLeftIn ? slide : -slide, opacity: 0)
        case .slideRightIn, .slideRightOut:
            return Extreme(offsetX: preset == .slideRightIn ? -slide : slide, opacity: 0)
        case .zoomIn:
            return Extreme(scale: 0.4, opacity: 0)
        case .zoomOut:
            return Extreme(scale: 0.4, opacity: 0)
        case .scaleUpIn:
            return Extreme(scale: 0.85, opacity: 0)
        case .scaleDownOut:
            return Extreme(scale: 0.85, opacity: 0)
        case .rotateIn:
            return Extreme(scale: 0.9, rotationDegrees: -12, opacity: 0)
        case .rotateOut:
            return Extreme(scale: 0.9, rotationDegrees: 12, opacity: 0)
        case .riseIn:
            return Extreme(offsetY: rise, opacity: 0)
        case .sinkOut:
            return Extreme(offsetY: rise, opacity: 0)
        case .trackingIn, .trackingOut:
            return Extreme(opacity: 0, tracking: track)
        case .blurIn, .blurOut:
            return Extreme(opacity: 0, blur: blur)
        default:
            return Extreme()
        }
    }

    /// 0.65 → 1.10 → 1.0, with the overshoot settling in the last 40%.
    private static func popScale(_ t: Double) -> Double {
        let t = clamp01(t)
        if t < 0.6 { return lerp(0.65, 1.10, easeOut(t / 0.6)) }
        return lerp(1.10, 1.0, easeInOut((t - 0.6) / 0.4))
    }

    // MARK: - Loop

    /// One cycle of every loop at speed 1. Slow enough to read as a held
    /// gesture rather than a vibration.
    private static let loopPeriod = 2.0

    private static func applyLoop(
        _ preset: TextAnimationPreset,
        elapsed: Double,
        speed: Double,
        weight: Double,
        into result: inout Contribution,
        states: inout [TextGlyphState]?,
        strength: Double,
        fontSize: Double,
        clusters: Int
    ) {
        let speed = min(max(speed, 0.1), 4)
        let amount = strength * weight
        let phase = elapsed * speed * 2 * .pi / loopPeriod

        switch preset {
        case .pulse:
            result.scale *= 1 + 0.05 * amount * sin(phase)
        case .breathing:
            // Deliberately the quietest of them: half speed, and the opacity
            // only dips a tenth.
            let slow = sin(phase * 0.5)
            result.scale *= 1 + 0.035 * amount * slow
            result.opacity *= 1 - 0.09 * amount * (0.5 - slow * 0.5)
        case .float:
            result.offsetY += 0.013 * amount * sin(phase)
        case .bounce:
            // A ball's arc: quick fall, soft landing, never below the baseline.
            result.offsetY -= 0.022 * amount * abs(sin(phase))
        case .swing:
            result.rotationDegrees += 5 * amount * sin(phase)
        case .wiggle:
            // Two frequencies so it never settles into an obvious metronome.
            result.rotationDegrees += 3 * amount * sin(phase * 1.7)
            result.offsetX += 0.004 * amount * sin(phase * 2.3)
        case .trackingPulse:
            result.tracking += fontSize * 0.08 * amount * sin(phase)
        case .flicker:
            // Deterministic, and floored well above dark: two incommensurate
            // sines read as irregular without ever strobing.
            let noise = 0.5 + 0.5 * (sin(phase * 3.1) * 0.6 + sin(phase * 7.3) * 0.4)
            result.opacity *= 1 - 0.28 * amount * (1 - noise)
        case .wave:
            guard clusters > 0 else { return }
            var wave = [TextGlyphState](repeating: .neutral, count: clusters)
            let amplitude = fontSize * 0.16 * amount
            // A little under a full wavelength across the line, so the whole
            // title is visibly travelling rather than moving as one block.
            let spacing = 2 * Double.pi / Double(max(clusters, 6)) * 1.6
            for index in 0..<clusters {
                wave[index].offsetY = amplitude * sin(phase - Double(index) * spacing)
            }
            states = merge(states, wave)
        default:
            break
        }
    }

    // MARK: - Per-glyph

    /// Combines two sets of per-cluster states. In, Out and Loop can each ask
    /// for glyph animation in the same frame — a Wave running under a
    /// Typewriter has to both type and travel.
    private static func merge(_ existing: [TextGlyphState]?, _ incoming: [TextGlyphState]) -> [TextGlyphState] {
        guard let existing, existing.count == incoming.count else { return incoming }
        return zip(existing, incoming).map { a, b in
            TextGlyphState(opacity: a.opacity * b.opacity,
                           scale: a.scale * b.scale,
                           offsetX: a.offsetX + b.offsetX,
                           offsetY: a.offsetY + b.offsetY,
                           rotationDegrees: a.rotationDegrees + b.rotationDegrees)
        }
    }

    /// Clusters appear in reading order. Each gets a short ramp rather than a
    /// hard cut, which at any real frame rate reads as typing without the
    /// last letter flickering on a frame boundary.
    private static func typewriter(clusters: Int, progress: Double, revealing: Bool) -> [TextGlyphState] {
        guard clusters > 0 else { return [] }
        let progress = clamp01(progress)
        let step = 1.0 / Double(clusters)
        let ramp = max(step * 0.25, 0.0001)
        return (0..<clusters).map { index in
            let start = Double(index) * step
            let shown = clamp01((progress - start) / ramp)
            return TextGlyphState(opacity: revealing ? shown : 1 - shown)
        }
    }

    /// Per-cluster entrance or exit with a rolling start.
    ///
    /// The stagger is capped as a share of the window, so a hundred-character
    /// paragraph still finishes on time instead of taking a hundred steps —
    /// the characters simply overlap more.
    private static func characterStagger(
        clusters: Int, progress: Double, strength: Double, fontSize: Double,
        popping: Bool, revealing: Bool
    ) -> [TextGlyphState] {
        guard clusters > 0 else { return [] }
        let progress = clamp01(progress)
        // At most two thirds of the window is spent rolling, so every cluster
        // keeps at least a third of it to actually move in.
        let span = min(0.66, Double(clusters - 1) * 0.06)
        let each = max(1 - span, 0.15)
        let step = clusters > 1 ? span / Double(clusters - 1) : 0
        return (0..<clusters).map { index in
            let order = revealing ? index : clusters - 1 - index
            let local = clamp01((progress - Double(order) * step) / each)
            let shown = revealing ? local : 1 - local
            var state = TextGlyphState(opacity: easeInOut(shown))
            if popping {
                state.scale = 1 + (popScale(local) - 1) * strength
                state.offsetY = -fontSize * 0.12 * strength * (1 - easeOut(local))
            }
            return state
        }
    }
}

// MARK: - Composition with the manual keyframe engine

extension TextClip {
    /// The title as it should be drawn at a composition time: manual keyframes
    /// first, animation presets folded on top.
    ///
    /// This is THE funnel. Playback, a paused frame, a timeline scrub, a track
    /// matte and the exporter all come through here, so none of them can
    /// disagree about what the title looks like.
    func resolved(at composition: TimelineTime?) -> ResolvedTextClip {
        // Manual keyframes decide the authored value, exactly as before.
        var clip = composition.map { evaluated(at: $0) } ?? self
        guard let composition, let settings = textAnimation, !settings.isEmpty else {
            return ResolvedTextClip(clip: clip)
        }
        // Clip-local, measured from the VISIBLE start so a trim retimes the
        // animation with the clip. Never an absolute project timestamp.
        let elapsed = composition.seconds - placement.timelineStart.seconds
        let duration = placement.duration.seconds
        let contribution = TextAnimator.contribution(
            settings,
            elapsed: elapsed,
            duration: duration,
            fontSize: clip.style.fontSize,
            clusters: TextAnimator.clusterCount(of: clip)
        )
        // Relative, every one of them: the title still lands on whatever
        // position, scale, rotation and opacity the user authored or keyframed.
        clip.transform.positionX += contribution.offsetX
        clip.transform.positionY += contribution.offsetY
        clip.transform.scale *= contribution.scale
        clip.transform.rotationDegrees += contribution.rotationDegrees
        clip.opacity = min(max(clip.opacity * contribution.opacity, 0), 1)
        // Additive, so authored tracking is offset rather than overwritten.
        clip.style.characterSpacing += contribution.tracking
        return ResolvedTextClip(clip: clip, effects: contribution.effects)
    }
}

extension TextAnimator {
    /// How many grapheme clusters the renderer will lay out.
    ///
    /// Counted on the CASE-MAPPED string, because that is what CoreText is
    /// handed and uppercasing can change the length. Clusters rather than UTF-16
    /// units, so a ZWJ emoji family or a combining accent is one step of a
    /// typewriter, not four.
    static func clusterCount(of clip: TextClip) -> Int {
        TextRenderer.displayText(clip).count
    }
}
