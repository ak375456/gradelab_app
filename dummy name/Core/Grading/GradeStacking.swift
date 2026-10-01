import Foundation

/// What a paste does to a clip that is already graded.
enum GradePasteMode: Sendable {
    /// The copied grade becomes the clip's grade. Everything that was there is
    /// gone. This is what pasting has always done.
    case replace
    /// The clip keeps its grade and the copied one is applied on top of it.
    case addOnTop
}

extension GradeSettings {
    /// This grade laid on top of `base`, as one grade.
    ///
    /// The pipeline runs a clip's grade once, so "two grades" has to resolve to
    /// a single `GradeSettings`. The rule is chosen to match what "keep mine and
    /// also apply theirs" means for each kind of control rather than being one
    /// blanket policy:
    ///
    /// - **The sliders add**, clamped to their own range. Exposure is in stops,
    ///   where adding is literally correct, and the rest are symmetric -100...100
    ///   scales where two warm grades landing warmer is the expected answer.
    /// - **Curves, HSL bands, wheels, the vignette, the look and the finishing
    ///   effects replace, but only where the incoming grade actually sets
    ///   them.** These are shapes, not amounts: averaging or summing two tone
    ///   curves is not a tone curve anyone asked for, so the copied one wins
    ///   where it exists and the clip keeps its own everywhere it does not.
    /// - **The grading window is the clip's own and never travels.** A window
    ///   is drawn around something in *this* picture, so an incoming one would
    ///   be pointing at nothing. Replace still carries it, because that is the
    ///   whole copied grade by definition; adding on top does not.
    func stacked(onto base: GradeSettings) -> GradeSettings {
        var result = base
        for parameter in GradeParameter.allCases {
            let range = parameter.range
            let sum = base[keyPath: parameter.keyPath] + self[keyPath: parameter.keyPath]
            result[keyPath: parameter.keyPath] = min(max(sum, range.lowerBound), range.upperBound)
        }
        result.advanced = stackedAdvanced(onto: base.advanced)
        return result
    }

    private func stackedAdvanced(onto base: AdvancedGrade?) -> AdvancedGrade? {
        guard let incoming = advanced else { return base }
        guard let base else {
            // Nothing underneath to keep, so the incoming grade stands as it is
            // apart from its window, which belongs to the picture it was drawn
            // on rather than this one.
            var carried = incoming
            carried.mask = nil
            // A relight limited to a mask names a window in the picture it was
            // set up on. The lights travel; the window reference does not.
            carried.relight?.maskID = nil
            return carried == .neutral ? nil : carried
        }
        var merged = base

        // Curves are resolved on both sides first: a project saved before the
        // advanced curves existed carries its shapes in the legacy array, and
        // merging the two representations directly would silently drop one of
        // them. Writing the result to `advancedCurves` makes it the resolved
        // value, so the legacy array is cleared rather than left to contradict.
        let baseCurves = base.resolvedCurves
        let incomingCurves = incoming.resolvedCurves
        var curves = baseCurves
        for type in CurveType.allCases where !incomingCurves[type].isNeutral {
            curves[type] = incomingCurves[type]
        }
        merged.advancedCurves = curves.isNeutral ? nil : curves
        merged.curves = Array(repeating: ToneCurve(), count: 4)

        merged.hsl = (0..<8).map { index in
            let band = incoming.band(index)
            return band == HueBand() ? base.band(index) : band
        }
        merged.wheels = (0..<3).map { index in
            let wheel = incoming.wheel(index)
            return wheel == GradingWheel() ? base.wheel(index) : wheel
        }

        if incoming.vignette != 0 {
            merged.vignette = incoming.vignette
            merged.vignetteMidpoint = incoming.vignetteMidpoint
            merged.vignetteFeather = incoming.vignetteFeather
        }
        if incoming.lut != nil {
            merged.lut = incoming.lut
            merged.lutIntensity = incoming.lutIntensity
        }
        if let effects = incoming.effects, !effects.isNeutral {
            merged.effects = effects
        }
        // Lighting is a setup, not an amount: two key lights added together is
        // not what "also apply theirs" means. The incoming lights replace the
        // clip's own where there are any, without the mask reference, which
        // belongs to the other picture.
        if var relight = incoming.relight, !relight.lights.isEmpty {
            relight.maskID = nil
            merged.relight = relight
        }
        // Untouched on purpose: `merged` starts from `base`, so the clip keeps
        // the window it already had.
        return merged == .neutral ? nil : merged
    }
}
