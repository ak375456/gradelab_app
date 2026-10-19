import SwiftUI
import UIKit

/// Small semantic accents identify grading tools while the picture and its
/// surround stay neutral. These are navigation cues, never grade values.
struct GradingToolAppearance {
    let symbol: String
    let tint: Color

    /// Native menus otherwise turn every SF Symbol into the same template tint.
    var menuIcon: Image {
        guard let image = UIImage(systemName: symbol) else { return Image(systemName: symbol) }
        return Image(uiImage: image.withTintColor(UIColor(tint), renderingMode: .alwaysOriginal))
    }
}

private enum GradingToolPalette {
    static let gold = AppColors.warning
    static let blue = AppColors.accent
    static let mint = AppColors.positive
    static let violet = Color(red: 0.73, green: 0.61, blue: 1)
    static let rose = Color(red: 1, green: 0.55, blue: 0.71)
    static let cyan = Color(red: 0.40, green: 0.83, blue: 0.90)
}

extension GradeParameter {
    var compactAppearance: GradingToolAppearance {
        switch self {
        case .exposure: .init(symbol: "plusminus.circle", tint: GradingToolPalette.gold)
        case .contrast: .init(symbol: "circle.lefthalf.filled", tint: GradingToolPalette.violet)
        case .highlights: .init(symbol: "sun.max", tint: GradingToolPalette.gold)
        case .shadows: .init(symbol: "moon", tint: GradingToolPalette.blue)
        case .whites: .init(symbol: "circle", tint: .white)
        case .blacks: .init(symbol: "circle.fill", tint: GradingToolPalette.violet)
        case .temperature: .init(symbol: "thermometer.medium", tint: GradingToolPalette.gold)
        case .tint: .init(symbol: "eyedropper", tint: GradingToolPalette.rose)
        case .saturation: .init(symbol: "drop.fill", tint: GradingToolPalette.cyan)
        case .vibrance: .init(symbol: "sparkles", tint: GradingToolPalette.mint)
        }
    }
}

extension GradePanel {
    var compactAppearance: GradingToolAppearance {
        let tint: Color
        switch self {
        case .light, .relight: tint = GradingToolPalette.gold
        case .color, .wheels, .hsl: tint = GradingToolPalette.rose
        case .curves, .warper: tint = GradingToolPalette.violet
        case .noise, .match: tint = GradingToolPalette.cyan
        case .masks, .mask: tint = GradingToolPalette.blue
        case .vignette, .effects, .lut: tint = GradingToolPalette.mint
        }
        return .init(symbol: symbol, tint: tint)
    }
}
