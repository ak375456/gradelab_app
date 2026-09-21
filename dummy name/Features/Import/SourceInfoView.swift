import SwiftUI

struct SourceInfoView: View {
    let project: GradeProject
    let onBack: () -> Void
    let onEdit: () -> Void
    /// Applies a source-handling choice. Optional so the screen still works
    /// somewhere that does not offer it.
    var onSetColorMode: ((ProjectColorMode) -> Void)?

    private var metadata: VideoMetadata { project.metadata }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    sourceHero
                    technicalMetadata
                    if hasColorMetadata { colorMetadata }
                    appleLogHandling
                    if ColorPipelineSupport(metadata: metadata).notice != nil { supportNotice }
                }
                .padding(AppSpacing.standard)
                .padding(.bottom, 92)
            }
            .scrollIndicators(.hidden)
        }
        .background(AppColors.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            AppButton(
                ColorPipelineSupport(metadata: metadata).allowsEditor ? "Open Editor" : "Editor Unavailable",
                systemImage: ColorPipelineSupport(metadata: metadata).allowsEditor
                    ? "slider.horizontal.3"
                    : "exclamationmark.triangle",
                expandsHorizontally: true,
                action: onEdit
            )
                .disabled(!ColorPipelineSupport(metadata: metadata).allowsEditor)
                .padding(AppSpacing.standard)
                .background(AppColors.background.opacity(0.96))
                .overlay(alignment: .top) { AppDivider() }
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back")
            Text("Source Information").font(AppTypography.headline).frame(maxWidth: .infinity)
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, AppSpacing.xSmall)
        .background(AppColors.background)
        .overlay(alignment: .bottom) { AppDivider() }
    }

    private var sourceHero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            AppSectionHeader("Source")
            VStack(alignment: .leading, spacing: AppSpacing.compact) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metadata.resolutionLabel).font(.system(.title, design: .monospaced, weight: .semibold))
                    Spacer()
                    if let resolutionClass = metadata.resolutionClass {
                        AppBadge(title: LocalizedStringKey(resolutionClass), tone: .accent)
                    }
                }
                HStack(spacing: AppSpacing.small) {
                    if let fps = metadata.frameRateLabel { AppBadge(title: LocalizedStringKey(fps)) }
                    AppBadge(title: LocalizedStringKey(metadata.codec))
                    if let depth = metadata.bitDepth {
                        AppBadge(title: LocalizedStringKey("\(depth)-bit"), tone: depth > 8 ? .warning : .neutral)
                    }
                }
                Text(project.displayName).font(AppTypography.secondary)
                    .foregroundStyle(AppColors.textSecondary).lineLimit(2)
            }
            .padding(AppSpacing.standard)
            .appSurface(fill: AppColors.surface)
        }
    }

    private var technicalMetadata: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            AppSectionHeader("Media")
            MetadataCard {
                MetadataRow(label: "Duration", value: metadata.durationLabel, systemImage: "clock")
                AppDivider(inset: AppSpacing.standard)
                if let bitrate = metadata.bitrateLabel {
                    MetadataRow(label: "Video Bitrate", value: bitrate, systemImage: "speedometer")
                    AppDivider(inset: AppSpacing.standard)
                }
                if let fileSize = metadata.fileSizeLabel {
                    MetadataRow(label: "File Size", value: fileSize, systemImage: "internaldrive")
                    AppDivider(inset: AppSpacing.standard)
                }
                MetadataRow(
                    label: "Audio",
                    value: metadata.hasAudio ? "Included" : "None",
                    detail: metadata.hasAudio ? "\(metadata.audioTrackCount) track\(metadata.audioTrackCount == 1 ? "" : "s")" : nil,
                    systemImage: metadata.hasAudio ? "waveform" : "speaker.slash"
                )
                if let creationDate = metadata.creationDate {
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "Created", value: creationDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                }
            }
        }
    }

    private var colorMetadata: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            AppSectionHeader("Color")
            MetadataCard {
                // What the source is, named from its own metadata. For a Log
                // file this is the fact that matters: "10-bit BT.2020" describes
                // the container, not the colour encoding.
                MetadataRow(label: "Profile", value: profile.displayName, systemImage: "camera.aperture")
                if let primaries = displayedPrimaries {
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "Primaries", value: primaries.value, detail: primaries.detail, systemImage: "triangle")
                }
                if let transfer = displayedTransfer {
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "Transfer", value: transfer.value, detail: transfer.detail, systemImage: "function")
                }
                if let matrix = metadata.yCbCrMatrix {
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "YCbCr Matrix", value: matrix, systemImage: "square.grid.3x3")
                }
                if let depth = metadata.bitDepth {
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "Bit Depth", value: "\(depth)-bit", systemImage: "square.stack.3d.up")
                }
                AppDivider(inset: AppSpacing.standard)
                MetadataRow(label: "Dynamic Range", value: profile.dynamicRangeLabel,
                            systemImage: profile.isLog ? "waveform.path.ecg" : "sun.max")
            }
        }
    }

    /// How Apple Log footage is handled, offered only for footage that is
    /// actually Apple Log.
    ///
    /// Log is not a picture — it is a way of storing one, deliberately flat so
    /// the camera keeps its highlight range. Decoding it is what makes it
    /// gradeable, so that is the default. Leaving it as recorded is offered for
    /// anyone who wants to see or grade the untouched signal, with the cost
    /// stated rather than discovered.
    @ViewBuilder private var appleLogHandling: some View {
        // Whichever Log format this source actually is. The decoded option has
        // to carry the matching mode: offering ".appleLog" for Log 2 footage
        // would decode it through BT.2020 primaries instead of Apple Wide Gamut.
        let decodedMode: ProjectColorMode? = switch profile {
        case .appleLog: .appleLog
        case .appleLog2: .appleLog2
        default: nil
        }
        if let onSetColorMode, let decodedMode {
            VStack(alignment: .leading, spacing: AppSpacing.compact) {
                // Literal keys rather than the profile's display name, so both
                // headings stay localisable.
                if decodedMode == .appleLog2 {
                    AppSectionHeader("Apple Log 2")
                } else {
                    AppSectionHeader("Apple Log")
                }
                VStack(alignment: .leading, spacing: AppSpacing.compact) {
                    Picker("Handling", selection: Binding(
                        get: { project.colorMode.isAppleLog ? decodedMode : .sdrWide },
                        set: { onSetColorMode($0) }
                    )) {
                        Text("Decode and render").tag(decodedMode)
                        Text("Original, as recorded").tag(ProjectColorMode.sdrWide)
                    }
                    .pickerStyle(.segmented)
                    Text(project.colorMode.isAppleLog
                         ? decodedExplanation(for: decodedMode)
                         : "The Log signal is passed through untouched, so the picture stays flat and the grading tools work on Log values. Creative looks are built for Rec.709 and will not land correctly on it.")
                        .font(AppTypography.caption)
                        .foregroundStyle(project.colorMode.isAppleLog
                                         ? AppColors.textSecondary : AppColors.warning)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.standard)
                .appSurface()
            }
        }
    }

    /// Apple Log 2 gets its own sentence because it genuinely does one more
    /// thing: a gamut conversion. Saying "Apple Log" for both would be the kind
    /// of near-truth that makes a colour problem hard to track down later.
    private func decodedExplanation(for mode: ProjectColorMode) -> String {
        switch mode {
        case .appleLog2:
            String(localized: "Apple's transfer function decodes the footage to scene light, the primaries are converted from Apple Wide Gamut to BT.2020, and Apple's own display transform renders it to Rec.709. This is the picture the camera captured, and what export produces.")
        default:
            String(localized: "Apple's transfer function decodes the footage to scene light, and Apple's own display transform renders it to Rec.709. This is the picture the camera captured, and what export produces.")
        }
    }

    private var supportNotice: some View {
        let support = ColorPipelineSupport(metadata: metadata)
        return HStack(alignment: .top, spacing: AppSpacing.compact) {
            Image(systemName: !support.isBlocking ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(!support.isBlocking ? AppColors.accent : AppColors.warning)
            Text(support.notice ?? "").font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary)
        }
        .padding(AppSpacing.standard)
        .appSurface()
    }

    /// What the source is, from its own metadata.
    private var profile: SourceColorProfile { SourceColorProfile.detect(metadata: metadata) }

    /// The file's own primaries tag, or — when the file carries none and the
    /// profile itself establishes them — the profile's, labelled as such.
    ///
    /// Apple Log files tag no primaries: the identifier
    /// `com.apple.rec2020.apple-log` establishes them instead. Showing nothing
    /// there would be less honest than showing where the value comes from.
    private var displayedPrimaries: (value: String, detail: String?)? {
        if let tagged = metadata.colorPrimaries { return (tagged, nil) }
        if let defined = profile.definedPrimaries { return (defined, "From the \(profile.displayName) profile") }
        return nil
    }

    /// Same rule for the transfer function. A Log file's curve is named by its
    /// Log identifier rather than by the standard transfer tag, which is why a
    /// bare "Transfer: undefined" would be misleading here.
    private var displayedTransfer: (value: String, detail: String?)? {
        if profile.isLog { return (profile.displayName, "Log identifier") }
        if let tagged = metadata.transferFunction { return (tagged, nil) }
        return nil
    }

    private var hasColorMetadata: Bool {
        metadata.colorPrimaries != nil || metadata.transferFunction != nil || metadata.yCbCrMatrix != nil
            || metadata.logTransferFunction != nil || metadata.isHDR == true
    }
}
