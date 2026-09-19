import CoreMedia
import Foundation

/// Animation is persistent project data, evaluated identically by preview and export.
///
/// Times are CLIP-LOCAL. The composition clock is converted once, in one place:
///
///     animationTime = animation.startOffset + (compositionTime - placement.timelineStart)
///
/// `startOffset` is what makes clip lifecycle operations correct without rewriting
/// keyframes: trimming the head or splitting advances the offset, so both halves of a
/// split keep the *identical* keyframe list and simply read different windows of it.
/// Easing continuity across a split is therefore exact rather than approximated by an
/// inserted boundary keyframe, and trimming hides keyframes instead of destroying them.

// MARK: - Properties

/// Strongly typed property identity. Raw values are the persisted document keys.
enum AnimatableProperty: String, Codable, CaseIterable, Sendable {
    // Shared visual transform: text, video and image clips all use these.
    case positionX, positionY, scale, widthScale, heightScale, rotation, opacity
    // Structural layer-mask geometry.
    case layerMaskPositionX, layerMaskPositionY, layerMaskWidth, layerMaskHeight
    case layerMaskRotation, layerMaskFeather
    // Color → Local grading-window geometry.
    case localMaskPositionX, localMaskPositionY, localMaskWidth, localMaskHeight
    case localMaskRotation, localMaskFeather, localMaskOpacity
    // Masked local grades (power windows). Stored on the mask layer itself, so
    // several masks on one clip each carry their own tracks for these.
    case localMaskCornerRadius, localMaskStrength
    // Text typography and geometry.
    case fontSize, characterSpacing, lineSpacing, layoutWidth, curve
    // Shape geometry. A shape's KIND is not here on purpose: there is no
    // halfway point between a star and an arrow, so it stays a discrete choice
    // while everything measurable about the figure animates.
    case shapeWidth, shapeHeight, shapeInnerRadius
    // Text appearance.
    case strokeWidth, backgroundOpacity, cornerRadius, backgroundPadding
    case shadowOpacity, shadowRadius, shadowOffsetX, shadowOffsetY
    case glowOpacity, glowRadius
    // Colors.
    case textColor, strokeColor, backgroundColor, shadowColor, glowColor
    case fillColor

    // ---------------------------------------------------------------------
    // Colour grading.
    //
    // Grading parameters are ordinary animatable properties: the same track,
    // the same interpolation, the same diamond, the same document key. What
    // makes them grading properties is only where they READ AND WRITE, which
    // `GradeSlot` in GradeAnimation.swift decides. Nothing here knows about
    // colour, and there is no second keyframe engine.
    //
    // Everything below describes itself through `gradeSlot`, so adding a
    // grading parameter means adding a case and one line to that table rather
    // than editing every switch in this file.
    // ---------------------------------------------------------------------

    // Colour → Light.
    case gradeExposure, gradeContrast, gradeHighlights, gradeShadows, gradeWhites, gradeBlacks
    // Colour → Color.
    case gradeTemperature, gradeTint, gradeSaturation, gradeVibrance
    // Colour → HSL: eight bands, three values each.
    case hslRedHue, hslRedSaturation, hslRedLuminance
    case hslOrangeHue, hslOrangeSaturation, hslOrangeLuminance
    case hslYellowHue, hslYellowSaturation, hslYellowLuminance
    case hslGreenHue, hslGreenSaturation, hslGreenLuminance
    case hslAquaHue, hslAquaSaturation, hslAquaLuminance
    case hslBlueHue, hslBlueSaturation, hslBlueLuminance
    case hslPurpleHue, hslPurpleSaturation, hslPurpleLuminance
    case hslMagentaHue, hslMagentaSaturation, hslMagentaLuminance
    // Colour → Wheels.
    case wheelShadowsHue, wheelShadowsStrength, wheelShadowsBrightness
    case wheelMidtonesHue, wheelMidtonesStrength, wheelMidtonesBrightness
    case wheelHighlightsHue, wheelHighlightsStrength, wheelHighlightsBrightness
    // Colour → Vignette.
    case gradeVignette, gradeVignetteMidpoint, gradeVignetteFeather
    // Colour → Look. The look ITSELF stays a discrete choice; only its
    // strength animates, which is what a look fade-in is.
    case gradeLookIntensity
    // Colour → Effects.
    case effectFade, effectSharpen, effectBloom, effectGlow, effectHalation, effectGrain
    // Colour → Curves. One track per curve, each keyframe a WHOLE curve
    // snapshot rather than a per-control-point animation.
    case curveMaster, curveRed, curveGreen, curveBlue
    case curveHueVsHue, curveHueVsSaturation, curveHueVsLuma
    case curveLumaVsSaturation, curveSaturationVsSaturation, curveSaturationVsLuma

