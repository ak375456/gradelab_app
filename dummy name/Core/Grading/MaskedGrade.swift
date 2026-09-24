import Foundation

// ---------------------------------------------------------------------------
// Power windows: masked local grading
//
// A clip carries one GLOBAL grade plus zero or more MASKED LOCAL grades. The
// local grade of a new mask is neutral, and it is applied to the result of the
// global grade rather than replacing it — so a mask adds half a stop to a face
// without the rest of the picture noticing, and without the global grade being
// computed twice.
//
// Geometry is normalised to the SOURCE frame, never to preview pixels. That is
// what makes a mask land in the same place on an iPhone preview, on an iPad,
// and in a 4K export, and it is also what will let tracking write position,
// scale and rotation keyframes later without redefining the storage.
// ---------------------------------------------------------------------------

enum MaskShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case ellipse
    case rectangle
    /// A graduated window: fully affected on one side of a line, falling to
    /// nothing on the other. Sky darkening, foreground lifts, side light.
    case linear
    /// An arbitrary closed region the user draws or taps out.
    case freehand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ellipse: String(localized: "Ellipse")
        case .rectangle: String(localized: "Rectangle")
        case .linear: String(localized: "Gradient")
        case .freehand: String(localized: "Freehand")
        }
    }

    var symbol: String {
        switch self {
        case .ellipse: "circle.dashed"
        case .rectangle: "rectangle.dashed"
        case .linear: "square.split.diagonal.2x2"
        case .freehand: "lasso"
        }
    }

    /// Shape selector as the shader reads it from the packed flag word.
    var shaderCode: Float {
        switch self {
        case .ellipse: 0
        case .rectangle: 1
        case .linear: 2
        case .freehand: 3
        }
    }

    /// Whether size, rotation and corner radius mean anything for this shape.
    var hasSize: Bool { self != .linear }
    var hasCornerRadius: Bool { self == .rectangle }
}

/// One freehand vertex, normalised to the source frame.
struct MaskPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }

    var clamped: MaskPoint {
        MaskPoint(x: min(max(x.isFinite ? x : 0.5, -1), 2),
                  y: min(max(y.isFinite ? y : 0.5, -1), 2))
    }
}

/// The shape of one window. Pure geometry: it carries no colour at all, so a
/// future tracker can rewrite it without touching the grade it reveals.
struct MaskGeometry: Codable, Equatable, Sendable {
    /// A polygon is capped so the whole mask stack fits one `setBytes` block,
    /// and so the per-pixel edge loop stays affordable at 4K.
    static let maximumPoints = 64

    var shape: MaskShape = .ellipse
    /// Centre for the primitives; the pivot that scale and rotation act around
    /// for a freehand polygon.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Width and height as a fraction of the frame for the primitives; scale
    /// factors around the pivot for a freehand polygon.
    var width: Double = 0.45
    var height: Double = 0.45
    var rotationDegrees: Double = 0
    /// 0 is square, 1 rounds the rectangle to a stadium. Rectangle only.
    var cornerRadius: Double = 0
    /// 0 is a hard edge; 1 is as soft as the shape allows.
    var feather: Double = 0.3
    /// Grades outside the shape instead of inside. Done as `1 - mask` in the
    /// shader, never by building a second window.
    var isInverted = false
    /// Freehand vertices, in frame-normalised coordinates. Empty otherwise.
    var points: [MaskPoint] = []
    /// Where a freehand path was drawn, as the centre of gravity of its points.
    ///
    /// The vertices are absolute frame coordinates, so something has to say what
    /// the path's own origin is. `centerX`/`centerY` is then a POSITION rather
    /// than a redundant copy of it: the shape is drawn about the pivot and
    /// measured about the centre, so moving the centre translates the whole
    /// path — which is what makes position, scale and rotation animatable on a
    /// freehand mask without animating individual vertices, and what a tracker
    /// will drive later.
    var pivotX: Double = 0.5
    var pivotY: Double = 0.5

    static let `default` = MaskGeometry()

