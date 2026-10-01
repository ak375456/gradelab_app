import Foundation

/// Binds `AnimatableProperty` to real, strongly typed storage on a clip.
///
/// Evaluation always returns a COPY. Authored values are never mutated by playback,
/// scrubbing or export, so evaluating cannot dirty the project or trigger autosave.
protocol AnimatableClip: TimelineClip {
    var animation: ClipAnimation? { get set }
    /// Properties this clip type can animate, in the order the inspector shows them.
    static var animatableProperties: [AnimatableProperty] { get }
    static func numberKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<Self, Double>?
    static func colorKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<Self, RGBAColor>?
    static func supports(_ property: AnimatableProperty) -> Bool
    /// Requirements rather than extension methods so a clip type whose storage a
    /// key path cannot address cheaply — a video clip's grade, which lives
    /// behind optional collections — can substitute a direct implementation that
    /// the whole engine, `evaluated(atLocal:)` included, then uses.
    func baseValue(of property: AnimatableProperty) -> KeyframeValue?
    mutating func setBaseValue(_ value: KeyframeValue, of property: AnimatableProperty)
    /// True when this clip carries animation that has to stay glued to its
    /// content through a head trim or a split, even if `animation` itself is
    /// empty — a clip whose only keyframes are on its masks still has a window.
    var maintainsAnimationWindow: Bool { get }
}

extension AnimatableClip {
    static func supports(_ property: AnimatableProperty) -> Bool { supportsKeyPath(property) }

    static func supportsKeyPath(_ property: AnimatableProperty) -> Bool {
        numberKeyPath(property) != nil || colorKeyPath(property) != nil
    }

    var isAnimated: Bool { animation.map { !$0.isEmpty } ?? false }
    var maintainsAnimationWindow: Bool { isAnimated }

    /// The authored (base) value, used when a property has no animation and as the
    /// starting point for the first keyframe a user adds.
    func baseValue(of property: AnimatableProperty) -> KeyframeValue? { keyPathValue(of: property) }

    func keyPathValue(of property: AnimatableProperty) -> KeyframeValue? {
        if let key = Self.numberKeyPath(property) { return .number(self[keyPath: key]) }
        if let key = Self.colorKeyPath(property) { return .color(self[keyPath: key]) }
        return nil
    }

    mutating func setBaseValue(_ value: KeyframeValue, of property: AnimatableProperty) {
        setKeyPathValue(value, of: property)
    }

    mutating func setKeyPathValue(_ value: KeyframeValue, of property: AnimatableProperty) {
        switch value {
        case .number(let number):
            if let key = Self.numberKeyPath(property) { self[keyPath: key] = property.clamped(number) }
        case .color(let color):
            if let key = Self.colorKeyPath(property) { self[keyPath: key] = color }
        case .curve:
            break
        }
    }

    /// Value actually rendered at a clip-local time: the animated value when the property
    /// is animated, otherwise the authored base value.
    func evaluatedValue(of property: AnimatableProperty, atLocal local: TimelineTime) -> KeyframeValue? {
        if let track = animation?.track(property), let value = track.value(at: local) { return value }
        return baseValue(of: property)
    }

    /// A copy with every animated property substituted for this clip-local time.
    func evaluated(atLocal local: TimelineTime) -> Self {
        guard let animation, !animation.isEmpty else { return self }
        var copy = self
        for track in animation.tracks {
            guard let value = track.value(at: local)?.clamped(to: track.property) else { continue }
            copy.setBaseValue(value, of: track.property)
        }
        return copy
    }

    /// A copy substituted for a COMPOSITION time. The single conversion point between the
    /// timeline clock and clip-local animation time.
    func evaluated(at composition: TimelineTime) -> Self {
        guard let animation, !animation.isEmpty,
              let local = animation.localTime(for: composition, clipStart: placement.timelineStart) else { return self }
        return evaluated(atLocal: local)
    }

    func localTime(for composition: TimelineTime) -> TimelineTime? {
        (animation ?? ClipAnimation()).localTime(for: composition, clipStart: placement.timelineStart)
    }

