import Foundation

// ---------------------------------------------------------------------------
// Noise Reduction — the authored description
//
// This file is the whole of what a project stores about noise reduction. It
// holds numbers and nothing else: no textures, no motion vectors, no measured
// noise profile. Everything the engine derives — the noise floor of a frame,
// the optical flow between two frames, which neighbours are usable — is
// regenerated from the footage, because it is a property OF the footage rather
// than a decision the user made, and baking it into a document would make the
// document large, stale and machine-specific all at once.
//
// It sits on `AdvancedGrade` beside the finishing effects and the Color Warper,
// and that placement is what gives it project persistence, undo/redo
// coalescing, copy/paste, presets and (later) keyframes without a line of code
// in any of those systems. The same reasoning applies as for `FilmEffects`:
// optional, so every project written before noise reduction existed decodes
// unchanged and renders exactly the picture it always did.
// ---------------------------------------------------------------------------

/// How many frames the temporal stage looks at, current frame included.
enum TemporalFrameCount: Int, Codable, CaseIterable, Identifiable, Sendable {
    /// The current frame and the one before it. The cheapest useful window, and
    /// the only one that needs no future frame at all.
    case two = 2
    /// One frame either side.
    case three = 3
    /// Two frames either side. The strongest, and the most expensive.
    case five = 5

    var id: Int { rawValue }

    /// How far the window reaches on each side of the current frame.
    ///
    /// Two frames is deliberately asymmetric: it uses the PAST frame only. A
    /// symmetric half-window is impossible with an even count, and reaching
    /// backwards is the half that is already decoded during playback, so the
    /// two-frame mode is the one that costs nothing to fetch.
    var backwardReach: Int {
        switch self {
        case .two: 1
        case .three: 1
        case .five: 2
        }
    }

    var forwardReach: Int {
        switch self {
        case .two: 0
        case .three: 1
        case .five: 2
        }
    }

    var title: String {
        switch self {
        case .two: "2"
        case .three: "3"
        case .five: "5"
        }
    }

    var detail: String {
        switch self {
        case .two: String(localized: "This frame and the one before it. Fastest, and never waits on a frame that has not been decoded yet.")
        case .three: String(localized: "One frame either side. A good balance for most footage.")
        case .five: String(localized: "Two frames either side. The strongest reduction, and the slowest.")
        }
    }
}

/// What the engine is allowed to spend.
///
/// The two modes run the SAME algorithm over the same stages in the same order;
/// they differ only in the resolution motion is estimated at and how wide the
/// spatial filter is allowed to reach. That is deliberate and is the whole
/// reason this is one enum rather than two code paths: a preview that denoised
/// by a different method than the export would be a preview of nothing.
enum NoiseReductionQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Interactive. Motion is estimated at a coarser scale and the spatial
    /// radius is capped, so a slider stays live under the finger.
    case preview
    /// What export always uses, and what the paused preview uses when it is
    /// selected here.
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: String(localized: "Preview")
        case .high: String(localized: "High Quality")
        }
    }

    var detail: String {
        switch self {
        case .preview: String(localized: "Estimates motion at a coarser scale so the controls stay live. Export still renders at high quality.")
        case .high: String(localized: "What the export uses. Slower to update while you drag.")
        }
    }

    /// The divisor between the frame and the grid motion is estimated on.
    ///
    /// Flow does not need full resolution — a motion vector describes where a
    /// region went, and regions are much larger than pixels. Estimating at a
    /// quarter of each edge is sixteen times less work for a field that is then
    /// interpolated back up, and the alignment error that introduces is well
    /// under the rejection thresholds the temporal stage already applies.
    ///
    /// Scaled by the picture: a 4K frame can afford a coarser divisor than a
    /// 1080p one and still resolve the same real-world motion.
    func flowDivisor(longEdge: Int) -> Int {
        switch self {
        case .preview: longEdge >= 2400 ? 8 : 4
        case .high: longEdge >= 2400 ? 4 : 2
        }
    }
}

