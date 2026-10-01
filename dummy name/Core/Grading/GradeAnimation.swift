import Foundation

// ---------------------------------------------------------------------------
// Animated colour grading
//
// There is no second keyframe engine here, and no parallel "grade animation"
// document. A grading parameter is an ordinary `AnimatableProperty` whose
// storage happens to be `GradeSettings`, and this file is the whole of that
// binding: which slot a property addresses, what it is called, what it is
// allowed to hold, and how to read and write it.
//
// The consequence is the architecture the rest of the app already has:
//
//     GradeSettings          the BASE grade. Authored. Never written by playback.
//     ClipAnimation          the tracks, exactly as transforms and text use them.
//     evaluated(atLocal:)    base + tracks + clip-local time -> a COPY
//
// The copy's `gradeSettings` IS the effective grade, so every existing consumer
// — the Metal uniforms, the curve LUT, the scopes, the exporter — keeps reading
// a plain `GradeSettings` and needs to know nothing about time.
// ---------------------------------------------------------------------------

/// Where a grading `AnimatableProperty` reads and writes.
///
/// Deliberately values rather than key paths: this is consulted on the render
/// thread for every animated property of every frame, and an enum switch costs
/// nothing while a key path built per call allocates.
enum GradeSlot: Hashable, Sendable {
    /// One of the ten top-level scalars: exposure through vibrance.
    case light(GradeParameter)
    case hslHue(Int), hslSaturation(Int), hslLuminance(Int)
    case wheelHue(Int), wheelStrength(Int), wheelBrightness(Int)
    case vignetteAmount, vignetteMidpoint, vignetteFeather
    /// The creative look's strength. The look itself stays a discrete choice.
    case lookIntensity
    case effect(FilmEffectSlot)
    /// A whole-curve snapshot track.
    case curve(CurveType)
    /// How hard the Color Warper pulls. The warp POINTS are not animated here:
    /// a moving point needs a whole-warp snapshot track, the way a curve does,
    /// and this is the scalar half that costs nothing to support.
    case colorWarpStrength
}

/// The finishing effects, named so a slot can address one without carrying a
/// key path. Raw values match `FilmEffectParameter.id` so the panel can pair
/// them up without a second table.
enum FilmEffectSlot: String, Hashable, Sendable, CaseIterable {
    case fade, sharpness, bloom, glow, halation, grain

    var keyPath: WritableKeyPath<FilmEffects, Float> {
        switch self {
        case .fade: \.fade
        case .sharpness: \.sharpness
        case .bloom: \.bloom
        case .glow: \.glow
        case .halation: \.halation
        case .grain: \.grain
        }
    }

    var title: String {
        switch self {
        case .fade: String(localized: "Fade")
        case .sharpness: String(localized: "Sharpen")
        case .bloom: String(localized: "Bloom")
        case .glow: String(localized: "Glow")
        case .halation: String(localized: "Halation")
        case .grain: String(localized: "Grain")
        }
    }
}

// MARK: - Slot metadata

extension GradeSlot {
    var kind: AnimatableProperty.Kind {
        if case .curve = self { return .curve }
        return .number
    }

    var title: String {
        switch self {
        case .light(let parameter): parameter.title
        case .hslHue(let band): String(localized: "\(HueBand.name(band)) hue")
        case .hslSaturation(let band): String(localized: "\(HueBand.name(band)) saturation")
        case .hslLuminance(let band): String(localized: "\(HueBand.name(band)) lightness")
        case .wheelHue(let wheel): String(localized: "\(GradingWheel.name(wheel)) hue")
        case .wheelStrength(let wheel): String(localized: "\(GradingWheel.name(wheel)) color strength")
        case .wheelBrightness(let wheel): String(localized: "\(GradingWheel.name(wheel)) brightness")
        case .vignetteAmount: String(localized: "Vignette amount")
        case .vignetteMidpoint: String(localized: "Vignette midpoint")
        case .vignetteFeather: String(localized: "Vignette feather")
        case .lookIntensity: String(localized: "Look strength")
        case .colorWarpStrength: String(localized: "Color Warper strength")
        case .effect(let effect): effect.title
        case .curve(let type): String(localized: "\(type.title) curve")
        }
    }

