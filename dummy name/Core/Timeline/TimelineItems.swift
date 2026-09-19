import CoreGraphics
import CoreMedia
import Foundation

struct RGBAColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
    static let black = Self(red: 0, green: 0, blue: 0)
    static let white = Self(red: 1, green: 1, blue: 1)
}

/// Composition coordinates, not screen pixels. Independent of preview size.
struct VisualTransform: Codable, Equatable, Sendable {
    var positionX: Double = 0.5
    var positionY: Double = 0.5
    var anchorX: Double = 0.5
    var anchorY: Double = 0.5
    var scale: Double = 1
    var widthScale: Double = 1
    var heightScale: Double = 1
    var rotationDegrees: Double = 0
    var locksAspectRatio = true

    /// Where a drawn layer's own bounds land on the canvas.
    ///
    /// The single definition of what anchor, scale, rotation and position mean
    /// for a layer the app draws. Both renderers and the canvas handles call
    /// this rather than each spelling the matrix out, so a title and a shape
    /// dragged to the same place cannot end up in different places.
    ///
    /// Canvas coordinates are Y-up, as CoreGraphics has them, while
    /// `positionY` is measured from the top — which is the inversion in the
    /// last line.
    func placement(bounds: CGRect, canvas: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: -(bounds.minX+bounds.width*anchorX),
                          y: -(bounds.maxY-bounds.height*anchorY))
            .concatenating(.init(scaleX: scale*widthScale, y: scale*heightScale))
            .concatenating(.init(rotationAngle: -rotationDegrees * .pi/180))
            .concatenating(.init(translationX: positionX*canvas.width, y: (1-positionY)*canvas.height))
    }
}

// Only implemented modes are representable/exposed at this checkpoint.
enum VisualBlendMode: String, Codable, Sendable, CaseIterable {
    case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten
}

/// A geometric alpha mask on one visual layer. Unlike `GradeMask`, this changes
/// clip coverage: pixels outside (or, when inverted, inside) the shape become
/// transparent and reveal the tracks below.
enum LayerMaskShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case ellipse
    case rectangle
    /// An infinite split line. At zero rotation the left side remains visible;
    /// animating its X position produces a classic wipe/reveal.
    case linear

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct LayerMask: Codable, Equatable, Sendable {
    var isEnabled = false
    var shape: LayerMaskShape = .ellipse
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 0.7
    var height: Double = 0.5
    var rotationDegrees: Double = 0
    var feather: Double = 0.12
    /// False keeps the top layer inside the shape. True keeps it outside,
    /// producing a cut-out through the middle.
    var isInverted = false

    static let disabled = LayerMask()

    var clamped: LayerMask {
        var value = self
        value.centerX = min(max(value.centerX, 0), 1)
        value.centerY = min(max(value.centerY, 0), 1)
        value.width = min(max(value.width, 0.01), 2)
        value.height = min(max(value.height, 0.01), 2)
        value.rotationDegrees = min(max(value.rotationDegrees, -180), 180)
        value.feather = min(max(value.feather, 0), 1)
        return value
    }
}

struct ItemPlacement: Codable, Equatable, Sendable {
    let id: UUID
    var trackID: UUID
    var timelineStart: TimelineTime
    var duration: TimelineTime
    var isEnabled = true
    var isLocked = false
    var range: TimelineRange { .init(start: timelineStart, duration: duration) }
}

protocol TimelineClip: Identifiable, Codable, Equatable, Sendable {
    var placement: ItemPlacement { get set }
}
extension TimelineClip { var id: UUID { placement.id } }

