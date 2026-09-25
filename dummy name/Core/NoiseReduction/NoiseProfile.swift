import Foundation

// ---------------------------------------------------------------------------
// Measuring the footage
//
// Two different things read the noise field, and it is worth being clear about
// which is which.
//
// The RENDER reads it on the GPU, per frame, per tile, and never sends it to
// the CPU. That is what makes the strengths adapt to the picture — weak on
// hair, strong on a flat wall — and it is deterministic: the same frame with
// the same settings measures the same thing and produces the same pixels, in
// the preview and in the export alike.
//
// AUTO reads it back once, when the button is pressed, to suggest a set of
// starting values. Nothing about the render depends on that readback, so a
// slow or failed measurement costs a suggestion and never a frame.
// ---------------------------------------------------------------------------

/// What one frame's noise looks like, in the working signal's own units.
struct NoiseProfile: Sendable, Equatable {
    /// The luminance noise floor: the standard deviation of the flattest
    /// regions the frame contains.
    var luma: Float
    /// The same for colour.
    var chroma: Float
    /// The luminance floor measured over the darkest quarter of the frame,
    /// where sensor noise is worst and where a Log grade is about to look.
    var shadowLuma: Float
    /// How much of the frame is dark enough for that number to mean anything.
    var shadowCoverage: Float

    static let clean = NoiseProfile(luma: 0, chroma: 0, shadowLuma: 0, shadowCoverage: 0)

    /// A short sentence for the panel. Descriptive rather than prescriptive:
    /// it reports what was measured, and the user decides what to do about it.
    var summary: String {
        let level = Self.description(for: max(luma, shadowLuma * 0.7))
        let colour = chroma > luma * 1.6 && chroma > 0.004
            ? String(localized: " with noticeable colour noise")
            : ""
        return String(localized: "Measured \(level) luminance noise\(colour).")
    }

    private static func description(for sigma: Float) -> String {
        switch sigma {
        case ..<0.0025: String(localized: "very light")
        case ..<0.006: String(localized: "light")
        case ..<0.013: String(localized: "moderate")
        case ..<0.026: String(localized: "heavy")
        default: String(localized: "very heavy")
        }
    }
}

extension NoiseProfile {
    /// A 0…100 strength for a measured noise level.
    ///
    /// The exponent is what makes this useful across four stops of noise: a
    /// clean clip and a very noisy one differ by more than an order of
    /// magnitude in sigma, and a linear mapping would put everything except
    /// night footage in the bottom tenth of the slider.
    private static func strength(_ sigma: Float) -> Float {
        guard sigma > 0 else { return 0 }
        return min(100, 100 * pow(min(sigma, 0.08) / 0.05, 0.6))
    }

    /// Starting values for this footage.
    ///
    /// A suggestion and nothing more: every number it writes is an ordinary
    /// authored value, it goes through the same undo entry any other edit does,
    /// and the user is expected to move all of them. What it is actually good
    /// at is scale — knowing that this clip needs roughly twice as much as that
    /// one — which is the part that is genuinely hard to judge by eye at
    /// preview size.
    func suggestion(
        for current: NoiseReduction,
        capability: NoiseReductionCapability
    ) -> NoiseReduction {
        var value = current
        // The shadows carry the noise a Log grade is about to lift, so they
        // are weighted into the estimate rather than averaged away by a
        // well-exposed sky.
        let effectiveLuma = max(luma, shadowLuma * (0.5 + 0.5 * shadowCoverage))
        let lumaLevel = Self.strength(effectiveLuma)
        let chromaLevel = Self.strength(chroma)

        value.isTemporalEnabled = capability.supportsTemporal
        value.isSpatialEnabled = true
        value.protectsEdges = true
        value.isMotionCompensated = true

        // A wider window is worth its cost only when there is real noise to
        // average away; on a clean clip it spends a great deal of time to
        // change nothing.
        let wanted: TemporalFrameCount = lumaLevel > 62 ? .five : .three
        value.frames = wanted.rawValue <= capability.maximumFrames.rawValue
            ? wanted : capability.maximumFrames

        // Temporal reduction is preferred over spatial wherever it is
        // available, because averaging genuinely independent samples of the
        // same scene point removes noise without removing anything else. The
        // spatial stage is set to finish what the temporal one could not.
        value.temporalLuma = capability.supportsTemporal ? lumaLevel * 0.85 : 0
        value.temporalChroma = capability.supportsTemporal
            ? min(100, chromaLevel * 1.25 + 15) : 0
        value.spatialLuma = capability.supportsTemporal ? lumaLevel * 0.45 : lumaLevel * 0.9
        value.spatialChroma = min(100, chromaLevel * (capability.supportsTemporal ? 0.9 : 1.3) + 10)

        // Noisier footage has coarser, blotchier noise, so the filter has to
        // reach further to see past it.
        value.radius = min(85, 22 + lumaLevel * 0.45)
        // A noisy clip has more genuine detail hiding under the noise, so there
        // is more worth putting back.
        value.detailRecovery = min(60, 15 + lumaLevel * 0.35)
        // Left where the user had them: these two are judgement, not
        // measurement, and overwriting a deliberate choice about how cautious
        // to be is not something a measurement has any business doing.
        value.motionThreshold = current.motionThreshold
        value.detailProtection = current.detailProtection
        return value.clamped
    }
}