    enum Kind: Sendable { case number, color, curve }

    var kind: Kind {
        switch self {
        case .textColor, .strokeColor, .backgroundColor, .shadowColor, .glowColor, .fillColor: .color
        default: gradeSlot?.kind ?? .number
        }
    }

    /// Properties every visual clip type supports.
    static let transform: [Self] = [.positionX, .positionY, .scale, .widthScale, .heightScale, .rotation, .opacity]

    /// A shape's own geometry and appearance, in the order the inspector shows
    /// them. Kept beside `transform` so the two lists that describe a drawn
    /// layer sit together rather than one being buried in a clip extension.
    static let shape: [Self] = [
        .shapeWidth, .shapeHeight, .cornerRadius, .shapeInnerRadius,
        .fillColor, .strokeColor, .strokeWidth,
        .shadowColor, .shadowOpacity, .shadowRadius, .shadowOffsetX, .shadowOffsetY,
        .glowColor, .glowOpacity, .glowRadius
    ]

    var title: String {
        // Grading parameters name themselves through their slot.
        if let grade = gradeSlot { return grade.title }
        return switch self {
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .scale: "Scale"
        case .widthScale: "Width scale"
        case .heightScale: "Height scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .layerMaskPositionX, .localMaskPositionX: "Position X"
        case .layerMaskPositionY, .localMaskPositionY: "Position Y"
        case .layerMaskWidth, .localMaskWidth: "Width"
        case .layerMaskHeight, .localMaskHeight: "Height"
        case .layerMaskRotation, .localMaskRotation: "Rotation"
        case .layerMaskFeather, .localMaskFeather: "Feather"
        case .localMaskOpacity: "Mask opacity"
        case .localMaskCornerRadius: "Corner radius"
        case .localMaskStrength: "Strength"
        case .fontSize: "Font size"
        case .characterSpacing: "Character spacing"
        case .lineSpacing: "Line spacing"
        case .layoutWidth: "Wrap width"
        case .curve: "Curve"
        case .shapeWidth: "Width"
        case .shapeHeight: "Height"
        case .shapeInnerRadius: "Star waist"
        case .strokeWidth: "Stroke width"
        case .backgroundOpacity: "Background opacity"
        case .cornerRadius: "Corner radius"
        case .backgroundPadding: "Background padding"
        case .shadowOpacity: "Shadow opacity"
        case .shadowRadius: "Shadow blur"
        case .shadowOffsetX: "Shadow offset X"
        case .shadowOffsetY: "Shadow offset Y"
        case .glowOpacity: "Glow intensity"
        case .glowRadius: "Glow radius"
        case .textColor: "Text color"
        case .fillColor: "Fill"
        case .strokeColor: "Stroke color"
        case .backgroundColor: "Background color"
        case .shadowColor: "Shadow color"
        case .glowColor: "Glow color"
        // Only a grading property reaches here, and it was named above.
        default: rawValue
        }
    }

    /// Storable bounds. Chosen so an evaluated clip always satisfies `VideoProject.validate()`:
    /// linear, hold and the supported easings are monotone between two in-range values, so an
    /// interpolated result can never leave the range its neighbours are in.
    /// Rotation is deliberately wide — multi-turn spins are a legitimate authored value and
    /// must never be wrapped into ±180, which would silently cancel a 0° → 360° rotation.
    var range: ClosedRange<Double> {
        if let grade = gradeSlot { return grade.range }
        return switch self {
        case .positionX, .positionY: -10...10
        case .scale, .widthScale, .heightScale: 0.01...20
        case .rotation: -36_000...36_000
        case .opacity, .backgroundOpacity, .shadowOpacity, .glowOpacity,
             .layerMaskFeather, .localMaskFeather, .localMaskOpacity,
             .localMaskCornerRadius, .localMaskStrength: 0...1
        case .layerMaskPositionX, .layerMaskPositionY,
             .localMaskPositionX, .localMaskPositionY: 0...1
        case .layerMaskWidth, .layerMaskHeight,
             .localMaskWidth, .localMaskHeight: 0.01...2
        case .layerMaskRotation, .localMaskRotation: -180...180
        case .fontSize: 6...2048
        case .characterSpacing: -20...100
        case .lineSpacing: 0...300
        case .layoutWidth: 0.05...1.5
        case .curve: -1...1
        // Canvas points, like a font size: the shape's own dimensions before
        // `transform.scale` is applied on top of them.
        case .shapeWidth, .shapeHeight: 1...8192
        case .shapeInnerRadius: 0.05...0.95
        case .strokeWidth: 0...64
        case .cornerRadius, .backgroundPadding, .shadowRadius, .glowRadius: 0...2048
        case .shadowOffsetX, .shadowOffsetY: -2048...2048
        case .textColor, .strokeColor, .backgroundColor, .shadowColor, .glowColor, .fillColor: 0...1
        // Only a grading property reaches here, and it was bounded above.
        default: 0...1
        }
    }

