import Foundation

// ---------------------------------------------------------------------------
// Relight animation
//
// There is no relight keyframe engine. A light reuses `AnimationTrack`,
// `Keyframe` and `KeyframeValue` unchanged, exactly as a masked local grade
// does; only the binding from property to storage is local, because a clip
// holds several lights and the project-wide property enum addresses one slot.
//
// Light keyframes are CLIP-LOCAL times read against the clip's own animation
// window, so a trim, a split or a speed change moves them exactly as it moves
// a transform's — and, like mask keyframes, they never push a project onto the
// layer compositor: the direct preview and export paths evaluate them too.
// ---------------------------------------------------------------------------

extension RelightLight {
    /// Every numeric property a light can carry, in inspector order.
    static let numericProperties: [AnimatableProperty] = [
        .relightPositionX, .relightPositionY, .relightDistance,
        .relightTargetX, .relightTargetY, .relightAzimuth, .relightElevation,
        .relightIntensity, .relightExposure, .relightTemperature, .relightTint,
        .relightSoftness, .relightFalloff, .relightRadius,
        .relightConeAngle, .relightFeather, .relightShadow
    ]

    /// Numeric properties plus the colour filter.
    static let animatableProperties: [AnimatableProperty] = numericProperties + [.relightColor]

    /// Whether `property` means anything for a light of `type`. A directional
    /// light has no position and a point light has no cone; offering their
    /// diamonds would offer keyframes that change nothing.
    static func supports(_ property: AnimatableProperty, type: RelightLightType) -> Bool {
        switch property {
        case .relightPositionX, .relightPositionY, .relightDistance, .relightFalloff, .relightRadius:
            return type.isPositional
        case .relightTargetX, .relightTargetY, .relightConeAngle, .relightFeather:
            return type == .spot
        case .relightAzimuth, .relightElevation:
            return type == .directional
        case .relightIntensity, .relightExposure, .relightTemperature, .relightTint,
             .relightSoftness, .relightShadow, .relightColor:
            return true
        default:
            return false
        }
    }

    func supports(_ property: AnimatableProperty) -> Bool {
        Self.supports(property, type: type)
    }

    var isAnimated: Bool { animation.map { !$0.isEmpty } ?? false }

    /// The authored value of one numeric property.
    func number(of property: AnimatableProperty) -> Double? {
        switch property {
        case .relightPositionX: positionX
        case .relightPositionY: positionY
        case .relightDistance: distance
        case .relightTargetX: targetX
        case .relightTargetY: targetY
        case .relightAzimuth: azimuth
        case .relightElevation: elevation
        case .relightIntensity: intensity
        case .relightExposure: exposure
        case .relightTemperature: temperature
        case .relightTint: tint
        case .relightSoftness: softness
        case .relightFalloff: falloff
        case .relightRadius: radius
        case .relightConeAngle: coneAngle
        case .relightFeather: feather
        case .relightShadow: shadowResponse
        default: nil
        }
    }

    /// Writes one numeric property, clamped to the range its keyframes are
    /// held to — the same bound, so adding a first keyframe never moves a value.
    mutating func setNumber(_ value: Double, of property: AnimatableProperty) {
        let clamped = property.clamped(value)
        switch property {
        case .relightPositionX: positionX = clamped
        case .relightPositionY: positionY = clamped
        case .relightDistance: distance = clamped
        case .relightTargetX: targetX = clamped
        case .relightTargetY: targetY = clamped
        case .relightAzimuth: azimuth = Self.normalizedAzimuth(value)
        case .relightElevation: elevation = clamped
        case .relightIntensity: intensity = clamped
        case .relightExposure: exposure = clamped
        case .relightTemperature: temperature = clamped
        case .relightTint: tint = clamped
        case .relightSoftness: softness = clamped
        case .relightFalloff: falloff = clamped
        case .relightRadius: radius = clamped
        case .relightConeAngle: coneAngle = clamped
        case .relightFeather: feather = clamped
        case .relightShadow: shadowResponse = clamped
        default: break
        }
    }