    /// Clip-local time only when the playhead is actually inside the clip, which
    /// is the question "may an animated value be written here?" really asks.
    func localTimeInside(_ composition: TimelineTime) -> TimelineTime? {
        guard let end = try? placement.range.end,
              composition >= placement.timelineStart, composition < end else { return nil }
        return localTime(for: composition)
    }

    /// The clip's head moved on the timeline while its CONTENT stayed put — a head trim or
    /// the right side of a split. Shifting the window keeps every keyframe: nothing outside
    /// the visible range is discarded, so extending the trim again restores it, and both
    /// halves of a split keep the identical curve rather than an interpolated approximation.
    ///
    /// The offset may go negative when a head is extended earlier than the animation origin.
    /// That is meaningful: evaluation then holds the first keyframe, so the animation stays
    /// glued to the content instead of sliding along with the new edge.
    mutating func shiftAnimationWindow(by delta: TimelineTime) {
        guard maintainsAnimationWindow, delta != .zero else { return }
        var animation = self.animation ?? ClipAnimation()
        guard let offset = try? animation.startOffset.adding(delta) else { return }
        animation.startOffset = offset
        self.animation = animation
    }
}

/// One authoring operation, so the view model can route the SAME rules to text, video and
/// image clips without a parallel implementation. `AnimatableClip` has `Self` requirements
/// and cannot be an existential, so the operation is reified instead of the clip.
enum AnimationEdit {
    case toggleKeyframe(AnimatableProperty, atLocal: TimelineTime)
    case setValue(AnimatableProperty, KeyframeValue, atLocal: TimelineTime?)
    /// Moves a number by a relative amount. Carries a COMPOSITION time, not a
    /// clip-local one, because the clips in a multiple selection start at
    /// different points and each has to resolve its own local time - one shared
    /// local time would land on the wrong frame of every clip but the first.
    case offsetValue(AnimatableProperty, by: Double, atComposition: TimelineTime)
    case removeKeyframe(AnimatableProperty, atLocal: TimelineTime)
    case removeAnimation(AnimatableProperty, atLocal: TimelineTime?)
    case resetProperty(AnimatableProperty)
    case removeAllAnimation(atLocal: TimelineTime?)
    case setInterpolation(KeyframeInterpolation, AnimatableProperty, atLocal: TimelineTime)
    case moveKeyframe(AnimatableProperty, from: TimelineTime, to: TimelineTime, spacing: TimelineTime)
}

/// A read-only view of either clip type, so the UI can query one shape.
struct AnimationSnapshot {
    let placement: ItemPlacement
    let animation: ClipAnimation?
    let isAnimated: Bool
    let supports: (AnimatableProperty) -> Bool
    let evaluatedValue: (AnimatableProperty, TimelineTime) -> KeyframeValue?
    let visibleKeyframes: (AnimatableProperty) -> [(local: TimelineTime, timeline: TimelineTime)]
    let keyframeSeconds: [Double]

    init<Clip: AnimatableClip>(_ clip: Clip) {
        placement = clip.placement
        animation = clip.animation
        isAnimated = clip.isAnimated
        supports = { Clip.supports($0) }
        evaluatedValue = { clip.evaluatedValue(of: $0, atLocal: $1) }
        visibleKeyframes = { clip.visibleKeyframes($0) }
        keyframeSeconds = clip.visibleKeyframeSeconds
    }

    /// A video clip's masked local grades keep their keyframes on the mask
    /// rather than on the clip, so the timeline's indicators would miss them.
    /// The concrete initialiser is chosen at the call site, which is exactly
    /// where the clip type is known.
    init(_ clip: VideoClip) {
        placement = clip.placement
        animation = clip.animation
        isAnimated = clip.isAnimated || clip.resolvedMaskedGrades.contains(where: \.isAnimated)
            || clip.hasRelightAnimation
        supports = { VideoClip.supports($0) }
        evaluatedValue = { clip.evaluatedValue(of: $0, atLocal: $1) }
        visibleKeyframes = { clip.visibleKeyframes($0) }
        keyframeSeconds = clip.allVisibleKeyframeSeconds
    }