    func clamped(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }

    /// Documented default, restored by "Reset this property".
    var defaultValue: KeyframeValue {
        if let grade = gradeSlot { return grade.defaultValue }
        return switch self {
        case .positionX, .positionY: .number(0.5)
        case .scale, .widthScale, .heightScale: .number(1)
        case .rotation: .number(0)
        case .opacity: .number(1)
        case .layerMaskPositionX, .layerMaskPositionY,
             .localMaskPositionX, .localMaskPositionY: .number(0.5)
        case .layerMaskWidth: .number(0.7)
        case .layerMaskHeight: .number(0.5)
        case .localMaskWidth: .number(0.6)
        case .localMaskHeight: .number(0.4)
        case .layerMaskRotation, .localMaskRotation: .number(0)
        case .layerMaskFeather: .number(0.12)
        case .localMaskFeather: .number(0.25)
        case .localMaskOpacity: .number(1)
        case .localMaskCornerRadius: .number(0)
        case .localMaskStrength: .number(1)
        case .fontSize: .number(64)
        case .characterSpacing, .lineSpacing: .number(0)
        case .layoutWidth: .number(0.8)
        case .curve: .number(0)
        case .shapeWidth, .shapeHeight: .number(480)
        case .shapeInnerRadius: .number(0.5)
        case .strokeWidth, .backgroundOpacity, .shadowOpacity, .glowOpacity, .cornerRadius: .number(0)
        case .backgroundPadding: .number(12)
        case .shadowRadius: .number(8)
        case .shadowOffsetX: .number(0)
        case .shadowOffsetY: .number(4)
        case .glowRadius: .number(12)
        case .textColor: .color(.white)
        case .fillColor: .color(ShapeClip.defaultFill)
        case .strokeColor, .backgroundColor, .shadowColor: .color(.black)
        case .glowColor: .color(.white)
        // Only a grading property reaches here; its neutral came from its slot.
        default: .number(0)
        }
    }
}

// MARK: - Values

/// Colors interpolate component-wise in the sRGB space they are authored and rendered in
/// (`CGColor(srgbRed:…)`), with alpha interpolated independently rather than premultiplied.
/// This keeps a fade to transparent from darkening on the way out.
enum KeyframeValue: Codable, Equatable, Sendable {
    case number(Double)
    case color(RGBAColor)
    /// A WHOLE curve at one moment.
    ///
    /// Curves are the one grading control whose value is not a scalar, and
    /// pairing individual control points across two keyframes is not something
    /// the document can guarantee: a user is free to add a point between one
    /// keyframe and the next. So a curve keyframe stores the complete curve and
    /// `AdvancedCurve.interpolated` blends the two by sampled height rather than
    /// by point identity. What is persisted is the authored control points; the
    /// GPU tables are always rebuilt from them.
    case curve(AdvancedCurve)

    var kind: AnimatableProperty.Kind {
        switch self { case .number: .number; case .color: .color; case .curve: .curve }
    }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var color: RGBAColor? { if case .color(let value) = self { return value }; return nil }
    var curve: AdvancedCurve? { if case .curve(let value) = self { return value }; return nil }