    /// Storable bounds, chosen to cover every value the panels can author.
    ///
    /// Wider than the slider where the two differ: an HSL hue slider offers
    /// ±30°, but a grade arriving from a hand-edited document or a future build
    /// must not have its first keyframe silently snapped.
    var range: ClosedRange<Double> {
        switch self {
        case .light(let parameter):
            Double(parameter.range.lowerBound)...Double(parameter.range.upperBound)
        case .hslHue: -180...180
        case .hslSaturation, .hslLuminance: -100...100
        case .wheelHue: 0...360
        case .wheelStrength: 0...100
        case .wheelBrightness: -100...100
        case .vignetteAmount: -100...100
        case .vignetteMidpoint, .vignetteFeather: 0...100
        case .lookIntensity: 0...100
        case .colorWarpStrength: 0...100
        case .effect: Double(FilmEffects.range.lowerBound)...Double(FilmEffects.range.upperBound)
        // Curve keyframes carry a curve, not a number; the bound is unused and
        // is stated only so the property always has one.
        case .curve: 0...1
        }
    }

    /// The value "Reset this property" restores: the grading neutral, which is
    /// not always zero.
    var defaultValue: KeyframeValue {
        switch self {
        case .vignetteMidpoint: .number(50)
        case .vignetteFeather: .number(70)
        case .lookIntensity: .number(100)
        case .colorWarpStrength: .number(100)
        case .curve(let type): .curve(.neutral(type))
        default: .number(0)
        }
    }

    /// Degrees in one full turn, for the parameters that are angles. Nil means
    /// a plain quantity, interpolated the ordinary way.
    var angularCycle: Double? {
        switch self {
        case .hslHue, .wheelHue: 360
        default: nil
        }
    }

    /// True when the property's whole range IS the circle, so an interpolated
    /// result should be brought back into it instead of clamped to an end.
    /// A hue SHIFT of ±30° is cyclic in the short-path sense but not in this
    /// one: -170 and +190 are not the same shift to ask for.
    var wrapsAngularRange: Bool {
        if case .wheelHue = self { return true }
        return false
    }

    /// The panel this parameter lives in, for the "this panel contains
    /// animation" indicator and for Remove Animation on a panel reset.
    var panel: GradePanel {
        switch self {
        case .light(let parameter): GradeParameter.light.contains(parameter) ? .light : .color
        case .hslHue, .hslSaturation, .hslLuminance: .hsl
        case .wheelHue, .wheelStrength, .wheelBrightness: .wheels
        case .vignetteAmount, .vignetteMidpoint, .vignetteFeather: .vignette
        case .lookIntensity: .lut
        case .colorWarpStrength: .warper
        case .effect: .effects
        case .curve: .curves
        }
    }
}

extension HueBand {
    static func name(_ index: Int) -> String {
        names.indices.contains(index) ? names[index] : String(localized: "Color")
    }
}

extension GradingWheel {
    static var names: [String] {
        [String(localized: "Shadows"), String(localized: "Midtones"),
         String(localized: "Highlights"), String(localized: "Offset")]
    }
    static func name(_ index: Int) -> String {
        names.indices.contains(index) ? names[index] : String(localized: "Wheel")
    }
}

// MARK: - Property -> slot

