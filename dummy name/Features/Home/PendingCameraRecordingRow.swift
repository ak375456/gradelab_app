import SwiftUI

struct PendingCameraRecordingRow: View {
    let recording: CameraRecording
    let originalURL: URL
    var isDeleting = false
    let onOpen: () -> Void
    let onDelete: () -> Void
    @Environment(\.homeScreenGrade) private var grade

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.displayName).font(AppTypography.callout).foregroundStyle(AppColors.textPrimary)
                    Text("Open in editor").font(AppTypography.caption).foregroundStyle(grade.accent)
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShareLink(item: originalURL) {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("Share original recording")
            Button(role: .destructive, action: onDelete) {
                Group {
                    if isDeleting { ProgressView().tint(AppColors.textSecondary) }
                    else { Image(systemName: "trash").foregroundStyle(AppColors.destructive) }
                }.frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Delete recording")
                .accessibilityHint("Asks before removing this recording")
        }
        .disabled(isDeleting)
    }
}
