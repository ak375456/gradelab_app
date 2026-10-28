#if !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

struct CameraRecordingChoice: View {
    @ObservedObject var model: CameraViewModel
    let recording: CameraRecording
    let onEdit: () -> Void
    let onContinue: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.standard) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28)).foregroundStyle(AppColors.positive)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Video captured").font(AppTypography.title)
                        Text("Choose a destination")
                            .font(AppTypography.callout).foregroundStyle(AppColors.textSecondary)
                    }
                }
                .padding(.bottom, 4)
                if let warning = model.recordingWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(AppTypography.caption).foregroundStyle(AppColors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                destinationButton("Edit in GradeLab", systemImage: "slider.horizontal.3", kind: .primary, action: onEdit)
                    .disabled(model.isSavingToPhotos)
                    .accessibilityHint("Creates a project with your editable camera look")
                destinationButton(model.isSavingToPhotos ? "Saving to Photos…" : "Save to Photos",
                          systemImage: "photo.on.rectangle", kind: .secondary) {
                    Task { await model.saveCompletedRecordingToPhotos() }
                }
                .disabled(model.isSavingToPhotos)
                .accessibilityHint("Saves the original video at full quality")
                if model.isSavingToPhotos { ProgressView().frame(maxWidth: .infinity).tint(AppColors.accent) }
                if let error = model.photosSaveError {
                    Text(error).font(AppTypography.caption).foregroundStyle(AppColors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.photosAccessDenied {
                        AppButton("Open Settings", systemImage: "gearshape", kind: .quiet) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                Text(recording.grade == .neutral
                     ? String(localized: "Photos saves the original recording at full quality.")
                     : String(localized: "Your look stays editable in GradeLab. Photos saves the original without the preview look."))
                    .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Decide later", action: onContinue)
                    .font(AppTypography.callout).frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.appQuiet)
                    .foregroundStyle(AppColors.textSecondary).disabled(model.isSavingToPhotos)
                    .accessibilityHint("Keeps this take on Home and returns to the camera")
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background.ignoresSafeArea())
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(390), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isSavingToPhotos)
    }

    private func destinationButton(_ title: LocalizedStringKey, systemImage: String,
                                   kind: AppButtonStyle.Kind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }.buttonStyle(AppButtonStyle(kind: kind))
    }
}
#endif
