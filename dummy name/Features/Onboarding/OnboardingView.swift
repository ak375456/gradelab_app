//
//  OnboardingView.swift
//  GradeLab
//
//  Three screens shown once, on first launch.
//

import Combine
import SwiftUI

/// One onboarding page: a clip, the two lines that frame it, and the light it
/// throws onto the screen behind it.
struct OnboardingPage: Identifiable {
    let id: Int
    let resourceName: String
    /// Declared rather than read from the asset. Reading it is asynchronous, and
    /// a video box that resizes after the page has already appeared is worse
    /// than a number that has to be updated when a clip is replaced.
    let aspectRatio: CGFloat
    let eyebrow: String
    let title: String
    let message: String
    let actionTitle: LocalizedStringKey
    /// The ambient wash behind the clip, drawn from the clip itself. It is the
    /// grade restated at the size of the whole screen: page one is lit by a
    /// dead slate grey, page two by the blue its sky was given back.
    let glow: Color
    let glowStrength: Double

    static let all: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            resourceName: "onboarding-1-before",
            aspectRatio: 864.0 / 1080.0,
            // "BEFORE" is doing work beyond labelling: it promises an after,
            // which is the whole reason anyone reaches the second page.
            eyebrow: "BEFORE",
            title: "Straight out of the camera",
            message: "Flat sky, dull greens, no depth.",
            actionTitle: "Next",
            glow: Color(red: 0.42, green: 0.46, blue: 0.52),
            glowStrength: 0.14
        ),
        OnboardingPage(
            id: 1,
            resourceName: "onboarding-2-after",
            aspectRatio: 864.0 / 1080.0,
            eyebrow: "AFTER",
            title: "The same clip, graded",
            message: "Nothing reshot, nothing replaced. Only the color changed.",
            actionTitle: "Next",
            glow: Color(red: 0.24, green: 0.62, blue: 0.92),
            // Deliberately the strongest of the three. The room brightening as
            // the page turns is the grade arriving a moment before the clip does.
            glowStrength: 0.30
        ),
        OnboardingPage(
            id: 2,
            resourceName: "onboarding-3-gradelab",
            aspectRatio: 720.0 / 1454.0,
            eyebrow: "IN GRADELAB",
            title: "Now do it to yours",
            message: "Looks, curves, wheels and LUTs on your own footage. Then export.",
            actionTitle: "Start Grading",
            glow: AppColors.accent,
            glowStrength: 0.20
        )
    ]
}

/// Owns one player per page for the life of the flow.
///
/// Built once, up front, rather than per page appearance: three short clips are
/// cheap to hold, and pre-warming them is what makes a swipe land on a moving
/// picture instead of a black box.
@MainActor
final class OnboardingPlayback: ObservableObject {
    let players: [LoopingVideoPlayer]

    init(pages: [OnboardingPage]) {
        players = pages.map { LoopingVideoPlayer(resourceName: $0.resourceName) }
    }

    /// Exactly one page plays at a time.
    func showPage(_ index: Int) {
        for (position, player) in players.enumerated() {
            if position == index {
                player.appeared()
            } else {
                player.disappeared()
            }
        }
    }

    func pauseAll() {
        players.forEach { $0.disappeared() }
    }

    func suppressAutoplay() {
        players.forEach { $0.suppressAutoplay() }
    }
}

struct OnboardingView: View {
    /// Called when the flow is finished or skipped. Both paths are the same
    /// outcome — the user is done with it and should not see it again.
    let onFinish: () -> Void

