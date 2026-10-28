#if !targetEnvironment(macCatalyst)
import SwiftUI

/// Separated controls keep every format reachable without a screen-tall Menu.
struct CameraFormatSheet: View {
    @ObservedObject var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let config = model.configuration {
                        HStack(spacing: 10) {
                            Image(systemName: "video.fill").foregroundStyle(AppColors.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(config.selected.title) · \(config.codec.title)").font(AppTypography.headline)
                                Text(config.selected.profile.title).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                            }
                            Spacer()
                            if !model.canConfigure { ProgressView() }
                        }.padding(16).cameraGlass()
                        section("Resolution", detail: "The recorded image size") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 10) {
                                ForEach(model.resolutions, id: \.resolutionID) { format in
                                    choice(format.resolution, selected: config.selected.resolutionID == format.resolutionID) { model.setResolution(format.width, height: format.height) }
                                }
                            }
                            Text("4:3 sensor modes appear only when this camera exposes them. Frame guides do not change the recorded size.")
                                .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        section("Frame rate", detail: "Frames captured each second") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 10) {
                                ForEach(config.formats.filter { $0.resolutionID == config.selected.resolutionID && $0.profile == config.selected.profile }, id: \.id) { format in
                                    choice("\(format.fps) fps", selected: format == config.selected) { model.setFrameRate(format.fps) }
                                }
                            }
                        }
                        section("Color profile", detail: "Profiles supported by GradeLab and this camera") {
                            VStack(spacing: 10) {
                                ForEach(CameraProfile.allCases) { profile in
                                    let available = config.formats.contains { $0.profile == profile }
                                    Button { model.setProfile(profile) } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(profile.title).font(AppTypography.bodyEmphasized)
                                                Text(available ? profile.detail : String(localized: "Not supported by this lens or device."))
                                                    .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer(minLength: 4)
                                            Image(systemName: !available ? "minus.circle" : config.selected.profile == profile ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(config.selected.profile == profile ? AppColors.accent : AppColors.textTertiary)
                                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                                    }.buttonStyle(.plain).disabled(!available || !model.canConfigure)
                                }
                            }
                        }
                        section("Codec", detail: "Available encoders for the selected format") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                                ForEach(CameraCodec.allCases) { codec in
                                    choice(codec.title, selected: config.codec == codec, available: config.codecs.contains(codec)) { model.reconfigure(codec: codec) }
                                }
                            }
                            Text("Dimmed codecs are unavailable for this camera and format. ProRes uses substantially more storage.")
                                .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        section("Recording quality", detail: "Higher bit rates preserve more detail and use more storage") {
                            if config.codec.isProRes {
                                Text("ProRes quality is determined by the selected codec variant.")
                                    .font(AppTypography.callout).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                                    ForEach(CameraRecordingQuality.allCases) { quality in
                                        Button { model.reconfigure(quality: quality) } label: {
                                            VStack(spacing: 4) {
                                                Text(quality.title).font(AppTypography.callout)
                                                Text("\(Double(quality.bitRate(format: config.selected, codec: config.codec)) / 1_000_000, specifier: "%.0f") Mbps")
                                                    .font(AppTypography.caption).monospacedDigit()
                                            }.frame(maxWidth: .infinity, minHeight: 62)
                                                .foregroundStyle(config.quality == quality ? AppColors.accent : AppColors.textPrimary)
                                                .background(config.quality == quality ? AppColors.accentMuted : AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(config.quality == quality ? AppColors.accent.opacity(0.7) : AppColors.border, lineWidth: 1))
                                        }.buttonStyle(.plain).disabled(!model.canConfigure)
                                            .accessibilityAddTraits(config.quality == quality ? .isSelected : [])
                                    }
                                }
                                Text("Target bit rate is approximate. Actual file size varies with the scene.")
                                    .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Toggle(isOn: Binding(get: { config.stabilizationEnabled }, set: { model.reconfigure(stabilization: $0) })) {
                            Label("Stabilization", systemImage: "hand.raised")
                        }
                        .disabled(!config.stabilizationAvailable || !model.canConfigure)
                        .tint(AppColors.accent).padding(16).cameraGlass()
                        Text("Format choices follow the selected lens. Guides, scopes and preview looks never change the original recording.")
                            .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
                    } else { ProgressView("Preparing camera formats…") }
                }.padding(20)
            }
            .scrollIndicators(.visible)
            .background(AppColors.background)
            .navigationTitle("Recording format").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .foregroundStyle(AppColors.textPrimary).preferredColorScheme(.dark)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppTypography.headline)
                Text(detail).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
            }
            content()
        }
    }

    private func choice(_ title: String, selected: Bool, available: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(AppTypography.callout).monospacedDigit()
                .multilineTextAlignment(.center).padding(.horizontal, 6)
                .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(selected ? AppColors.accentMuted : AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AppColors.accent.opacity(0.7) : AppColors.border, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!model.canConfigure || !available).opacity(available ? 1 : 0.4)
            .accessibilityHint(available ? "" : String(localized: "Not supported by this lens or device."))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
