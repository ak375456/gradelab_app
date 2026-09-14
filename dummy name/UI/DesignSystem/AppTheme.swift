//
//  AppTheme.swift
//  GradeLab
//
//  A small, semantic design language for GradeLab's dark editing interface.
//

import SwiftUI

enum AppColors {
    /// The deepest app background. Near-black rather than absolute black preserves surface depth.
    static let background = Color(red: 0.035, green: 0.039, blue: 0.047)
    static let editorBackground = Color(red: 0.020, green: 0.023, blue: 0.029)

    static let surface = Color(red: 0.070, green: 0.078, blue: 0.090)
    static let surfaceRaised = Color(red: 0.100, green: 0.110, blue: 0.126)
    static let surfacePressed = Color(red: 0.125, green: 0.137, blue: 0.156)

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.66)
    static let textTertiary = Color.white.opacity(0.48)
    static let textDisabled = Color.white.opacity(0.30)

    /// GradeLab's single brand accent. Other hues below communicate state only.
    static let accent = Color(red: 0.31, green: 0.69, blue: 0.96)
    static let accentMuted = Color(red: 0.31, green: 0.69, blue: 0.96).opacity(0.16)

    static let separator = Color.white.opacity(0.10)
    static let border = Color.white.opacity(0.13)
    static let controlTrack = Color.white.opacity(0.15)

    static let positive = Color(red: 0.31, green: 0.78, blue: 0.55)
    static let warning = Color(red: 0.94, green: 0.68, blue: 0.28)
    static let destructive = Color(red: 0.78, green: 0.22, blue: 0.26)
}

enum AppTypography {
    static let display = Font.system(.largeTitle, design: .default, weight: .bold)
    static let title = Font.system(.title2, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default, weight: .regular)
    static let bodyEmphasized = Font.system(.body, design: .default, weight: .medium)
    static let callout = Font.system(.callout, design: .default, weight: .regular)
    static let secondary = Font.system(.subheadline, design: .default, weight: .regular)
    static let sectionLabel = Font.system(.caption, design: .default, weight: .semibold)
    static let caption = Font.system(.caption, design: .default, weight: .regular)

    /// Monospaced numerals prevent measurement and slider values from visually jumping.
    static let numeric = Font.system(.callout, design: .monospaced, weight: .semibold)
        .monospacedDigit()
    static let metadataValue = Font.system(.subheadline, design: .monospaced, weight: .medium)
        .monospacedDigit()
}

enum AppSpacing {
    static let hairline: CGFloat = 1
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let compact: CGFloat = 12
    static let standard: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
    static let xxLarge: CGFloat = 48
}

enum AppCornerRadius {
    static let small: CGFloat = 6
    static let control: CGFloat = 10
    static let card: CGFloat = 14
    static let prominent: CGFloat = 18
}

struct AppDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(AppColors.separator)
            .frame(height: AppSpacing.hairline)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

private struct AppSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color
    let border: Color

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: AppSpacing.hairline)
            }
    }
}

extension View {
    func appSurface(
        cornerRadius: CGFloat = AppCornerRadius.card,
        fill: Color = AppColors.surface,
        border: Color = AppColors.border
    ) -> some View {
        modifier(AppSurfaceModifier(cornerRadius: cornerRadius, fill: fill, border: border))
    }
}
