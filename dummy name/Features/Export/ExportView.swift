import SwiftUI

struct ExportView: View {
    @StateObject private var model: ExportViewModel
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsClose = false
    @State private var paywallFeature: ProFeature?

    init(project: GradeProject, settings: GradeSettings) {
        _model = StateObject(wrappedValue: ExportViewModel(project: project, settings: settings))
    }

    /// States the actual encode, so a 10-bit source is never reported as if it
    /// were being written at 8-bit.
    private var exportColorSummary: String {
        // Names the encode that will actually happen, ProRes included, so the
        // line is never a description of a codec the file is not written in.
        let codec = model.configuration.codec
        let encode = codec.usesBitRate ? "HEVC Main 10" : codec.rawValue
        let audio = String(localized: "Timeline audio mixed to AAC")
        switch model.project.colorMode {
        case .hdrHLG:
            return "10-bit HDR · \(encode) · HLG, BT.2020 · \(audio)"
        case .sdrWide:
            return "10-bit Rec.709 SDR · \(encode) · \(audio)"
        case .appleLog, .appleLog2:
            return "\(model.project.colorMode.title) → Rec.709 SDR · 10-bit \(encode) · \(audio)"
        case .sdr:
            return codec.usesBitRate
                ? "8-bit Rec.709 SDR · \(audio)"
                : "Rec.709 SDR · \(encode) · \(audio)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch model.state {
                case .preparing:
                    progressView(title: String(localized: "Preparing Export"), progress: nil)
                case .exporting(let progress):
                    progressView(title: String(localized: "Exporting"), progress: progress)
                case .finishing(let progress):
                    progressView(title: String(localized: "Finishing"), progress: progress)
                case .completed:
                    completionView
                case .cancelled:
                    statusView(
                        icon: "xmark.circle",
                        title: "Export Cancelled",
                        message: "No incomplete output was kept.",
                        actionTitle: "Back to Settings",
                        action: model.resetAfterFailure
                    )
                case .failed(let message):
                    statusView(
                        icon: "exclamationmark.triangle",
                        title: "Export Failed",
                        message: message,
                        actionTitle: "Back to Settings",
                        action: model.resetAfterFailure
                    )
                case .idle:
                    configurationView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .numericEntryHost()
        .keepsScreenAwake(model.isBusy || model.isSaving)
        .interactiveDismissDisabled(model.isBusy || model.isSaving || (model.outputURL != nil && !model.savedToPhotos))
        .alert("Close this export?", isPresented: $confirmsClose) {
            Button("Keep Export Open", role: .cancel) {}
            Button("Close", role: .destructive) { dismiss() }
        } message: {
            Text("The temporary file will be removed. Save to Photos or use Share to save a copy to Files first.")
        }
        .onAppear(perform: model.prepare)
        .paywallSheet($paywallFeature)
        .sheet(isPresented: $model.showsShareSheet) {
            if let outputURL = model.outputURL {
                VideoShareSheet(videoURL: outputURL)
                    .ignoresSafeArea()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if model.isBusy { model.cancel() } else { requestClose() }
            } label: {
                Text(model.isBusy ? "Cancel" : "Close")
                    .font(AppTypography.callout)
                    .foregroundStyle(model.isBusy ? AppColors.destructive : AppColors.textSecondary)
                    .frame(minWidth: 54, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint(model.isBusy ? "Stops the export and removes its incomplete file" : "Closes export")
            .disabled(model.isSaving)

            Text(exportTitle)
                .font(AppTypography.headline)
                .frame(maxWidth: .infinity)

            Color.clear.frame(width: 54, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, AppSpacing.standard)
        .overlay(alignment: .bottom) { AppDivider() }
    }

    private var exportTitle: String {
        if case .completed = model.state { return String(localized: "Export Complete") }
        return String(localized: "Export")
    }

    private var configurationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                sourceSummary
                outputSummary
                capabilityStatus
                estimateSummary
                proNotice
                // The device's own limits come first. When this hardware cannot
                // write the chosen configuration at all, the button stays a
                // disabled "Export Video" and the capability card above says
                // why — offering to sell Pro for an export that still would not
                // run would be the wrong thing to put in front of someone.
                AppButton(
                    showsUnlock ? "Unlock Pro to Export" : "Export Video",
                    systemImage: showsUnlock ? "lock.fill" : "arrow.up.circle.fill",
                    expandsHorizontally: true
                ) {
                    if let requirement = model.proRequirement, !store.hasPro {
                        paywallFeature = requirement
                    } else {
                        model.startExport()
                    }
                }
                .disabled(!model.canStart)
            }
            .padding(AppSpacing.standard)
            .padding(.bottom, AppSpacing.xLarge)
        }
        .scrollIndicators(.hidden)
    }

    private var sourceSummary: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            AppSectionHeader("Source")
            MetadataCard {
                MetadataRow(label: "Resolution", value: model.project.metadata.resolutionLabel)
                AppDivider(inset: AppSpacing.standard)
                MetadataRow(label: "Frame Rate", value: model.project.metadata.frameRateLabel ?? "Unknown")
                AppDivider(inset: AppSpacing.standard)
                MetadataRow(
                    label: "Codec",
                    value: model.project.metadata.codec,
                    detail: model.project.metadata.bitDepth.map { "\($0)-bit" }
                )
                if let bitrate = model.project.metadata.bitrateLabel {
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "Estimated Bitrate", value: bitrate)
                }
            }
        }
    }

    private var outputSummary: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            AppSectionHeader("Output", subtitle: LocalizedStringKey(outputTechnicalLine))
            VStack(spacing: 16) {
                Picker("Format", selection: $model.configuration.container) {
                    ForEach(ExportConfiguration.Container.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Codec", selection: $model.configuration.codec) {
                    ForEach(ExportConfiguration.Codec.allCases, id: \.self) { codec in
                        Text(optionLabel(codec.rawValue, needsPro: codecNeedsPro(codec))).tag(codec)
                    }
                }
                Text("HEVC makes smaller files. H.264 works with more apps.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Size", selection: $model.configuration.resolution) {
                    ForEach(ExportConfiguration.Resolution.allCases, id: \.self) { resolution in
                        Text(optionLabel(resolution.rawValue,
                                         needsPro: resolutionNeedsPro(resolution))).tag(resolution)
                    }
                }
                if model.configuration.resolution == .custom {
                    Stepper("Longest edge: \(model.configuration.customLongEdge) px", value: $model.configuration.customLongEdge, in: 64...7680, step: 2)
                    TextField("Longest edge in pixels", value: $model.configuration.customLongEdge, format: .number)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                }
                Text("Resizing keeps the original shape. Upscaling does not add detail.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Frame rate", selection: $model.configuration.frameRate) {
                    ForEach(ExportConfiguration.FrameRate.allCases, id: \.self) { rate in
                        Text(optionLabel(rate == .original ? "Project frame rate" : "\(rate.rawValue) fps",
                                         needsPro: frameRateNeedsPro(rate))).tag(rate)
                    }
                }
                if model.configuration.frameRate != .original {
                    Text("Frames are repeated or dropped. Speed and audio timing stay unchanged; no motion interpolation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Edited timelines render on the project’s frame grid. Source files remain unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Quality", selection: $model.configuration.qualityPreset) {
                    ForEach(ExportConfiguration.QualityPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(model.configuration.videoBitRate != nil)
                DisclosureGroup("Advanced bitrate") {
                    Toggle(isOn: Binding(get: { model.configuration.videoBitRate != nil }, set: { model.configuration.videoBitRate = $0 ? 30_000_000 : nil })) {
                        Text("Set bitrate manually").proMarked(!store.hasPro)
                    }
                    if let rate = model.configuration.videoBitRate {
                        HStack {
                            Text("Bitrate"); Spacer()
                            NumericEntryLabel(title: "Bitrate (Mbps)", text: "\(rate / 1_000_000) Mbps",
                                              value: Double(rate) / 1_000_000, range: 2...240) { typed in
                                model.configuration.videoBitRate = Int(typed.rounded()) * 1_000_000
                            }
                        }
                        ResettableSlider(value: Binding(get: { Double(model.configuration.videoBitRate ?? 30_000_000) / 1_000_000 },
                                                        set: { model.configuration.videoBitRate = Int($0) * 1_000_000 }),
                                         range: 2...240, resetValue: 30, label: "Video bitrate in megabits per second")
                    }
                    Text("Higher bitrate uses more storage. Quality presets choose an average target automatically; actual file size varies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                    Text(exportColorSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }.pickerStyle(.menu).padding().appSurface()
        }
    }

    // MARK: - Pro

    /// Whether the paywall is the only thing left between these settings and
    /// the file, which is the one case where the button should offer to unlock.
    private var showsUnlock: Bool { model.isLocked && model.canStart }

    /// Each menu row asks about its own control only.
    ///
    /// Asking the whole-configuration question here was a bug: on a 4K project
    /// the resolution alone puts the export behind the paywall, so every codec
    /// — HEVC included — came back "Pro", which is untrue of the codec and
    /// reads as a mistake. These ask the policy about one control at a time.
    private func codecNeedsPro(_ codec: ExportConfiguration.Codec) -> Bool {
        !store.hasPro && ProAccessPolicy.codecRequiresPro(codec)
    }

    private func resolutionNeedsPro(_ resolution: ExportConfiguration.Resolution) -> Bool {
        !store.hasPro && ProAccessPolicy.resolutionRequiresPro(
            resolution,
            canvas: model.project.canvas,
            customLongEdge: model.configuration.customLongEdge)
    }

    private func frameRateNeedsPro(_ frameRate: ExportConfiguration.FrameRate) -> Bool {
        !store.hasPro && ProAccessPolicy.frameRateRequiresPro(frameRate)
    }

    /// A menu row's text. Menu rows cannot carry a badge view, so Pro options
    /// say so in words.
    private func optionLabel(_ title: String, needsPro: Bool) -> String {
        needsPro ? "\(title) · Pro" : title
    }

    /// Every Pro feature this export would use, listed above the button so the
    /// reasons are visible before it is pressed rather than only after — and so
    /// someone who would rather not pay can see exactly what to undo.
    @ViewBuilder
    private var proNotice: some View {
        if !store.hasPro {
            let requirements = model.proRequirements
            if !requirements.isEmpty {
                ProRequirementList(features: requirements) {
                    paywallFeature = requirements.first
                }
            }
        }
    }

    /// Size and length, immediately above the Export button.
    ///
    /// The size is arithmetic from the average bitrate the encoder is being
    /// given, so it is shown as approximate — a variable-bitrate encode of
    /// simple footage comes in under it. Time is not offered here: how long an
    /// encode takes depends on the device and the grade, and a number invented
    /// before any frame has been written would be a guess dressed up as a fact.
    @ViewBuilder
    private var estimateSummary: some View {
        if let estimate = model.estimate {
            HStack(spacing: AppSpacing.compact) {
                Image(systemName: "internaldrive")
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppColors.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated size \(estimate.sizeLabel)")
                        .font(AppTypography.secondary)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("\(TimecodeFormatter.string(from: estimate.durationSeconds)) of video · actual size varies with the footage")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.standard)
            .appSurface()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Estimated size \(estimate.sizeLabel)")
        }
    }

    @ViewBuilder
    private var capabilityStatus: some View {
        if model.isCheckingCapabilities {
            HStack(spacing: AppSpacing.compact) {
                ProgressView().tint(AppColors.accent)
                Text("Checking this device’s encoder…")
                    .font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.standard)
            .appSurface()
            .accessibilityElement(children: .combine)
        } else if let capabilities = model.capabilities, capabilities.canExport {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Label("This device supports the selected configuration.", systemImage: "checkmark.circle.fill")
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppColors.positive)
                // Things that do not block the export but change the result, so
                // they are said rather than left to be discovered afterwards.
                ForEach(capabilities.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.standard)
                .appSurface()
        } else if let capabilities = model.capabilities {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Label("This device cannot export this configuration.", systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.bodyEmphasized).foregroundStyle(AppColors.warning)
                ForEach(capabilities.issues, id: \.self) { issue in
                    Text(issue).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                }
                Text(model.project.colorMode.isWidePrecision
                     ? "This needs hardware HEVC Main 10 support at the selected size and frame rate."
                     : "Requires a supported 8-bit SDR source and a compatible hardware encoder. Try a smaller size or another codec.")
                    .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.standard)
            .appSurface()
        }
    }

    private func progressView(title: String, progress: ExportProgress?) -> some View {
        VStack(spacing: AppSpacing.large) {
            ZStack {
                Circle().stroke(AppColors.controlTrack, lineWidth: 7)
                if let progress {
                    Circle()
                        .trim(from: 0, to: progress.fractionCompleted)
                        .stroke(AppColors.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView().controlSize(.large).tint(AppColors.accent)
                }
                if let progress {
                    Text("\(progress.percentage)%")
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .contentTransition(.numericText(value: progress.fractionCompleted))
                }
            }
            .frame(width: 128, height: 128)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(progress.map { "\($0.percentage) percent" } ?? "Preparing")

            VStack(spacing: AppSpacing.small) {
                Text(title).font(AppTypography.title)
                Text(outputTechnicalLine).font(AppTypography.numeric).foregroundStyle(AppColors.textSecondary)
                if let progress {
                    Text("\(TimecodeFormatter.string(from: progress.processedDuration)) of \(TimecodeFormatter.string(from: progress.totalDuration))")
                        .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
                }
                if let remaining = model.timeRemaining {
                    Text(ExportTimeRemaining.label(remaining))
                        .font(AppTypography.secondary)
                        .foregroundStyle(AppColors.textSecondary)
                        // Measured, so it moves. Animating the swap keeps it
                        // from flickering as the figure settles.
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: remaining)
                }
                if let estimate = model.estimate {
                    Text("Estimated size \(estimate.sizeLabel)")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }

            AppButton("Cancel Export", kind: .destructive, action: model.cancel)
        }
        .padding(AppSpacing.xLarge)
    }

    private var completionView: some View {
        ScrollView {
            VStack(spacing: AppSpacing.large) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .medium)).foregroundStyle(AppColors.positive)
                    .accessibilityHidden(true)
                Text("Your grade is baked into the exported frames.")
                    .font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)

                if let metadata = model.outputMetadata {
                    MetadataCard("Generated File", systemImage: "film") {
                        MetadataRow(label: "Resolution", value: metadata.resolutionLabel)
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Frame Rate", value: metadata.frameRateLabel ?? "Unknown")
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Codec", value: metadata.codec)
                        if let size = metadata.fileSizeLabel {
                            AppDivider(inset: AppSpacing.standard)
                            MetadataRow(label: "File Size", value: size)
                        }
                    }
                } else if model.isInspectingOutput {
                    HStack(spacing: AppSpacing.compact) {
                        ProgressView().tint(AppColors.accent)
                        Text("Inspecting generated metadata…")
                            .font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(AppSpacing.standard).appSurface()
                } else {
                    Label("Generated file is ready.", systemImage: "film")
                        .font(AppTypography.secondary)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.standard)
                        .appSurface()
                }

                if let message = model.message {
                    Text(message)
                        .font(AppTypography.secondary)
                        .foregroundStyle(model.savedToPhotos ? AppColors.positive : AppColors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.compact)
                        .appSurface()
                }

                VStack(spacing: AppSpacing.small) {
                    AppButton(
                        model.savedToPhotos ? "Saved to Photos" : (model.isSaving ? "Saving…" : "Save to Photos"),
                        systemImage: model.savedToPhotos ? "checkmark" : "photo.badge.plus",
                        expandsHorizontally: true,
                        action: model.saveToPhotos
                    )
                    .disabled(model.isSaving || model.savedToPhotos)
                    AppButton("Share", systemImage: "square.and.arrow.up", kind: .secondary, expandsHorizontally: true) {
                        model.showsShareSheet = true
                    }
                    AppButton("Done", kind: .quiet, expandsHorizontally: true) { requestClose() }
                        .disabled(model.isSaving)
                }
            }
            .padding(AppSpacing.large)
        }
        .scrollIndicators(.hidden)
    }

    private func statusView(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: AppSpacing.large) {
            Image(systemName: icon).font(.system(size: 46)).foregroundStyle(AppColors.warning)
            VStack(spacing: AppSpacing.small) {
                Text(title).font(AppTypography.title)
                Text(message).font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center)
            }
            AppButton(LocalizedStringKey(actionTitle), kind: .secondary, action: action)
        }
        .padding(AppSpacing.xLarge)
    }

    private var outputTechnicalLine: String {
        let size = model.project.metadata.displaySize
        let dimensions = model.configuration.dimensions(width: Int(size.width), height: Int(size.height))
        let frameRate = model.configuration.frameRate.value.map { "\(Int($0)) fps" } ?? model.project.metadata.frameRateLabel ?? String(localized: "Original timing")
        return "\(dimensions.width) × \(dimensions.height) • \(frameRate) • \(model.configuration.codec.rawValue)"
    }

    private func requestClose() {
        if model.outputURL != nil && !model.savedToPhotos { confirmsClose = true }
        else { dismiss() }
    }
}
