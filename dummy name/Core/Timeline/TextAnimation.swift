import Foundation

/// A ready-made animation a title can play without the user authoring a single
/// keyframe.
///
/// These are NOT keyframes and they never become keyframes. A preset stays a
/// preset — a name, a duration and a strength — so it can still be changed to
/// something else, or turned off, long after it was applied. The manual
/// keyframe engine in `AnimatableClip` is untouched and keeps running
/// independently; see `TextAnimator` for how the two are composed.
///
/// **Raw values are written into project documents, so this list is APPEND
/// ONLY.** Never rename or reorder an existing case's raw value. A project
/// saved by a newer build may name a preset this build has never heard of;
/// `TextAnimationSettings` decodes that as no animation rather than refusing to
/// open the document.
enum TextAnimationPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    // MARK: In
    case fadeIn
    case slideUpIn
    case slideDownIn
    case slideLeftIn
    case slideRightIn
    case popIn
    case zoomIn
    case scaleUpIn
    case rotateIn
    case riseIn
    case typewriterIn
    case wipeIn
    case trackingIn
    case blurIn
    case characterPopIn

    // MARK: Out
    case fadeOut
    case slideUpOut
    case slideDownOut
    case slideLeftOut
    case slideRightOut
    case popOut
    case zoomOut
    case scaleDownOut
    case rotateOut
    case sinkOut
    case wipeOut
    case trackingOut
    case blurOut
    case characterFadeOut

    // MARK: Loop
    case pulse
    case breathing
    case float
    case bounce
    case swing
    case wiggle
    case wave
    case flicker
    case trackingPulse

    var id: String { rawValue }

    /// Which of the three slots this preset belongs to. A preset is only ever
    /// offered in — and only ever evaluated for — its own slot.
    var slot: TextAnimationSlot {
        switch self {
        case .fadeIn, .slideUpIn, .slideDownIn, .slideLeftIn, .slideRightIn,
             .popIn, .zoomIn, .scaleUpIn, .rotateIn, .riseIn,
             .typewriterIn, .wipeIn, .trackingIn, .blurIn, .characterPopIn:
            return .incoming
        case .fadeOut, .slideUpOut, .slideDownOut, .slideLeftOut, .slideRightOut,
             .popOut, .zoomOut, .scaleDownOut, .rotateOut, .sinkOut,
             .wipeOut, .trackingOut, .blurOut, .characterFadeOut:
            return .outgoing
        case .pulse, .breathing, .float, .bounce, .swing, .wiggle, .wave, .flicker, .trackingPulse:
            return .loop
        }
    }

    /// Short, so the tiles read at a glance.
    var title: String {
        switch self {
        case .fadeIn, .fadeOut: String(localized: "Fade")
        case .slideUpIn, .slideUpOut: String(localized: "Slide Up")
        case .slideDownIn, .slideDownOut: String(localized: "Slide Down")
        case .slideLeftIn, .slideLeftOut: String(localized: "Slide Left")
        case .slideRightIn, .slideRightOut: String(localized: "Slide Right")
        case .popIn: String(localized: "Pop")
        case .popOut: String(localized: "Pop Out")
        case .zoomIn: String(localized: "Zoom In")
        case .zoomOut: String(localized: "Zoom Out")
        case .scaleUpIn: String(localized: "Scale Up")
        case .scaleDownOut: String(localized: "Scale Down")
        case .rotateIn, .rotateOut: String(localized: "Rotate")
        case .riseIn: String(localized: "Rise")
        case .sinkOut: String(localized: "Sink")
        case .typewriterIn: String(localized: "Typewriter")
        case .wipeIn, .wipeOut: String(localized: "Wipe")
        // Its own key: "Tracking" already means motion tracking in the mask
        // panel, and the two are different words in most languages - this one
        // is letter spacing.
        case .trackingIn, .trackingOut:
            String(localized: "textAnimation.tracking", defaultValue: "Tracking")
        case .blurIn, .blurOut: String(localized: "Blur")
        case .characterPopIn: String(localized: "Character Pop")
        case .characterFadeOut: String(localized: "Character Fade")
        case .pulse: String(localized: "Pulse")
        case .breathing: String(localized: "Breathing")
        case .float: String(localized: "Float")
        case .bounce: String(localized: "Bounce")
        case .swing: String(localized: "Swing")
        case .wiggle: String(localized: "Wiggle")
        case .wave: String(localized: "Wave")
        case .flicker: String(localized: "Flicker")
        case .trackingPulse:
            String(localized: "textAnimation.trackingPulse", defaultValue: "Tracking Pulse")
        }
    }

    /// Picker artwork. Static symbols on purpose: fifteen live text previews in
    /// a grid costs far more than the editor preview they are choosing for.
    var symbol: String {
        switch self {
        case .fadeIn, .fadeOut: "circle.lefthalf.filled"
        case .slideUpIn, .slideUpOut: "arrow.up"
        case .slideDownIn, .slideDownOut: "arrow.down"
        case .slideLeftIn, .slideLeftOut: "arrow.left"
        case .slideRightIn, .slideRightOut: "arrow.right"
        case .popIn, .popOut: "sparkle"
        case .zoomIn: "arrow.up.left.and.arrow.down.right"
        case .zoomOut: "arrow.down.right.and.arrow.up.left"
        case .scaleUpIn: "arrow.up.forward"
        case .scaleDownOut: "arrow.down.backward"
        case .rotateIn, .rotateOut: "rotate.right"
        case .riseIn: "arrow.up.to.line"
        case .sinkOut: "arrow.down.to.line"
        case .typewriterIn: "keyboard"
        case .wipeIn, .wipeOut: "rectangle.righthalf.filled"
        case .trackingIn, .trackingOut: "arrow.left.and.right"
        case .blurIn, .blurOut: "drop"
        case .characterPopIn: "textformat.abc"
        case .characterFadeOut: "textformat.abc.dottedunderline"
        case .pulse: "waveform.path"
        case .breathing: "lungs"
        case .float: "arrow.up.and.down"
        case .bounce: "arrow.turn.up.forward.iphone"
        case .swing: "metronome"
        case .wiggle: "scribble"
        case .wave: "water.waves"
        case .flicker: "light.beacon.max"
        case .trackingPulse: "arrow.left.and.right.square"
        }
    }

    /// Presets offered for one slot, in the order the picker shows them.
    static func all(in slot: TextAnimationSlot) -> [TextAnimationPreset] {
        allCases.filter { $0.slot == slot }
    }

    /// Whether this preset animates individual glyphs. Those bypass the text
    /// raster cache, because the picture genuinely changes every frame, so the
    /// panel can warn and the renderer can branch on one question.
    var isPerGlyph: Bool {
        switch self {
        case .typewriterIn, .characterPopIn, .characterFadeOut, .wave: true
        default: false
        }
    }
}

