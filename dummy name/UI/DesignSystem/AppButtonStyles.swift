//
//  AppButtonStyles.swift
//  GradeLab
//

import SwiftUI

struct AppButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case quiet
        case destructive
    }

    var kind: Kind = .primary
    var isCompact = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? AppTypography.callout : AppTypography.bodyEmphasized)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, isCompact ? AppSpacing.compact : AppSpacing.standard)
            .frame(minHeight: isCompact ? 44 : 46)
            .background(backgroundColor(isPressed: configuration.isPressed), in: buttonShape)
            .overlay {
                buttonShape
                    .strokeBorder(borderColor, lineWidth: AppSpacing.hairline)
            }
            .contentShape(buttonShape)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppCornerRadius.control, style: .continuous)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary:
            return AppColors.editorBackground
        case .secondary, .quiet, .destructive:
            return AppColors.textPrimary
        }
    }

    private var borderColor: Color {
        switch kind {
        case .secondary:
            return AppColors.border
        case .primary, .quiet, .destructive:
            return .clear
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch kind {
        case .primary:
            return AppColors.accent.opacity(isPressed ? 0.78 : 1)
        case .secondary:
            return isPressed ? AppColors.surfacePressed : AppColors.surfaceRaised
        case .quiet:
            return isPressed ? AppColors.surfaceRaised : .clear
        case .destructive:
            return AppColors.destructive.opacity(isPressed ? 0.78 : 1)
        }
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static var appPrimary: AppButtonStyle { AppButtonStyle(kind: .primary) }
    static var appSecondary: AppButtonStyle { AppButtonStyle(kind: .secondary) }
    static var appQuiet: AppButtonStyle { AppButtonStyle(kind: .quiet) }
    static var appDestructive: AppButtonStyle { AppButtonStyle(kind: .destructive) }

    static func appCompact(_ kind: AppButtonStyle.Kind = .secondary) -> AppButtonStyle {
        AppButtonStyle(kind: kind, isCompact: true)
    }
}

struct AppButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var kind: AppButtonStyle.Kind = .primary
    var expandsHorizontally = false
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        kind: AppButtonStyle.Kind = .primary,
        expandsHorizontally: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.expandsHorizontally = expandsHorizontally
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: expandsHorizontally ? .infinity : nil)
        }
        .buttonStyle(AppButtonStyle(kind: kind))
    }
}
