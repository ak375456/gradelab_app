import SwiftUI

// ---------------------------------------------------------------------------
// Keyframe controls for the Color tab
//
// The same diamond, the same lane, the same previous/next and the same
// Animation menu the Transform tools use — pointed at grading properties. There
// is no colour-specific animation control, and no colour-specific rule: what
// these views do is call `EditorViewModel`'s existing keyframe methods with a
// grading `AnimatableProperty`.
//
// Everything here degrades to nothing when the thing being graded is a
// photograph. A still has no playhead, so `GradingModel` is asked for its
// timeline model and simply does not have one; the shared panels then show the
// plain sliders they always did.
// ---------------------------------------------------------------------------

extension GradingModel {
    /// The timeline model behind these controls, or nil for a photograph.
    var keyframeHost: EditorViewModel? { self as? EditorViewModel }
}

/// The diamond that goes in a grading slider's header row.
struct GradeKeyframeDiamond<Model: GradingModel>: View {
    @ObservedObject var model: Model
    let property: AnimatableProperty

    var body: some View {
        if let editor = model.keyframeHost {
            KeyframeDiamond(
                state: editor.keyframeState(property),
                title: property.title,
                enabled: editor.isPlayheadInsideSelection && editor.canGrade
            ) {
                editor.toggleKeyframe(property)
            }
        }
    }
}

/// The lane and the per-property actions, shown under a grading control once it
/// is actually animating. Hidden entirely while it is not, so a panel nobody has
/// animated looks exactly as it did.
struct GradeKeyframeLane<Model: GradingModel>: View {
    @ObservedObject var model: Model
    let property: AnimatableProperty
    @State private var selected: TimelineTime?

    var body: some View {
        if let editor = model.keyframeHost, editor.keyframeState(property) != .off {
            VStack(spacing: 2) {
                KeyframeLane(model: editor, property: property, selectedLocal: $selected)
                KeyframeNavigator(model: editor, property: property, selectedKeyframe: $selected)
            }
            .onChange(of: editor.gradeAnimationContextID) { _, _ in selected = nil }
        }
    }
}

/// A grading slider with its keyframe controls: the one component every Color
/// panel uses, so a parameter cannot be animatable in one panel and not in
/// another.
struct GradeSlider<Model: GradingModel>: View {
    @ObservedObject var model: Model
    let property: AnimatableProperty
    let title: String
    let range: ClosedRange<Float>
    var step: Float = 1
    var neutral: Float = 0
    let valueFormatter: (Float) -> String

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            AdjustmentSlider(
                value: model.gradeBinding(property),
                title: title,
                range: range,
                step: step,
                neutralValue: neutral,
                valueFormatter: valueFormatter
            ) {
                GradeKeyframeDiamond(model: model, property: property)
            }
            // An animated value can only be changed at a frame the clip
            // occupies, which is the rule every other animated control follows.
            .disabled(!model.canGrade || !model.canEditGradeValue(property))
            GradeKeyframeLane(model: model, property: property)
        }
    }
}

/// The "this panel contains animation" marker. Deliberately small: it says a
/// tool holds animation, and the diamonds inside it say which parameter.
struct GradeAnimationDot<Model: GradingModel>: View {
    @ObservedObject var model: Model
    let panel: GradePanel

    var body: some View {
        if model.keyframeHost?.panelHasAnimation(panel) == true {
            Circle()
                .fill(AppColors.accent)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}

/// The header the Color tab shows above its keyframeable controls: the
/// first-run hint, the out-of-range notice, and Remove All.
struct GradeKeyframeHeader<Model: GradingModel>: View {
    @ObservedObject var model: Model
    @State private var help = false
    @State private var confirmsRemoveAll = false

    var body: some View {
        if let editor = model.keyframeHost {
            KeyframeSectionHeader(model: editor, help: $help, confirmsRemoveAll: $confirmsRemoveAll)
                .sheet(isPresented: $help) { KeyframeHelp() }
                .confirmationDialog("Remove all animation from this clip?",
                                    isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
                    Button("Remove All Animation", role: .destructive) { editor.removeAllAnimation() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every animated property keeps the value you can see now. Masked grades are cleared too.")
                }
        }
    }
}
