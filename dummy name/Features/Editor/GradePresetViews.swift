import SwiftUI

// ---------------------------------------------------------------------------
// My Presets
//
// A preset is a whole grading state, not a `.cube`, so it lives beside the look
// strip rather than inside it: the two are different things and the UI says so.
// ---------------------------------------------------------------------------

/// The saved-preset grid.
///
/// Tapping a tile applies that preset to the selected clip. Nothing is baked,
/// nothing is locked, and the clip is free to be edited afterwards.
struct MyPresetsGrid<Model: GradingModel>: View {
    @ObservedObject var model: Model
    @ObservedObject var presets: GradePresetLibrary
    /// Opens the save sheet, so the empty state can offer it too.
    let onSaveGrade: () -> Void
    @ObservedObject private var store = ProStore.shared
    @State private var paywallFeature: ProFeature?

    @State private var renaming: GradePreset?
    @State private var renameText = ""
    @State private var deleting: GradePreset?

    private var tileSize: CGFloat { PresetTileMetrics.size }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: 120), spacing: 12)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if presets.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(presets.presets) { preset in
                        tile(preset)
                    }
                }
                Text("Tapping a preset replaces the current grade. You can keep editing afterwards, and the preset stays as it was saved.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
        .alert("Rename preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let preset = renaming {
                    do { try presets.rename(preset.id, to: renameText) }
                    catch { model.editError = error.localizedDescription }
                }
                renaming = nil
            }.disabled(GradePresetName.sanitize(renameText) == nil)
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Preset", role: .destructive) {
                if let deleting { presets.delete(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This removes the saved preset only. Clips you already applied it to keep their grade.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No saved presets yet.")
                .font(.subheadline.weight(.medium))
            Text("Create a grade and save it here.")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            Button(store.hasPro ? "Save Current Grade" : "Save Current Grade (Pro)") {
                if store.hasPro { onSaveGrade() } else { paywallFeature = .gradePresets }
            }
            .paywallSheet($paywallFeature)
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
                .disabled(!model.canGrade)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ preset: GradePreset) -> some View {
        Button { model.applyPreset(preset) } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = presets.thumbnail(for: preset) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        AppColors.surface
                            .overlay(Image(systemName: "paintpalette").font(.system(size: 18))
                                .foregroundStyle(AppColors.textSecondary))
                    }
                }
                .frame(width: tileSize, height: tileSize)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if preset.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 10))
                            .foregroundStyle(.yellow)
                            .padding(4)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(4)
                    }
                }
                Text(preset.name).font(.caption2).lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: tileSize + 12)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.textPrimary)
        .disabled(!model.canGrade)
        .accessibilityLabel(preset.isFavorite ? "\(preset.name), favourite" : preset.name)
        .accessibilityHint("Applies this preset to the selected clip")
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = preset.name
                renaming = preset
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                do { try presets.duplicate(preset.id) }
                catch { model.editError = error.localizedDescription }
            }
            Button(preset.isFavorite ? "Unfavourite" : "Favourite",
                   systemImage: preset.isFavorite ? "star.slash" : "star") {
                presets.toggleFavorite(preset.id)
            }
            Button("Update with current grade", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.updatePreset(preset.id) }
            }.disabled(!model.canGrade)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = preset }
        }
    }
}

/// The save sheet: a preview of what is being saved, a name, and a favourite
/// toggle. Deliberately nothing else — no tags, folders or descriptions.
struct SaveGradePresetSheet<Model: GradingModel>: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isFavorite = false
    @State private var thumbnail: UIImage?
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String? { GradePresetName.sanitize(name) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        AppColors.surface.overlay(ProgressView())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preset Name").font(.caption).foregroundStyle(AppColors.textSecondary)
                    TextField("My Preset", text: $name)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 10))
                        .onSubmit(save)
                }

                Toggle("Favourite", isOn: $isFavorite)
                    .font(.subheadline)
                    .tint(AppColors.accent)

                Text("Saves the whole grade — light, colour, curves, HSL, wheels, vignette, the look and its strength, and the finishing effects.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Save Grade as Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName == nil || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .task {
            name = model.suggestedPresetName()
            thumbnail = await model.makePresetThumbnail()
            nameFocused = true
        }
    }

    private func save() {
        guard let trimmedName, !isSaving else { return }
        isSaving = true
        Task {
            let saved = await model.saveGradeAsPreset(name: trimmedName, isFavorite: isFavorite, thumbnail: thumbnail)
            isSaving = false
            if saved { dismiss() }
        }
    }
}


/// Preset-tile size. A plain constant rather than a static on `MyPresetsGrid`,
/// which is generic over its model and so cannot hold stored statics.
private enum PresetTileMetrics {
    static let size: CGFloat = 76
}