    /// Clip-local time for a timeline time, whether or not it falls inside the clip.
    func localTime(for composition: TimelineTime) -> TimelineTime? {
        (animation ?? ClipAnimation()).localTime(for: composition, clipStart: placement.timelineStart)
    }
    /// Clip-local time only when the playhead is actually inside the clip.
    func localTimeInside(_ composition: TimelineTime) -> TimelineTime? {
        guard let end = try? placement.range.end,
              composition >= placement.timelineStart, composition < end else { return nil }
        return localTime(for: composition)
    }
}

// MARK: - Authoring operations
//
// The editing rules live here, generically, so text and video share one implementation
// and can be tested without any view model.

extension AnimatableClip {
    /// Diamond tap: add a keyframe holding the value currently on screen, or remove the
    /// keyframe on this exact frame. Only ever touches `property`.
    mutating func toggleKeyframe(_ property: AnimatableProperty, atLocal local: TimelineTime) {
        var animation = self.animation ?? ClipAnimation()
        let onScreen = evaluatedValue(of: property, atLocal: local)
        if animation.track(property)?.index(at: local) != nil {
            animation.update(property) { $0.remove(at: local) }
            // Removing the last keyframe keeps what was visible as the new base value.
            if animation.track(property) == nil, let onScreen { setBaseValue(onScreen, of: property) }
        } else if let onScreen {
            animation.update(property) { $0.set(onScreen, at: local) }
        }
        self.animation = animation.isEmpty ? nil : animation
    }

    /// Adds `delta` to a number, leaving every other layer's own value intact.
    ///
    /// Unanimated: shifts the base value. Animated: writes a keyframe at this
    /// frame, seeded from what is on screen. A property animated on a clip the
    /// playhead is outside of is left alone - there is no frame to write to.
    mutating func offsetValue(_ property: AnimatableProperty, by delta: Double, atComposition composition: TimelineTime) {
        guard animation?.track(property) != nil else {
            guard let current = baseValue(of: property)?.number else { return }
            setBaseValue(.number(current + delta), of: property)
            return
        }
        guard let local = localTimeInside(composition),
              let current = evaluatedValue(of: property, atLocal: local)?.number else { return }
        setValue(.number(current + delta), of: property, atLocal: local)
    }

    /// The single write rule.
    /// Unanimated: change the base value, creating no animation.
    /// Animated: update the keyframe on this frame, or insert one here.
    /// Returns false when an animated property was edited with no valid local time.
    @discardableResult
    mutating func setValue(_ value: KeyframeValue, of property: AnimatableProperty, atLocal local: TimelineTime?) -> Bool {
        guard animation?.track(property) != nil else { setBaseValue(value, of: property); return true }
        guard let local else { return false }
        var animation = self.animation ?? ClipAnimation()
        animation.update(property) { $0.set(value, at: local) }
        self.animation = animation
        return true
    }

    mutating func removeKeyframe(_ property: AnimatableProperty, atLocal local: TimelineTime) {
        guard var animation = self.animation else { return }
        let onScreen = evaluatedValue(of: property, atLocal: local)
        animation.update(property) { $0.remove(at: local) }
        if animation.track(property) == nil, let onScreen { setBaseValue(onScreen, of: property) }
        self.animation = animation.isEmpty ? nil : animation
    }

    /// Stops animating but keeps the value currently on screen.
    mutating func removeAnimation(of property: AnimatableProperty, atLocal local: TimelineTime?) {
        guard var animation = self.animation else { return }
        let onScreen = local.flatMap { evaluatedValue(of: property, atLocal: $0) }
        animation.removeAnimation(of: property)
        self.animation = animation.isEmpty ? nil : animation
        if let onScreen { setBaseValue(onScreen, of: property) }
    }

    /// Restores the documented default AND clears the property's animation.
    mutating func resetProperty(_ property: AnimatableProperty) {
        if var animation = self.animation {
            animation.removeAnimation(of: property)
            self.animation = animation.isEmpty ? nil : animation
        }
        setBaseValue(property.defaultValue, of: property)
    }

    mutating func removeAllAnimation(atLocal local: TimelineTime?) {
        guard let animation = self.animation else { return }
        let held = local.map { local in
            animation.animatedProperties.compactMap { property -> (AnimatableProperty, KeyframeValue)? in
                evaluatedValue(of: property, atLocal: local).map { (property, $0) }
            }
        } ?? []
        self.animation = nil
        for (property, value) in held { setBaseValue(value, of: property) }
    }

