import Foundation
import simd

/// Constants and conversions for the HDR working space.
///
/// Every number here is either taken from a published specification or measured
/// from AVFoundation's own decoder by `Scripts/ValidateHDRDecode.swift`. None of
/// it is inferred. See `Docs/HDR_PIPELINE_PLAN.md` §2 for the measurements and
/// their sources.
enum HDRColorSpace {
    // MARK: - BT.2100 HLG transfer (Table 5)

    static let hlgA = 0.17883277
    static let hlgB = 0.28466892
    static let hlgC = 0.55991073

    /// BT.2100 HLG inverse OETF: signal (0...1) → scene light (0...1).
    static func hlgSceneLight(fromSignal signal: Double) -> Double {
        guard signal > 0 else { return 0 }
        if signal <= 0.5 { return signal * signal / 3 }
        return (exp((signal - hlgC) / hlgA) + hlgB) / 12
    }

    /// BT.2100 HLG OETF: scene light (0...1) → signal (0...1).
    ///
    /// This is the one piece of HLG maths the app implements itself, because
    /// encoding needs the forward direction and AVFoundation only offers the
    /// inverse. It is verified by round-tripping against that inverse rather
    /// than against itself.
    static func hlgSignal(fromSceneLight light: Double) -> Double {
        guard light > 0 else { return 0 }
        if light <= 1.0 / 12 { return sqrt(3 * light) }
        return hlgA * log(12 * light - hlgB) + hlgC
    }

    // MARK: - Working space

    /// BT.2020 luminance weights. The decoder is asked for BT.2020 primaries, so
    /// these are the matching coefficients.
    static let luminanceWeights = SIMD3<Double>(0.2627, 0.6780, 0.0593)

    static func luminance(_ rgb: SIMD3<Double>) -> Double {
        (rgb * luminanceWeights).sum()
    }

    /// HDR Reference White is 203 cd/m², at HLG signal 0.75 (ITU-R BT.2408).
    static let referenceWhiteSignal = 0.75
    static let referenceWhiteNits = 203.0

    /// Reference white in normalised scene light: ≈0.26496. Dividing scene light
    /// by this puts diffuse white at 1.0, which is what keeps SDR content, text
    /// and white UI at a sane brightness in an HDR project.
    static var referenceWhiteSceneLight: Double {
        hlgSceneLight(fromSignal: referenceWhiteSignal)
    }

    /// Peak HLG over diffuse white in the working space: ≈3.774.
    ///
    /// This is scene-referred headroom. It is deliberately *not* the 4.926 of
    /// BT.2408's 203 vs 1000 cd/m² — that ratio is a property of the **display**
    /// after the OOTF, and the OOTF is the system's job, not ours. Applying it
    /// here as well would double-count it.
    static var peakInWorkingSpace: Double {
        1.0 / referenceWhiteSceneLight
    }

    /// HLG signal → working space (scene-linear, 1.0 = diffuse white).
    static func toWorkingSpace(signal: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            hlgSceneLight(fromSignal: signal.x),
            hlgSceneLight(fromSignal: signal.y),
            hlgSceneLight(fromSignal: signal.z)
        ) / referenceWhiteSceneLight
    }

    /// Working space → HLG signal, for display and for encoding.
    static func signal(fromWorkingSpace working: SIMD3<Double>) -> SIMD3<Double> {
        let scene = working * referenceWhiteSceneLight
        return SIMD3(
            hlgSignal(fromSceneLight: scene.x),
            hlgSignal(fromSceneLight: scene.y),
            hlgSignal(fromSceneLight: scene.z)
        )
    }

    // MARK: - Display headroom

    /// Below this there is no useful EDR headroom. The system still tone maps
    /// HLG correctly for the display, so this is only used to label the preview
    /// honestly — not to switch to a different transform of our own.
    /// (WWDC22 — Explore EDR on iOS.)
    static let minimumUsefulHeadroom: Double = 1.5
}
