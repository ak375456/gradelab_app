import SwiftUI

/// The iPhone's speed editor, on a screen of its own.
///
/// The inspector column on a phone is roughly a third of a small screen, shared
/// with a mode bar that already scrolls. A speed curve in there would be about
/// forty points tall, which is not something anyone can place a point on. So
/// ramping gets the whole screen instead, laid out the way the work actually
/// goes: see the frame, shape the curve, adjust the point you just grabbed.
///
/// Nothing here is a different feature from the Mac's. It is the same model,
/// the same curve view and the same vocabulary — given the room it needs by
/// taking the screen rather than by shrinking.
struct PhoneSpeedEditor: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject var editor: SpeedEditorModel
    @Environment(\.dismiss) private var dismiss

    private var remap: TimeRemap { model.selectedRemap }

    private var selectedPoint: SpeedPoint? {
        guard let id = editor.selectedPoint, let clip = model.selectedClip else { return nil }
        return clip.resolvedRemap.points.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    SpeedCurveView(model: model, editor: editor,
                                   height: max(200, proxy.size.height * 0.42))
                        .padding(.horizontal, AppSpacing.compact)
                        .padding(.top, AppSpacing.small)

                    Spacer(minLength: 0)
                    controls
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .foregroundStyle(AppColors.textPrimary)
            .preferredColorScheme(.dark)
            .navigationTitle("Speed Ramp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.settlePendingSpeedEdit()
                        dismiss()
                    }
                }
            }
            // A sheet is its own presentation context, so it needs its own
            // numeric-entry host — the editor's does not reach in here.
            .numericEntryHost()
        }
        // Tall, but deliberately not the whole screen: the editor's own live
        // preview stays visible above it. A full-screen editor would have to
        // put a SECOND picture in here, and there is one Metal preview in this
        // app — the one the player is already drawing into. Borrowing the real
        // one by leaving it uncovered is both cheaper and more honest than
        // standing up a duplicate.
        .presentationDetents([.fraction(0.62), .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.62)))
    }

    /// The bottom third: what the selected point is, and the two actions that
    /// are always wanted. Large targets, few of them, nothing that needs a
    /// second tap to discover.
    private var controls: some View {
        VStack(spacing: AppSpacing.compact) {
            if let point = selectedPoint {
                VStack(spacing: AppSpacing.small) {
                    Text(ClipSpeed.percentLabel(point.speed))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    // A coarse rate strip, because on a phone the common case is
                    // a round number and dragging for it is fiddly.
                    HStack(spacing: AppSpacing.small) {
                        ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { rate in
                            Button {
                                model.moveSpeedPoint(point.id, toTimeline: nil, speed: rate)
                            } label: {
                                Text(ClipSpeed.percentLabel(rate))
                                    .font(AppTypography.caption)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(abs(point.speed - rate) < 0.005
                                                ? AppColors.accentMuted : AppColors.surface,
                                                in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
                                    .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.small))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Picker("Transition", selection: Binding(
                        get: { point.interpolation },
                        set: { model.setSpeedPointInterpolation(point.id, to: $0) }
                    )) {
                        ForEach(SpeedInterpolation.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)

                    Button(role: .destructive) {
                        model.removeSpeedPoint(point.id)
                        editor.selection.removeAll()
                    } label: {
                        Label("Delete Point", systemImage: "trash").frame(minHeight: 44)
                    }
                }
            } else {
                Text("Tap a point to edit it, or double tap the graph to add one.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }

            HStack(spacing: AppSpacing.small) {
                Button {
                    model.addSpeedPoint()
                } label: {
                    Label("Add Point", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .disabled(model.playheadInSelectedClip == nil)
                Button {
                    model.resetSpeedCurve()
                    editor.selection.removeAll()
                } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .disabled(remap.points.isEmpty)
            }
            .font(AppTypography.caption)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.bottom, AppSpacing.standard)
    }
}