    /// Keeps hand-edited or future project JSON from reaching Metal with
    /// geometry it cannot evaluate. Authored values are left alone; this is the
    /// resolved render value.
    var clamped: MaskGeometry {
        var value = self
        func finite(_ number: Double, _ fallback: Double) -> Double {
            number.isFinite ? number : fallback
        }
        // These bounds are the ones `AnimatableProperty` clamps keyframed
        // values to. Keeping them identical is what stops a mask jumping the
        // moment its first keyframe is added.
        value.centerX = min(max(finite(centerX, 0.5), 0), 1)
        value.centerY = min(max(finite(centerY, 0.5), 0), 1)
        value.width = min(max(finite(width, 0.45), 0.01), 2)
        value.height = min(max(finite(height, 0.45), 0.01), 2)
        value.rotationDegrees = min(max(finite(rotationDegrees, 0), -180), 180)
        value.cornerRadius = min(max(finite(cornerRadius, 0), 0), 1)
        value.feather = min(max(finite(feather, 0.3), 0), 1)
        value.pivotX = min(max(finite(pivotX, 0.5), 0), 1)
        value.pivotY = min(max(finite(pivotY, 0.5), 0), 1)
        if !value.points.isEmpty {
            value.points = value.points.prefix(Self.maximumPoints).map(\.clamped)
        }
        return value
    }

    /// A polygon needs three vertices before it encloses anything. Below that
    /// the shader is told to skip the layer rather than draw a degenerate edge.
    var isRenderable: Bool {
        shape != .freehand || points.count >= 3
    }

    /// Centre of gravity of the drawn points, used as the pivot a freehand mask
    /// scales and rotates around.
    var pointCentroid: MaskPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(into: (x: 0.0, y: 0.0)) { $0.x += $1.x; $0.y += $1.y }
        return MaskPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
    }

    /// A starting shape for a newly added mask, centred in the frame.
    static func starting(_ shape: MaskShape) -> MaskGeometry {
        var geometry = MaskGeometry()
        geometry.shape = shape
        switch shape {
        case .ellipse:
            geometry.width = 0.45; geometry.height = 0.45; geometry.feather = 0.4
        case .rectangle:
            geometry.width = 0.5; geometry.height = 0.35; geometry.cornerRadius = 0.1; geometry.feather = 0.3
        case .linear:
            geometry.feather = 0.4
        case .freehand:
            // Scale factors, not a size: a polygon starts unscaled.
            geometry.width = 1; geometry.height = 1; geometry.feather = 0.2
        }
        return geometry
    }
}

/// One masked local grade on a clip: a window, and the grade that shows through
/// it. The grade starts neutral — a new mask changes nothing until a slider is
/// moved, which is what makes "add a mask, then grade" feel like one action
/// rather than a duplicated look.
/// A colour-based selection: the secondary every grading app has and this one
/// did not.
///
/// It selects by what a pixel *is* rather than by where it is, which is the
/// difference between "darken this corner" and "warm the skin wherever it
/// moves". That is also why it needs no tracking: a qualifier follows the
/// subject for free, because it never knew where the subject was.
///
/// Qualifying happens on the colour the layer RECEIVES — after the clip's own
/// grade, before this layer's. Picking a skin tone and then lifting exposure
/// therefore keeps selecting skin, instead of the selection sliding off the
/// thing it was pointed at as soon as the grade moves it.
///
/// Optional on `MaskedGradeLayer` so every project saved before it decodes as
/// the purely geometric mask it was authored as.
struct ColorQualifier: Codable, Equatable, Sendable {
    var isEnabled = false
    /// Degrees, 0...360.
    var hueCenter: Double = 25
    /// Half-width in degrees. The full selected arc is twice this.
    var hueRange: Double = 20
    var saturationMin: Double = 0.15
    var saturationMax: Double = 1
    var lumaMin: Double = 0.1
    var lumaMax: Double = 0.95
    /// How far outside each edge the selection fades. 0 is a hard key, which is
    /// almost always the wrong answer on real footage and is why this does not
    /// default to it.
    var softness: Double = 0.25
    /// Grades everything the key does NOT select.
    var isInverted = false
    /// Ignores the layer's shape and qualifies the whole frame.
    ///
    /// On by default because a colour secondary usually wants the whole
    /// picture; switching it off is how the two are combined, which is the
    /// "only the skin, and only in this corner" case.
    var ignoresShape = true

    /// Defaults centred on average skin, because that is what a qualifier is
    /// reached for first.
    static let skin = ColorQualifier()