struct VideoClip: TimelineClip {
    var placement: ItemPlacement
    var assetID: UUID
    var sourceRange: TimelineRange
    var gradeSettings: GradeSettings = .neutral
    var transform = VisualTransform()
    var opacity: Double = 1
    var blendMode: VisualBlendMode = .normal
    /// Optional keeps every project written before layer masks decodable.
    var layerMask: LayerMask? = nil
    /// Power windows: zero or more local grades, each confined to its own mask.
    ///
    /// Deliberately NOT inside `gradeSettings`. A grade is a description of
    /// colour that a preset can carry to another clip; a mask is spatial
    /// structure that belongs to this picture and means nothing on another one.
    /// Keeping them apart is what lets Copy Grade and Save as Preset stay
    /// exactly what they were.
    ///
    /// Optional so every project written before masked grading decodes as the
    /// unchanged, single-grade clip it was.
    var maskedGrades: [MaskedGradeLayer]? = nil
    // Follows this video's source range and placement until explicitly separated.
    var embeddedAudio: EmbeddedAudio?
    /// Optional so projects saved before keyframes existed still decode unchanged.
    var animation: ClipAnimation? = nil
    /// Optional so projects saved before speed existed still decode unchanged.
    /// Read through `speed`, never directly.
    var playbackSpeed: Double? = nil
    /// Blend adjacent source frames instead of holding each one. Optional for
    /// the same backwards-compatible reason.
    var blendsRetimedFrames: Bool? = nil

    /// Whether this clip's retiming should cross-dissolve between source frames
    /// rather than stepping between them.
    ///
    /// Only meaningful when the clip is actually retimed — at normal speed every
    /// output frame lands exactly on a source frame and there is nothing to
    /// blend, so the flag is ignored rather than costing a pointless pass.
    var smoothsMotion: Bool {
        get { (blendsRetimedFrames ?? false) && isRetimed }
        set { blendsRetimedFrames = newValue }
    }

    /// Playback rate. 1 is normal; above 1 plays faster and occupies less
    /// timeline. `placement.duration` is always `sourceRange.duration / speed`.
    var speed: Double {
        get { ClipSpeed.clamped(playbackSpeed ?? ClipSpeed.normal) }
        set { playbackSpeed = ClipSpeed.clamped(newValue) }
    }

    var isRetimed: Bool { speed != ClipSpeed.normal }
    var resolvedLayerMask: LayerMask { (layerMask ?? .disabled).clamped }
    var resolvedMaskedGrades: [MaskedGradeLayer] { maskedGrades ?? [] }

    /// The masked grades as rendered at a clip-local time, with every geometry
    /// keyframe evaluated. Authored values are never touched.
    ///
    /// Mask keyframes are read against the clip's OWN animation window, so a
    /// head trim or a split moves them exactly as it moves transform keyframes —
    /// there is one conversion between the composition clock and clip-local time
    /// in this app, and this uses it.
    func evaluatedMaskedGrades(atLocal local: TimelineTime) -> [MaskedGradeLayer] {
        guard let maskedGrades, !maskedGrades.isEmpty else { return [] }
        return maskedGrades.evaluated(atLocal: local)
    }

    /// The same, for a composition time.
    func evaluatedMaskedGrades(at composition: TimelineTime) -> [MaskedGradeLayer] {
        guard let maskedGrades, !maskedGrades.isEmpty else { return [] }
        guard let local = localTime(for: composition) else { return maskedGrades }
        return maskedGrades.evaluated(atLocal: local)
    }

    /// Maps a timeline position to the source frame shown there.
    ///
    /// Speed scales the elapsed distance into the source: at 2×, one second of
    /// timeline consumes two seconds of source. Without this the preview would
    /// show the wrong frame for every retimed clip while the composition played
    /// the right one.
    func sourceTime(at timelineTime: TimelineTime) throws -> TimelineTime {
        let relative = try timelineTime.subtracting(placement.timelineStart)
        let clamped = min(placement.duration, max(.zero, relative))
        let scaled = try TimelineTime(CMTimeConvertScale(
            CMTimeMultiplyByFloat64(clamped.cmTime, multiplier: speed),
            timescale: sourceRange.duration.cmTime.timescale,
            method: .roundHalfAwayFromZero
        ))
        return try sourceRange.start.adding(min(sourceRange.duration, scaled))
    }
}

struct EmbeddedAudio: Codable, Equatable, Sendable {
    var volume: Double = 1
    var isMuted = false
    /// Fade lengths in seconds. Optional so projects saved before fades existed
    /// still decode unchanged, and so a clip that has never been faded stores
    /// nothing rather than a zero.
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
}

struct AudioClip: TimelineClip {
    var placement: ItemPlacement
    var assetID: UUID
    var sourceRange: TimelineRange
    /// nil means all source audio tracks; ordinal selects a specific source track.
    var sourceTrackIndex: Int?
    var volume: Double = 1
    var isMuted = false
    /// Fade lengths in seconds, as for `EmbeddedAudio`.
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
}