extension AnimatableProperty {
    /// The grading slot this property addresses, or nil when it is a transform,
    /// a mask geometry or a text property.
    ///
    /// The one table. Everything else about a grading property — its name, its
    /// range, its neutral, whether it is an angle, which panel shows it — is
    /// derived from what this returns.
    var gradeSlot: GradeSlot? {
        switch self {
        case .gradeExposure: .light(.exposure)
        case .gradeContrast: .light(.contrast)
        case .gradeHighlights: .light(.highlights)
        case .gradeShadows: .light(.shadows)
        case .gradeWhites: .light(.whites)
        case .gradeBlacks: .light(.blacks)
        case .gradeTemperature: .light(.temperature)
        case .gradeTint: .light(.tint)
        case .gradeSaturation: .light(.saturation)
        case .gradeVibrance: .light(.vibrance)

        case .hslRedHue: .hslHue(0)
        case .hslRedSaturation: .hslSaturation(0)
        case .hslRedLuminance: .hslLuminance(0)
        case .hslOrangeHue: .hslHue(1)
        case .hslOrangeSaturation: .hslSaturation(1)
        case .hslOrangeLuminance: .hslLuminance(1)
        case .hslYellowHue: .hslHue(2)
        case .hslYellowSaturation: .hslSaturation(2)
        case .hslYellowLuminance: .hslLuminance(2)
        case .hslGreenHue: .hslHue(3)
        case .hslGreenSaturation: .hslSaturation(3)
        case .hslGreenLuminance: .hslLuminance(3)
        case .hslAquaHue: .hslHue(4)
        case .hslAquaSaturation: .hslSaturation(4)
        case .hslAquaLuminance: .hslLuminance(4)
        case .hslBlueHue: .hslHue(5)
        case .hslBlueSaturation: .hslSaturation(5)
        case .hslBlueLuminance: .hslLuminance(5)
        case .hslPurpleHue: .hslHue(6)
        case .hslPurpleSaturation: .hslSaturation(6)
        case .hslPurpleLuminance: .hslLuminance(6)
        case .hslMagentaHue: .hslHue(7)
        case .hslMagentaSaturation: .hslSaturation(7)
        case .hslMagentaLuminance: .hslLuminance(7)

        case .wheelShadowsHue: .wheelHue(0)
        case .wheelShadowsStrength: .wheelStrength(0)
        case .wheelShadowsBrightness: .wheelBrightness(0)
        case .wheelMidtonesHue: .wheelHue(1)
        case .wheelMidtonesStrength: .wheelStrength(1)
        case .wheelMidtonesBrightness: .wheelBrightness(1)
        case .wheelHighlightsHue: .wheelHue(2)
        case .wheelHighlightsStrength: .wheelStrength(2)
        case .wheelHighlightsBrightness: .wheelBrightness(2)
        case .wheelOffsetHue: .wheelHue(3)
        case .wheelOffsetStrength: .wheelStrength(3)
        case .wheelOffsetBrightness: .wheelBrightness(3)

        case .gradeVignette: .vignetteAmount
        case .gradeVignetteMidpoint: .vignetteMidpoint
        case .gradeVignetteFeather: .vignetteFeather
        case .gradeLookIntensity: .lookIntensity

        case .effectFade: .effect(.fade)
        case .effectSharpen: .effect(.sharpness)
        case .effectBloom: .effect(.bloom)
        case .effectGlow: .effect(.glow)
        case .effectHalation: .effect(.halation)
        case .effectGrain: .effect(.grain)

        case .gradeColorWarpStrength: .colorWarpStrength

        case .curveMaster: .curve(.master)
        case .curveRed: .curve(.red)
        case .curveGreen: .curve(.green)
        case .curveBlue: .curve(.blue)
        case .curveHueVsHue: .curve(.hueVsHue)
        case .curveHueVsSaturation: .curve(.hueVsSaturation)
        case .curveHueVsLuma: .curve(.hueVsLuma)
        case .curveLumaVsSaturation: .curve(.lumaVsSaturation)
        case .curveSaturationVsSaturation: .curve(.saturationVsSaturation)
        case .curveSaturationVsLuma: .curve(.saturationVsLuma)

        default: nil
        }
    }

    var isGradeProperty: Bool { gradeSlot != nil }

