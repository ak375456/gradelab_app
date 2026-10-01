import Foundation

// ---------------------------------------------------------------------------
// Relight: the authored model
//
// Relight changes the apparent lighting of a recorded shot. It does that from
// an ESTIMATE of the scene's geometry — a relative depth map, derived surface
// orientation and a confidence for both — not from a reconstruction of it, and
// nothing in this model pretends otherwise. The lights described here are
// image-space lights that react to that estimated geometry: a key placed on the
// right brightens the surfaces that face right and leaves the ones facing away
// alone, which is what makes the result read as light rather than as a mask.
//
// What lives here is only what a person authored: the lights, where they are,
// what colour they are, how strong. The depth analysis is rebuildable cache
// data and lives outside the document (see `RelightDepthStore`), for the same
// reason background-removal mattes do — it is large, it is derived entirely
// from the media, and losing it costs a re-analysis rather than any work.
//
// It sits on the grade (`AdvancedGrade.relight`) beside noise reduction, so it
// inherits persistence, undo coalescing, copy/paste and presets without a line
// of code in any of them. Its animation is the project-wide keyframe engine:
// each light carries a `ClipAnimation`, exactly as a masked local grade does,
// because a clip holds several lights and the property enum addresses one slot.
// ---------------------------------------------------------------------------

/// The three kinds of virtual light.
enum RelightLightType: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A distant source: sun, window, overall direction. Has a direction and
    /// no position.
    case directional
    /// Light radiating from a place in the scene: a lamp, a phone torch, a
    /// practical. Has a position, a depth and a reach.
    case point
    /// A focused cone: stage light, dramatic face light. A point light that is
    /// also aimed.
    case spot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directional: String(localized: "Directional")
        case .point: String(localized: "Point")
        case .spot: String(localized: "Spot")
        }
    }

    var symbol: String {
        switch self {
        case .directional: "sun.max.fill"
        case .point: "lightbulb.fill"
        case .spot: "flashlight.on.fill"
        }
    }

    /// The selector the shader reads.
    var shaderCode: Float {
        switch self {
        case .directional: 0
        case .point: 1
        case .spot: 2
        }
    }

    /// Whether the light sits at a place in the picture rather than infinitely far away.
    var isPositional: Bool { self != .directional }
}