/// Where a clip's fade lengths are decided, once, for everything that needs
/// them: the mix that preview and export share, and the timeline that draws
/// them. A fade is stored as a request; this is what actually fits in the clip.
enum AudioFade {
    /// Longest fade offered. Past a few seconds a fade stops reading as a fade.
    static let maximum = 10.0

    /// The two fades as they will really be applied.
    ///
    /// Neither can be negative or longer than the clip, and together they cannot
    /// be longer than it either — two fades that overlap would each be reading a
    /// level the other is still changing. When they collide they are scaled to
    /// meet exactly in the middle, which is what a listener expects: the clip
    /// rises and falls with no level section between.
    static func resolved(duration: Double, fadeIn: Double?, fadeOut: Double?) -> (rise: Double, fall: Double) {
        guard duration > 0 else { return (0, 0) }
        func clamped(_ value: Double?) -> Double {
            guard let value, value.isFinite, value > 0 else { return 0 }
            return min(value, min(duration, maximum))
        }
        let rise = clamped(fadeIn), fall = clamped(fadeOut)
        guard rise + fall > duration, rise + fall > 0 else { return (rise, fall) }
        let scale = duration / (rise + fall)
        return (rise * scale, fall * scale)
    }
}

struct TextClip: TimelineClip {
    var placement: ItemPlacement
    var text = "Text"
    var style = TextStyle()
    var transform = VisualTransform()
    var opacity: Double = 1
    var blendMode: VisualBlendMode = .normal
    var color = RGBAColor.white
    var strokeColor = RGBAColor.black
    var strokeWidth: Double = 0
    var backgroundColor = RGBAColor.black
    var backgroundOpacity: Double = 0
    var cornerRadius: Double = 0
    var shadowOpacity: Double = 0
    var shadowRadius: Double = 8
    var shadowOffsetX: Double = 0
    var shadowOffsetY: Double = 4
    var glowOpacity: Double = 0
    var curve: Double = 0 // normalized arc amount (-1...1)
    var decoration: TextDecoration? = nil
    /// Optional: replaces the flat fill. Nil keeps `color` and old documents decodable.
    var gradient: GradientFill? = nil
    /// Optional so projects saved before keyframes existed still decode unchanged.
    var animation: ClipAnimation? = nil
}

/// Fill gradient across the glyph ink box. Angle 0 sweeps left to right; 90 sweeps bottom to top.
struct GradientFill: Codable, Equatable, Sendable {
    var start = RGBAColor.white
    var end = RGBAColor(red: 1, green: 0.42, blue: 0.1)
    var angleDegrees: Double = 90
}

struct TextDecoration: Codable, Equatable, Sendable {
    var padding: Double = 12
    var shadowColor = RGBAColor.black
    var glowColor = RGBAColor.white
    var glowRadius: Double = 12
}

struct TextStyle: Codable, Equatable, Sendable {
    enum CaseMode: String, Codable, Sendable, CaseIterable { case original, uppercase, lowercase, title }
    enum Alignment: String, Codable, Sendable, CaseIterable { case left, center, right, justified }
    // Stable PostScript font identifier; nil selects the system font.
    var fontName: String?
    // Typographic units in project canvas space, never SwiftUI view coordinates.
    var fontSize: Double = 64
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var caseMode: CaseMode = .original
    var color = RGBAColor.white
    var characterSpacing: Double = 0
    var lineSpacing: Double = 0
    var alignment: Alignment = .center
    // Layout wrapping width is distinct from geometric widthScale.
    var layoutWidth: Double = 0.8
}