    var isFinite: Bool {
        switch self {
        case .number(let value): value.isFinite
        case .color(let c): [c.red, c.green, c.blue, c.alpha].allSatisfy(\.isFinite)
        case .curve(let c): c.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
    }

    func clamped(to property: AnimatableProperty) -> Self {
        switch self {
        // Angles are brought back into the circle by the interpolation that
        // produced them, not here: an authored 360 is a value the user asked
        // for and must not turn into 0 under their finger.
        case .number(let value): return .number(property.clamped(value))
        case .color(let c): return .color(.init(red: min(1, max(0, c.red)), green: min(1, max(0, c.green)),
                                                blue: min(1, max(0, c.blue)), alpha: min(1, max(0, c.alpha))))
        case .curve(let c): return .curve(c.clampedToCurveSpace)
        }
    }

    /// `fraction` is already eased and clamped to 0...1.
    ///
    /// `property` decides whether a number is a plain quantity or an angle; an
    /// angle takes the short way round the circle, so a hue animating from 350
    /// to 10 passes through 0 rather than unwinding backwards through 180.
    static func interpolate(
        _ from: Self, _ to: Self, _ fraction: Double,
        property: AnimatableProperty? = nil
    ) -> Self {
        switch (from, to) {
        case (.number(let a), .number(let b)):
            guard let cycle = property?.angularCycle, cycle > 0 else {
                return .number(a + (b - a) * fraction)
            }
            var delta = (b - a).truncatingRemainder(dividingBy: cycle)
            if delta > cycle / 2 { delta -= cycle } else if delta < -cycle / 2 { delta += cycle }
            let angle = a + delta * fraction
            // Going the short way from 350 to 10 passes through 360, which is
            // the same place as 0 but not the same NUMBER. Bringing it back into
            // the circle here rather than at the point of use is what keeps the
            // value a control reads identical to the one the shader is given.
            guard property?.wrapsAngularRange == true else { return .number(angle) }
            return .number(angle - (angle / cycle).rounded(.down) * cycle)
        case (.color(let a), .color(let b)):
            return .color(.init(red: a.red + (b.red - a.red) * fraction,
                                green: a.green + (b.green - a.green) * fraction,
                                blue: a.blue + (b.blue - a.blue) * fraction,
                                alpha: a.alpha + (b.alpha - a.alpha) * fraction))
        case (.curve(let a), .curve(let b)):
            return .curve(AdvancedCurve.interpolated(a, b, Float(fraction)))
        // Mismatched types cannot be produced by a validated document. Hold rather than guess.
        default: return from
        }
    }
}

// MARK: - Interpolation

enum KeyframeInterpolation: String, Codable, Sendable, CaseIterable {
    /// Constant speed between neighbours.
    case linear
    /// Step: this keyframe's value is held until the next keyframe's exact time.
    case hold
    case easeIn
    case easeOut
    case easeInOut

    var title: String {
        switch self {
        case .linear: "Linear"
        case .hold: "Hold"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In-Out"
        }
    }
    var symbol: String {
        switch self {
        case .linear: "line.diagonal"
        case .hold: "stairs"
        case .easeIn: "chart.line.uptrend.xyaxis"
        case .easeOut: "chart.line.downtrend.xyaxis"
        case .easeInOut: "chart.line.flattrend.xyaxis"
        }
    }

    /// Monotone on 0...1 with f(0)=0 and f(1)=1, so no easing can overshoot a property range.
    func eased(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        switch self {
        case .linear, .hold: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t * t * (3 - 2 * t)
        }
    }

    /// Unknown modes from a newer document recover to linear instead of failing the open.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .linear
    }
}

// MARK: - Keyframes

struct Keyframe: Codable, Equatable, Sendable {
    /// Clip-local time. Never a timeline coordinate.
    var time: TimelineTime
    var value: KeyframeValue
    /// Describes the segment LEAVING this keyframe. The last keyframe's mode is unused.
    var interpolation: KeyframeInterpolation = .linear

    private enum CodingKeys: String, CodingKey { case time, value, interpolation }
    init(time: TimelineTime, value: KeyframeValue, interpolation: KeyframeInterpolation = .linear) {
        self.time = time; self.value = value; self.interpolation = interpolation
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(TimelineTime.self, forKey: .time)
        value = try c.decode(KeyframeValue.self, forKey: .value)
        interpolation = try c.decodeIfPresent(KeyframeInterpolation.self, forKey: .interpolation) ?? .linear
    }
}

/// One property's ordered keyframes. Times are unique and strictly increasing.
struct AnimationTrack: Codable, Equatable, Sendable {
    let property: AnimatableProperty
    private(set) var keyframes: [Keyframe]

    static let keyframeLimit = 2000