/// One virtual light.
///
/// Placement is in the clip's DISPLAY-normalised space — the upright picture a
/// person sees, top-left origin — not in encoded source coordinates. A phone
/// shot recorded sideways is still lit "from the right" when the light is on
/// the right of what is on screen. The renderer converts once, per pixel, with
/// the same orientation the viewer applies.
struct RelightLight: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var type: RelightLightType
    /// The eye. A disabled light keeps every value and renders nothing.
    var isEnabled: Bool

    /// Where a point or spot light is, 0...1 across and down the picture.
    /// Allowed a little outside the frame, which is where a key often is.
    var positionX: Double
    var positionY: Double
    /// How far the light is from the camera. 0 is in front of everything, near
    /// the lens; 1 is far behind the subject, which turns a point light into a
    /// rim or background light.
    var distance: Double
    /// Where a spotlight is aimed, in the same space as its position.
    var targetX: Double
    var targetY: Double
    /// A directional light's bearing in the picture plane, in degrees.
    /// 0 lights from the right, 90 from the top, 180 from the left.
    var azimuth: Double
    /// How far a directional light comes from in front of the scene, in
    /// degrees. 90 is from the camera, 0 is pure side light, and negative
    /// comes from behind the subject.
    var elevation: Double
    /// Percent. 100 is a normal light, above it is stylised, and below zero
    /// the light takes light away — negative fill.
    var intensity: Double
    /// Stops a fully lit surface gains at 100%. Kept apart from intensity so
    /// the photographic amount and the artistic dial are separate controls.
    var exposure: Double
    /// A colour filter over the light, sRGB-authored like every colour in the
    /// document. White leaves temperature and tint to decide the colour.
    var color: RGBAColor
    /// Kelvin. 6500 is neutral daylight; lower is warmer.
    var temperature: Double
    /// Green (negative) to magenta (positive), -100...100.
    var tint: Double
    /// 0 is a hard source, 1 an enormous soft one. Widens the falloff across a
    /// surface and reads geometry at a larger scale; it is not a blur.
    var softness: Double
    /// How quickly a point or spot light dies away with distance. 0 soft,
    /// 0.5 natural, 1 strong.
    var falloff: Double
    /// A point or spot light's reach, in frame heights.
    var radius: Double
    /// A spotlight's half-angle, in degrees.
    var coneAngle: Double
    /// How much of the cone's edge is soft, 0...1.
    var feather: Double
    /// How strongly surfaces turned away from this light darken. Zero is
    /// "light only": the light adds and never takes. It does not invent cast
    /// shadows — it shades the side of a form that faces away.
    var shadowResponse: Double
    /// A small specular term. Off by default: a heavy one makes skin plastic.
    var specular: Double
    var roughness: Double
    /// Light that wraps a little way around silhouette edges. Subtle by
    /// design; too much reads as glow.
    var lightWrap: Double
    /// This light's keyframes, read against the clip's own animation window
    /// so a trim or a split moves them exactly as it moves a transform's.
    var animation: ClipAnimation?

    init(
        id: UUID = UUID(),
        name: String,
        type: RelightLightType,
        isEnabled: Bool = true,
        positionX: Double = 0.78,
        positionY: Double = 0.32,
        distance: Double = 0.25,
        targetX: Double = 0.5,
        targetY: Double = 0.45,
        azimuth: Double = 25,
        elevation: Double = 35,
        intensity: Double = 100,
        exposure: Double = 1,
        color: RGBAColor = .white,
        temperature: Double = 6500,
        tint: Double = 0,
        softness: Double = 0.5,
        falloff: Double = 0.5,
        radius: Double = 0.9,
        coneAngle: Double = 26,
        feather: Double = 0.5,
        shadowResponse: Double = 0,
        specular: Double = 0,
        roughness: Double = 0.6,
        lightWrap: Double = 0,
        animation: ClipAnimation? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isEnabled = isEnabled
        self.positionX = positionX
        self.positionY = positionY
        self.distance = distance
        self.targetX = targetX
        self.targetY = targetY
        self.azimuth = azimuth
        self.elevation = elevation
        self.intensity = intensity
        self.exposure = exposure
        self.color = color
        self.temperature = temperature
        self.tint = tint
        self.softness = softness
        self.falloff = falloff
        self.radius = radius
        self.coneAngle = coneAngle
        self.feather = feather
        self.shadowResponse = shadowResponse
        self.specular = specular
        self.roughness = roughness
        self.lightWrap = lightWrap
        self.animation = animation
    }

    /// A new light of `type`, placed where that kind of light is usually
    /// useful first: a key up and to the right, a spot aimed at the middle.
    static func starting(_ type: RelightLightType, name: String) -> RelightLight {
        var light = RelightLight(name: name, type: type)
        switch type {
        case .directional:
            light.softness = 0.55
            light.shadowResponse = 0.25
        case .point:
            light.positionX = 0.74; light.positionY = 0.36
            light.distance = 0.22; light.radius = 0.9
        case .spot:
            light.positionX = 0.8; light.positionY = 0.18
            light.distance = 0.15; light.radius = 1.4
            light.targetX = 0.5; light.targetY = 0.45
            light.softness = 0.35
        }
        return light
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, isEnabled, positionX, positionY, distance, targetX, targetY
        case azimuth, elevation, intensity, exposure, color, temperature, tint
        case softness, falloff, radius, coneAngle, feather, shadowResponse
        case specular, roughness, lightWrap, animation
    }

    /// Tolerant of documents written by a newer build: a missing value falls
    /// back to a default that renders rather than failing the open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RelightLight(name: "", type: .point)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "Light")
        type = (try? c.decodeIfPresent(RelightLightType.self, forKey: .type)) ?? .point
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        func number(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        positionX = try number(.positionX, defaults.positionX)
        positionY = try number(.positionY, defaults.positionY)
        distance = try number(.distance, defaults.distance)
        targetX = try number(.targetX, defaults.targetX)
        targetY = try number(.targetY, defaults.targetY)
        azimuth = try number(.azimuth, defaults.azimuth)
        elevation = try number(.elevation, defaults.elevation)
        intensity = try number(.intensity, defaults.intensity)
        exposure = try number(.exposure, defaults.exposure)
        color = try c.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .white
        temperature = try number(.temperature, defaults.temperature)
        tint = try number(.tint, defaults.tint)
        softness = try number(.softness, defaults.softness)
        falloff = try number(.falloff, defaults.falloff)
        radius = try number(.radius, defaults.radius)
        coneAngle = try number(.coneAngle, defaults.coneAngle)
        feather = try number(.feather, defaults.feather)
        shadowResponse = try number(.shadowResponse, defaults.shadowResponse)
        specular = try number(.specular, defaults.specular)
        roughness = try number(.roughness, defaults.roughness)
        lightWrap = try number(.lightWrap, defaults.lightWrap)
        animation = try c.decodeIfPresent(ClipAnimation.self, forKey: .animation)
    }

    /// The light as it reaches the GPU: every value finite and inside the
    /// range its keyframe property allows, so a hand-edited document cannot
    /// send the shader a NaN or a negative radius. Authored values are left
    /// alone; this is the resolved render value.
    var clamped: RelightLight {
        var value = self
        for property in Self.numericProperties {
            guard let current = value.number(of: property) else { continue }
            let fallback = property.defaultValue.number ?? 0
            value.setNumber(current.isFinite ? current : fallback, of: property)
        }
        value.color = RGBAColor(red: min(max(color.red.isFinite ? color.red : 1, 0), 1),
                                green: min(max(color.green.isFinite ? color.green : 1, 0), 1),
                                blue: min(max(color.blue.isFinite ? color.blue : 1, 0), 1))
        value.specular = min(max(specular.isFinite ? specular : 0, 0), 1)
        value.roughness = min(max(roughness.isFinite ? roughness : 0.6, 0), 1)
        value.lightWrap = min(max(lightWrap.isFinite ? lightWrap : 0, 0), 1)
        return value
    }

    /// Whether this light can change a pixel at all.
    var contributes: Bool {
        isEnabled && intensity.isFinite && abs(intensity) > 0.01
            && exposure.isFinite && exposure > 0.001
    }

    /// A copy with a new identity, for Duplicate.
    func duplicated(named name: String) -> RelightLight {
        replacingIdentity(with: UUID(), name: name)
    }

    private func replacingIdentity(with id: UUID, name: String) -> RelightLight {
        RelightLight(id: id, name: name, type: type, isEnabled: isEnabled,
                     positionX: positionX, positionY: positionY, distance: distance,
                     targetX: targetX, targetY: targetY, azimuth: azimuth, elevation: elevation,
                     intensity: intensity, exposure: exposure, color: color,
                     temperature: temperature, tint: tint, softness: softness, falloff: falloff,
                     radius: radius, coneAngle: coneAngle, feather: feather,
                     shadowResponse: shadowResponse, specular: specular, roughness: roughness,
                     lightWrap: lightWrap, animation: animation)
    }
}