/// The three independent slots a title animates in. All three can be set at
/// once: In plays at the head, Out plays at the tail, Loop fills the middle.
enum TextAnimationSlot: String, CaseIterable, Identifiable, Sendable {
    case incoming, outgoing, loop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .incoming: String(localized: "In")
        case .outgoing: String(localized: "Out")
        case .loop: String(localized: "Loop")
        }
    }
}

/// The whole authored animation state of one title.
///
/// Deliberately tiny and high level. Six hidden keyframes could express Pop
/// once, but not "Pop, a bit softer, a bit slower" a week later.
struct TextAnimationSettings: Codable, Equatable, Sendable {
    var incoming: TextAnimationPreset?
    var incomingDuration: TimelineTime = Self.defaultDuration
    var outgoing: TextAnimationPreset?
    var outgoingDuration: TimelineTime = Self.defaultDuration
    var loop: TextAnimationPreset?
    /// Loop cycles per base period. 0.5 is half speed, 2 is double.
    var loopSpeed: Double = 1
    /// Amplitude, 0...1. Scales distance, overshoot, angle, blur and tracking —
    /// never opacity, because a fade that only reaches half is not a softer
    /// fade, it is a broken one.
    var strength: Double = 1

    static let defaultDuration = (try? TimelineTime.seconds(0.5)) ?? .zero
    static let minimumDuration = 0.1
    static let maximumDuration = 2.0

    /// Nothing selected in any slot: the title renders exactly as an old
    /// project's would, and the evaluator returns early.
    var isEmpty: Bool { incoming == nil && outgoing == nil && loop == nil }

    func preset(_ slot: TextAnimationSlot) -> TextAnimationPreset? {
        switch slot {
        case .incoming: incoming
        case .outgoing: outgoing
        case .loop: loop
        }
    }

    mutating func setPreset(_ preset: TextAnimationPreset?, for slot: TextAnimationSlot) {
        switch slot {
        case .incoming: incoming = preset
        case .outgoing: outgoing = preset
        case .loop: loop = preset
        }
    }

    func duration(_ slot: TextAnimationSlot) -> TimelineTime {
        slot == .outgoing ? outgoingDuration : incomingDuration
    }

    mutating func setDuration(_ duration: TimelineTime, for slot: TextAnimationSlot) {
        switch slot {
        case .incoming: incomingDuration = duration
        case .outgoing: outgoingDuration = duration
        case .loop: break
        }
    }

    /// Any slot using per-glyph animation, which is the expensive kind.
    var usesPerGlyphAnimation: Bool {
        [incoming, outgoing, loop].contains { $0?.isPerGlyph == true }
    }

    // MARK: - Forward compatible decoding

    private enum CodingKeys: String, CodingKey {
        case incoming, incomingDuration, outgoing, outgoingDuration, loop, loopSpeed, strength
    }

    init() {}

    /// A preset named by a newer build decodes to nothing rather than throwing.
    /// Refusing to open a whole project because one title mentions an animation
    /// this version does not have would be a bad trade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func preset(_ key: CodingKeys) -> TextAnimationPreset? {
            guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return TextAnimationPreset(rawValue: raw)
        }
        incoming = preset(.incoming)
        outgoing = preset(.outgoing)
        loop = preset(.loop)
        incomingDuration = (try? container.decodeIfPresent(TimelineTime.self, forKey: .incomingDuration))
            .flatMap { $0 } ?? Self.defaultDuration
        outgoingDuration = (try? container.decodeIfPresent(TimelineTime.self, forKey: .outgoingDuration))
            .flatMap { $0 } ?? Self.defaultDuration
        loopSpeed = (try? container.decodeIfPresent(Double.self, forKey: .loopSpeed)).flatMap { $0 } ?? 1
        strength = (try? container.decodeIfPresent(Double.self, forKey: .strength)).flatMap { $0 } ?? 1
        // A slot holding a preset from another slot could only come from a
        // damaged or hand-edited document, and would animate at the wrong end.
        if incoming?.slot != .incoming { incoming = nil }
        if outgoing?.slot != .outgoing { outgoing = nil }
        if loop?.slot != .loop { loop = nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(incoming?.rawValue, forKey: .incoming)
        try container.encodeIfPresent(outgoing?.rawValue, forKey: .outgoing)
        try container.encodeIfPresent(loop?.rawValue, forKey: .loop)
        try container.encode(incomingDuration, forKey: .incomingDuration)
        try container.encode(outgoingDuration, forKey: .outgoingDuration)
        try container.encode(loopSpeed, forKey: .loopSpeed)
        try container.encode(strength, forKey: .strength)
    }
}
