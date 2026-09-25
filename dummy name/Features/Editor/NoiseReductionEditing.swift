import SwiftUI

// ---------------------------------------------------------------------------
// Editing the noise reduction
//
// Written once against `GradingModel` rather than twice against the two
// editors, exactly as the Color Warper's editing is. Everything goes through
// `settings`, so a drag becomes one coalesced undo entry, a copied grade
// carries the settings with it, and a saved preset stores them — none of which
// needed a line of code here.
// ---------------------------------------------------------------------------

extension GradingModel {
    /// The clip's noise reduction, never nil. A project that has never opened
    /// the panel reads neutral and writes nothing.
    var noiseReduction: NoiseReduction {
        (settings.advanced ?? .neutral).noiseReduction ?? .neutral
    }

    /// True when the module would change a pixel.
    var hasNoiseReduction: Bool {
        (settings.advanced ?? .neutral).resolvedNoiseReduction != nil
    }

    /// Applies one edit and stores the result, dropping it back to nothing when
    /// it has returned to neutral so an untouched project writes no key.
    func editNoiseReduction(_ edit: (inout NoiseReduction) -> Void) {
        guard canGrade else { return }
        var value = noiseReduction
        edit(&value)
        var advanced = settings.advanced ?? .neutral
        advanced.normalizeCollections()
        advanced.noiseReduction = value == .neutral ? nil : value
        settings.advanced = advanced == .neutral ? nil : advanced
    }

    func noiseBinding<T>(_ keyPath: WritableKeyPath<NoiseReduction, T>) -> Binding<T> {
        Binding(
            get: { self.noiseReduction[keyPath: keyPath] },
            set: { value in self.editNoiseReduction { $0[keyPath: keyPath] = value } })
    }

    /// A strength slider's binding, which also switches its own section on.
    ///
    /// Dragging Temporal Luma up from zero can only mean one thing, and making
    /// someone find a separate switch before the slider does anything is the
    /// kind of correctness nobody thanks you for.
    func noiseStrengthBinding(_ parameter: NoiseReductionParameter) -> Binding<Float> {
        Binding(
            get: { self.noiseReduction[keyPath: parameter.keyPath] },
            set: { value in
                self.editNoiseReduction {
                    $0[keyPath: parameter.keyPath] = value
                    guard value > 0, parameter.neutralValue == 0 else { return }
                    switch parameter.section {
                    case .temporal: $0.isTemporalEnabled = true
                    case .spatial: $0.isSpatialEnabled = true
                    }
                }
            })
    }

    func applyNoisePreset(_ preset: NoiseReduction.Preset) {
        editNoiseReduction { $0 = preset.applied(to: $0) }
        flushGradeHistory()
    }

    func resetNoiseReduction() {
        editNoiseReduction { $0 = .neutral }
        flushGradeHistory()
    }
}