/// How much work the depth analysis does. Fast is for previewing on a busy
/// device; High is denser, steadier and what export always uses where the
/// device can run it.
enum RelightQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: String(localized: "Fast")
        case .high: String(localized: "High")
        }
    }

    // MARK: Preference

    private static let defaultsKey = "relight.previewQuality"

    /// The preview's choice. A preference rather than part of the document,
    /// like the playback quality: it says how hard this device should work
    /// while editing, not what the finished picture is.
    static func loadPreference() -> RelightQuality {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(RelightQuality.init(rawValue:)) ?? .fast
    }

    func savePreference() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// What depth analysis this relight was set up against.
///
/// Recorded for the document's own honesty — which analysis generation and
/// which media the lights were placed on — not used to find the cache: the
/// renderer derives the cache identity from the media itself every time, so a
/// replaced file or a newer analysis version can never be paired with stale
/// depth by a reference that went out of date.
struct RelightAnalysisReference: Codable, Equatable, Sendable {
    /// `RelightSettings.analysisVersion` at the time of analysis.
    var version: Int
    /// The media identity the cache is filed under.
    var cacheIdentifier: String
    var quality: RelightQuality
    var startedAt: Date
}

/// Relight on one clip: a set of lights and the scene-wide controls they share.
struct RelightSettings: Codable, Equatable, Sendable {
    /// Bumped whenever the analysis changes in a way that makes older cached
    /// depth unusable. Part of the cache directory, so an old cache is simply
    /// never found rather than misread.
    static let analysisVersion = 1
    /// How many lights one relight renders. The lights travel in one uniform
    /// block alongside the rest of the frame's state, and six covers a key, a
    /// fill, a rim and a background with room to spare.
    static let maximumLights = 6

