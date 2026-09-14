//
//  AppEmptyState.swift
//  GradeLab
//

import SwiftUI

struct AppEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: AppSpacing.standard) {
            Image(systemName: systemImage)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(AppColors.accent)
                .frame(width: 58, height: 58)
                .background(AppColors.accentMuted, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(AppColors.accent.opacity(0.20), lineWidth: AppSpacing.hairline)
                }
                .accessibilityHidden(true)

            VStack(spacing: AppSpacing.small) {
                Text(title)
                    .font(AppTypography.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.appSecondary)
                    .padding(.top, AppSpacing.xSmall)
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.xLarge)
    }
}
