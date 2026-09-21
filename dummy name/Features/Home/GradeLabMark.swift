//
//  GradeLabMark.swift
//  GradeLab
//
//  The app's mark, which is also the control that grades the home screen.
//

import SwiftUI

/// GradeLab's mark: three grading tracks, each with its handle resting at a
/// different point along it.
///
/// The mark used to be inert artwork wearing the app's own button chrome — a
/// 52pt raised tile with a hairline border, the same recipe as the Import Photo
/// button — so testers pressed it and got nothing back. Taking the promise away
/// was one answer; keeping it is the better one. Tapping the mark now opens
/// `ScreenGradePanel`, and the three handles show where that grade stands, so
/// the logo reads as a live miniature of the thing the app does.
///
/// A control nobody can find is not a control, so until the panel has been
/// opened once — ever, across launches — the mark glows and throws its handles
/// out and back one time, which says "these move" in a way a static icon cannot.
struct GradeLabMark: View {
    let grade: HomeScreenGrade
    let isOpen: Bool
    let isInviting: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var sweep: CGFloat = 0

    /// How far each handle is thrown during the one-shot demonstration, and
    /// which way. Different per track, so it reads as three controls moving
    /// rather than one object sliding.
    private static let demonstration: [CGFloat] = [0.26, -0.20, 0.30]

    private static let artworkWidth: CGFloat = 32
    private static let artworkHeight: CGFloat = 35

    var body: some View {
        Button(action: action) {
            ZStack {
                halo
                tracks
            }
            // The artwork stays small so it reads as a mark; the target around
            // it is square and well past the 44pt minimum, because the thing
            // being tapped is a 32pt drawing sitting next to a screen edge.
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(MarkPressStyle())
        .accessibilityLabel("Screen grade")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tints this screen only. Opens the hue, vibrance and lift controls.")
        .task(id: isInviting) { await invite() }
    }

    private var tracks: some View {
        VStack(spacing: 7) {
            ForEach(Array(grade.handlePositions.enumerated()), id: \.offset) { index, position in
                MarkTrack(
                    handle: position + sweep * Self.demonstration[index],
                    tint: grade.accent,
                    rail: isOpen ? AppColors.textSecondary : AppColors.textTertiary
                )
            }
        }
        .frame(width: Self.artworkWidth, height: Self.artworkHeight)
    }

    /// The invitation to tap, and nothing else: it is gone for good once the
    /// panel has been opened, so a returning user is not nagged by their own
    /// app forever.
    @ViewBuilder
    private var halo: some View {
        if isInviting {
            Circle()
                .fill(grade.accent)
                .frame(width: 30, height: 30)
                .blur(radius: 12)
                .opacity(breathing ? 0.45 : 0.12)
                .scaleEffect(breathing ? 1.3 : 0.82)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: breathing
                )
                .accessibilityHidden(true)
        }
    }

    private func invite() async {
        guard isInviting else {
            breathing = false
            sweep = 0
            return
        }

        // With Reduce Motion on this settles immediately into a steady glow:
        // still visible, never moving.
        breathing = true
        guard !reduceMotion else { return }

        // A beat first. The sweep is meant to catch an eye that has already
        // landed on the screen, not to be over before the screen is read.
        try? await Task.sleep(for: .seconds(0.7))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.66)) { sweep = 1 }
        try? await Task.sleep(for: .seconds(0.75))
        withAnimation(.spring(response: 0.62, dampingFraction: 0.85)) { sweep = 0 }
    }

    private var accessibilityValue: String {
        guard !grade.isNeutral else { return String(localized: "Neutral") }
        return String(localized: """
            Hue \(Int(grade.hue.rounded())) degrees, \
            vibrance \(Int(grade.vibrance.rounded())) percent, \
            lift \(Int(grade.lift.rounded())) percent
            """)
    }
}

/// One track of the mark: a rail, and a handle somewhere along it.
private struct MarkTrack: View {
    /// 0 is the left end of the rail, 1 the right.
    let handle: CGFloat
    let tint: Color
    let rail: Color

    private static let handleDiameter: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.width - Self.handleDiameter, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(rail)
                    .frame(height: 1.5)

                Circle()
                    .fill(tint)
                    .frame(width: Self.handleDiameter, height: Self.handleDiameter)
                    .offset(x: travel * min(max(handle, 0), 1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The mark answers a touch by shrinking under it. Without this it is the only
/// button on the screen that does not move when pressed, which is how it earned
/// its reputation for being decorative in the first place.
private struct MarkPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7),
                             trigger: configuration.isPressed) { _, isPressed in isPressed }
    }
}
