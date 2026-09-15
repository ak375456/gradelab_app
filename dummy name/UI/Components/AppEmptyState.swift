//
//  AppEmptyState.swift
//  GradeLab
//

import SwiftUI

struct AppEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String
    /// The brand accent unless a screen is wearing a grade of its own.
    var tint: Color = AppColors.accent
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: AppSpacing.standard) {
            Image(systemName: systemImage)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 58, height: 58)
                .background(tint.opacity(0.16), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(tint.opacity(0.20), lineWidth: AppSpacing.hairline)
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
