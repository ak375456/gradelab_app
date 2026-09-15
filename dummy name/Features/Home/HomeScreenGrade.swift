//
//  HomeScreenGrade.swift
//  GradeLab
//
//  The one grade in the app that GradeLab applies to itself.
//

import SwiftUI
import UIKit

// MARK: - The grade

/// A grade the home screen applies to its own colours.
///
/// It stops at the home screen deliberately. Chrome around a picture has to stay
/// neutral — a tinted panel beside a clip is a lie about the clip — so the
/// editor, the viewer and every export keep the shipped palette no matter what
/// is set here. The home screen is the one surface in GradeLab with no footage
/// on it, which makes it the one surface that is safe to play with.
///
/// Neutral is the shipped palette exactly: every axis rests at 0, which is also
/// the detent `AdjustmentSlider` snaps to, so a double-tap on any slider puts
/// that axis back to stock.
struct HomeScreenGrade: Equatable {
    /// Degrees the accent hue is rotated around the wheel.
    var hue: Float = 0
    /// Percent toward grey (negative) or toward full saturation (positive).
    var vibrance: Float = 0
    /// Percent the surfaces are lifted off black. Lifting also washes them with
    /// the accent hue, the way a lit wall behind a monitor would.
    var lift: Float = 0

    static let neutral = HomeScreenGrade()

    static let hueRange: ClosedRange<Float> = -180...180
    static let vibranceRange: ClosedRange<Float> = -100...100
    static let liftRange: ClosedRange<Float> = -100...100

    var isNeutral: Bool { self == .neutral }

    // MARK: Derived palette

    var accent: Color {
        var components = BaseColor.accent
        components.hue = ColorComponents.wrap(components.hue + CGFloat(hue) / 360)
        components.saturation = Self.stretch(components.saturation, by: CGFloat(vibrance) / 100)
        return components.color
    }

    var accentMuted: Color { accent.opacity(0.16) }
    var background: Color { lifted(BaseColor.background) }
    var surface: Color { lifted(BaseColor.surface) }
    var surfaceRaised: Color { lifted(BaseColor.surfaceRaised) }

    /// What `.saturation()` would have to be multiplied by to reach this grade's
    /// accent, for the rare place that filters a subtree instead of colouring it.
    var accentSaturationScale: Double {
        guard BaseColor.accent.saturation > 0 else { return 1 }
        return Double(Self.stretch(BaseColor.accent.saturation, by: CGFloat(vibrance) / 100)
                      / BaseColor.accent.saturation)
    }

    /// Lift raises a surface off black. Only lifting upward carries hue with it:
    /// a colourist pulling *down* is crushing to black, and a black that drifts
    /// blue as it deepens would be the opposite of what they asked for.
    private func lifted(_ base: ColorComponents) -> Color {
        var components = base
        let amount = CGFloat(lift) / 100
        components.brightness = min(max(components.brightness + amount * 0.030, 0), 1)

        if amount > 0 {
            components.hue = ColorComponents.wrap(BaseColor.accent.hue + CGFloat(hue) / 360)
            components.saturation = min(components.saturation + amount * 0.45, 1)
        }

        return components.color
    }

    /// Pushes a saturation toward grey or toward full, rather than scaling it, so
    /// that −100% is genuinely colourless instead of "a bit less blue".
    private static func stretch(_ saturation: CGFloat, by amount: CGFloat) -> CGFloat {
        amount >= 0
            ? saturation + (1 - saturation) * amount
            : saturation * (1 + amount)
    }

    // MARK: The mark's handles

    /// Where each handle sits along its track, 0...1, for `GradeLabMark`.
    ///
    /// Rest is the artwork, not the middle of the track. The three handles were
    /// drawn off-centre and each at a different place, and that asymmetry is what
    /// makes the thing a mark rather than a sliders icon — so each axis travels
    /// out from where its dot has always been drawn and returns there at neutral.
    var handlePositions: [CGFloat] {
        [Self.handlePosition(hue, extent: Self.hueRange.upperBound, rest: 0.25),
         Self.handlePosition(vibrance, extent: Self.vibranceRange.upperBound, rest: 0.78),
         Self.handlePosition(lift, extent: Self.liftRange.upperBound, rest: 0.44)]
    }

    private static func handlePosition(_ value: Float, extent: Float, rest: CGFloat) -> CGFloat {
        let travel = min(rest, 1 - rest)
        return rest + CGFloat(value / extent) * travel
    }

    // MARK: Persistence

    // Written when the panel closes, not on every drag event. The sliders report
    // continuously so the screen can re-grade under the finger, and pushing that
    // through UserDefaults sixty times a second would be paying to store a
    // setting nobody has finished choosing yet.
    private enum Key {
        static let hue = "home.screenGrade.hue"
        static let vibrance = "home.screenGrade.vibrance"
        static let lift = "home.screenGrade.lift"
    }

    static func restored(from defaults: UserDefaults = .standard) -> HomeScreenGrade {
        HomeScreenGrade(
            hue: clamped(defaults.double(forKey: Key.hue), to: hueRange),
            vibrance: clamped(defaults.double(forKey: Key.vibrance), to: vibranceRange),
            lift: clamped(defaults.double(forKey: Key.lift), to: liftRange)
        )
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(Double(hue), forKey: Key.hue)
        defaults.set(Double(vibrance), forKey: Key.vibrance)
        defaults.set(Double(lift), forKey: Key.lift)
    }

    /// A missing key reads as 0, which is neutral, so a first launch needs no
    /// special case. Anything absurd on disk is pulled back into range.
    private static func clamped(_ value: Double, to range: ClosedRange<Float>) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(Float(value), range.lowerBound), range.upperBound)
    }
}

// MARK: - Colour components

/// A colour taken apart so a grade can move one component and put it back.
private struct ColorComponents {
    var hue: CGFloat
    var saturation: CGFloat
    var brightness: CGFloat
    var alpha: CGFloat

    init(_ color: Color) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 1
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.alpha = alpha
    }

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness, opacity: alpha)
    }

    /// `Color(hue:)` clamps rather than wraps, so a rotation past either end has
    /// to come back round before it is handed over.
    static func wrap(_ hue: CGFloat) -> CGFloat {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }
}

/// The palette pulled apart once at launch. Taking a `UIColor` to pieces is not
/// expensive, but the grade is recomputed for every view on the screen on every
/// frame of a drag, and these four inputs never change.
private enum BaseColor {
    static let accent = ColorComponents(AppColors.accent)
    static let background = ColorComponents(AppColors.background)
    static let surface = ColorComponents(AppColors.surface)
    static let surfaceRaised = ColorComponents(AppColors.surfaceRaised)
}

// MARK: - Environment

private struct HomeScreenGradeKey: EnvironmentKey {
    static let defaultValue = HomeScreenGrade.neutral
}

extension EnvironmentValues {
    /// The home screen's grade of itself. Neutral — the shipped palette —
    /// everywhere else in the app, and nothing outside Home reads it.
    var homeScreenGrade: HomeScreenGrade {
        get { self[HomeScreenGradeKey.self] }
        set { self[HomeScreenGradeKey.self] = newValue }
    }
}