    /// Any angle brought into 0..<360, which is the range a bearing is stored in.
    static func normalizedAzimuth(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    func baseKeyframeValue(of property: AnimatableProperty) -> KeyframeValue? {
        if property == .relightColor { return .color(color) }
        return number(of: property).map { .number($0) }
    }

    mutating func setBaseKeyframeValue(_ value: KeyframeValue, of property: AnimatableProperty) {
        switch value {
        case .number(let number): setNumber(number, of: property)
        case .color(let rgba):
            guard property == .relightColor else { return }
            color = RGBAColor(red: min(max(rgba.red, 0), 1),
                              green: min(max(rgba.green, 0), 1),
                              blue: min(max(rgba.blue, 0), 1))
        case .curve: break
        }
    }

    /// The light as rendered at a clip-local time. Authored values are never
    /// mutated, so evaluating cannot dirty the project.
    func evaluated(atLocal local: TimelineTime) -> RelightLight {
        guard let animation, !animation.isEmpty else { return self }
        var copy = self
        for track in animation.tracks {
            guard let value = track.value(at: local)?.clamped(to: track.property) else { continue }
            copy.setBaseKeyframeValue(value, of: track.property)
        }
        return copy
    }

    /// Scales keyframe times with a clip speed change, as `ClipAnimation.retimed` does.
    func retimed(by factor: Double) -> RelightLight {
        guard let animation, !animation.isEmpty else { return self }
        var copy = self
        copy.animation = animation.retimed(by: factor)
        return copy
    }

    /// The same, through an arbitrary remapping, for a ramp.
    func retimed(through remap: (TimelineTime) -> TimelineTime) -> RelightLight {
        guard let animation, !animation.isEmpty else { return self }
        var copy = self
        copy.animation = animation.retimed(through: remap)
        return copy
    }
}

extension RelightSettings {
    /// Scene-wide properties the relight itself animates.
    static let animatableProperties: [AnimatableProperty] = [.relightStrength]

    var isAnimated: Bool {
        (animation.map { !$0.isEmpty } ?? false) || lights.contains(where: \.isAnimated)
    }

    func number(of property: AnimatableProperty) -> Double? {
        property == .relightStrength ? strength : nil
    }

    mutating func setNumber(_ value: Double, of property: AnimatableProperty) {
        guard property == .relightStrength else { return }
        strength = property.clamped(value)
    }

    /// The relight as rendered at a clip-local time: its own strength track and
    /// every light's tracks evaluated.
    func evaluated(atLocal local: TimelineTime) -> RelightSettings {
        guard isAnimated else { return self }
        var copy = self
        if let animation, !animation.isEmpty {
            for track in animation.tracks {
                guard let value = track.value(at: local)?.clamped(to: track.property),
                      let number = value.number else { continue }
                copy.setNumber(number, of: track.property)
            }
        }
        copy.lights = lights.map { $0.evaluated(atLocal: local) }
        return copy
    }

    func retimed(by factor: Double) -> RelightSettings {
        guard isAnimated else { return self }
        var copy = self
        copy.animation = animation?.retimed(by: factor)
        copy.lights = lights.map { $0.retimed(by: factor) }
        return copy
    }

    func retimed(through remap: (TimelineTime) -> TimelineTime) -> RelightSettings {
        guard isAnimated else { return self }
        var copy = self
        copy.animation = animation?.retimed(through: remap)
        copy.lights = lights.map { $0.retimed(through: remap) }
        return copy
    }

    /// Every keyframe time this relight carries, clip-local, deduplicated.
    var keyframeLocalTimes: [TimelineTime] {
        var times: [TimelineTime] = []
        func collect(_ animation: ClipAnimation?) {
            for track in animation?.tracks ?? [] {
                for frame in track.keyframes where !times.contains(frame.time) { times.append(frame.time) }
            }
        }
        collect(animation)
        for light in lights { collect(light.animation) }
        return times.sorted()
    }
}

// MARK: - Clips

extension VideoClip {
    /// The clip's authored relight, or nil when it has none.
    var resolvedRelight: RelightSettings? { gradeSettings.advanced?.relight }

    /// The relight as rendered at a clip-local time, or nil when there is
    /// nothing to render. Light keyframes are read against the clip's own
    /// animation window, which is the window mask keyframes use as well.
    func evaluatedRelight(atLocal local: TimelineTime) -> RelightSettings? {
        guard let relight = gradeSettings.advanced?.relight else { return nil }
        let evaluated = relight.evaluated(atLocal: local)
        return evaluated.isActive ? evaluated : nil
    }

    /// The same, for a composition time, through the single clock conversion.
    func evaluatedRelight(at composition: TimelineTime) -> RelightSettings? {
        guard let relight = gradeSettings.advanced?.relight else { return nil }
        guard relight.isAnimated, let local = localTime(for: composition) else {
            return relight.isActive ? relight : nil
        }
        return evaluatedRelight(atLocal: local)
    }

    /// True when this clip's relight changes over time.
    var hasRelightAnimation: Bool { resolvedRelight?.isAnimated ?? false }
}
