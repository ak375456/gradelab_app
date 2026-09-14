//
//  LoopingVideoPlayer.swift
//  GradeLab
//
//  The seamless, silent loop behind each onboarding page.
//

import AVFoundation
import Combine
import SwiftUI

/// Resolves the bundle carrying the onboarding clips. Same reasoning as
/// `Bundle.lutResources`: under XCTest `Bundle.main` is the test runner, so the
/// lookup has to go through a type that lives in the app itself.
private final class OnboardingBundleToken {}

/// One clip, looping forever, with a single play/pause control.
///
/// `AVPlayerLooper` rather than a seek on `didPlayToEndTime`: the looper keeps
/// the next cycle enqueued, so the clip repeats without the black frame a seek
/// leaves behind. On a screen whose entire job is to look good, that gap reads
/// as a bug.
@MainActor
final class LoopingVideoPlayer: ObservableObject {
    /// Whether the clip is actually running — drives the control's icon.
    @Published private(set) var isPlaying = false

    let player = AVQueuePlayer()

    /// True while this page is the one on screen. Off-screen pages are paused
    /// rather than torn down, so returning to one resumes instantly.
    private var isOnScreen = false
    /// Set only by the play/pause control. Kept apart from `isOnScreen` so that
    /// swiping away and back does not silently undo a deliberate pause.
    private var isPausedByUser = false
    private var looper: AVPlayerLooper?

    init(resourceName: String) {
        guard let url = Bundle(for: OnboardingBundleToken.self)
            .url(forResource: resourceName, withExtension: "mp4") else {
            #if DEBUG
            print("Onboarding clip missing from the bundle: \(resourceName).mp4")
            #endif
            return
        }
        // The clips carry no audio track at all, but muting is also what keeps
        // the shared audio session untouched — onboarding must never interrupt
        // whatever the user is already listening to.
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func appeared() {
        isOnScreen = true
        apply()
    }

    func disappeared() {
        isOnScreen = false
        apply()
    }

    func togglePlayPause() {
        isPausedByUser.toggle()
        apply()
    }

    /// Suppresses autoplay before the first frame is ever shown — used for
    /// Reduce Motion, where a clip that starts moving on its own is the thing
    /// the setting exists to prevent.
    func suppressAutoplay() {
        isPausedByUser = true
        apply()
    }

    private func apply() {
        let shouldPlay = isOnScreen && !isPausedByUser
        if shouldPlay {
            player.play()
        } else {
            player.pause()
        }
        isPlaying = shouldPlay
    }
}

/// A plain `AVPlayerLayer` host. `VideoPlayer` from AVKit is not used here
/// because it brings its own transport controls, and the only control this
/// screen offers is play/pause.
struct LoopingVideoSurface: UIViewRepresentable {
    let player: AVQueuePlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    final class PlayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