    mutating func setInterpolation(_ mode: KeyframeInterpolation, of property: AnimatableProperty, atLocal local: TimelineTime) {
        animation?.update(property) { $0.setInterpolation(mode, at: local) }
    }

    mutating func moveKeyframe(_ property: AnimatableProperty, from: TimelineTime, to target: TimelineTime, minimumSpacing: TimelineTime) {
        animation?.update(property) { $0.move(from: from, to: target, minimumSpacing: minimumSpacing) }
    }

    mutating func apply(_ edit: AnimationEdit) {
        switch edit {
        case .toggleKeyframe(let property, let local): toggleKeyframe(property, atLocal: local)
        case .setValue(let property, let value, let local): setValue(value, of: property, atLocal: local)
        case .offsetValue(let property, let delta, let composition):
            offsetValue(property, by: delta, atComposition: composition)
        case .removeKeyframe(let property, let local): removeKeyframe(property, atLocal: local)
        case .removeAnimation(let property, let local): removeAnimation(of: property, atLocal: local)
        case .resetProperty(let property): resetProperty(property)
        case .removeAllAnimation(let local): removeAllAnimation(atLocal: local)
        case .setInterpolation(let mode, let property, let local): setInterpolation(mode, of: property, atLocal: local)
        case .moveKeyframe(let property, let from, let to, let spacing):
            moveKeyframe(property, from: from, to: to, minimumSpacing: spacing)
        }
    }

    /// Keyframes in TIMELINE coordinates, restricted to the range the clip occupies, so
    /// navigation never seeks to a keyframe hidden by a trim.
    func visibleKeyframes(_ property: AnimatableProperty) -> [(local: TimelineTime, timeline: TimelineTime)] {
        guard let animation, let track = animation.track(property), let end = try? placement.range.end else { return [] }
        return track.keyframes.compactMap { frame in
            guard let time = animation.compositionTime(forLocal: frame.time, clipStart: placement.timelineStart),
                  time >= placement.timelineStart, time < end else { return nil }
            return (frame.time, time)
        }
    }

    /// Every keyframe on the clip, deduplicated, in timeline seconds.
    var visibleKeyframeSeconds: [Double] {
        guard let animation else { return [] }
        var seen = Set<Int64>()
        var result: [Double] = []
        for track in animation.tracks {
            for entry in visibleKeyframes(track.property) where seen.insert(Int64((entry.timeline.seconds * 100_000).rounded())).inserted {
                result.append(entry.timeline.seconds)
            }
        }
        return result.sorted()
    }
}

// MARK: - Text

extension TextClip: AnimatableClip {
    static let animatableProperties: [AnimatableProperty] =
        AnimatableProperty.transform + [
            .fontSize, .characterSpacing, .lineSpacing, .layoutWidth, .curve,
            .textColor, .strokeColor, .strokeWidth,
            .backgroundColor, .backgroundOpacity, .backgroundPadding, .cornerRadius,
            .shadowColor, .shadowOpacity, .shadowRadius, .shadowOffsetX, .shadowOffsetY,
            .glowColor, .glowOpacity, .glowRadius
        ]

    static func numberKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<TextClip, Double>? {
        switch property {
        case .positionX: \.transform.positionX
        case .positionY: \.transform.positionY
        case .scale: \.transform.scale
        case .widthScale: \.transform.widthScale
        case .heightScale: \.transform.heightScale
        case .rotation: \.transform.rotationDegrees
        case .opacity: \.opacity
        case .fontSize: \.style.fontSize
        case .characterSpacing: \.style.characterSpacing
        case .lineSpacing: \.style.lineSpacing
        case .layoutWidth: \.style.layoutWidth
        case .curve: \.curve
        case .strokeWidth: \.strokeWidth
        case .backgroundOpacity: \.backgroundOpacity
        case .cornerRadius: \.cornerRadius
        case .backgroundPadding: \.decorationPadding
        case .shadowOpacity: \.shadowOpacity
        case .shadowRadius: \.shadowRadius
        case .shadowOffsetX: \.shadowOffsetX
        case .shadowOffsetY: \.shadowOffsetY
        case .glowOpacity: \.glowOpacity
        case .glowRadius: \.decorationGlowRadius
        default: nil
        }
    }

