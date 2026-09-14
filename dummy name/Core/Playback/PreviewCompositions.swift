@preconcurrency import AVFoundation

// ---------------------------------------------------------------------------
// Reduced-resolution playback compositions
//
// One composition per quality, built once alongside the full-resolution one and
// handed to the player. Switching between them is an assignment on the existing
// `AVPlayerItem`: no media is re-read, no composition is rebuilt, and the player
// is never replaced — which is what makes "reduce while playing, restore when
// paused" cheap enough to do on every play and pause.
// ---------------------------------------------------------------------------

extension SequenceComposition {
    /// The render size for a given long-edge limit, or nil when the picture is
    /// already at or below it and nothing needs to change.
    static func reducedRenderSize(width: Int, height: Int, longEdgeLimit: Int) -> CGSize? {
        let longest = max(width, height)
        guard longest > longEdgeLimit, longest > 0, width > 0, height > 0 else { return nil }
        let scale = Double(longEdgeLimit) / Double(longest)
        // Even dimensions: 4:2:0 chroma is subsampled by two in each direction.
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    /// Reduced copies of `base`, keyed by the quality that produces them.
    ///
    /// - Parameter scalingTrack: the composition's video track for the built-in
    ///   compositor, which draws the source at its natural size and so needs an
    ///   explicit scale transform to fill a smaller canvas. Pass nil for the
    ///   custom layer compositor, which normalises to whatever canvas it is
    ///   handed and therefore needs only the new render size.
    static func playbackCompositions(
        base: AVVideoComposition,
        scalingTrack: AVAssetTrack?
    ) -> [PreviewQuality: AVVideoComposition] {
        let width = Int(base.renderSize.width.rounded())
        let height = Int(base.renderSize.height.rounded())
        var result: [PreviewQuality: AVVideoComposition] = [:]
        for quality in PreviewQuality.allCases {
            guard let limit = quality.longEdgeLimit,
                  let size = reducedRenderSize(width: width, height: height, longEdgeLimit: limit),
                  let copy = base.mutableCopy() as? AVMutableVideoComposition else { continue }
            copy.renderSize = size
            if let scalingTrack {
                // Scale by the ratio actually used on each axis rather than one
                // shared factor: rounding to even dimensions moves the two by
                // slightly different amounts, and a uniform scale would leave a
                // sub-pixel black edge along one side.
                let transform = CGAffineTransform(
                    scaleX: size.width / base.renderSize.width,
                    y: size.height / base.renderSize.height
                )
                copy.instructions = base.instructions.map { instruction in
                    Self.scaled(instruction, by: transform, track: scalingTrack)
                }
            }
            result[quality] = copy
        }
        return result
    }

    /// A copy of one instruction with the scale applied to its layer.
    ///
    /// The instructions are rebuilt rather than mutated: the full-resolution
    /// composition is still live on the player item, and a layer instruction is
    /// a reference type that both would otherwise share.
    private static func scaled(
        _ instruction: AVVideoCompositionInstructionProtocol,
        by transform: CGAffineTransform,
        track: AVAssetTrack
    ) -> AVMutableVideoCompositionInstruction {
        let copy = AVMutableVideoCompositionInstruction()
        copy.timeRange = instruction.timeRange
        copy.backgroundColor = CGColor(gray: 0, alpha: 1)
        // An instruction with no layers is a gap: it stays empty, so the frame
        // is the background colour exactly as it is at full resolution.
        let hasLayers = (instruction as? AVVideoCompositionInstruction)?.layerInstructions.isEmpty == false
        guard hasLayers else {
            copy.layerInstructions = []
            return copy
        }
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        copy.layerInstructions = [layer]
        return copy
    }
}
