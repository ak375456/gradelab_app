import SwiftUI

/// The editor's side of track matte: what the selected layer's matte is, what
/// it could be pointed at, and the three edits that change it.
///
/// Each of those edits is one `commit`, so it is one undo step and one
/// autosave, exactly like every other structural change in this app. Nothing
/// here touches a transform, a mask or a grade: a track matte is a relationship
/// between two layers and removing it puts both layers back untouched.
extension EditorViewModel {
    /// The selected layer's track matte, or nil when it has none.
    var selectedTrackMatte: TrackMatteConfiguration? { selectedItem?.trackMatte }

    /// Whether the selected layer can carry a track matte at all. Audio cannot:
    /// it has no picture to cut.
    var canUseTrackMatte: Bool {
        guard let item = selectedItem, item.isCompositable else { return false }
        return canEditSelection
    }

    /// Layers that could supply the selected layer's coverage, topmost first.
    /// The selected layer itself and anything that would close a loop are
    /// already excluded, so every entry here is one the compositor can resolve.
    var trackMatteCandidates: [TrackMatteEditing.Candidate] {
        guard let id = selectedClipID else { return [] }
        return TrackMatteEditing.candidates(for: id, in: project)
    }

    /// The chosen source's display name, for the closed picker.
    var selectedTrackMatteSourceName: String? {
        guard let matte = selectedTrackMatte else { return nil }
        return trackMatteCandidates.first { $0.id == matte.sourceItemID }?.name
    }

    /// True when the matte source is shorter than the target, or starts later.
    /// The target is transparent outside the source, which is what an alpha
    /// matte means — worth saying, not worth silently repairing.
    var trackMatteIsShorterThanClip: Bool {
        guard let id = selectedClipID, selectedTrackMatte != nil else { return false }
        return !TrackMatteEditing.sourceCoversTarget(id, in: project)
    }

    /// The layer directly above the selected one, when it can be a matte.
    /// A convenience only: what gets stored is still its item id.
    var trackMatteLayerAbove: TrackMatteEditing.Candidate? {
        guard let item = selectedItem,
              let index = project.timeline.tracks.firstIndex(where: { $0.id == item.placement.trackID }),
              index > 0 else { return nil }
        let above = project.timeline.tracks[index - 1]
        let candidates = trackMatteCandidates
        return above.items
            .compactMap { candidate in candidates.first { $0.id == candidate.id } }
            .first
    }

    /// Points the selected layer at a matte source, keeping whatever mode it
    /// already had. Switching source must not quietly switch an inverted matte
    /// back to a normal one.
    func setTrackMatteSource(_ sourceID: UUID, mode: TrackMatteMode? = nil) {
        guard let id = selectedClipID else { return }
        let existing = selectedTrackMatte
        let resolved = mode ?? existing?.mode ?? .alpha
        commit(existing == nil ? "Track Matte" : "Change Matte Source", rebuildsSequence: false) { project in
            var configuration = existing ?? TrackMatteConfiguration(sourceItemID: sourceID)
            configuration.sourceItemID = sourceID
            configuration.mode = resolved
            try TrackMatteEditing.setMatte(configuration, on: id, in: &project)
            return id
        }
    }

    /// Switches which side of the matte keeps the layer. One undo step, and it
    /// changes nothing else: same source, same transforms, same masks, same
    /// grade.
    func setTrackMatteMode(_ mode: TrackMatteMode) {
        guard let id = selectedClipID, var configuration = selectedTrackMatte else { return }
        guard configuration.mode != mode else { return }
        configuration.mode = mode
        commit(mode.title, rebuildsSequence: false) { project in
            try TrackMatteEditing.setMatte(configuration, on: id, in: &project)
            return id
        }
    }

    func removeTrackMatte() {
        guard let id = selectedClipID, selectedTrackMatte != nil else { return }
        inspectedMatteTargetID = nil
        commit("Remove Track Matte", rebuildsSequence: false) { project in
            try TrackMatteEditing.setMatte(nil, on: id, in: &project)
            return id
        }
    }

    /// Whether the matte source also appears in the picture in its own right.
    /// Off is the professional default: the source is consumed by the matte.
    func setTrackMatteRendersSource(_ renders: Bool) {
        guard let id = selectedClipID, var configuration = selectedTrackMatte,
              configuration.drawsSourceSeparately != renders else { return }
        configuration.drawsSourceSeparately = renders
        commit(renders ? "Show Matte Source" : "Hide Matte Source", rebuildsSequence: false) { project in
            try TrackMatteEditing.setMatte(configuration, on: id, in: &project)
            return id
        }
    }

    /// Shows the coverage itself in the preview: white where the layer is kept,
    /// black where it is cut, grey in between — in both modes, so an inverted
    /// matte reads white outside the letters, exactly where the picture
    /// survives. Editor-only; the export path builds its own render state and
    /// never carries an inspection id.
    func toggleMatteInspection() {
        guard selectedTrackMatte != nil else { inspectedMatteTargetID = nil; return }
        inspectedMatteTargetID = inspectedMatteTargetID == nil ? selectedClipID : nil
    }

