import SwiftUI

/// Lightweight transition browser: static symbols keep the panel responsive
/// while the actual preview remains the frame-accurate Metal compositor above.
struct TransitionPanel: View {
    @ObservedObject var model: EditorViewModel

    private let categories = ["BASIC", "MOVEMENT", "CAMERA", "WIPES", "GEOMETRIC", "CREATIVE", "STYLIZED", "ADVANCED"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRANSITIONS").font(.caption.weight(.bold)).foregroundStyle(AppColors.textSecondary)
                    if let transition = model.selectedTransition {
                        Text(transition.type.title).font(.headline)
                    } else {
                        Text("Choose an effect at the playhead").font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                }
                Spacer()
                if model.selectedTransition != nil {
                    Button(role: .destructive, action: model.removeSelectedTransition) {
                        Label("Remove", systemImage: "trash")
                    }.font(.caption.weight(.semibold))
                }
            }

            if let transition = model.selectedTransition {
                VStack(spacing: 6) {
                    HStack {
                        Text("Duration").font(.caption.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2fs", transition.duration.seconds))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Slider(value: Binding(
                        get: { model.selectedTransition?.duration.seconds ?? TimelineTransitionEditing.defaultSeconds },
                        set: model.setTransitionDuration),
                        in: model.selectedTransitionMinimumDuration...max(model.selectedTransitionMinimumDuration,
                            model.selectedTransitionMaximumDuration),
                        onEditingChanged: { editing in
                            if editing { model.beginTransitionDurationEditing() }
                            else { model.endTransitionDurationEditing() }
                        })
                        .tint(AppColors.accent)
                        .accessibilityLabel("Transition duration")
                }
                .padding(10)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    transitionRow(title: nil, types: [])
                    ForEach(categories, id: \.self) { category in
                        transitionRow(title: category,
                                      types: TimelineTransitionType.allCases.filter { $0.category == category })
                    }
                }
            }.scrollIndicators(.visible)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func transitionRow(title: String?, types: [TimelineTransitionType]) -> some View {
        if let title {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(AppColors.textSecondary)
        }
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                if title == nil {
                    transitionTile(title: "None", systemImage: "nosign",
                                   selected: model.selectedTransition == nil) {
                        model.removeSelectedTransition()
                    }
                }
                ForEach(types) { type in
                    transitionTile(title: type.title, systemImage: type.systemImage,
                                   selected: model.selectedTransition?.type == type) {
                        model.applyTransition(type)
                    }
                }
            }
        }.scrollIndicators(.hidden)
    }

    private func transitionTile(title: String, systemImage: String, selected: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 19, weight: .medium))
                Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .frame(width: 82, height: 58)
            .background(selected ? AppColors.accent : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? AppColors.accent : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