    var clamped: ColorQualifier {
        var value = self
        value.hueCenter = (value.hueCenter.isFinite ? value.hueCenter : 25)
            .truncatingRemainder(dividingBy: 360)
        if value.hueCenter < 0 { value.hueCenter += 360 }
        value.hueRange = min(max(value.hueRange.isFinite ? value.hueRange : 20, 1), 180)
        value.saturationMin = min(max(value.saturationMin.isFinite ? value.saturationMin : 0, 0), 1)
        value.saturationMax = min(max(value.saturationMax.isFinite ? value.saturationMax : 1, 0), 1)
        value.lumaMin = min(max(value.lumaMin.isFinite ? value.lumaMin : 0, 0), 1)
        value.lumaMax = min(max(value.lumaMax.isFinite ? value.lumaMax : 1, 0), 1)
        // A reversed range selects nothing and reads as a broken control rather
        // than as an empty selection, so the pair is ordered instead.
        if value.saturationMin > value.saturationMax {
            swap(&value.saturationMin, &value.saturationMax)
        }
        if value.lumaMin > value.lumaMax { swap(&value.lumaMin, &value.lumaMax) }
        value.softness = min(max(value.softness.isFinite ? value.softness : 0.25, 0), 1)
        return value
    }

    /// A sampled colour as the qualifier measures it.
    ///
    /// The same HSL definition `rgbToHSL` uses in Shaders.metal — hue in
    /// degrees, saturation and lightness 0...1 — so a picked colour lands in the
    /// middle of the key rather than near its edge. If the two ever disagreed,
    /// picking a colour would select a slightly different one.
    static func components(of colour: SIMD3<Float>) -> (hue: Double, saturation: Double, luma: Double) {
        let r = Double(min(max(colour.x, 0), 1))
        let g = Double(min(max(colour.y, 0), 1))
        let b = Double(min(max(colour.z, 0), 1))
        let hi = max(r, max(g, b)), lo = min(r, min(g, b))
        let delta = hi - lo
        let luma = (hi + lo) / 2
        guard delta > 0.00001 else { return (0, 0, luma) }
        let saturation = luma > 0.5 ? delta / (2 - hi - lo) : delta / (hi + lo)
        var hue: Double
        if hi == r {
            hue = (g - b) / delta + (g < b ? 6 : 0)
        } else if hi == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        return (hue, saturation, luma)
    }

    /// Centres the key on a colour picked off the picture, keeping the widths
    /// the user has already dialled in.
    mutating func center(on hue: Double, saturation: Double, luma: Double) {
        isEnabled = true
        hueCenter = hue
        // Widths are set around the sample rather than replaced, so a pick
        // re-aims the key without discarding a tuned selection.
        let satPad = max(0.12, softness * 0.4)
        saturationMin = max(0, saturation - satPad)
        saturationMax = min(1, saturation + satPad)
        let lumaPad = max(0.15, softness * 0.5)
        lumaMin = max(0, luma - lumaPad)
        lumaMax = min(1, luma + lumaPad)
    }
}

struct MaskedGradeLayer: Codable, Equatable, Identifiable, Sendable {
    /// How many layers one clip can render. The whole stack travels as a single
    /// 4 KB `setBytes` block on every pass, which is what bounds this; it is not
    /// an arbitrary product limit.
    static let maximumPerClip = 8

