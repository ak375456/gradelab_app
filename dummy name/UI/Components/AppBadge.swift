//
//  AppBadge.swift
//  GradeLab
//

import SwiftUI

struct AppBadge: View {
    enum Tone {
        case neutral
        case accent
        case positive
        case warning
    }

    let title: LocalizedStringKey
    var systemImage: String?
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }

            Text(title)
        }
        .font(AppTypography.sectionLabel)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, 5)
        .background(backgroundColor, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(foregroundColor.opacity(0.24), lineWidth: AppSpacing.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    private var foregroundColor: Color {
        switch tone {
        case .neutral:
            return AppColors.textSecondary
        case .accent:
            return AppColors.accent
        case .positive:
            return AppColors.positive
        case .warning:
            return AppColors.warning
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .neutral:
            return AppColors.surfaceRaised
        case .accent:
            return AppColors.accentMuted
        case .positive:
            return AppColors.positive.opacity(0.14)
        case .warning:
            return AppColors.warning.opacity(0.14)
        }
    }
}