    /// Scales every keyframe time by `factor`.
    ///
    /// Used when a clip's speed changes: keyframe times are clip-local timeline
    /// coordinates, so without this a 2× clip would push half its animation past
    /// its own end. Scaling keeps the animation where the eye expects it —
    /// proportionally in the same place, running at the new rate.
    func retimed(by factor: Double) -> AnimationTrack {
        guard factor.isFinite, factor > 0, factor != 1 else { return self }
        return AnimationTrack(property: property, keyframes: keyframes.map { keyframe in
            var scaled = keyframe
            if let time = try? TimelineTime(CMTimeMultiplyByFloat64(
                keyframe.time.cmTime, multiplier: factor)) {
                scaled.time = time
            }
            return scaled
        })
    }

    init(property: AnimatableProperty, keyframes: [Keyframe] = []) {
        self.property = property
        self.keyframes = keyframes
        normalize()
    }

    private enum CodingKeys: String, CodingKey { case property, keyframes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        property = try c.decode(AnimatableProperty.self, forKey: .property)
        keyframes = try c.decode([Keyframe].self, forKey: .keyframes)
        normalize()
    }

    /// Sorts and removes duplicate frames. A malformed document recovers to a usable
    /// track here; `VideoProject.validate()` still rejects values it cannot render.
    private mutating func normalize() {
        keyframes.sort { $0.time < $1.time }
        var deduped: [Keyframe] = []
        for frame in keyframes {
            if deduped.last?.time == frame.time { deduped[deduped.count - 1] = frame }
            else { deduped.append(frame) }
        }
        if deduped.count > Self.keyframeLimit { deduped = Array(deduped.prefix(Self.keyframeLimit)) }
        keyframes = deduped
    }

    var isEmpty: Bool { keyframes.isEmpty }

    func index(at time: TimelineTime) -> Int? { keyframes.firstIndex { $0.time == time } }
    func keyframe(at time: TimelineTime) -> Keyframe? { index(at: time).map { keyframes[$0] } }
    func previous(before time: TimelineTime) -> Keyframe? { keyframes.last { $0.time < time } }
    func next(after time: TimelineTime) -> Keyframe? { keyframes.first { $0.time > time } }

    /// Inserts, or replaces the keyframe already on that exact frame.
    mutating func set(_ value: KeyframeValue, at time: TimelineTime, interpolation: KeyframeInterpolation? = nil) {
        let clamped = value.clamped(to: property)
        if let index = index(at: time) {
            keyframes[index].value = clamped
            if let interpolation { keyframes[index].interpolation = interpolation }
            return
        }
        guard keyframes.count < Self.keyframeLimit else { return }
        // A new keyframe inherits the curve of the segment it lands in, so inserting a
        // point inside an eased span does not silently turn that span linear.
        let inherited = interpolation ?? previous(before: time)?.interpolation ?? keyframes.first?.interpolation ?? .linear
        keyframes.append(.init(time: time, value: clamped, interpolation: inherited))
        normalize()
    }

    mutating func remove(at time: TimelineTime) {
        keyframes.removeAll { $0.time == time }
    }

    mutating func setInterpolation(_ mode: KeyframeInterpolation, at time: TimelineTime) {
        guard let index = index(at: time) else { return }
        keyframes[index].interpolation = mode
    }

    /// Retiming policy: a keyframe never destroys a neighbour. The move is clamped to stay
    /// strictly between the adjacent keyframes, and callers clamp again to the clip range.
    /// Returns the time actually used.
    @discardableResult
    mutating func move(from: TimelineTime, to requested: TimelineTime, minimumSpacing: TimelineTime) -> TimelineTime? {
        guard let index = index(at: from) else { return nil }
        var target = requested
        if index > 0, let floor = try? keyframes[index - 1].time.adding(minimumSpacing), target < floor { target = floor }
        if index + 1 < keyframes.count, let ceiling = try? keyframes[index + 1].time.subtracting(minimumSpacing), target > ceiling { target = ceiling }
        if target < .zero { target = .zero }
        // Clamping can collapse onto a neighbour when there is no room at all; keep the
        // existing time rather than overwriting one.
        if keyframes.indices.contains(index - 1), keyframes[index - 1].time == target { return keyframes[index].time }
        if keyframes.indices.contains(index + 1), keyframes[index + 1].time == target { return keyframes[index].time }
        keyframes[index].time = target
        normalize()
        return target
    }

    /// Shifts every keyframe by a signed amount. Used when a clip's head moves.
    mutating func shift(by delta: TimelineTime) {
        keyframes = keyframes.compactMap { frame in
            guard let time = try? frame.time.adding(delta) else { return nil }
            return Keyframe(time: time, value: frame.value, interpolation: frame.interpolation)
        }
        normalize()
    }