    let id: UUID
    var name: String
    /// The eye. False keeps the geometry and the grade but renders neither.
    var isEnabled: Bool
    var geometry: MaskGeometry
    /// Neutral on creation, and never seeded from the global grade.
    var localGrade: GradeSettings
    /// Multiplies the mask, not the individual controls. 0 is no effect.
    var strength: Double
    /// Geometry animation, evaluated against the clip's own animation window so
    /// a trim or a split moves mask keyframes exactly as it moves transform
    /// ones. Reuses the project-wide keyframe engine; there is no second one.
    var animation: ClipAnimation?
    /// The colour selection, when this layer has one. Nil is a purely
    /// geometric mask, which is what every layer authored before this was.
    var qualifier: ColorQualifier?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        geometry: MaskGeometry,
        localGrade: GradeSettings = .neutral,
        strength: Double = 1,
        animation: ClipAnimation? = nil,
        qualifier: ColorQualifier? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.geometry = geometry
        self.localGrade = localGrade
        self.strength = strength
        self.animation = animation
        self.qualifier = qualifier
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, geometry, localGrade, strength, animation, qualifier, createdAt
    }

    /// Tolerant of documents written by a newer build: anything missing falls
    /// back to a value that renders rather than failing the open.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Mask"
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        geometry = try container.decodeIfPresent(MaskGeometry.self, forKey: .geometry) ?? .default
        localGrade = try container.decodeIfPresent(GradeSettings.self, forKey: .localGrade) ?? .neutral
        strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        animation = try container.decodeIfPresent(ClipAnimation.self, forKey: .animation)
        qualifier = try container.decodeIfPresent(ColorQualifier.self, forKey: .qualifier)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }

    var resolvedStrength: Double {
        strength.isFinite ? min(max(strength, 0), 1) : 1
    }

    /// What actually reaches the GPU.
    var resolved: MaskedGradeLayer {
        var copy = self
        copy.geometry = geometry.clamped
        copy.strength = resolvedStrength
        return copy
    }

    /// Whether this layer can change a pixel at all. A mask with a neutral local
    /// grade is legitimate — it is what the user has right after adding one — so
    /// this is used for hints, never to silently drop the layer.
    var changesPicture: Bool {
        isEnabled && resolvedStrength > 0 && geometry.isRenderable
            && localGrade.hasCreativeChangeIgnoringMask
    }

    /// Renderable at all: an enabled, non-degenerate window with any strength.
    /// A neutral grade still renders, because Show Mask has to draw it.
    var isRenderable: Bool {
        isEnabled && resolvedStrength > 0 && geometry.isRenderable
    }

    /// A copy with a new identity, for Duplicate.
    func duplicated(named name: String) -> MaskedGradeLayer {
        MaskedGradeLayer(
            id: UUID(), name: name, isEnabled: isEnabled, geometry: geometry,
            localGrade: localGrade, strength: strength, animation: animation,
            createdAt: .now)
    }
}

// MARK: - Keyframes
//
// The layer reuses `AnimationTrack`, `Keyframe` and `KeyframeValue` unchanged.
// Only the property-to-storage binding is local, because a clip can hold several
// masks and the project-wide property enum addresses one slot per clip.

extension MaskedGradeLayer {
    /// Geometry properties a mask can animate, in inspector order. Freehand
    /// vertices are deliberately absent: animating individual path points is a
    /// separate feature, and a polygon still animates as a whole through
    /// position, scale and rotation.
    static let geometryProperties: [AnimatableProperty] = [
        .localMaskPositionX, .localMaskPositionY, .localMaskWidth, .localMaskHeight,
        .localMaskRotation, .localMaskCornerRadius, .localMaskFeather, .localMaskStrength
    ]

    /// Geometry plus the grading parameters of the layer's own local grade.
    ///
    /// The grading half is the SAME list the clip animates, addressed through
    /// the same tracks: a mask does not get its own colour animation system, it
    /// gets the one that exists pointed at `localGrade`.
    /// The grading parameters a window can carry: Light, Colour, Curves, HSL
    /// and Wheels. The vignette, the finishing effects and the creative look are
    /// frame-absolute or source-level and are not offered inside a window, so
    /// they are not animatable inside one either — the same rule
    /// `GradePanel.localCapable` states for the controls.
    static let localGradeProperties: [AnimatableProperty] =
        AnimatableProperty.gradeProperties.filter { property in
            property.gradeSlot.map { GradePanel.localCapable.contains($0.panel) } ?? false
        }

    static let animatableProperties: [AnimatableProperty] =
        geometryProperties + localGradeProperties

    static func supports(_ property: AnimatableProperty, shape: MaskShape) -> Bool {
        switch property {
        case .localMaskPositionX, .localMaskPositionY,
             .localMaskRotation, .localMaskFeather, .localMaskStrength:
            return true
        case .localMaskWidth, .localMaskHeight:
            return shape.hasSize || shape == .freehand
        case .localMaskCornerRadius:
            return shape.hasCornerRadius
        default:
            return localGradeProperties.contains(property)
        }
    }

    func supports(_ property: AnimatableProperty) -> Bool {
        Self.supports(property, shape: geometry.shape)
    }