/// One clip's noise reduction, as authored.
///
/// Every strength is stored on a 0…100 scale and every one of them defaults to
/// zero, so `NoiseReduction.neutral` is a value that provably cannot change a
/// pixel — which is what lets every render path test one thing and skip the
/// entire engine.
struct NoiseReduction: Codable, Equatable, Sendable {

    // MARK: Temporal

    /// Whether the temporal stage runs at all. Separate from the strengths
    /// because turning the stage off must also stop the neighbour decoding and
    /// the motion estimation, not merely weight their result to zero.
    var isTemporalEnabled = false
    var frames: TemporalFrameCount = .three
    /// Luminance noise across time. Conservative by default: luma carries the
    /// detail people notice losing.
    var temporalLuma: Float = 0
    /// Colour noise across time. Tolerates far more than luma does.
    var temporalChroma: Float = 0
    /// How readily a difference between frames is believed to be real motion
    /// rather than noise. Low is cautious — less reduction, no trails.
    var motionThreshold: Float = 50
    /// Holds reduction back where the picture has real high-frequency structure.
    var detailProtection: Float = 50
    /// Estimate motion and align neighbours before combining them.
    ///
    /// On by default and meant to stay on: without it the temporal stage is
    /// frame averaging, which is the one thing this engine exists not to be.
    /// It is exposed because a locked-off tripod shot does not need it and an
    /// aligned pass costs real time.
    var isMotionCompensated = true

    // MARK: Spatial

    var isSpatialEnabled = false
    var spatialLuma: Float = 0
    var spatialChroma: Float = 0
    /// How far the spatial filter reaches. Small for fine grain, large for the
    /// blotchy low-frequency noise of a lifted shadow.
    var radius: Float = 35
    /// Puts real detail back after the filtering, without putting the noise
    /// back with it.
    var detailRecovery: Float = 0
    /// Edge-aware weighting in the spatial stage.
    ///
    /// Same shape of decision as `isMotionCompensated`: on by default, and off
    /// only for someone who wants the plain smoothing and knows they do.
    var protectsEdges = true

    // MARK: Both

    var quality: NoiseReductionQuality = .preview

    static let neutral = NoiseReduction()
    static let strengthRange: ClosedRange<Float> = 0...100

    // MARK: - What is actually switched on

    /// True when the temporal stage would change a pixel.
    var temporalIsActive: Bool {
        isTemporalEnabled && (temporalLuma > 0 || temporalChroma > 0)
    }

    /// True when the spatial stage would change a pixel.
    ///
    /// Detail Recovery is included even at zero filter strength on purpose: with
    /// no temporal stage and no spatial filtering there is no removed signal for
    /// it to put back, and reading it as active would run a whole pass to add
    /// zero. It counts only when something has been taken away.
    var spatialIsActive: Bool {
        isSpatialEnabled && (spatialLuma > 0 || spatialChroma > 0)
    }

    /// True when Detail Recovery has something to restore.
    var recoveryIsActive: Bool {
        detailRecovery > 0 && (temporalIsActive || spatialIsActive)
    }

    /// True when the engine has any work at all. Every render path tests this
    /// one property and, when it is false, takes exactly the route it took
    /// before noise reduction existed.
    var isActive: Bool { temporalIsActive || spatialIsActive }

    var isNeutral: Bool { self == .neutral }

    /// How many frames either side the engine needs fetched for this setting.
    /// Zero whenever the temporal stage is off, which is what stops a disabled
    /// stage from keeping a decoder alive.
    var temporalReach: (backward: Int, forward: Int) {
        guard temporalIsActive else { return (0, 0) }
        return (frames.backwardReach, frames.forwardReach)
    }

    /// Keeps hand-edited or future project JSON from reaching Metal with values
    /// no control could produce. Authored values are untouched; this is the
    /// resolved render value only.
    var clamped: NoiseReduction {
        var value = self
        func c(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 100) : 0 }
        value.temporalLuma = c(temporalLuma)
        value.temporalChroma = c(temporalChroma)
        value.motionThreshold = c(motionThreshold)
        value.detailProtection = c(detailProtection)
        value.spatialLuma = c(spatialLuma)
        value.spatialChroma = c(spatialChroma)
        value.radius = c(radius)
        value.detailRecovery = c(detailRecovery)
        return value
    }
}