    static func colorKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<TextClip, RGBAColor>? {
        switch property {
        case .textColor: \.color
        case .strokeColor: \.strokeColor
        case .backgroundColor: \.backgroundColor
        case .shadowColor: \.decorationShadowColor
        case .glowColor: \.decorationGlowColor
        default: nil
        }
    }
}

/// `decoration` is optional storage; these give the animator real writable key paths
/// without changing how the model persists.
extension TextClip {
    var decorationPadding: Double {
        get { (decoration ?? .init()).padding }
        set { var d = decoration ?? .init(); d.padding = newValue; decoration = d }
    }
    var decorationGlowRadius: Double {
        get { (decoration ?? .init()).glowRadius }
        set { var d = decoration ?? .init(); d.glowRadius = newValue; decoration = d }
    }
    var decorationShadowColor: RGBAColor {
        get { (decoration ?? .init()).shadowColor }
        set { var d = decoration ?? .init(); d.shadowColor = newValue; decoration = d }
    }
    var decorationGlowColor: RGBAColor {
        get { (decoration ?? .init()).glowColor }
        set { var d = decoration ?? .init(); d.glowColor = newValue; decoration = d }
    }
}

// MARK: - Shapes

/// A shape animates for exactly one reason: it is an `AnimatableClip`. There is
/// no shape-specific animation code anywhere — the tracks, the interpolation,
/// the diamond, the split and trim behaviour and the document format are the
/// ones text and video already use.
extension ShapeClip: AnimatableClip {
    static let animatableProperties: [AnimatableProperty] =
        AnimatableProperty.transform + AnimatableProperty.shape

    static func numberKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<ShapeClip, Double>? {
        switch property {
        case .positionX: \.transform.positionX
        case .positionY: \.transform.positionY
        case .scale: \.transform.scale
        case .widthScale: \.transform.widthScale
        case .heightScale: \.transform.heightScale
        case .rotation: \.transform.rotationDegrees
        case .opacity: \.opacity
        case .shapeWidth: \.width
        case .shapeHeight: \.height
        case .shapeInnerRadius: \.innerRadius
        case .cornerRadius: \.cornerRadius
        case .strokeWidth: \.strokeWidth
        case .shadowOpacity: \.shadowOpacity
        case .shadowRadius: \.shadowRadius
        case .shadowOffsetX: \.shadowOffsetX
        case .shadowOffsetY: \.shadowOffsetY
        case .glowOpacity: \.glowOpacity
        case .glowRadius: \.glowRadius
        default: nil
        }
    }

    static func colorKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<ShapeClip, RGBAColor>? {
        switch property {
        case .fillColor: \.fillColor
        case .strokeColor: \.strokeColor
        case .shadowColor: \.shadowColor
        case .glowColor: \.glowColor
        default: nil
        }
    }
}

// MARK: - Video and image

extension VideoClip: AnimatableClip {
    static let animatableProperties: [AnimatableProperty] = AnimatableProperty.transform + [
        .layerMaskPositionX, .layerMaskPositionY, .layerMaskWidth, .layerMaskHeight,
        .layerMaskRotation, .layerMaskFeather,
        .localMaskPositionX, .localMaskPositionY, .localMaskWidth, .localMaskHeight,
        .localMaskRotation, .localMaskFeather, .localMaskOpacity
    ] + AnimatableProperty.gradeProperties

    /// Grading joins the transform properties rather than being checked
    /// separately, so validation, `AnimationSnapshot` and the inspector all see
    /// one list.
    static func supports(_ property: AnimatableProperty) -> Bool {
        supportsKeyPath(property) || property.isGradeProperty
    }

    /// The grade is read and written directly rather than through a key path.
    ///
    /// `gradeSettings` reaches its parameters through optional collections, so a
    /// key path into one would have to be built per call — on the render thread,
    /// once per animated property per frame. This is the same rule the key-path
    /// path applies, without the allocation.
    func baseValue(of property: AnimatableProperty) -> KeyframeValue? {
        if property.isGradeProperty { return gradeSettings.gradeValue(property) }
        return keyPathValue(of: property)
    }

