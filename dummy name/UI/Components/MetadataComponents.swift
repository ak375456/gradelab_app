//
//  MetadataComponents.swift
//  GradeLab
//

import SwiftUI

struct MetadataRow: View {
    let label: LocalizedStringKey
    let value: String
    var detail: String?
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.compact) {
            HStack(spacing: AppSpacing.small) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }

                Text(label)
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer(minLength: AppSpacing.standard)

            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(AppTypography.metadataValue)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.trailing)

                if let detail {
                    Text(detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.vertical, AppSpacing.compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        guard let detail else { return value }
        return "\(value), \(detail)"
    }
}

struct MetadataCard<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: LocalizedStringKey? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: AppSpacing.small) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(AppColors.accent)
                            .accessibilityHidden(true)
                    }

                    Text(title)
                        .font(AppTypography.headline)
                        .foregroundStyle(AppColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(AppSpacing.standard)

                AppDivider()
            }

            content()
        }
        .appSurface()
    }
}

struct MetadataValueCard: View {
    let label: LocalizedStringKey
    let value: String
    var supportingValue: String?
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.small) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.accent)
                        .accessibilityHidden(true)
                }

                Text(label)
                    .font(AppTypography.sectionLabel)
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)
            }

            Text(value)
                .font(AppTypography.numeric)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let supportingValue {
                Text(supportingValue)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.standard)
        .appSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        guard let supportingValue else { return value }
        return "\(value), \(supportingValue)"
    }
}
