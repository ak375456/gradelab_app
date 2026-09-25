import Foundation

// ---------------------------------------------------------------------------
// What this device can actually be offered
//
// The working set for temporal reduction is, at 4K with a five-frame window,
// the largest thing the app ever allocates — several hundred megabytes of
// float textures. Offering that on a phone that will be killed for asking is
// not a feature, so the window is capped by arithmetic rather than by a device
// list: the stage can say what a configuration costs, and this compares it to
// what there is.
//
// Deriving it beats naming devices. A device table goes stale with every
// release and says nothing about the project that is actually open — the same
// phone can carry a five-frame window at 1080p and not at 4K, and that is the
// distinction that matters.
// ---------------------------------------------------------------------------

struct NoiseReductionCapability: Sendable, Equatable {
    /// The widest temporal window this device can run at this frame size.
    let maximumFrames: TemporalFrameCount
    /// False when even a two-frame window is out of reach, in which case the
    /// spatial stage is still offered and the temporal one is not.
    let supportsTemporal: Bool
    /// Roughly what the largest supported window would cost, for the panel to
    /// explain itself with.
    let workingSetBytes: Int

    /// What a project of this size can have.
    ///
    /// - Parameter longEdge: the project's own long edge, not the preview's.
    ///   Reduced-resolution playback makes the surfaces smaller, but the paused
    ///   preview and the export both run at full size and those are what has to
    ///   fit.
    static func resolve(width: Int, height: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Self {
        // A share of physical memory rather than a fixed number. iOS gives an
        // app well under half the machine before it starts killing things, and
        // GradeLab is already holding decoded frames, look tables and the
        // compositor's own surfaces — so this is deliberately a slice, not a
        // ceiling.
        //
        // A Mac is given more: it has virtual memory to fall back on and no
        // jetsam, so being wrong there is slow rather than fatal.
        //
        // The platform test is written out rather than taken from
        // `AppPlatform`, which lives in a file that imports UIKit and PhotosUI.
        // This is the whole of what is needed and it keeps the engine
        // compilable on its own, which is what lets the validation harness
        // build and run it outside the app.
        #if targetEnvironment(macCatalyst)
        let isMac = true
        #else
        let isMac = ProcessInfo.processInfo.isiOSAppOnMac
        #endif
        let budget = Int(Double(physicalMemory) * (isMac ? 0.30 : 0.16))

        var best: TemporalFrameCount?
        var bytes = 0
        for count in [TemporalFrameCount.five, .three, .two] {
            let neighbours = count.backwardReach + count.forwardReach
            let cost = NoiseReductionStage.approximateBytes(
                width: width, height: height, neighbours: neighbours)
            if cost <= budget { best = count; bytes = cost; break }
        }
        guard let best else {
            return Self(maximumFrames: .two, supportsTemporal: false,
                        workingSetBytes: NoiseReductionStage.approximateBytes(
                            width: width, height: height, neighbours: 0))
        }
        return Self(maximumFrames: best, supportsTemporal: true, workingSetBytes: bytes)
    }

    /// The frame counts this device offers, so the panel shows what it can
    /// deliver rather than showing three buttons and refusing one.
    var availableFrames: [TemporalFrameCount] {
        TemporalFrameCount.allCases.filter { $0.rawValue <= maximumFrames.rawValue }
    }

    /// `settings` with anything this device cannot run brought back into range.
    ///
    /// Applied on the way to the renderer rather than to the document. A
    /// project authored on a Mac with a five-frame window keeps that window in
    /// its file and gets it back on a Mac; on a phone it simply renders with
    /// the widest one that fits, and says so.
    func constrained(_ settings: NoiseReduction) -> NoiseReduction {
        var value = settings
        if !supportsTemporal {
            value.isTemporalEnabled = false
        } else if value.frames.rawValue > maximumFrames.rawValue {
            value.frames = maximumFrames
        }
        return value
    }

    /// True when rendering `settings` here would not be what the document asks
    /// for, so the panel can say which part was reduced.
    func reduces(_ settings: NoiseReduction) -> Bool {
        settings.isTemporalEnabled && (!supportsTemporal || settings.frames.rawValue > maximumFrames.rawValue)
    }
}