    mutating func setBaseValue(_ value: KeyframeValue, of property: AnimatableProperty) {
        guard property.isGradeProperty else { return setKeyPathValue(value, of: property) }
        gradeSettings.setGradeValue(value.clamped(to: property), for: property)
    }

    /// A clip whose only keyframes are on its masked local grades still needs
    /// its animation window moved by a trim or a split, or the mask animation
    /// would slide against the picture it was drawn on.
    var maintainsAnimationWindow: Bool {
        isAnimated || (maskedGrades?.contains(where: \.isAnimated) ?? false) || hasRelightAnimation
    }

    static func numberKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<VideoClip, Double>? {
        switch property {
        case .positionX: \.transform.positionX
        case .positionY: \.transform.positionY
        case .scale: \.transform.scale
        case .widthScale: \.transform.widthScale
        case .heightScale: \.transform.heightScale
        case .rotation: \.transform.rotationDegrees
        case .opacity: \.opacity
        case .layerMaskPositionX: \.animatedLayerMaskCenterX
        case .layerMaskPositionY: \.animatedLayerMaskCenterY
        case .layerMaskWidth: \.animatedLayerMaskWidth
        case .layerMaskHeight: \.animatedLayerMaskHeight
        case .layerMaskRotation: \.animatedLayerMaskRotation
        case .layerMaskFeather: \.animatedLayerMaskFeather
        case .localMaskPositionX: \.animatedLocalMaskCenterX
        case .localMaskPositionY: \.animatedLocalMaskCenterY
        case .localMaskWidth: \.animatedLocalMaskWidth
        case .localMaskHeight: \.animatedLocalMaskHeight
        case .localMaskRotation: \.animatedLocalMaskRotation
        case .localMaskFeather: \.animatedLocalMaskFeather
        case .localMaskOpacity: \.animatedLocalMaskOpacity
        default: nil
        }
    }

    static func colorKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<VideoClip, RGBAColor>? { nil }
}

// MARK: - Effective grade

extension VideoClip {
    /// The grade as actually rendered at a clip-local time: the base grade with
    /// every animated parameter substituted.
    ///
    /// This is the whole of "effective grade". There is no separate resolved
    /// type, because a resolved grade is exactly a `GradeSettings` with no
    /// keyframes left in it — which is what every consumer already takes.
    func effectiveGrade(atLocal local: TimelineTime) -> GradeSettings {
        guard let animation, !animation.isEmpty else { return gradeSettings }
        var resolved = gradeSettings
        for track in animation.tracks where track.property.isGradeProperty {
            guard let value = track.value(at: local) else { continue }
            resolved.setGradeValue(value.clamped(to: track.property), for: track.property)
        }
        return resolved
    }

    /// The same for a composition time, through the single clock conversion.
    func effectiveGrade(at composition: TimelineTime) -> GradeSettings {
        guard let local = localTime(for: composition) else { return gradeSettings }
        return effectiveGrade(atLocal: local)
    }

    /// Every keyframe the clip carries in timeline seconds, its masks' included,
    /// so the timeline marks a clip whose only animation is a mask's.
    ///
    /// Mask keyframes are read against the CLIP's animation window, which is the
    /// window they are evaluated against.
    var allVisibleKeyframeSeconds: [Double] {
        let masks = maskedGrades ?? []
        // Relight keyframes live on the lights, like mask keyframes live on
        // the masks, and are read against the same clip window.
        let relightTimes = resolvedRelight?.keyframeLocalTimes ?? []
        guard masks.contains(where: \.isAnimated) || !relightTimes.isEmpty else {
            return visibleKeyframeSeconds
        }
        let window = animation ?? ClipAnimation()
        guard let end = try? placement.range.end else { return visibleKeyframeSeconds }
        var seen = Set<Int64>()
        var result = visibleKeyframeSeconds
        for value in result { seen.insert(Int64((value * 100_000).rounded())) }
        func add(_ local: TimelineTime) {
            guard let time = window.compositionTime(forLocal: local,
                                                    clipStart: placement.timelineStart),
                  time >= placement.timelineStart, time < end,
                  seen.insert(Int64((time.seconds * 100_000).rounded())).inserted else { return }
            result.append(time.seconds)
        }
        for mask in masks {
            for track in mask.animation?.tracks ?? [] {
                for frame in track.keyframes { add(frame.time) }
            }
        }
        for local in relightTimes { add(local) }
        return result.sorted()
    }