// MARK: - Presets

extension NoiseReduction {
    /// The starting points offered in the panel.
    ///
    /// Each one is nothing but a set of the ordinary values above. There is no
    /// hidden second algorithm behind any of them, and every number a preset
    /// writes is left editable — which is what makes them a starting point
    /// rather than a mode.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case light, medium, strong, lowLight, chromaCleanup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .light: String(localized: "Light")
            case .medium: String(localized: "Medium")
            case .strong: String(localized: "Strong")
            case .lowLight: String(localized: "Low Light")
            case .chromaCleanup: String(localized: "Chroma Cleanup")
            }
        }

        var detail: String {
            switch self {
            case .light: String(localized: "A gentle pass for clean daylight footage with a little grain.")
            case .medium: String(localized: "The usual starting point for phone and mirrorless footage.")
            case .strong: String(localized: "High ISO and heavily lifted shadows.")
            case .lowLight: String(localized: "Night footage: wide temporal window, strong chroma, protected detail.")
            case .chromaCleanup: String(localized: "Colour speckle only. Luminance detail is left exactly where it is.")
            }
        }

        /// Applied over whatever is there now, so Quality and Motion
        /// Compensation — which are about how the engine runs rather than how
        /// strong it is — survive choosing a preset.
        func applied(to current: NoiseReduction) -> NoiseReduction {
            var value = current
            value.isTemporalEnabled = true
            value.isSpatialEnabled = true
            value.protectsEdges = true
            switch self {
            case .light:
                value.frames = .three
                value.temporalLuma = 45; value.temporalChroma = 55
                value.motionThreshold = 40; value.detailProtection = 65
                value.spatialLuma = 20; value.spatialChroma = 40
                value.radius = 25; value.detailRecovery = 20
            case .medium:
                value.frames = .three
                value.temporalLuma = 72; value.temporalChroma = 80
                value.motionThreshold = 50; value.detailProtection = 55
                value.spatialLuma = 42; value.spatialChroma = 65
                value.radius = 35; value.detailRecovery = 30
            case .strong:
                value.frames = .five
                value.temporalLuma = 85; value.temporalChroma = 92
                value.motionThreshold = 60; value.detailProtection = 45
                value.spatialLuma = 55; value.spatialChroma = 78
                value.radius = 50; value.detailRecovery = 40
            case .lowLight:
                value.frames = .five
                value.temporalLuma = 88; value.temporalChroma = 95
                value.motionThreshold = 50; value.detailProtection = 70
                value.spatialLuma = 58; value.spatialChroma = 88
                value.radius = 60; value.detailRecovery = 45
            case .chromaCleanup:
                value.frames = .three
                value.temporalLuma = 0; value.temporalChroma = 90
                value.motionThreshold = 50; value.detailProtection = 50
                value.spatialLuma = 0; value.spatialChroma = 82
                value.radius = 55; value.detailRecovery = 0
            }
            return value.clamped
        }
    }
}

// MARK: - Control metadata

/// One noise-reduction control as the panel shows it.
///
/// Written as a table rather than as a column of hand-built sliders so the
/// panel, the reset action and the Auto button all address the same list and
/// cannot drift apart about which slider drives which value.
struct NoiseReductionParameter: Identifiable {
    enum Section: Sendable { case temporal, spatial }

    let id: String
    let section: Section
    let name: String
    let detail: String
    let keyPath: WritableKeyPath<NoiseReduction, Float>
    /// Where the slider sits when the control is doing nothing, which is also
    /// what a double-tap returns it to.
    let neutralValue: Float

