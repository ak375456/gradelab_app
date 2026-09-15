import SwiftUI

struct AudioToolPanel: View {
    @ObservedObject var model: EditorViewModel
    let addSoundEffect: () -> Void
    let addAudio: () -> Void
    let showTracks: () -> Void
    let waveformUnavailable: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let settings = model.audioSettings {
                    HStack {
                        Text(model.selectedAudio == nil ? "Linked audio" : "Audio clip").font(.caption.weight(.semibold))
                        Spacer()
                        NumericEntryLabel(title: "Clip volume", text: "\(Int(settings.volume * 100))%",
                                          value: settings.volume * 100, range: 0...100, tint: .secondary) { typed in
                            model.changeAudio(volume: min(1, max(0, typed/100))); model.flushGradeHistory()
                        }.font(.caption.monospacedDigit()).disabled(!model.canEditSelection)
                        Button { model.changeAudio(muted: !settings.isMuted) } label: {
                            Image(systemName: settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 44, height: 36)
                        }.accessibilityLabel(settings.isMuted ? "Unmute clip" : "Mute clip")
                            .foregroundStyle(settings.isMuted ? Color.orange : Color.primary)
                            .disabled(!model.canEditSelection)
                    }
                    ResettableSlider(value: Binding(get: { model.audioSettings?.volume ?? 1 },
                                                    set: { model.changeAudio(volume: $0) }),
                                     range: 0...1, resetValue: 1, label: "Clip volume",
                                     onEditingChanged: { if !$0 { model.flushGradeHistory() } })
                        .tint(.cyan).accessibilityValue("\(Int(settings.volume * 100)) percent")
                        .disabled(!model.canEditSelection)
                    if model.audioFadeLimit > 0 {
                        AudioFadeControls(model: model)
                    }
                    if model.selectedClip != nil {
                        Button(action: model.separateAudio) { Label("Separate audio", systemImage: "waveform.path") }
                            .font(.caption.weight(.medium)).frame(minHeight: 36).disabled(!model.canEditSelection)
                    }
                    if waveformUnavailable { Text("Waveform unavailable · audio editing still works").font(.caption2).foregroundStyle(.secondary) }
                } else {
                    Text(model.selectedClip != nil ? "No linked audio in this clip" : "Select an audio clip to adjust its volume")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(action: addSoundEffect) { Label("Sounds", systemImage: "waveform.badge.plus") }
                        .disabled(model.isImporting)
                    Button(action: addAudio) { Label("Files", systemImage: "folder") }
                        .disabled(model.isImporting)
                    if model.selectedAudio != nil { Button { Task { await model.detectBeats() } } label: { Label("Beats", systemImage: "waveform.path.ecg") } }
                    Spacer()
                    Button(action: showTracks) { Label("Tracks", systemImage: "slider.horizontal.3") }
                }.font(.caption.weight(.medium)).frame(minHeight: 36)
                Text(model.selectedAudio == nil ? "Separate to edit the sound independently. The picture stays unchanged." : "Drag edges to trim · Hold to move · Keep holding for more")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.bottom, 8)
        }.scrollIndicators(.visible)
    }
}


/// Fade in and fade out, in seconds.
///
/// Both stop at half the clip so the two can never overlap — the model clamps
/// anything stored to the same rule, so the slider is showing the fade that will
/// actually be heard rather than a request that gets quietly shortened.
private struct AudioFadeControls: View {
    @ObservedObject var model: EditorViewModel

    private var limit: Double { model.audioFadeLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            row(title: "Fade in",
                icon: "speaker.wave.1",
                value: model.audioSettings?.fadeIn ?? 0) { model.changeAudio(fadeIn: $0) }
            row(title: "Fade out",
                icon: "speaker.wave.1.fill",
                value: model.audioSettings?.fadeOut ?? 0) { model.changeAudio(fadeOut: $0) }
        }
    }

    private func row(
        title: String,
        icon: String,
        value: Double,
        set: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(title, systemImage: icon).font(.caption.weight(.semibold))
                Spacer()
                Text(value > 0.0005 ? String(format: "%.1fs", value) : "Off")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value > 0.0005 ? Color.primary : Color.secondary)
            }
            ResettableSlider(
                value: Binding(get: { min(value, limit) }, set: set),
                range: 0...limit, resetValue: 0, label: title,
                onEditingChanged: { if !$0 { model.flushGradeHistory() } })
                .tint(.cyan)
                .accessibilityValue(value > 0.0005 ? String(format: "%.1f seconds", value) : "off")
                .disabled(!model.canEditSelection)
        }
    }
}
