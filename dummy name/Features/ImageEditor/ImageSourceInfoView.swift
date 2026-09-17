import SwiftUI

/// What the imported file actually is. Every value is read from the file by
/// `ImageMetadataReader`; nothing here is inferred from the extension, and
/// anything the file does not declare is shown as unknown rather than guessed.
struct ImageSourceInfoView: View {
    let project: ImageProject
    @Environment(\.dismiss) private var dismiss

    private var metadata: ImageMetadata { project.metadata }
    private var support: ImageColorSupport { project.colorSupport }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    hero
                    MetadataCard("Image") {
                        MetadataRow(label: "Dimensions", value: metadata.resolutionLabel,
                                    detail: metadata.megapixelLabel)
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Format", value: metadata.formatLabel,
                                    detail: metadata.typeIdentifier)
                        if let size = metadata.fileSizeLabel {
                            AppDivider(inset: AppSpacing.standard)
                            MetadataRow(label: "File size", value: size)
                        }
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Orientation", value: metadata.orientationLabel,
                                    detail: "EXIF \(metadata.orientation)")
                        if let dpi = metadata.dpi, dpi > 0 {
                            AppDivider(inset: AppSpacing.standard)
                            MetadataRow(label: "Resolution", value: String(format: "%.0f DPI", locale: .current, dpi))
                        }
                        if let created = metadata.creationDate {
                            AppDivider(inset: AppSpacing.standard)
                            MetadataRow(label: "Captured", value: created.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    MetadataCard("Color") {
                        MetadataRow(label: "Profile",
                                    value: metadata.colorProfileName ?? (metadata.hasEmbeddedProfile ? "Embedded" : "Untagged"),
                                    detail: metadata.hasEmbeddedProfile ? "ICC profile embedded" : "Interpreted as sRGB")
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Bit depth",
                                    value: metadata.bitsPerComponent.map { "\($0)-bit" } ?? "Unknown")
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Color model", value: metadata.colorModel ?? "Unknown")
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Alpha", value: metadata.hasAlpha ? "Present" : "None",
                                    detail: metadata.hasAlpha ? "Flattened onto black for grading" : nil)
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "HDR gain map",
                                    value: metadata.hasHDRGainMap ? "Present" : "None",
                                    detail: metadata.hasHDRGainMap
                                        ? "The SDR picture is graded; the map is not exported"
                                        : nil)
                        AppDivider(inset: AppSpacing.standard)
                        MetadataRow(label: "Working space", value: "Rec.709",
                                    detail: "The space GradeLab grades and exports in")
                    }
                    if let notice = support.notice {
                        VStack(alignment: .leading, spacing: AppSpacing.small) {
                            AppSectionHeader("Color pipeline")
                            Text(notice)
                                .font(AppTypography.callout)
                                .foregroundStyle(AppColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(AppSpacing.standard)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .appSurface()
                        }
                    }
                }
                .padding(AppSpacing.standard)
            }
            .scrollIndicators(.hidden)
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle("Image Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            HStack(alignment: .firstTextBaseline) {
                Text(metadata.resolutionLabel)
                    .font(.system(.title, design: .monospaced, weight: .semibold))
                Spacer()
                AppBadge(title: LocalizedStringKey(metadata.megapixelLabel), tone: .accent)
            }
            HStack(spacing: AppSpacing.small) {
                AppBadge(title: LocalizedStringKey(metadata.formatLabel))
                if let depth = metadata.bitsPerComponent {
                    AppBadge(title: LocalizedStringKey("\(depth)-bit"))
                }
                if metadata.isWideGamut { AppBadge(title: "Wide gamut", tone: .warning) }
                if metadata.hasHDRGainMap { AppBadge(title: "Gain map") }
            }
            Text(project.displayName).font(AppTypography.secondary)
                .foregroundStyle(AppColors.textSecondary).lineLimit(2)
        }
        .padding(AppSpacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(fill: AppColors.surface)
    }
}
