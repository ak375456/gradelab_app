import SwiftUI

struct LayerControls: View {
    @ObservedObject var model: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: TimelineTrack?
    @State private var draftName = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.project.timeline.tracks) { track in
                        let displayName = track.layerDisplayName
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                // Selecting and renaming are separate targets, so tapping the
                                // name always means "rename this layer".
                                Button { model.selectTrack(track.id) } label: {
                                    Image(systemName: model.selectedTrack?.id == track.id ? "checkmark.circle.fill" : "circle")
                                        .font(.body)
                                        .foregroundStyle(model.selectedTrack?.id == track.id ? AppColors.accent : AppColors.textSecondary)
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }
                                .accessibilityLabel("Select \(displayName)")
                                .accessibilityAddTraits(model.selectedTrack?.id == track.id ? .isSelected : [])
                                Button {
                                    draftName = track.kind == .text && track.name == TimelineTrack.defaultName(for: .text)
                                        ? "" : track.name
                                    renaming = track
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(displayName).lineLimit(1).truncationMode(.tail)
                                        Image(systemName: "pencil").font(.caption2).foregroundStyle(AppColors.textSecondary)
                                        Spacer(minLength: 0)
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }
                                .accessibilityLabel("Rename \(displayName)")
                                .accessibilityHint("Opens a field to type a new layer name")
                            }
                            HStack(spacing: 16) {
                                Button { model.toggleTrack(track.id, lock: false) } label: { Image(systemName: track.kind == .audio ? (track.isEnabled ? "speaker.wave.2" : "speaker.slash") : (track.isEnabled ? "eye" : "eye.slash")).frame(width: 44, height: 44) }
                                    .accessibilityLabel(track.kind == .audio ? (track.isEnabled ? "Mute audio track" : "Unmute audio track") : (track.isEnabled ? "Hide layer and linked audio" : "Show layer and linked audio"))
                                Button { model.toggleTrack(track.id, lock: true) } label: { Image(systemName: track.isLocked ? "lock.fill" : "lock.open").frame(width: 44, height: 44) }
                                    .accessibilityLabel(track.isLocked ? "Unlock layer" : "Lock layer")
                                Spacer()
                                Button { model.reorderTrack(track.id, direction: -1) } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("Raise layer")
                                    .disabled(track.id == model.project.timeline.tracks.first?.id || track.isLocked)
                                Button { model.reorderTrack(track.id, direction: 1) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("Lower layer")
                                    .disabled(track.id == model.project.timeline.tracks.last?.id || track.isLocked)
                            }.foregroundStyle(.secondary)
                        }
                    }
                } footer: { Text("Text layers use their on-screen text as the name until you rename them. Top layers appear above lower layers. Hiding a layer also silences its linked audio. Locked layers still play and export, and can still be renamed.") }
            }.buttonStyle(.plain).navigationTitle("Layers").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }.disabled(model.isPreparingTimeline)
                .alert("Rename layer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                       presenting: renaming) { track in
                    TextField("Layer name", text: $draftName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                    Button("Cancel", role: .cancel) { renaming = nil }
                    Button("Save") { model.renameTrack(track.id, to: draftName); renaming = nil }
                } message: { track in
                    Text(track.kind == .text
                         ? "Set a custom layer name, or leave it empty to keep using the on-screen text."
                         : "This name appears in the timeline and in this list. Leaving it empty restores the default.")
                }
        }.preferredColorScheme(.dark)
    }
}

struct MarkerControls: View {
    @ObservedObject var model: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button("Add / remove at playhead") { model.toggleMarker() }
                ForEach(model.project.timeline.markers.sorted { $0.time < $1.time }) { marker in
                    HStack {
                        Button { model.seekTimeline(to: marker.time.seconds, finishing: true); dismiss() } label: {
                            Label(String(format: "%.3f s", locale: .current, marker.time.seconds), systemImage: "bookmark.fill")
                        }
                        Spacer()
                        Button(role: .destructive) { model.deleteMarker(marker.id) } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("Delete marker")
                    }
                }
            }.buttonStyle(.plain).navigationTitle("Markers").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }.preferredColorScheme(.dark)
    }
}

struct VideoTransformPanel: View {
    @State var clip: VideoClip
    let apply: (VideoClip) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Position · canvas coordinates") {
                    value(String(localized: "X"), $clip.transform.positionX, -1...2)
                    value(String(localized: "Y"), $clip.transform.positionY, -1...2)
                }
                Section("Transform") {
                    value(String(localized: "Scale"), $clip.transform.scale, 0.05...6)
                    value(String(localized: "Rotation"), $clip.transform.rotationDegrees, -180...180)
                    value("Opacity", $clip.opacity, 0...1)
                    Picker("Blend", selection: $clip.blendMode) {
                        ForEach(VisualBlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section {
                    Button("Reset transform") { clip.transform = .init(); clip.opacity = 1; clip.blendMode = .normal }
                } footer: { Text("Apply updates the video layer in both preview and export. X/Y 0.5 centers the video. The canvas pinch zoom is separate.") }
            }.navigationTitle("Video transform").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply(clip); dismiss() } }
                }
        }.preferredColorScheme(.dark).numericEntryHost()
    }
    private func value(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack {
            HStack { Text(title); Spacer()
                NumericEntryLabel(title: title, text: binding.wrappedValue.formatted(.number.precision(.fractionLength(2))),
                                  value: binding.wrappedValue, range: range, tint: .primary) { binding.wrappedValue = $0 } }
            Slider(value: binding, in: range)
        }
    }
}