    // Not `Sendable`: a key path is not, and this table is read from the
    // main actor by the panel and by nothing else. `FilmEffectParameter` beside
    // it is the same shape for the same reason.
    static let all: [NoiseReductionParameter] = [
        .init(id: "temporalLuma", section: .temporal, name: String(localized: "Luma"),
              detail: String(localized: "Luminance noise, across time. The detail people notice losing lives here, so start low."),
              keyPath: \.temporalLuma, neutralValue: 0),
        .init(id: "temporalChroma", section: .temporal, name: String(localized: "Chroma"),
              detail: String(localized: "Colour speckle across time. Takes far more than luma does before anything shows."),
              keyPath: \.temporalChroma, neutralValue: 0),
        .init(id: "motionThreshold", section: .temporal, name: String(localized: "Motion Threshold"),
              detail: String(localized: "How readily a difference between frames is believed to be movement. Lower is cautious: less reduction, and no trails."),
              keyPath: \.motionThreshold, neutralValue: 50),
        .init(id: "detailProtection", section: .temporal, name: String(localized: "Detail Protection"),
              detail: String(localized: "Holds both stages back where the picture has real texture — hair, fabric, grass, small text. It also decides how much Detail Recovery is willing to believe."),
              keyPath: \.detailProtection, neutralValue: 50),
        .init(id: "spatialLuma", section: .spatial, name: String(localized: "Luma"),
              detail: String(localized: "Luminance noise within the frame, filtered along edges rather than across them."),
              keyPath: \.spatialLuma, neutralValue: 0),
        .init(id: "spatialChroma", section: .spatial, name: String(localized: "Chroma"),
              detail: String(localized: "Colour blotches within the frame. Guided by the luminance, so colour edges stay where the picture's edges are."),
              keyPath: \.spatialChroma, neutralValue: 0),
        .init(id: "radius", section: .spatial, name: String(localized: "Radius"),
              detail: String(localized: "How far the filter reaches. Small for fine grain; large for the blotchy noise of a lifted shadow."),
              keyPath: \.radius, neutralValue: 35),
        .init(id: "detailRecovery", section: .spatial, name: String(localized: "Detail Recovery"),
              detail: String(localized: "Puts real detail back after the filtering. Differences too small to be anything but noise are left out."),
              keyPath: \.detailRecovery, neutralValue: 0)
    ]

    static func section(_ section: Section) -> [NoiseReductionParameter] {
        all.filter { $0.section == section }
    }
}

// MARK: - What actually happened

/// What noise reduction managed on the last frame rendered.
///
/// Reported rather than inferred. Temporal reduction can only combine frames
/// that exist and have been decoded, so a setting that asks for a five-frame
/// window is sometimes running on three, on one, or on none of them — at the
/// start of a clip, across a cut, or for the moment after the playhead has been
/// dragged somewhere new. A panel that said "5 frames" through all of that
/// would be describing the settings rather than the picture.
struct NoiseReductionStatus: Equatable, Sendable {
    var isActive = false
    var wantsTemporal = false
    var temporalRan = false
    var neighbours = 0
    /// True when this device is running a narrower window than the document
    /// asks for.
    var reduced = false
    /// True when the preview is rendering at a reduced size — which it does
    /// while the transport is running — so the neighbouring frames do not match
    /// the frame on screen and the temporal stage has nothing to combine.
    ///
    /// Reported for the same reason as `unavailableInComposite`: the spatial
    /// half still runs, so the picture is not wrong, but a Frames control that
    /// does nothing while playing has to say which state it is in rather than
    /// leave someone dragging it.
    var previewIsReduced = false
    /// True when the project's structure routes it through the layer
    /// compositor, which does not run the engine.
    ///
    /// Reported rather than hidden. Preview and export agree with each other in
    /// this state — both composite without denoising — so nothing is
    /// inconsistent, but a module whose sliders moved and whose picture did not
    /// has to say why.
    var unavailableInComposite = false

    static let inactive = NoiseReductionStatus()

    /// True while the temporal stage is asked for but is not what produced the
    /// picture on screen — the state a scrub leaves behind until the decode
    /// catches up.
    var isWaitingForFrames: Bool {
        isActive && wantsTemporal && !temporalRan && !previewIsReduced && !unavailableInComposite
    }

    /// One short line for the panel.
    var summary: String {
        if unavailableInComposite { return String(localized: "Not applied") }
        guard isActive else { return String(localized: "Off") }
        guard wantsTemporal else { return String(localized: "Spatial") }
        if previewIsReduced { return String(localized: "Spatial while playing") }
        if !temporalRan { return String(localized: "Spatial — finding frames") }
        return String(localized: "Temporal · \(neighbours + 1) frames")
    }
}