    var isAnimated: Bool { animation.map { !$0.isEmpty } ?? false }

    func baseValue(of property: AnimatableProperty) -> Double? {
        switch property {
        case .localMaskPositionX: geometry.centerX
        case .localMaskPositionY: geometry.centerY
        case .localMaskWidth: geometry.width
        case .localMaskHeight: geometry.height
        case .localMaskRotation: geometry.rotationDegrees
        case .localMaskCornerRadius: geometry.cornerRadius
        case .localMaskFeather: geometry.feather
        case .localMaskStrength: strength
        default: localGrade.gradeNumber(property)
        }
    }

    mutating func setBaseValue(_ value: Double, of property: AnimatableProperty) {
        let clamped = property.clamped(value)
        switch property {
        case .localMaskPositionX: geometry.centerX = clamped
        case .localMaskPositionY: geometry.centerY = clamped
        case .localMaskWidth: geometry.width = clamped
        case .localMaskHeight: geometry.height = clamped
        case .localMaskRotation: geometry.rotationDegrees = clamped
        case .localMaskCornerRadius: geometry.cornerRadius = clamped
        case .localMaskFeather: geometry.feather = clamped
        case .localMaskStrength: strength = clamped
        default: localGrade.setGradeNumber(clamped, for: property)
        }
    }

    /// The same, for the value types a scalar cannot express — today only a
    /// whole-curve snapshot.
    func baseKeyframeValue(of property: AnimatableProperty) -> KeyframeValue? {
        if case .curve(let type) = property.gradeSlot { return .curve(localGrade.gradeCurve(type)) }
        return baseValue(of: property).map { .number($0) }
    }

    mutating func setBaseKeyframeValue(_ value: KeyframeValue, of property: AnimatableProperty) {
        switch value {
        case .number(let number): setBaseValue(number, of: property)
        case .curve(let curve):
            guard case .curve(let type) = property.gradeSlot else { return }
            localGrade.setGradeCurve(curve, for: type)
        case .color: break
        }
    }

    func evaluatedValue(of property: AnimatableProperty, atLocal local: TimelineTime) -> Double? {
        if let track = animation?.track(property), let value = track.value(at: local)?.number {
            return value
        }
        return baseValue(of: property)
    }

    /// The layer as actually rendered at a clip-local time. Authored values are
    /// never mutated, so evaluating cannot dirty the project.
    func evaluated(atLocal local: TimelineTime) -> MaskedGradeLayer {
        guard let animation, !animation.isEmpty else { return self }
        var copy = self
        for track in animation.tracks {
            guard let value = track.value(at: local)?.clamped(to: track.property) else { continue }
            copy.setBaseKeyframeValue(value, of: track.property)
        }
        return copy
    }

    /// True when this layer's colour changes over time, as opposed to its shape.
    var hasGradeAnimation: Bool {
        animation?.tracks.contains { $0.property.isGradeProperty && !$0.isEmpty } ?? false
    }

    /// Scales keyframe times with a clip speed change, for the same reason
    /// `ClipAnimation.retimed` exists: mask keyframes are clip-local times.
    func retimed(by factor: Double) -> MaskedGradeLayer {
        guard let animation, !animation.isEmpty else { return self }
        var copy = self
        copy.animation = animation.retimed(by: factor)
        return copy
    }
}

// MARK: - Collection helpers

extension Array where Element == MaskedGradeLayer {
    /// The layers the renderer will actually evaluate, in list order and within
    /// the stack budget. One place decides this so preview, scopes and export
    /// can never disagree about which masks are live.
    var renderable: [MaskedGradeLayer] {
        filter(\.isRenderable).prefix(MaskedGradeLayer.maximumPerClip).map(\.resolved)
    }

    /// Every layer evaluated for one clip-local time.
    func evaluated(atLocal local: TimelineTime) -> [MaskedGradeLayer] {
        map { $0.evaluated(atLocal: local) }
    }

    /// "Mask 1", "Mask 2"… skipping names already taken.
    func nextDefaultName() -> String {
        let taken = Set(map(\.name))
        var index = count + 1
        while taken.contains(String(localized: "Mask \(index)")) { index += 1 }
        return String(localized: "Mask \(index)")
    }
}
