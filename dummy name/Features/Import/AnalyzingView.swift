import SwiftUI

struct AnalyzingView: View {
    /// What is being analysed.
    ///
    /// The screen is shared by both import paths, and the two genuinely do
    /// different work: a video is read for format, timing and colour, a
    /// photograph has no timing to read. Saying "video" over a still was not
    /// just the wrong noun — it described work that was not happening.
    enum Media {
        case video
        case image

        var title: LocalizedStringKey {
            switch self {
            case .video: "Analyzing Video…"
            case .image: "Analyzing Photo…"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .video: "Reading format, timing, and color metadata"
            case .image: "Reading format and color metadata"
            }
        }

        var accessibilityLabel: LocalizedStringKey {
            switch self {
            case .video: "Analyzing video"
            case .image: "Analyzing photo"
            }
        }
    }

    let fileName: String?
    var media: Media = .video

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            VStack(spacing: AppSpacing.large) {
                ZStack {
                    Circle().stroke(AppColors.border, lineWidth: 1).frame(width: 78, height: 78)
                    ProgressView().controlSize(.large).tint(AppColors.accent)
                }
                VStack(spacing: AppSpacing.small) {
                    Text(media.title).font(AppTypography.title).foregroundStyle(AppColors.textPrimary)
                    if let fileName {
                        Text(fileName).font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                    }
                    Text(media.detail)
                        .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(AppSpacing.xLarge)
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(media.accessibilityLabel)
    }
}