    var isInspectingMatte: Bool { inspectedMatteTargetID != nil }

    /// Closing the tool takes the matte view with it, so a debug view is never
    /// left on over ordinary editing.
    func endTrackMatteEditing() {
        guard inspectedMatteTargetID != nil else { return }
        inspectedMatteTargetID = nil
    }
}

// ---------------------------------------------------------------------------
// The Track Matte tool
//
// Deliberately NOT under Color. A track matte changes what part of this layer
// exists, not what colour it is — it belongs with Transform, Mask and Blend.
// ---------------------------------------------------------------------------

struct TrackMattePanel: View {
    @ObservedObject var model: EditorViewModel

    private var matte: TrackMatteConfiguration? { model.selectedTrackMatte }

    var body: some View {
        ScrollView {
            if !model.canUseTrackMatte {
                Text(model.selectedItem == nil
                     ? "Select a video, image, text or shape layer to give it a track matte."
                     : "This layer is locked, or cannot carry a track matte.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    modeRow
                    if matte != nil {
                        sourceRow
                        if model.trackMatteIsShorterThanClip { shortMatteWarning }
                        optionsRow
                        removeRow
                    } else {
                        emptyHint
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .scrollIndicators(.visible)
        .disabled(model.isPreparingTimeline)
        .onChange(of: model.selectedClipID) { _, _ in model.endTrackMatteEditing() }
        .onDisappear { model.endTrackMatteEditing() }
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Mode").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Menu {
                    Button("None") { model.removeTrackMatte() }
                    ForEach(TrackMatteMode.allCases) { mode in
                        Button {
                            applyMode(mode)
                        } label: {
                            // A checkmark rather than a segmented control: the
                            // list grows when the luma readings arrive. An empty
                            // symbol name is not the way to draw "no tick" —
                            // SF Symbols logs a miss for it — so the two states
                            // are two labels.
                            if matte?.mode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                        .disabled(matte == nil && model.trackMatteCandidates.isEmpty)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(matte.map(\.mode.title) ?? String(localized: "None"))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Track matte mode")
            }
            Text(matte?.mode.explanation
                 ?? String(localized: "Another layer supplies this layer's transparency."))
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
            Text("Alpha reads that layer's opacity only — its colour never reaches the picture, so black and white letters cut identically. Inverted keeps the opposite side.")
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Matte source").font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 8)
                Menu {
                    ForEach(model.trackMatteCandidates) { candidate in
                        Button {
                            model.setTrackMatteSource(candidate.id)
                        } label: {
                            Text(candidate.coversTarget ? candidate.name : "\(candidate.name) ⚠︎")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.selectedTrackMatteSourceName ?? String(localized: "Select layer"))
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Matte source layer")
            }
            if let above = model.trackMatteLayerAbove, above.id != matte?.sourceItemID {
                Button("Use layer above · \(above.name)") { model.setTrackMatteSource(above.id) }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortMatteWarning: some View {
        Label("Matte does not cover the entire clip. Outside the matte there is no coverage, so this layer is transparent there.",
              systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(AppColors.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .appSurface(fill: AppColors.warning.opacity(0.10), border: AppColors.warning.opacity(0.28))
    }

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Also draw the matte source", isOn: Binding(
                get: { matte?.drawsSourceSeparately ?? false },
                set: { model.setTrackMatteRendersSource($0) }
            )).tint(AppColors.accent)
            Text("Off is the usual choice: the source is used up cutting this layer instead of being drawn over it as well.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
            Divider().overlay(AppColors.separator)
            Toggle("View matte", isOn: Binding(
                get: { model.isInspectingMatte },
                set: { _ in model.toggleMatteInspection() }
            )).tint(AppColors.accent)
            Text("Shows the coverage: white where this layer is kept, black where it is cut, grey in between. It follows the mode, so an inverted matte reads white outside the letters. Preview only — it is never exported.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var removeRow: some View {
        Button(role: .destructive) { model.removeTrackMatte() } label: {
            Label("Remove track matte", systemImage: "xmark.circle")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.trackMatteCandidates.isEmpty {
                Text("Add a second layer — a title, a shape, a logo or another clip — to use as the matte.")
                    .font(.subheadline).foregroundStyle(AppColors.textSecondary)
            } else {
                Text("Pick a layer to cut this one:")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.trackMatteCandidates) { candidate in
                    Button { model.setTrackMatteSource(candidate.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(candidate.detail).font(.caption2).foregroundStyle(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .appSurface(fill: AppColors.surfaceRaised, border: AppColors.border)
    }

    /// With a matte already set this only changes which side of it keeps the
    /// layer — same source, one undo step. With none set it also picks a
    /// source, defaulting to the layer above, so the common case is one tap.
    private func applyMode(_ mode: TrackMatteMode) {
        guard matte == nil else { model.setTrackMatteMode(mode); return }
        guard let source = model.trackMatteLayerAbove ?? model.trackMatteCandidates.first else { return }
        model.setTrackMatteSource(source.id, mode: mode)
    }
}