    /// A relight's bearing is an angle too, and its whole range is the circle:
    /// a light swinging from 350° to 10° passes through 0° rather than sweeping
    /// all the way round the subject the long way.
    var angularCycle: Double? { self == .relightAzimuth ? 360 : gradeSlot?.angularCycle }
    var wrapsAngularRange: Bool {
        self == .relightAzimuth || (gradeSlot?.wrapsAngularRange ?? false)
    }

    /// Every grading property, in panel order. Derived from the table above so
    /// a case that was added but never mapped simply is not offered, rather
    /// than being offered and doing nothing.
    static let gradeProperties: [AnimatableProperty] = allCases.filter(\.isGradeProperty)

    /// The reverse table, so a control that knows which slot it drives can find
    /// its property without a scan. Built once from the forward table, which is
    /// what keeps the two from ever disagreeing.
    private static let bySlot: [GradeSlot: AnimatableProperty] =
        gradeProperties.reduce(into: [:]) { table, property in
            if let slot = property.gradeSlot { table[slot] = property }
        }

    static func light(_ parameter: GradeParameter) -> AnimatableProperty? { bySlot[.light(parameter)] }
    static func hsl(band: Int, _ component: HueBandComponent) -> AnimatableProperty? {
        bySlot[component.slot(band)]
    }
    static func wheel(index: Int, _ component: WheelComponent) -> AnimatableProperty? {
        bySlot[component.slot(index)]
    }
    static func effect(_ slot: FilmEffectSlot) -> AnimatableProperty? { bySlot[.effect(slot)] }
    static func curve(_ type: CurveType) -> AnimatableProperty? { bySlot[.curve(type)] }
}

/// Which of a hue band's three values a control is driving.
enum HueBandComponent: Sendable {
    case hue, saturation, luminance
    func slot(_ band: Int) -> GradeSlot {
        switch self {
        case .hue: .hslHue(band)
        case .saturation: .hslSaturation(band)
        case .luminance: .hslLuminance(band)
        }
    }
}

/// The same for a colour wheel.
enum WheelComponent: Sendable {
    case hue, strength, brightness
    func slot(_ index: Int) -> GradeSlot {
        switch self {
        case .hue: .wheelHue(index)
        case .strength: .wheelStrength(index)
        case .brightness: .wheelBrightness(index)
        }
    }
}

// MARK: - Reading and writing a grade through a property

extension GradeSettings {
    /// The authored value of one grading property, or nil when the property is
    /// not a numeric grading parameter.
    func gradeNumber(_ property: AnimatableProperty) -> Double? {
        guard let slot = property.gradeSlot else { return nil }
        let advanced = self.advanced ?? .neutral
        switch slot {
        case .light(let parameter): return Double(self[keyPath: parameter.keyPath])
        case .hslHue(let band): return Double(advanced.band(band).hue)
        case .hslSaturation(let band): return Double(advanced.band(band).saturation)
        case .hslLuminance(let band): return Double(advanced.band(band).luminance)
        case .wheelHue(let index): return Double(advanced.wheel(index).hue)
        case .wheelStrength(let index): return Double(advanced.wheel(index).strength)
        case .wheelBrightness(let index): return Double(advanced.wheel(index).brightness)
        case .vignetteAmount: return Double(advanced.vignette)
        case .vignetteMidpoint: return Double(advanced.vignetteMidpoint)
        case .vignetteFeather: return Double(advanced.vignetteFeather)
        // The stored value is optional, but a strength control is never blank:
        // a look with no explicit strength is applied at full.
        case .lookIntensity: return Double(advanced.lutIntensity ?? 100)
        case .effect(let effect): return Double(advanced.resolvedEffects[keyPath: effect.keyPath])
        // Same reading as the look's strength: a warp with no explicit strength
        // is applied at full, so the control is never blank.
        case .colorWarpStrength: return Double(advanced.colorWarp?.strength ?? 100)
        case .curve: return nil
        }
    }