    /// True when anything about this clip's colour changes over time, globally
    /// or inside one of its masks. Drives the panel indicators.
    var hasGradeAnimation: Bool {
        if animation?.tracks.contains(where: { $0.property.isGradeProperty && !$0.isEmpty }) == true { return true }
        return maskedGrades?.contains { mask in
            mask.animation?.tracks.contains { $0.property.isGradeProperty && !$0.isEmpty } ?? false
        } ?? false
    }
}

/// Optional mask storage is exposed through concrete computed properties so it
/// can participate in the same strongly typed keyframe engine as Transform.
extension VideoClip {
    private mutating func editLayerMask(_ edit: (inout LayerMask) -> Void) {
        var value = resolvedLayerMask
        edit(&value)
        layerMask = value
    }

    var animatedLayerMaskCenterX: Double {
        get { resolvedLayerMask.centerX }
        set { editLayerMask { $0.centerX = newValue } }
    }
    var animatedLayerMaskCenterY: Double {
        get { resolvedLayerMask.centerY }
        set { editLayerMask { $0.centerY = newValue } }
    }
    var animatedLayerMaskWidth: Double {
        get { resolvedLayerMask.width }
        set { editLayerMask { $0.width = newValue } }
    }
    var animatedLayerMaskHeight: Double {
        get { resolvedLayerMask.height }
        set { editLayerMask { $0.height = newValue } }
    }
    var animatedLayerMaskRotation: Double {
        get { resolvedLayerMask.rotationDegrees }
        set { editLayerMask { $0.rotationDegrees = newValue } }
    }
    var animatedLayerMaskFeather: Double {
        get { resolvedLayerMask.feather }
        set { editLayerMask { $0.feather = newValue } }
    }

    private mutating func editLocalMask(_ edit: (inout GradeMask) -> Void) {
        var advanced = gradeSettings.advanced ?? .neutral
        var value = advanced.resolvedMask
        edit(&value)
        advanced.mask = value
        gradeSettings.advanced = advanced
    }

    var animatedLocalMaskCenterX: Double {
        get { Double((gradeSettings.advanced ?? .neutral).resolvedMask.centerX) / 100 }
        set { editLocalMask { $0.centerX = Float(newValue * 100) } }
    }
    var animatedLocalMaskCenterY: Double {
        get { Double((gradeSettings.advanced ?? .neutral).resolvedMask.centerY) / 100 }
        set { editLocalMask { $0.centerY = Float(newValue * 100) } }
    }
    var animatedLocalMaskWidth: Double {
        get { Double((gradeSettings.advanced ?? .neutral).resolvedMask.width) / 100 }
        set { editLocalMask { $0.width = Float(newValue * 100) } }
    }
    var animatedLocalMaskHeight: Double {
        get { Double((gradeSettings.advanced ?? .neutral).resolvedMask.height) / 100 }
        set { editLocalMask { $0.height = Float(newValue * 100) } }
    }
    var animatedLocalMaskRotation: Double {
        get { Double((gradeSettings.advanced ?? .neutral).resolvedMask.rotation) }
        set { editLocalMask { $0.rotation = Float(newValue) } }
    }
    var animatedLocalMaskFeather: Double {
        get { Double((gradeSettings.advanced ?? .neutral).resolvedMask.feather) / 100 }
        set { editLocalMask { $0.feather = Float(newValue * 100) } }
    }
    var animatedLocalMaskOpacity: Double {
        get { Double((gradeSettings.advanced ?? .neutral).resolvedMask.opacity) / 100 }
        set { editLocalMask { $0.opacity = Float(newValue * 100) } }
    }
}

// MARK: - Project-wide queries

extension Timeline {
    var hasAnimation: Bool {
        tracks.contains { track in
            track.items.contains { item in
                switch item {
                case .text(let clip): clip.isAnimated
                case .shape(let clip): clip.isAnimated
                case .video(let clip): clip.isAnimated
                case .audio: false
                }
            }
        }
    }
}
