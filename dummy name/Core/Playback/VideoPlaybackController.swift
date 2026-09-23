@preconcurrency import AVFoundation
import Combine
import Foundation
import QuartzCore

@MainActor
final class VideoPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var frameUpdateID: UInt = 0
    @Published var isSeeking = false

    let player: AVPlayer
    let frameProvider: VideoFrameProvider

    private let output: AVPlayerItemVideoOutput
    private var periodicTimeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var statusObservation: AnyCancellable?
    private var wasPlayingBeforeInterruption = false
    private var wantsPlayback = false
    private var pendingSeekTask: Task<Void, Never>?
    private var pendingInteractiveTime: CMTime?
    private var preciseSeekTask: Task<Void, Never>?
    private var minimumTime: Double
    /// The composed timeline's cadence, used to place the last seekable frame.
    /// Zero until it is known, which `lastFrameTime` falls back for.
    private var frameDuration: Double

    // MARK: - Preview quality

    /// The composition the picture is graded and inspected through: the
    /// project's own resolution.
    private var fullVideoComposition: AVVideoComposition?
    /// Reduced copies, one per quality, built with the sequence.
    private var playbackVideoCompositions: [PreviewQuality: AVVideoComposition] = [:]
    /// True while the player item is carrying a reduced composition.
    private var isPreviewReduced = false
    /// What the item is actually carrying, compared by identity so a quality
    /// change during playback is applied rather than mistaken for a no-op.
    private var appliedVideoComposition: AVVideoComposition?

    /// How much resolution playback gives up. Changing it takes effect at the
    /// next play; the paused picture is always full resolution.
    @Published var previewQuality: PreviewQuality = .load() {
        didSet {
            guard previewQuality != oldValue else { return }
            previewQuality.save()
            updatePreviewComposition()
        }
    }

    /// The reduced composition for the current setting, if it reduces anything.
    /// `.full` has no entry, and neither does a project already small enough.
    private var reducedComposition: AVVideoComposition? {
        playbackVideoCompositions[previewQuality]
    }

    /// True when playback is actually running at a reduced size, for the UI to
    /// say so rather than claim a reduction that is not happening.
    var isPlayingReduced: Bool { isPreviewReduced }

    /// Swaps the player item's composition to match what the preview is doing.
    ///
    /// Reduced while playing, full the moment it stops. Assigning a composition
    /// to the existing item is all it takes — the asset, the item and the player
    /// are untouched, so there is no reload and no gap in the audio.
    private func updatePreviewComposition() {
        guard let item = player.currentItem, let fullVideoComposition else { return }
        let reduced = isPlaying ? reducedComposition : nil
        let target = reduced ?? fullVideoComposition
        // Compared by identity, not by "is it reduced": changing the quality
        // mid-playback swaps one reduced composition for another, and that must
        // not read as a no-op. Assigning is what forces a re-render, so doing it
        // when nothing changed would be a stutter of its own.
        guard target !== appliedVideoComposition else { return }
        appliedVideoComposition = target
        isPreviewReduced = reduced != nil
        item.videoComposition = target
        // Coming back to full resolution has to repaint the still: nothing else
        // will, and the frame on screen was rendered at the smaller size.
        if reduced == nil, !isSeeking, pendingSeekTask == nil,
           item.status == .readyToPlay {
            seekPrecisely(to: currentTime)
        }
    }

    /// Decoder output format, chosen by project colour mode.
    ///
    /// SDR keeps the original 8-bit NV12 request, unchanged. HDR asks
    /// AVFoundation for `kCVPixelFormatType_64RGBAHalf` with a **linear**
    /// transfer function, which makes its pixel transfer session perform the
    /// HLG→linear conversion, the BT.2020 YCbCr matrix and the gamut conversion
    /// for us. Measured behaviour of that path — including the fact that it
    /// returns scene light scaled so HLG signal 1.0 → 12.0, and preserves
    /// out-of-P3 colour as negative coordinates — is recorded in
    /// `Docs/HDR_PIPELINE_PLAN.md` §2 and reproducible with
    /// `Scripts/ValidateHDRDecode.swift`.
    ///
    /// Asking for HLG rather than linear is what makes a mixed timeline work:
    /// SDR clips are converted to HLG by AVFoundation with SDR white landing on
    /// reference white, so they sit at a sane brightness in an HDR project
    /// instead of being renormalised by us and coming out hazy.
    nonisolated static func outputSettings(for colorMode: ProjectColorMode) -> [String: Any] {
        switch colorMode {
        case .sdr:
            return [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        case .sdrWide:
            // Native 10-bit 4:2:2. The existing YUV shader path handles it
            // unchanged - `YUVUniforms` already computes 10-bit code ranges, and
            // 4:2:2 only changes the chroma plane's size, which CVPixelBuffer
            // reports. Asking for 4:2:2 rather than 4:2:0 avoids resampling the
            // chroma of a ProRes source on the way in.
            return [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        case .appleLog, .appleLog2:
            // Apple Log ProRes is 4:2:2 10-bit. Apple Log 2 is the same
            // container and the same code-value convention; only the primaries
            // the values describe differ, which is a shader concern, not a
            // decoder one. Full range is requested because
            // the white paper's reference table is in full-range codes (0 -> 0,
            // 1.0 -> 1023): asking for video range would squeeze the signal into
            // 64...940 and cost precision on the way in for nothing.
            return [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        case .hdrHLG:
            return [
                AVVideoColorPropertiesKey: [
                    // Ask for the HLG representation, not linear. AVFoundation
                    // then converts *any* source into a correctly referenced HLG
                    // signal — measured: an SDR Rec.709 white lands on signal
                    // 0.749, i.e. BT.2408 reference white. That is the
                    // mixed-timeline reference-white policy, implemented by
                    // Apple rather than by us.
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ],
                AVVideoAllowWideColorKey: true,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        }
    }

    func replaceSequence(_ sequence: SequenceComposition, at time: Double) {
        pause()
        if let observer = periodicTimeObserver { player.removeTimeObserver(observer); periodicTimeObserver = nil }
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer); endObserver = nil }
        statusObservation = nil
        player.currentItem?.remove(output)
        let item = AVPlayerItem(asset: sequence.source.asset)
        // Always built at the project's resolution: playback drops to a reduced
        // copy only once it starts, and comes back here when it stops.
        fullVideoComposition = sequence.source.videoComposition
        playbackVideoCompositions = sequence.source.playbackVideoCompositions
        appliedVideoComposition = sequence.source.videoComposition
        isPreviewReduced = false
        item.videoComposition = sequence.source.videoComposition
        item.audioMix = sequence.source.audioMix
        // Retimed audio keeps its pitch. Scaling the track alone shifts pitch
        // with rate, which is not what anyone wants from a speed control.
        item.audioTimePitchAlgorithm = .spectral
        item.add(output)
        minimumTime = 0
        duration = sequence.source.duration.seconds
        // The composition's own cadence, which is what the last composed frame
        // is actually placed on; the track's nominal rate is the fallback.
        frameDuration = sequence.source.videoComposition.map { $0.frameDuration.seconds }
            ?? sequence.source.nominalFrameRate.map { 1 / $0 } ?? 0
        currentTime = clampedTime(time)
        isReady = false
        errorMessage = nil
        player.replaceCurrentItem(with: item)
        frameProvider.reset()
        installObservers(for: item)
        seekPrecisely(to: currentTime)
    }

    /// Forces the custom compositor to produce a fresh frame for the current
    /// time, after something it reads has changed.
    ///
    /// Reassigning `videoComposition` is what invalidates AVFoundation's
    /// composed-frame cache; a seek to the same time on its own can be served
    /// from that cache and show a stale picture. The pair is therefore load
    /// bearing, but it is also expensive — AVFoundation rebuilds its render
    /// pipeline and the precise seek decodes to the frame.
    ///
    /// Dragging a Transform slider calls this on every update, which is dozens
    /// of times a second. Unthrottled, each one arrived before the last had
    /// finished and the preview simply stopped moving. Coalescing bounds it to
    /// roughly ten refreshes a second, and the trailing call guarantees the
    /// value the drag ends on is the one shown.
    func refreshCompositionFrame() {
        let now = CACurrentMediaTime()
        let sinceLast = now - lastCompositionRefresh
        guard sinceLast >= Self.compositionRefreshInterval else {
            guard !hasPendingCompositionRefresh else { return }
            hasPendingCompositionRefresh = true
            let delay = Self.compositionRefreshInterval - sinceLast
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.hasPendingCompositionRefresh = false
                self.applyCompositionRefresh()
            }
            return
        }
        applyCompositionRefresh()
    }

    private static let compositionRefreshInterval: CFTimeInterval = 0.1

    private func applyCompositionRefresh() {
        guard let item = player.currentItem, let composition = item.videoComposition else { return }
        lastCompositionRefresh = CACurrentMediaTime()
        item.videoComposition = composition.mutableCopy() as? AVVideoComposition
        if !isPlaying { seekPrecisely(to: currentTime) }
    }

    private var lastCompositionRefresh: CFTimeInterval = 0
    private var hasPendingCompositionRefresh = false

    func clearSequence() {
        releaseSequenceResources()
        duration = 0; currentTime = 0
    }

    /// Pausing retains the decoder and custom compositor. Release them while
    /// exporting, but keep the playhead and duration for the editor underneath.
    func releaseSequenceResources() {
        pause()
        pendingSeekTask?.cancel(); pendingSeekTask = nil
        preciseSeekTask?.cancel(); preciseSeekTask = nil
        if let observer = periodicTimeObserver { player.removeTimeObserver(observer); periodicTimeObserver = nil }
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer); endObserver = nil }
        statusObservation = nil
        isReady = false
        fullVideoComposition = nil
        playbackVideoCompositions = [:]
        appliedVideoComposition = nil
        isPreviewReduced = false
        player.currentItem?.remove(output)
        player.replaceCurrentItem(with: nil)
        frameProvider.reset()
    }

    init(url: URL, duration: Double, range: TimelineRange? = nil, colorMode: ProjectColorMode = .sdr,
         frameDuration: Double? = nil) {
        minimumTime = range?.start.seconds ?? 0
        self.duration = (try? range?.end.seconds) ?? duration
        self.frameDuration = frameDuration ?? 0
        output = AVPlayerItemVideoOutput(outputSettings: Self.outputSettings(for: colorMode))
        output.suppressesPlayerRendering = true
        frameProvider = VideoFrameProvider(output: output)

        let item = AVPlayerItem(url: url)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        installObservers(for: item)
        installAudioObservers()
        frameProvider.setMediaDataCallback { [weak self] in
            Task { @MainActor [weak self] in
                self?.frameUpdateID &+= 1
            }
        }
        frameProvider.clear()
        if minimumTime > 0 { seekPrecisely(to: minimumTime) }
    }

    deinit {
        pendingSeekTask?.cancel()
        preciseSeekTask?.cancel()
        frameProvider.setMediaDataCallback(nil)
        player.pause()
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard errorMessage == nil else { return }
        wantsPlayback = true
        activateAudioSession()
        // A seek now stops one frame short of the end, so the threshold has to
        // clear a frame as well or play would resume on the last frame instead
        // of starting over.
        if currentTime >= seekBounds.endThreshold {
            seekPrecisely(to: minimumTime) { [weak self] in
                guard let self, self.wantsPlayback else { return }
                self.player.play()
                self.isPlaying = true
                self.updatePreviewComposition()
            }
        } else {
            player.play()
            isPlaying = true
            updatePreviewComposition()
        }
    }

    func pause() {
        wantsPlayback = false
        pendingSeekTask?.cancel()
        preciseSeekTask?.cancel()
        pendingSeekTask = nil
        preciseSeekTask = nil
        pendingInteractiveTime = nil
        isSeeking = false
        player.pause()
        isPlaying = false
        updatePreviewComposition()
        deactivateAudioSession()
    }

    /// Touching the playhead stops playback, and it stays stopped.
    ///
    /// Resuming on its own made the picture run away from under the finger the
    /// instant the drag ended, which is the opposite of what someone lining up a
    /// frame wants. Play is a deliberate action; after a scrub it has to be
    /// asked for again.
    func beginSeeking() {
        pause()
        isSeeking = true
    }

    func seekInteractively(to seconds: Double) {
        guard isSeeking else { return }
        let target = clampedTime(seconds)
        currentTime = target
        pendingInteractiveTime = CMTime(seconds: target, preferredTimescale: TimelineTime.projectTimescale)
        guard pendingSeekTask == nil else { return }
        pendingSeekTask = Task { [weak self] in
            guard let self else { return }
            // Latest-target coalescing, not a debounce that starves continuous drags.
            while !Task.isCancelled, let time = self.pendingInteractiveTime {
                self.pendingInteractiveTime = nil
                _ = await self.player.seek(to: time,
                    toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
                guard !Task.isCancelled else { return }
                self.frameProvider.clear()
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { self.pendingSeekTask = nil }
        }
    }

    func endSeeking(at seconds: Double) {
        endSeeking(at: CMTime(seconds: clampedTime(seconds), preferredTimescale: TimelineTime.projectTimescale))
    }

    func endSeeking(at time: CMTime) {
        guard isSeeking else { return }
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        pendingInteractiveTime = nil
        seekPrecisely(to: time) { [weak self] in
            self?.isSeeking = false
        }
    }

    func seekPrecisely(to seconds: Double, completion: (() -> Void)? = nil) {
        seekPrecisely(to: CMTime(seconds: clampedTime(seconds), preferredTimescale: TimelineTime.projectTimescale), completion: completion)
    }

    func seekPrecisely(to time: CMTime, completion: (() -> Void)? = nil) {
        let target = clampedTime(time.seconds)
        let time = time.seconds == target ? time : CMTime(seconds: target, preferredTimescale: TimelineTime.projectTimescale)
        preciseSeekTask?.cancel()
        preciseSeekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            self.currentTime = target
            self.frameProvider.clear()
            self.preciseSeekTask = nil
            completion?()
        }
    }

    func handleScenePhase(active: Bool) {
        if !active {
            pause()
        } else {
            frameProvider.clear()
        }
    }

    private func installObservers(for item: AVPlayerItem) {
        statusObservation = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                MainActor.assumeIsolated {
                    guard let self, let item, self.player.currentItem === item else { return }
                    switch status {
                    case .readyToPlay:
                        self.isReady = true
                        self.errorMessage = nil
                        self.frameProvider.clear()
                        self.frameUpdateID &+= 1
                    case .failed:
                        self.isReady = false
                        self.errorMessage = "This video could not be prepared for playback."
                        self.pause()
                    case .unknown:
                        self.isReady = false
                    @unknown default:
                        self.isReady = false
                    }
                }
            }

        let interval = CMTime(seconds: 1 / 30, preferredTimescale: 600)
        periodicTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak item] time in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                if !self.isSeeking {
                    self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                }
                let wasPlaying = self.isPlaying
                self.isPlaying = self.player.timeControlStatus == .playing
                if self.currentTime >= self.duration, self.isPlaying { self.pause() }
                // Playback can also stop without anyone calling pause -- a stall,
                // or the end of the item. The picture has to come back to full
                // resolution either way.
                else if wasPlaying != self.isPlaying { self.updatePreviewComposition() }
                self.isReady = item.status == .readyToPlay
                if item.status == .failed {
                    self.errorMessage = "This video could not be prepared for playback."
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.isPlaying = false
                self.currentTime = self.duration
                self.updatePreviewComposition()
            }
        }
    }

    private func installAudioObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(notification)
            }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        }
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("Audio session setup failed: \(error)")
            #endif
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            #if DEBUG
            print("Audio session deactivation failed: \(error)")
            #endif
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            wantsPlayback = false
            player.pause()
            isPlaying = false
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                .contains(.shouldResume)
            let resume = wasPlayingBeforeInterruption && shouldResume
            wasPlayingBeforeInterruption = false
            if resume { play() }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason == .oldDeviceUnavailable else { return }
        pause()
    }

    /// The rule that keeps a seek on the last frame instead of past it.
    /// See `SeekBounds`, where it is stated and unit tested.
    private var seekBounds: SeekBounds {
        SeekBounds(minimumTime: minimumTime, duration: duration, frameDuration: frameDuration)
    }

    /// The last position that can display a real frame. UI playheads use this
    /// instead of the duration boundary, which lies just after the footage.
    var maximumSeekTime: Double { seekBounds.lastFrameTime }

    private func clampedTime(_ seconds: Double) -> Double { seekBounds.clamped(seconds) }
}