    /// Writes one grading property. Nothing else on the grade is touched.
    ///
    /// The optional storage `AdvancedGrade` uses to keep untouched projects
    /// small is maintained here: a write that leaves the advanced grade neutral
    /// puts it back to nil, so evaluating a clip that has no advanced grade
    /// cannot invent one.
    mutating func setGradeNumber(_ value: Double, for property: AnimatableProperty) {
        guard let slot = property.gradeSlot else { return }
        let clamped = Float(property.clamped(value))
        if case .light(let parameter) = slot {
            self[keyPath: parameter.keyPath] = clamped
            return
        }
        var advanced = self.advanced ?? .neutral
        switch slot {
        case .light: break
        case .hslHue(let band): advanced.editBand(band) { $0.hue = clamped }
        case .hslSaturation(let band): advanced.editBand(band) { $0.saturation = clamped }
        case .hslLuminance(let band): advanced.editBand(band) { $0.luminance = clamped }
        case .wheelHue(let index): advanced.editWheel(index) { $0.hue = clamped }
        case .wheelStrength(let index): advanced.editWheel(index) { $0.strength = clamped }
        case .wheelBrightness(let index): advanced.editWheel(index) { $0.brightness = clamped }
        case .vignetteAmount: advanced.vignette = clamped
        case .vignetteMidpoint: advanced.vignetteMidpoint = clamped
        case .vignetteFeather: advanced.vignetteFeather = clamped
        case .lookIntensity: advanced.lutIntensity = clamped
        case .effect(let effect):
            var effects = advanced.resolvedEffects
            effects[keyPath: effect.keyPath] = clamped
            effects.clamp()
            advanced.effects = effects.isNeutral ? nil : effects
        case .colorWarpStrength:
            // Only written when there is a warp to apply it to. Storing a
            // strength on its own would leave a project carrying a warper with
            // nothing in it, which `AdvancedGrade`'s optional storage exists to
            // avoid.
            if var warp = advanced.colorWarp {
                warp.strength = clamped
                advanced.colorWarp = warp
            }
        case .curve: break
        }
        self.advanced = advanced == .neutral ? nil : advanced
    }

    /// The authored curve of one type, resolved through the legacy migration so
    /// an old three-slider tone curve animates from where it actually is.
    func gradeCurve(_ type: CurveType) -> AdvancedCurve {
        (advanced ?? .neutral).resolvedCurves[type]
    }

    /// Writes one curve, clearing the legacy representation in the same write so
    /// the two can never both be live — the rule `EditorViewModel.editCurve`
    /// already follows for an authored edit.
    mutating func setGradeCurve(_ curve: AdvancedCurve, for type: CurveType) {
        var advanced = self.advanced ?? .neutral
        var curves = advanced.resolvedCurves
        curves[type] = curve
        advanced.advancedCurves = curves.isNeutral ? nil : curves
        advanced.curves = AdvancedGrade.neutral.curves
        self.advanced = advanced == .neutral ? nil : advanced
    }

    /// Read/write by property, for the generic keyframe engine.
    func gradeValue(_ property: AnimatableProperty) -> KeyframeValue? {
        if case .curve(let type) = property.gradeSlot { return .curve(gradeCurve(type)) }
        return gradeNumber(property).map { .number($0) }
    }

    mutating func setGradeValue(_ value: KeyframeValue, for property: AnimatableProperty) {
        switch value {
        case .number(let number): setGradeNumber(number, for: property)
        case .curve(let curve):
            guard case .curve(let type) = property.gradeSlot else { return }
            setGradeCurve(curve, for: type)
        case .color: break
        }
    }
}

extension AdvancedGrade {
    /// Grows the collection first, so a grade saved before a band existed can be
    /// written without `normalizeCollections()` rebuilding all three arrays.
    mutating func editBand(_ index: Int, _ edit: (inout HueBand) -> Void) {
        guard (0..<8).contains(index) else { return }
        while hsl.count < 8 { hsl.append(HueBand()) }
        edit(&hsl[index])
    }

