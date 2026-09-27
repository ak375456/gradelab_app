import SwiftUI

/// The Animation section of the Text inspector.
///
/// Select text → Animation → In / Out / Loop → pick one → tune duration and
/// strength. Nothing here writes a keyframe; the keyframe controls in the other
/// sections keep working exactly as they did, on top of whatever is chosen here.
struct TextAnimationPanel: View {
    @ObservedObject var model: EditorViewModel
    /// Owned by EditorView, so a redraw of the panel cannot bounce the user
    /// back to In while they are choosing an exit.
    @Binding var slot: TextAnimationSlot

    private var settings: TextAnimationSettings { model.textAnimationSettings }
    private var selected: TextAnimationPreset? { settings.preset(slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            slots
            tiles
            if let selected {
                controls(for: selected)
            } else {
                Text("Pick an animation to play it without adding a single keyframe. Position, scale and colour keyframes keep working underneath.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            if !settings.isEmpty {
                Button(role: .destructive) { model.removeAllTextAnimation() } label: {
                    Label("Remove all text animation", systemImage: "xmark.circle")
                        .font(.caption.weight(.medium)).frame(minHeight: 44)
                }
                .accessibilityHint("Clears In, Out and Loop. Manual keyframes are not affected.")
            }
        }
    }

    // MARK: - Slots

    private var slots: some View {
        HStack(spacing: 8) {
            ForEach(TextAnimationSlot.allCases) { value in
                let active = slot == value
                let filled = settings.preset(value) != nil
                Button { slot = value } label: {
                    HStack(spacing: 5) {
                        Text(value.title).font(.caption.weight(.semibold))
                        if filled {
                            Circle().fill(active ? AnyShapeStyle(Color.black.opacity(0.55))
                                                 : AnyShapeStyle(AppColors.accent))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(active ? AppColors.accent : Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(active ? Color.black : AppColors.textPrimary)
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .accessibilityLabel(value.title)
                .accessibilityValue(settings.preset(value)?.title ?? String(localized: "None"))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 8)], spacing: 8) {
            tile(nil)
            ForEach(TextAnimationPreset.all(in: slot)) { tile($0) }
        }
    }

    private func tile(_ preset: TextAnimationPreset?) -> some View {
        let active = selected == preset
        return Button {
            model.setTextAnimation(preset, for: slot)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: preset?.symbol ?? "nosign")
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 22)
                Text(preset?.title ?? String(localized: "None"))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
                    .frame(height: 24, alignment: .top)
            }
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(active ? AppColors.accent.opacity(0.22) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(active ? AppColors.accent : .clear, lineWidth: 1.5))
            .foregroundStyle(active ? AppColors.accent : AppColors.textPrimary)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel(preset?.title ?? String(localized: "None"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Controls

    @ViewBuilder private func controls(for preset: TextAnimationPreset) -> some View {
        if slot == .loop {
            slider(String(localized: "Speed"), value: settings.loopSpeed, range: 0.25...3, reset: 1) {
                model.setTextAnimationLoopSpeed($0)
            } commit: {
                model.setTextAnimationLoopSpeed($0, immediate: true)
            }
        } else {
            slider(String(localized: "Duration (s)"),
                   value: min(settings.duration(slot).seconds, model.textAnimationDurationLimit),
                   range: TextAnimationSettings.minimumDuration...model.textAnimationDurationLimit,
                   reset: min(TextAnimationSettings.defaultDuration.seconds, model.textAnimationDurationLimit)) {
                model.setTextAnimationDuration($0, for: slot)
            } commit: {
                model.setTextAnimationDuration($0, for: slot, immediate: true)
            }
        }
        slider(String(localized: "Strength"), value: settings.strength, range: 0...1, reset: 1) {
            model.setTextAnimationStrength($0)
        } commit: {
            model.setTextAnimationStrength($0, immediate: true)
        }
        Button { model.previewTextAnimation(slot) } label: {
            Label("Replay", systemImage: "arrow.trianglehead.counterclockwise")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .accessibilityLabel("Replay \(slot.title) animation")
        .disabled(model.isPreparingTimeline)
        if preset.isPerGlyph {
            Text("Animates each letter, so this one redraws the title every frame. Fine on a title, heavier on a paragraph.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
        }
        if slot != .loop, settings.incoming != nil, settings.outgoing != nil,
           let clip = model.selectedText {
            let fitted = TextAnimator.windows(settings, duration: clip.placement.duration.seconds)
            if fitted.incoming + 0.005 < settings.incomingDuration.seconds
                || fitted.outgoing + 0.005 < settings.outgoingDuration.seconds {
                Text("This clip is too short for both, so they have been scaled to \(fitted.incoming, specifier: "%.2f")s in and \(fitted.outgoing, specifier: "%.2f")s out.")
                    .font(.caption2).foregroundStyle(AppColors.warning)
            }
        }
    }

    /// Matches the slider rows in the rest of the Text inspector: a tappable
    /// read-out for typing an exact value, and one undo entry per drag.
    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, reset: Double,
                        change: @escaping (Double) -> Void,
                        commit: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                NumericEntryLabel(title: title, text: value.formatted(.number.precision(.fractionLength(0...2))),
                                  value: value, range: range, tint: .primary) { typed in commit(typed) }
                    .font(.caption.monospacedDigit())
            }
            ResettableSlider(value: Binding(get: { value }, set: change),
                             range: range, resetValue: reset, label: title,
                             onEditingChanged: { editing in if !editing { model.flushGradeHistory() } },
                             onReset: { commit(reset) })
        }
    }
}
