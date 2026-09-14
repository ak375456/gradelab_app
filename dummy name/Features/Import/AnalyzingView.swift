import SwiftUI

struct AnalyzingView: View {
    let fileName: String?

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            VStack(spacing: AppSpacing.large) {
                ZStack {
                    Circle().stroke(AppColors.border, lineWidth: 1).frame(width: 78, height: 78)
                    ProgressView().controlSize(.large).tint(AppColors.accent)
                }
                VStack(spacing: AppSpacing.small) {
                    Text("Analyzing Video…").font(AppTypography.title).foregroundStyle(AppColors.textPrimary)
                    if let fileName {
                        Text(fileName).font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                    }
                    Text("Reading format, timing, and color metadata")
                        .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
                }
            }
            .padding(AppSpacing.xLarge)
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing video")
    }
}
