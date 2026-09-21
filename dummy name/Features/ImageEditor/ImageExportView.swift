import SwiftUI

/// The still-image export sheet: pick a format, write the file at the source's
/// own resolution, then save or share it.
struct ImageExportView: View {
    @StateObject private var model: ImageExportViewModel
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var paywallFeature: ProFeature?

    init(project: ImageProject) {
        _model = StateObject(wrappedValue: ImageExportViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch model.state {
                case .idle: configuration
                case .exporting(let progress): progressView(progress)
                case .completed: completion
                case .failed(let message): failure(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .numericEntryHost()
        .keepsScreenAwake(model.isBusy || model.isSaving)
        .interactiveDismissDisabled(model.isBusy || model.isSaving)
        // The written file lives in the temporary directory. It is removed when
        // this sheet goes away — after Save to Photos or Share have taken their
        // own copy — rather than left for the system to collect eventually.
        .onDisappear { model.discardOutput() }
        .paywallSheet($paywallFeature)
        .sheet(isPresented: $model.showsShareSheet) {
            if let url = model.output?.url { VideoShareSheet(videoURL: url).ignoresSafeArea() }
        }
        .alert("Export", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var topBar: some View {
        HStack {
            Button {
                if model.isBusy { model.cancel() } else { model.discardOutput(); dismiss() }
            } label: {
                Text(model.isBusy ? "Cancel" : "Close")
                    .font(AppTypography.callout)
                    .foregroundStyle(model.isBusy ? AppColors.destructive : AppColors.textSecondary)
                    .frame(minWidth: 54, minHeight: 44, alignment: .leading)
            }
            .disabled(model.isSaving)
            Text(model.state == .completed ? "Export Complete" : "Export Image")
                .font(AppTypography.headline).frame(maxWidth: .infinity)
            Color.clear.frame(width: 54, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, AppSpacing.standard)
        .overlay(alignment: .bottom) { AppDivider() }
    }

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                MetadataCard("Output") {
                    MetadataRow(label: "Dimensions", value: model.outputSizeLabel,
                                detail: "Original resolution")
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "Color", value: "Rec.709",
                                detail: "Tagged in the file")
                    AppDivider(inset: AppSpacing.standard)
                    MetadataRow(label: "Grade", value: "Applied at full resolution",
                                detail: "Same shader as the preview")
                }

                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    AppSectionHeader("Format")
                    Picker("Format", selection: $model.configuration.format) {
                        ForEach(ImageExportFormat.available) { format in
                            Text(format == .jpeg || store.hasPro ? format.title : "\(format.title) · Pro").tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(model.configuration.format.detail)
                        .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                }

                if model.configuration.format.isLossy {
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        AppSectionHeader("Quality") {
                            Text(model.configuration.qualityLabel)
                                .font(AppTypography.numeric).foregroundStyle(AppColors.textSecondary)
                        }
                        Slider(value: $model.configuration.quality,
                               in: ImageExportConfiguration.qualityRange)
                            .tint(AppColors.accent)
                            .accessibilityLabel("Compression quality")
                            .accessibilityValue(model.configuration.qualityLabel)
                    }
                }

                if model.hasCutout {
                    transparencyOptions
                }

                proNotice
                AppButton(model.isLocked ? "Unlock Pro to Export" : "Export Image",
                          systemImage: model.isLocked ? "lock.fill" : "arrow.up.circle.fill",
                          expandsHorizontally: true) {
                    if let requirement = model.proRequirement, !store.hasPro {
                        paywallFeature = requirement
                    } else {
                        model.startExport()
                    }
                }
            }
            .padding(AppSpacing.standard)
        }
        .scrollIndicators(.hidden)
    }

    private var transparencyOptions: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            AppSectionHeader(model.flattensCutout ? "Background" : "Transparency")
            if model.flattensCutout {
                HStack(spacing: AppSpacing.small) {
                    flattenPreset(String(localized: "White"), color: .white)
                    flattenPreset(String(localized: "Black"), color: .black)
                    ColorPicker("Custom", selection: flattenColorBinding, supportsOpacity: false)
                        .font(AppTypography.callout)
                        .frame(minHeight: 44)
                }
                Text("This format does not preserve transparency, so the cutout will be flattened onto this color.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                Label("PNG preserves the transparent background.", systemImage: "checkerboard.rectangle")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(minHeight: 44)
            }
        }
    }

    private func flattenPreset(_ title: String, color: RGBAColor) -> some View {
        Button {
            model.configuration.flattenColor = color
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                Text(title)
            }
            .font(AppTypography.callout)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.configuration.flattenColor == color ? AppColors.accent : AppColors.textSecondary)
    }

    private var flattenColorBinding: Binding<Color> {
        Binding {
            let color = model.configuration.flattenColor
            return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
        } set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            model.configuration.flattenColor = RGBAColor(red: red, green: green, blue: blue)
        }
    }

    /// Every Pro feature this still would use.
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

    private func progressView(_ progress: Double) -> some View {
        VStack(spacing: AppSpacing.compact) {
            ProgressView(value: progress)
                .tint(AppColors.accent)
                .frame(maxWidth: 280)
            Text("Rendering at \(model.outputSizeLabel)")
                .font(AppTypography.callout).foregroundStyle(AppColors.textSecondary)
            Text("\(Int(progress * 100))%")
                .font(AppTypography.numeric).foregroundStyle(AppColors.textTertiary)
        }
        .padding(AppSpacing.large)
    }

    private var completion: some View {
        VStack(spacing: AppSpacing.large) {
            VStack(spacing: AppSpacing.small) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 44)).foregroundStyle(AppColors.positive)
                if let output = model.output {
                    Text("\(output.width) × \(output.height) · \(output.format.title)")
                        .font(AppTypography.numeric)
                    if output.byteCount > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: output.byteCount, countStyle: .file))
                            .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            VStack(spacing: AppSpacing.compact) {
                AppButton(model.savedToPhotos ? "Saved to Photos" : "Save to Photos",
                          systemImage: model.savedToPhotos ? "checkmark" : "square.and.arrow.down",
                          expandsHorizontally: true, action: model.saveToPhotos)
                    .disabled(model.isSaving || model.savedToPhotos)
                AppButton("Share", systemImage: "square.and.arrow.up", kind: .secondary,
                          expandsHorizontally: true) { model.showsShareSheet = true }
                AppButton("Done", kind: .secondary, expandsHorizontally: true) {
                    model.discardOutput(); dismiss()
                }
            }
            .frame(maxWidth: 320)
        }
        .padding(AppSpacing.large)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: AppSpacing.compact) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(AppColors.warning)
            Text("Export Failed").font(AppTypography.headline)
            Text(message)
                .font(AppTypography.callout).foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            AppButton("Back to Settings", kind: .secondary, action: model.resetAfterFailure)
        }
        .padding(AppSpacing.large)
    }
}