    /// Relight ON/OFF. Off keeps every light and renders none of them.
    var isEnabled: Bool
    var lights: [RelightLight]
    /// Blends the original picture with the relit one, 0...1.
    var strength: Double
    /// Rolls added light off smoothly before it reaches white, 0...1.
    var preserveHighlights: Double
    /// Keeps the deepest blacks from being lifted by added light, 0...1.
    var protectBlacks: Double
    /// How strongly the light follows the estimated form, 0.25...3. 1 is the
    /// analysis as measured; lower flattens the modelling toward an even
    /// wash, higher sculpts harder. An artistic dial on the response, not a
    /// setting of the depth analysis — which is why it is safe to offer.
    var form: Double
    /// Limits the relight to one of the clip's masked grades. Nil is the whole
    /// frame. A mask that no longer exists — the grade was pasted onto another
    /// clip, or the mask was deleted — reads as the whole frame, and the panel
    /// shows exactly that, so what is drawn and what is described agree.
    var maskID: UUID?
    var analysis: RelightAnalysisReference?
    /// Scene-wide animation: today the strength.
    var animation: ClipAnimation?

    init(
        isEnabled: Bool = true,
        lights: [RelightLight] = [],
        strength: Double = 1,
        preserveHighlights: Double = 0.7,
        protectBlacks: Double = 0.35,
        form: Double = 1,
        maskID: UUID? = nil,
        analysis: RelightAnalysisReference? = nil,
        animation: ClipAnimation? = nil
    ) {
        self.isEnabled = isEnabled
        self.lights = lights
        self.strength = strength
        self.preserveHighlights = preserveHighlights
        self.protectBlacks = protectBlacks
        self.form = form
        self.maskID = maskID
        self.analysis = analysis
        self.animation = animation
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, lights, strength, preserveHighlights, protectBlacks, form, maskID, analysis, animation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lights = try c.decodeIfPresent([RelightLight].self, forKey: .lights) ?? []
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        preserveHighlights = try c.decodeIfPresent(Double.self, forKey: .preserveHighlights) ?? 0.7
        protectBlacks = try c.decodeIfPresent(Double.self, forKey: .protectBlacks) ?? 0.35
        form = try c.decodeIfPresent(Double.self, forKey: .form) ?? 1
        maskID = try c.decodeIfPresent(UUID.self, forKey: .maskID)
        analysis = try? c.decodeIfPresent(RelightAnalysisReference.self, forKey: .analysis)
        animation = try c.decodeIfPresent(ClipAnimation.self, forKey: .animation)
    }

    /// Whether the relight would change a pixel, before any depth is known.
    var isActive: Bool {
        isEnabled && strength.isFinite && strength > 0.0005
            && lights.prefix(Self.maximumLights).contains(where: \.contributes)
    }

    /// The lights that reach the GPU, in list order, within the budget.
    var renderableLights: [RelightLight] {
        Array(lights.filter(\.contributes).prefix(Self.maximumLights)).map(\.clamped)
    }

    var resolvedStrength: Double {
        strength.isFinite ? min(max(strength, 0), 1) : 1
    }

    var resolvedPreserveHighlights: Double {
        preserveHighlights.isFinite ? min(max(preserveHighlights, 0), 1) : 0.7
    }

    var resolvedProtectBlacks: Double {
        protectBlacks.isFinite ? min(max(protectBlacks, 0), 1) : 0.35
    }

    static let formRange: ClosedRange<Double> = 0.25...3

    var resolvedForm: Double {
        form.isFinite ? min(max(form, Self.formRange.lowerBound), Self.formRange.upperBound) : 1
    }

    /// "Light 1", "Light 2"… skipping names already taken.
    func nextLightName() -> String {
        let taken = Set(lights.map(\.name))
        var index = lights.count + 1
        while taken.contains(String(localized: "Light \(index)")) { index += 1 }
        return String(localized: "Light \(index)")
    }

    /// True when nothing about this relight would survive being dropped: no
    /// lights, and every scene value where a new relight starts. Used to store
    /// nothing rather than an empty block.
    var isEmpty: Bool {
        lights.isEmpty && animation == nil && maskID == nil
    }
}

extension AdvancedGrade {
    /// The relight the pipeline applies, or nil when there is nothing to apply.
    ///
    /// Nil rather than an inactive value for the same reason the noise
    /// reduction and the warp resolve to nil: every consumer — the three render
    /// paths, the analysis prompt, the exporter's preparation — tests one thing
    /// and skips the work entirely.
    var resolvedRelight: RelightSettings? {
        guard let relight, relight.isActive else { return nil }
        return relight
    }
}