    private let pages = OnboardingPage.all
    @StateObject private var playback = OnboardingPlayback(pages: OnboardingPage.all)
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Corner radius for the clip. Larger than `AppCornerRadius.prominent`,
    /// which is sized for controls; this is a picture, and the softer corner is
    /// what stops it reading as one more panel in a dark interface.
    private let clipCornerRadius: CGFloat = 26

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()
            ambientGlow
            content
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if reduceMotion { playback.suppressAutoplay() }
            playback.showPage(index)
        }
        .onChange(of: index) { _, newValue in
            playback.showPage(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            // Playing a clip nobody can see drains battery and, on a locked
            // device, keeps the decoder awake for nothing.
            if phase == .active {
                playback.showPage(index)
            } else {
                playback.pauseAll()
            }
        }
    }

    /// All three washes are drawn at once and cross-faded by opacity.
    ///
    /// A single gradient whose colour is swapped would jump: SwiftUI cannot
    /// interpolate a `RadialGradient`'s stops, so the change would land in one
    /// frame at exactly the moment the page is already moving.
    private var ambientGlow: some View {
        ZStack {
            ForEach(pages) { page in
                RadialGradient(
                    colors: [page.glow.opacity(page.glowStrength), .clear],
                    center: .init(x: 0.5, y: 0.56),
                    startRadius: 0,
                    endRadius: 460
                )
                .opacity(page.id == index ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.55), value: index)
        .accessibilityHidden(true)
    }

    private var content: some View {
        VStack(spacing: 0) {
            skipBar
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { position, page in
                    pageBody(page, player: playback.players[position])
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
    }

    private var skipBar: some View {
        HStack {
            Spacer()
            Button(action: onFinish) {
                Text("Skip")
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.horizontal, AppSpacing.compact)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Goes straight to GradeLab")
        }
        .padding(.horizontal, AppSpacing.compact)
    }

    private func pageBody(_ page: OnboardingPage, player: LoopingVideoPlayer) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            // The text is on screen from the first frame rather than fading in
            // behind the clip: someone who swipes straight past should still
            // have been told what they were looking at.
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(page.eyebrow)
                    .font(AppTypography.sectionLabel)
                    .tracking(1.4)
                    .foregroundStyle(AppColors.accent)
                Text(page.title)
                    .font(AppTypography.display)
                    .foregroundStyle(AppColors.textPrimary)
                Text(page.message)
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Tall enough for the longest page's copy at the default text size.
            // Without it the clip lands a few points lower on the pages whose
            // text wraps further — and pages one and two are a before and an
            // after, so a frame that shifts between them reads as a second
            // change alongside the grade. A floor rather than a fixed height,
            // so larger accessibility sizes push down instead of clipping.
            .frame(minHeight: 196, alignment: .top)

            videoBox(page, player: player)
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.bottom, AppSpacing.standard)
    }

    private func videoBox(_ page: OnboardingPage, player: LoopingVideoPlayer) -> some View {
        // The aspect ratio has to shape the box before the corners, the border
        // and the shadow are applied to it; the expanding frame comes last, and
        // only centres that box in whatever height the page has left. Filling
        // first would draw the border around empty letterbox instead.
        LoopingVideoSurface(player: player.player)
            // Hidden from VoiceOver on its own rather than as part of the box:
            // hiding the box would take the play control with it.
            .accessibilityHidden(true)
            .aspectRatio(page.aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: clipCornerRadius, style: .continuous))
            .overlay {
                // A single hairline, brightest along the top edge, where light
                // would catch a real one.
                RoundedRectangle(cornerRadius: clipCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: AppSpacing.hairline
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                PlayPauseButton(player: player)
                    .padding(AppSpacing.compact)
            }
            // Lifts the picture off the background, which is otherwise almost
            // the same black as the clip's own darkest areas.
            .shadow(color: .black.opacity(0.55), radius: 28, y: 14)
            .shadow(color: page.glow.opacity(0.28), radius: 44, y: 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: AppSpacing.large) {
            pageIndicator
            AppButton(pages[index].actionTitle, expandsHorizontally: true) {
                if index == pages.count - 1 {
                    onFinish()
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) { index += 1 }
                }
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.top, AppSpacing.standard)
        .padding(.bottom, AppSpacing.small)
    }

    /// Drawn rather than left to the `TabView`, which only offers its dots over
    /// the paged content itself. Three of them, visible from the first page, are
    /// what tell someone there is more than this — and the current one stretches
    /// into a bar, so the position reads at a glance rather than by counting.
    private var pageIndicator: some View {
        HStack(spacing: AppSpacing.small) {
            ForEach(pages) { page in
                Capsule()
                    .fill(page.id == index ? AppColors.accent : AppColors.controlTrack)
                    .frame(width: page.id == index ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: index)
        .accessibilityElement()
        .accessibilityLabel("Page \(index + 1) of \(pages.count)")
    }
}

/// The only transport control the flow offers.
///
/// Its own view, and its own `@ObservedObject`, because a player passed into a
/// `@ViewBuilder` method is not observed by the page: the icon would keep
/// whichever state the page happened to be built with and stop matching the
/// clip.
private struct PlayPauseButton: View {
    @ObservedObject var player: LoopingVideoPlayer

    var body: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: AppSpacing.hairline))
                // The control sits on the picture, so it stays quiet until it is
                // wanted; the tap target underneath it is still a full 44pt.
                .opacity(player.isPlaying ? 0.72 : 1)
                .contentShape(Circle())
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: player.isPlaying)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}
