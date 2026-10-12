import SwiftUI

struct AudioToolPanel: View {
    @ObservedObject var model: EditorViewModel
    let addSoundEffect: () -> Void
    let addAudio: () -> Void
    let showTracks: () -> Void
    let waveformUnavailable: Bool
    @State var toneExpanded = false
    @State private var advancedExpanded = false
    @State var compressorExpanded = false
    @State var duckingExpanded = false
    @State var spaceExpanded = false
    @State var textureExpanded = false
    @State var compressorAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let settings = model.audioSettings {
                    basic(settings)
                    tone
                    compressor
                    ducking
                    space
                    texture
                    AudioClipLevelMeter(model: model)
                    if model.selectedClip != nil {
                        Button(action: model.separateAudio) {
                            Label("Separate audio", systemImage: "waveform.path")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.font(.caption.weight(.medium)).disabled(!model.canEditSelection)
                    }
                    if waveformUnavailable {
                        Text("Waveform unavailable · audio editing still works")
                            .font(.caption2).foregroundStyle(AppColors.textSecondary)
                    }
                } else {
                    Label(model.selectedClip != nil ? "No linked audio in this clip" : "Select a clip to adjust its sound",
                          systemImage: "waveform")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                }
                libraryActions
                Text(model.selectedAudio == nil
                     ? "Separate audio to trim and move the sound independently."
                     : "Drag edges to trim · Hold to move · Keep holding for more")
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
            }.padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
        .onChange(of: model.selectedClipID) { _, _ in advancedExpanded = false }
    }

    private func basic(_ settings: EmbeddedAudio) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Basic").font(.subheadline.weight(.semibold))
                    Text(model.selectedAudio == nil ? "Linked audio" : "Audio clip")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                Button {
                    model.flushGradeHistory()
                    model.changeAudio(muted: !settings.isMuted)
                    model.flushGradeHistory()
                } label: {
                    Label(settings.isMuted ? "Muted" : "Mute",
                          systemImage: settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption.weight(.medium)).frame(minWidth: 68, minHeight: 44)
                }
                .foregroundStyle(settings.isMuted ? AppColors.warning : AppColors.accent)
                .accessibilityLabel(settings.isMuted ? "Unmute clip" : "Mute clip")
            }
            row("Volume", value: settings.volume * 100, range: 0...100, reset: 100,
                format: { "\(Int($0.rounded()))%" }) { model.changeAudio(volume: $0 / 100) }
            row("Pan", value: model.audioProcessing.pan * 100, range: -100...100,
                format: Self.panLabel) { value in model.changeAudioProcessing { $0.pan = value / 100 } }
            if model.audioFadeLimit > 0 {
                HStack(spacing: 16) {
                    row("Fade in", value: settings.fadeIn ?? 0, range: 0...model.audioFadeLimit,
                        format: Self.seconds) { model.changeAudio(fadeIn: $0) }
                    row("Fade out", value: settings.fadeOut ?? 0, range: 0...model.audioFadeLimit,
                        format: Self.seconds) { model.changeAudio(fadeOut: $0) }
                }
            }
        }
        .disabled(!model.canEditSelection)
        .padding(12).appSurface()
    }

    private var tone: some View {
        DisclosureGroup(isExpanded: $toneExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("Tone on", isOn: Binding(get: { model.audioProcessing.isToneEnabled }, set: { enabled in
                        model.flushGradeHistory()
                        model.changeAudioProcessing { $0.isToneEnabled = enabled }
                        model.flushGradeHistory()
                    })).font(.caption.weight(.medium)).tint(AppColors.accent)
                    Spacer(minLength: 20)
                    Button("Reset") { model.applyAudioPreset(.flat) }
                        .font(.caption.weight(.medium)).frame(minHeight: 44)
                        .disabled(!model.audioProcessing.hasTone && model.audioProcessing.isToneEnabled)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(AudioVoicePreset.allCases.filter { $0 != .flat }) { preset in presetButton(preset) }
                }
                Text(model.audioProcessing.preset?.detail ?? String(localized: "Custom tone. Your EQ values are shown below."))
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    toneRow("Bass", path: \.bass)
                    toneRow("Mids", path: \.mid)
                    toneRow("Treble", path: \.treble)
                    DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                        VStack(spacing: 8) {
                            row("Low cut", value: model.audioProcessing.lowCut, range: AudioProcessingSettings.lowCutRange,
                                format: { $0 < 20 ? String(localized: "Off") : "\(Int($0)) Hz" }) { value in
                                model.changeAudioProcessing { $0.lowCut = value }
                            }
                            row("High cut", value: model.audioProcessing.highCut, range: AudioProcessingSettings.highCutRange,
                                reset: 20_000, format: { $0 >= 20_000 ? String(localized: "Off") : String(format: "%.1f kHz", $0 / 1_000) }) { value in
                                model.changeAudioProcessing { $0.highCut = value }
                            }
                            Text("Low cut reduces rumble. High cut softens hiss and detail.")
                                .font(.caption2).foregroundStyle(AppColors.textSecondary)
                        }.padding(.top, 8)
                    }.font(.caption.weight(.medium))
                }.disabled(!model.audioProcessing.isToneEnabled)
                if !model.audioProcessing.isToneEnabled {
                    Text("Tone bypassed. Your EQ is saved; Basic settings and other effects still apply.")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Label("Tone", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.audioProcessing.isToneEnabled
                     ? model.audioProcessing.preset?.name ?? String(localized: "Custom")
                     : String(localized: "Bypassed"))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }.frame(minHeight: 44)
        }
        .tint(AppColors.accent).disabled(!model.canEditSelection)
        .padding(.horizontal, 12).padding(.vertical, 4).appSurface()
    }

    private var compressor: some View {
        effectCard("Compressor", icon: "waveform.path", summary: model.audioProcessing.compressor?.isEnabled == true ? "On" : "Off",
                   expanded: $compressorExpanded) {
            let c = model.audioProcessing.compressor ?? .init()
            effectSwitch("Compressor on", path: \.compressor, fallback: .init())
            Text("Even out loud and quiet moments. Start with Amount, then fine-tune if needed.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                row("Amount", value: c.amount * 100, range: 0...100, reset: 50, format: Self.percent) { value in
                    editEffect(\.compressor, fallback: .init()) { $0.setAmount(value / 100) }
                }
                DisclosureGroup("Advanced", isExpanded: $compressorAdvanced) {
                    VStack(spacing: 8) {
                        row("Threshold", value: c.threshold, range: -60...0, reset: -21, format: Self.decibels) { value in
                            editEffect(\.compressor, fallback: .init()) { $0.threshold = value }
                        }
                        row("Ratio", value: c.ratio, range: 1...12, reset: 4.5, format: { String(format: "%.1f:1", $0) }) { value in
                            editEffect(\.compressor, fallback: .init()) { $0.ratio = value }
                        }
                        HStack(spacing: 16) {
                            row("Attack", value: c.attack, range: 1...100, reset: 15, format: Self.milliseconds) { value in
                                editEffect(\.compressor, fallback: .init()) { $0.attack = value }
                            }
                            row("Release", value: c.release, range: 20...1_000, reset: 180, format: Self.milliseconds) { value in
                                editEffect(\.compressor, fallback: .init()) { $0.release = value }
                            }
                        }
                        row("Makeup", value: c.makeup, range: 0...12, format: Self.decibels) { value in
                            editEffect(\.compressor, fallback: .init()) { $0.makeup = value }
                        }
                    }.padding(.top, 8)
                }.font(.caption.weight(.medium))
            }.disabled(!c.isEnabled || model.audioProcessing.compressor == nil)
        }
    }

    private var ducking: some View {
        let d = model.audioProcessing.ducking ?? .init()
        let sources = model.audioDuckingSources
        let hasSource = sources.contains { $0.id == d.sourceClipID }
        return effectCard("Auto Ducking", icon: "speaker.wave.1", summary: model.audioProcessing.ducking?.isEnabled == true && hasSource ? "On" : "Off",
                          expanded: $duckingExpanded) {
            effectSwitch("Ducking on", path: \.ducking, fallback: .init())
            Text("Lower this clip under a voice. Select music here, then choose the voice clip below.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
            if sources.isEmpty {
                Label("Add another audio clip or a video with sound to choose a voice source.", systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Voice source").font(.caption.weight(.medium))
                Picker("Voice source", selection: Binding<UUID?>(get: { hasSource ? d.sourceClipID : nil }, set: { id in
                    model.flushGradeHistory()
                    editEffect(\.ducking, fallback: .init()) { $0.sourceClipID = id }
                    model.flushGradeHistory()
                })) {
                    Text("Choose a clip").tag(UUID?.none)
                    ForEach(sources, id: \.id) { source in Text(source.name).tag(Optional(source.id)) }
                }.pickerStyle(.menu).labelsHidden().font(.caption).tint(AppColors.accent)
                    .lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityLabel("Voice source")
                if d.sourceClipID != nil && !hasSource {
                    Text("Voice source was removed. Choose another clip to restore ducking.")
                        .font(.caption2).foregroundStyle(AppColors.warning)
                }
                VStack(spacing: 8) {
                    row("Reduction", value: d.reduction, range: 0...30, reset: 12, format: { String(format: "−%.1f dB", $0) }) { value in
                        editEffect(\.ducking, fallback: .init()) { $0.reduction = value }
                    }
                    HStack(spacing: 16) {
                        row("Lower before", value: d.attack, range: 0.02...1, reset: 0.15, format: Self.seconds) { value in
                            editEffect(\.ducking, fallback: .init()) { $0.attack = value }
                        }
                        row("Recover", value: d.release, range: 0.1...3, reset: 0.6, format: Self.seconds) { value in
                            editEffect(\.ducking, fallback: .init()) { $0.release = value }
                        }
                    }
                    row("Voice threshold", value: d.threshold, range: -55 ... -10, reset: -35, format: Self.decibels) { value in
                        editEffect(\.ducking, fallback: .init()) { $0.threshold = value }
                    }
                    Text("Lower the threshold for quiet speech. Raise it if background noise keeps the music low.")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
                    let levels = model.audioDuckingPreview
                    if !levels.isEmpty {
                        AudioDuckingPreview(levels: levels)
                        Text("Music level across this clip · updates with your controls")
                            .font(.caption2).foregroundStyle(AppColors.textSecondary)
                    }
                }.disabled(!d.isEnabled || model.audioProcessing.ducking == nil || !hasSource)
            }
        }
    }

    private var space: some View {
        let e = model.audioProcessing.echo ?? .init()
        let r = model.audioProcessing.reverb ?? .init()
        let enabled = model.audioProcessing.echo?.isEnabled == true || model.audioProcessing.reverb?.isEnabled == true
        return effectCard("Echo & Reverb", icon: "waveform.circle", summary: enabled ? "On" : "Off", expanded: $spaceExpanded) {
            Menu {
                Button("Slapback") { applySpace(echo: .init(mix: 0.3, time: 0.1, feedback: 0.15), reverb: nil) }
                Button("Small room") { applySpace(echo: nil, reverb: .init(mix: 0.18, size: 0.2, damping: 0.6)) }
                Button("Hall") { applySpace(echo: nil, reverb: .init(mix: 0.35, size: 0.85, damping: 0.35)) }
                Button("Reset space") { applySpace(echo: nil, reverb: nil) }
            } label: { Label("Space presets", systemImage: "sparkles").font(.caption.weight(.medium)).frame(minHeight: 44) }
            effectSwitch("Echo on", path: \.echo, fallback: .init())
            VStack(spacing: 8) {
                row("Echo mix", value: e.mix * 100, range: 0...80, reset: 25, format: Self.percent) { value in
                    editEffect(\.echo, fallback: .init()) { $0.mix = value / 100 }
                }
                HStack(spacing: 16) {
                    row("Time", value: e.time, range: 0.04...1.5, reset: 0.3, format: Self.seconds) { value in
                        editEffect(\.echo, fallback: .init()) { $0.time = value }
                    }
                    row("Feedback", value: e.feedback * 100, range: 0...80, reset: 35, format: Self.percent) { value in
                        editEffect(\.echo, fallback: .init()) { $0.feedback = value / 100 }
                    }
                }
            }.disabled(!e.isEnabled || model.audioProcessing.echo == nil)
            Divider().overlay(AppColors.border)
            effectSwitch("Reverb on", path: \.reverb, fallback: .init())
            VStack(spacing: 8) {
                row("Reverb mix", value: r.mix * 100, range: 0...80, reset: 20, format: Self.percent) { value in
                    editEffect(\.reverb, fallback: .init()) { $0.mix = value / 100 }
                }
                HStack(spacing: 16) {
                    row("Size", value: r.size * 100, range: 0...100, reset: 50, format: Self.percent) { value in
                        editEffect(\.reverb, fallback: .init()) { $0.size = value / 100 }
                    }
                    row("Damping", value: r.damping * 100, range: 0...100, reset: 50, format: Self.percent) { value in
                        editEffect(\.reverb, fallback: .init()) { $0.damping = value / 100 }
                    }
                }
            }.disabled(!r.isEnabled || model.audioProcessing.reverb == nil)
            Text("Echo repeats the sound. Reverb adds a room tail. Tails end at the clip edge; leave room before trimming.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var texture: some View {
        let t = model.audioProcessing.texture ?? .init()
        return effectCard("Texture", icon: "waveform.path.ecg", summary: model.audioProcessing.texture?.isEnabled == true ? "On" : "Off",
                          expanded: $textureExpanded) {
            effectSwitch("Texture on", path: \.texture, fallback: .init())
            VStack(spacing: 8) {
                row("Distortion", value: t.distortion * 100, range: 0...100, format: Self.percent) { value in
                    editEffect(\.texture, fallback: .init()) { $0.distortion = value / 100 }
                }
                row("Bitcrusher", value: t.crush * 100, range: 0...100, format: Self.percent) { value in
                    editEffect(\.texture, fallback: .init()) { $0.crush = value / 100 }
                }
            }.disabled(!t.isEnabled || model.audioProcessing.texture == nil)
            Text("Distortion adds grit. Bitcrusher creates a rough, digital sound. Start low and watch the clip level.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func effectCard<Content: View>(_ title: String, icon: String, summary: String,
                                          expanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 12, content: content).padding(.top, 8)
        } label: {
            HStack {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(summary).font(.caption).foregroundStyle(AppColors.textSecondary)
            }.frame(minHeight: 44)
        }.tint(AppColors.accent).disabled(!model.canEditSelection)
            .padding(.horizontal, 12).padding(.vertical, 4).appSurface()
    }

    private func effectSwitch<T: AudioEffectSettings>(_ title: String, path: WritableKeyPath<AudioProcessingSettings, T?>,
                                                       fallback: T) -> some View {
        Toggle(title, isOn: Binding(get: { model.audioProcessing[keyPath: path]?.isEnabled == true }, set: { enabled in
            model.flushGradeHistory()
            editEffect(path, fallback: fallback) { $0.isEnabled = enabled }
            model.flushGradeHistory()
        })).font(.caption.weight(.medium)).tint(AppColors.accent).frame(minHeight: 44)
    }
    private func editEffect<T>(_ path: WritableKeyPath<AudioProcessingSettings, T?>, fallback: T, _ edit: (inout T) -> Void) {
        model.changeAudioProcessing { settings in
            var effect = settings[keyPath: path] ?? fallback
            edit(&effect); settings[keyPath: path] = effect
        }
    }
    private func applySpace(echo: AudioEchoSettings?, reverb: AudioReverbSettings?) {
        model.flushGradeHistory()
        model.changeAudioProcessing { $0.echo = echo; $0.reverb = reverb }
        model.flushGradeHistory()
    }
    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
    private static func decibels(_ value: Double) -> String { String(format: "%.1f dB", value) }
    private static func milliseconds(_ value: Double) -> String { "\(Int(value.rounded())) ms" }

    private func presetButton(_ preset: AudioVoicePreset) -> some View {
        let selected = model.audioProcessing.preset == preset
        return Button { model.applyAudioPreset(preset) } label: {
            HStack(spacing: 6) {
                Image(systemName: preset.icon)
                Text(preset.name).lineLimit(2)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
            }
            .font(.caption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
            .background(selected ? AppColors.accentMuted : AppColors.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
            .overlay(RoundedRectangle(cornerRadius: AppCornerRadius.control)
                .strokeBorder(selected ? AppColors.accent.opacity(0.65) : AppColors.border, lineWidth: 1))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(preset.detail)
    }

    private func toneRow(_ title: String, path: WritableKeyPath<AudioProcessingSettings, Double>) -> some View {
        row(title, value: model.audioProcessing[keyPath: path], range: AudioProcessingSettings.gainRange,
            format: { String(format: "%+.1f dB", $0) }) { value in
            model.changeAudioProcessing { $0[keyPath: path] = value }
        }
    }

    private func row(_ title: String, value: Double, range: ClosedRange<Double>, reset: Double = 0,
                     format: @escaping (Double) -> String, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer(minLength: 4)
                NumericEntryLabel(title: title, text: format(value), value: value, range: range,
                                  tint: value == reset ? AppColors.textSecondary : AppColors.accent) {
                    set($0); model.flushGradeHistory()
                }.font(.caption.monospacedDigit())
            }
            ResettableSlider(value: Binding(get: { value }, set: set), range: range,
                             resetValue: reset, label: title,
                             onEditingChanged: { if !$0 { model.flushGradeHistory() } })
                .tint(AppColors.accent).frame(minHeight: 44)
                .accessibilityValue(format(value))
        }
    }

    private var libraryActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { libraryButtons }
            VStack(alignment: .leading, spacing: 4) { libraryButtons }
        }.font(.caption.weight(.medium))
    }
    @ViewBuilder private var libraryButtons: some View {
        Button(action: addSoundEffect) { Label("Sounds", systemImage: "waveform.badge.plus") }
            .disabled(model.isImporting).frame(minHeight: 44)
        Button(action: addAudio) { Label("Files", systemImage: "folder") }
            .disabled(model.isImporting).frame(minHeight: 44)
        if model.selectedAudio != nil {
            Button { Task { await model.detectBeats() } } label: { Label("Beats", systemImage: "waveform.path.ecg") }
                .frame(minHeight: 44)
        }
        Button(action: showTracks) { Label("Tracks", systemImage: "slider.horizontal.3") }.frame(minHeight: 44)
    }

    private static func seconds(_ value: Double) -> String {
        value > 0.0005 ? String(format: value < 1 ? "%.2fs" : "%.1fs", locale: .current, value) : String(localized: "Off")
    }
    private static func panLabel(_ value: Double) -> String {
        abs(value) < 0.5 ? String(localized: "Center") : "\(value < 0 ? "L" : "R") \(Int(abs(value).rounded()))"
    }
}

private struct AudioClipLevelMeter: View {
    @ObservedObject var model: EditorViewModel
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let reading = model.audioLevel
            let progress = min(1, max(0, (reading.decibels + 60) / 60))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clip level").font(.caption.weight(.medium))
                    Spacer()
                    Text(reading.peak > 1 ? "Clipping · lower volume"
                         : reading.peak > 0.001 ? String(format: "%.1f dBFS", reading.decibels)
                         : String(localized: "Silent"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(reading.peak > 1 ? AppColors.warning : AppColors.textSecondary)
                }
                GeometryReader { geometry in
                    Capsule().fill(AppColors.controlTrack)
                    Capsule().fill(reading.peak > 1 ? AppColors.warning : AppColors.positive)
                        .frame(width: geometry.size.width * progress)
                }.frame(height: 4).accessibilityHidden(true)
                if !reading.isSupported {
                    Text("Audio effects are unavailable for this audio format.")
                        .font(.caption2).foregroundStyle(AppColors.warning)
                }
            }.accessibilityElement(children: .combine)
        }.padding(.horizontal, 4)
    }
}

private struct AudioDuckingPreview: View {
    let levels: [Double]
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for (index, gain) in levels.enumerated() {
                let point = CGPoint(x: Double(index) / Double(max(1, levels.count - 1)) * size.width,
                                    y: (1 - gain) * (size.height - 8) + 4)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(AppColors.accent), lineWidth: 2)
        }.frame(height: 48).padding(.horizontal, 6).background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Ducking envelope. Lower sections indicate reduced music volume.")
    }
}
