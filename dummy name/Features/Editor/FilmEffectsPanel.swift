import SwiftUI

/// The finishing effects: fade, sharpen, bloom, glow, halation and grain.
///
/// One slider each, with the explanation shown only for the ones that are
/// actually doing something — six paragraphs of help at once would be worse
/// than none.
struct FilmEffectsPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProPanelNotice(feature: .filmEffects)
            ForEach(FilmEffectParameter.all) { parameter in
                if let property = parameter.property {
                    let isPro = ProAccessPolicy.proEffectIDs.contains(parameter.id)
                    VStack(alignment: .leading, spacing: 2) {
                        GradeSlider(
                            model: model,
                            property: property,
                            title: isPro && !ProStore.shared.hasPro ? "\(parameter.name) · Pro" : parameter.name,
                            range: FilmEffects.range,
                            valueFormatter: AdjustmentValueFormatters.signed(fractionDigits: 0))
                        if model.gradeBinding(property).wrappedValue > 0 {
                            Text(parameter.detail)
                                .font(.caption2).foregroundStyle(AppColors.textSecondary)
                        }
                    }
                }
            }
            if model.hasFilmEffects {
                Button("Reset effects") { model.resetFilmEffects(); model.flushGradeHistory() }
                    .font(.caption.weight(.medium)).frame(minHeight: 36)
                    .disabled(!model.canGrade)
            }
            Text("Grain moves with the picture: animating its amount is fine, and the pattern itself stays put frame to frame.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
            Text("Fade and grain are computed per pixel. Sharpen, bloom, glow and halation need the pixels around them, so they run as a pass after grading — in the preview and in the export alike.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
        }
    }
}