    /// Evaluated value, or nil when the track carries no keyframes.
    ///
    /// - Before the first keyframe: that keyframe's value.
    /// - After the last: that keyframe's value.
    /// - Exactly one keyframe: constant.
    /// - Between two: interpolated with the LEFT keyframe's mode.
    func value(at time: TimelineTime) -> KeyframeValue? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        // Exact rational comparison: never a floating-point tolerance.
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        var lower = 0, upper = keyframes.count - 1
        while upper - lower > 1 {
            let mid = (lower + upper) / 2
            if keyframes[mid].time <= time { lower = mid } else { upper = mid }
        }
        let start = keyframes[lower], end = keyframes[upper]
        if start.interpolation == .hold { return start.value }
        guard let span = try? end.time.subtracting(start.time), span > .zero,
              let elapsed = try? time.subtracting(start.time) else { return start.value }
        // Only the position WITHIN a segment is real-valued; segment choice stayed exact.
        let fraction = elapsed.seconds / span.seconds
        return KeyframeValue.interpolate(start.value, end.value, start.interpolation.eased(fraction),
                                         property: property)
    }
}

/// Every animated property on one clip.
struct ClipAnimation: Codable, Equatable, Sendable {
    var tracks: [AnimationTrack] = []
    /// Clip-local time corresponding to the clip's first frame. Advanced by head trims
    /// and splits so animation outside the visible range is hidden, never discarded.
    var startOffset: TimelineTime = .zero

    /// Scales every track and the animation window together, so the animation
    /// keeps its position relative to the clip's visible range.
    func retimed(by factor: Double) -> ClipAnimation {
        guard factor.isFinite, factor > 0, factor != 1 else { return self }
        var copy = self
        copy.tracks = tracks.map { $0.retimed(by: factor) }
        if let offset = try? TimelineTime(CMTimeMultiplyByFloat64(
            startOffset.cmTime, multiplier: factor)) {
            copy.startOffset = offset
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey { case tracks, startOffset }
    init(tracks: [AnimationTrack] = [], startOffset: TimelineTime = .zero) {
        self.tracks = tracks; self.startOffset = startOffset
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decode([AnimationTrack].self, forKey: .tracks)
        startOffset = try c.decodeIfPresent(TimelineTime.self, forKey: .startOffset) ?? .zero
    }

    var isEmpty: Bool { tracks.allSatisfy(\.isEmpty) }
    var animatedProperties: [AnimatableProperty] { tracks.filter { !$0.isEmpty }.map(\.property) }
    func track(_ property: AnimatableProperty) -> AnimationTrack? {
        tracks.first { $0.property == property && !$0.keyframes.isEmpty }
    }

    mutating func update(_ property: AnimatableProperty, _ edit: (inout AnimationTrack) -> Void) {
        if let index = tracks.firstIndex(where: { $0.property == property }) {
            edit(&tracks[index])
            if tracks[index].isEmpty { tracks.remove(at: index) }
        } else {
            var track = AnimationTrack(property: property)
            edit(&track)
            if !track.isEmpty { tracks.append(track) }
        }
    }

    mutating func removeAnimation(of property: AnimatableProperty) {
        tracks.removeAll { $0.property == property }
    }

    /// Clip-local time for a composition time, given where the clip starts on the timeline.
    func localTime(for composition: TimelineTime, clipStart: TimelineTime) -> TimelineTime? {
        guard let elapsed = try? composition.subtracting(clipStart),
              let local = try? startOffset.adding(elapsed) else { return nil }
        return local
    }

    /// The inverse, for seeking the playhead to a keyframe.
    func compositionTime(forLocal local: TimelineTime, clipStart: TimelineTime) -> TimelineTime? {
        guard let elapsed = try? local.subtracting(startOffset) else { return nil }
        return try? clipStart.adding(elapsed)
    }
}

// MARK: - Diamond state

/// What the keyframe diamond beside a property is showing.
///
/// Top level rather than nested in a view model because grading controls now
/// ask for it too, and the still-image editor — which has no timeline and so no
/// keyframes at all — must be able to name the type without importing one.
enum AnimationKeyframeState: Equatable, Sendable {
    /// No animation: changing the value changes the base value.
    case off
    /// Animated, but no keyframe on this exact frame.
    case animated
    /// A keyframe sits on this exact frame.
    case onKeyframe
}