struct TextStylePreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var style: TextStyle
    var color: RGBAColor
    var strokeColor: RGBAColor
    var strokeWidth: Double
    var backgroundColor: RGBAColor
    var backgroundOpacity: Double
    var gradient: GradientFill? = nil
    static let builtIn: [TextStylePreset] = [
        .init(id: "clean", name: "Clean", style: .init(), color: .white, strokeColor: .black, strokeWidth: 0, backgroundColor: .black, backgroundOpacity: 0),
        .init(id: "label", name: "Label", style: .init(fontSize: 48, isBold: true), color: .white, strokeColor: .black, strokeWidth: 2, backgroundColor: .black, backgroundOpacity: 0.65),
        .init(id: "outline", name: "White + black stroke", style: .init(fontSize: 64, isBold: true), color: .white, strokeColor: .black, strokeWidth: 5, backgroundColor: .black, backgroundOpacity: 0),
        .init(id: "inverse-outline", name: "Black + white stroke", style: .init(fontSize: 64, isBold: true), color: .black, strokeColor: .white, strokeWidth: 5, backgroundColor: .black, backgroundOpacity: 0),
        .init(id: "subtitle", name: "Subtitle", style: .init(fontSize: 48, isBold: true), color: .white, strokeColor: .black, strokeWidth: 2, backgroundColor: .black, backgroundOpacity: 0.7)
    ] + [
        ("yellow", RGBAColor(red: 1, green: 0.9, blue: 0)),
        ("orange", RGBAColor(red: 1, green: 0.45, blue: 0)),
        ("blue", RGBAColor(red: 0, green: 0.65, blue: 1)),
        ("green", RGBAColor(red: 0.2, green: 1, blue: 0.15)),
        ("pink", RGBAColor(red: 1, green: 0.12, blue: 0.4)),
        ("purple", RGBAColor(red: 0.65, green: 0.1, blue: 1))
    ].flatMap { name, color in [
        TextStylePreset(id: "outline-\(name)", name: "\(name.capitalized) outline", style: .init(isBold: true), color: color, strokeColor: .black, strokeWidth: 4, backgroundColor: .black, backgroundOpacity: 0),
        TextStylePreset(id: "label-\(name)", name: "\(name.capitalized) label", style: .init(isBold: true), color: name == "yellow" ? .black : .white, strokeColor: .black, strokeWidth: 0, backgroundColor: color, backgroundOpacity: 1)
    ] } + [
        ("sunset", RGBAColor(red: 1, green: 0.85, blue: 0.2), RGBAColor(red: 1, green: 0.2, blue: 0.35), 90.0, 0.0),
        ("ocean", RGBAColor(red: 0.35, green: 1, blue: 0.95), RGBAColor(red: 0.15, green: 0.35, blue: 1), 90.0, 0.0),
        ("candy", RGBAColor(red: 1, green: 0.45, blue: 0.95), RGBAColor(red: 0.55, green: 0.5, blue: 1), 0.0, 0.0),
        ("gold", RGBAColor(red: 1, green: 0.95, blue: 0.55), RGBAColor(red: 0.75, green: 0.5, blue: 0.05), 90.0, 4.0),
        ("chrome", RGBAColor(red: 1, green: 1, blue: 1), RGBAColor(red: 0.45, green: 0.5, blue: 0.6), 90.0, 4.0)
    ].map { name, start, end, angle, stroke in
        TextStylePreset(id: "gradient-\(name)", name: "\(name.capitalized) gradient", style: .init(isBold: true),
            color: start, strokeColor: .black, strokeWidth: stroke, backgroundColor: .black, backgroundOpacity: 0,
            gradient: .init(start: start, end: end, angleDegrees: angle))
    }
}

enum TimelineItem: Codable, Equatable, Identifiable, Sendable {
    case video(VideoClip)
    case audio(AudioClip)
    case text(TextClip)
    case shape(ShapeClip)

    var placement: ItemPlacement {
        switch self {
        case .video(let c): c.placement
        case .audio(let c): c.placement
        case .text(let c): c.placement
        case .shape(let c): c.placement
        }
    }
    var id: UUID { placement.id }
    var assetID: UUID? {
        switch self {
        case .video(let c): c.assetID
        case .audio(let c): c.assetID
        case .text, .shape: nil
        }
    }
    /// A drawn layer: one whose picture the app generates rather than reads from
    /// an asset. Text and shapes behave identically everywhere this matters —
    /// they have no source range, they live on their own track, and they can sit
    /// anywhere on the timeline without a media edit underneath them.
    var isDrawnOverlay: Bool {
        switch self { case .text, .shape: true; case .video, .audio: false }
    }
}