    /// Four, not three, since the offset wheel. The bound was missed when it was
    /// added and every write to wheel 3 silently returned here, so the control
    /// moved and the picture never changed.
    mutating func editWheel(_ index: Int, _ edit: (inout GradingWheel) -> Void) {
        guard (0..<4).contains(index) else { return }
        while wheels.count < 4 { wheels.append(GradingWheel()) }
        edit(&wheels[index])
    }
}

// MARK: - Curve snapshot interpolation

extension AdvancedCurve {
    /// Authored points brought inside the space the curve is defined in, so a
    /// hand-edited document cannot store a point the evaluator has to guess at.
    var clampedToCurveSpace: AdvancedCurve {
        var copy = self
        // A mapping curve outputs a value in the same 0...1 units it reads; an
        // adjustment curve outputs a signed offset around zero.
        let lowest: Float = type.isMapping ? 0 : -1
        copy.points = points.prefix(Self.maximumSnapshotPoints).map { point in
            var value = point
            value.x = min(max(point.x.isFinite ? point.x : 0, 0), 1)
            value.y = min(max(point.y.isFinite ? point.y : 0, lowest), 1)
            return value
        }
        return copy
    }

    /// How many control points one snapshot may carry. Well above anything the
    /// editor can produce by hand; it exists so a malformed document cannot make
    /// the evaluator do unbounded work per frame.
    static let maximumSnapshotPoints = 128

    /// The blend of two snapshots of the same curve at `fraction`.
    ///
    /// The two snapshots need not share a topology — a user is free to add a
    /// control point between one keyframe and the next — so points are not
    /// paired by identity. Instead both curves are SAMPLED at the union of their
    /// x positions and those heights are what interpolate. That is exactly the
    /// curve-lookup-table interpolation the GPU would otherwise need, expressed
    /// as control points, which is what lets it reach the existing curve texture
    /// unchanged: the graph the user drags and the table the shader samples stay
    /// one curve rather than two approximations of one.
    ///
    /// Identities are carried over from the snapshots rather than minted, so
    /// evaluating a frame allocates no UUIDs and a selected point keeps its
    /// selection while the curve animates.
    static func interpolated(_ from: Self, _ to: Self, _ fraction: Float) -> Self {
        guard fraction > 0 else { return from }
        guard fraction < 1 else { return to }
        let fromPoints = from.sortedPoints
        let toPoints = to.sortedPoints
        // Same topology is the common case — the second snapshot is usually the
        // first one reshaped — and it needs no sampling at all.
        if fromPoints.count == toPoints.count {
            var blended = from
            blended.points = zip(fromPoints, toPoints).map { a, b in
                CurvePoint(id: a.id,
                           x: a.x + (b.x - a.x) * fraction,
                           y: a.y + (b.y - a.y) * fraction)
            }
            blended.interpolation = from.interpolation == to.interpolation ? from.interpolation : .monotoneCubic
            return blended
        }
        var xs: [(x: Float, id: UUID)] = fromPoints.map { ($0.x, $0.id) }
        for point in toPoints where !xs.contains(where: { abs($0.x - point.x) < 1e-6 }) {
            xs.append((point.x, point.id))
        }
        guard !xs.isEmpty else { return from }
        xs.sort { $0.x < $1.x }
        let a = CurveEvaluator(from)
        let b = CurveEvaluator(to)
        var blended = from
        blended.points = xs.map { entry in
            let ya = a.value(at: entry.x)
            let yb = b.value(at: entry.x)
            return CurvePoint(id: entry.id, x: entry.x, y: ya + (yb - ya) * fraction)
        }
        // A sampled blend is a set of heights, and the smooth reading of a set
        // of heights is the monotone cubic the rest of the app uses.
        blended.interpolation = .monotoneCubic
        return blended
    }
}
