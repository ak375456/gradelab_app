import Foundation
import simd

// ---------------------------------------------------------------------------
// From authored numbers to what the kernels actually use
//
// Every mapping between a 0…100 slider and an internal quantity lives here and
// nowhere else. That matters more than it usually does, because preview and
// export run the same kernels: if the two ever derived a threshold differently,
// the only place it would show is the finished file.
//
// The curves are deliberately not linear. Noise reduction is a control people
// creep up on — the interesting range is the bottom third, where the difference
// between "clean" and "plastic" is a few points — so the strengths rise slowly
// at first and steeply at the top, and the read-out still says what the user
// set.
// ---------------------------------------------------------------------------

/// Matches `NoiseUniforms` in NoiseReductionShaders.metal.
///
/// Packed into `float4`s for the same reason `GradeUniforms` is: it is what
/// Metal's constant buffers align to, and a scalar field would silently pad.
struct NoiseReductionUniforms: Sendable, Equatable {
    /// x temporal luma, y temporal chroma, z motion tolerance in sigmas,
    /// w detail protection.
    var temporal: SIMD4<Float> = .zero
    /// x spatial luma, y spatial chroma, z radius in pixels, w edge protection.
    var spatial: SIMD4<Float> = .zero
    /// x detail recovery, y coring in sigmas, z shadow bias, w chroma radius.
    var detail: SIMD4<Float> = .zero
    /// x accepted frame count, y temporal distance falloff, z noise floor,
    /// w noise ceiling.
    var window: SIMD4<Float> = SIMD4(1, 0.75, 0.0008, 0.25)
    /// xyz luma weights of the working primaries, w 1 for extended-range
    /// (linear-derived) input.
    var luma: SIMD4<Float> = SIMD4(0.2126, 0.7152, 0.0722, 0)
    /// x/y one texel of the luma plane, z/w one texel of the chroma plane.
    var geometry: SIMD4<Float> = .zero
    /// x/y one texel of the motion grid, z/w that grid's dimensions. Written
    /// by the stage once it knows what resolution motion was estimated at.
    var flow: SIMD4<Float> = SIMD4(1, 1, 1, 1)
}

/// Matches `NoisePlaneUniforms` in Shaders.metal: the little that the two ends
/// of the engine — the conversion into the working planes and back out of them
/// — need to know.
///
/// Separate from `NoiseReductionUniforms` on purpose. Those two kernels live in
/// Shaders.metal beside the colour science they depend on, and giving them the
/// whole denoising parameter block would tie that file to every later change in
/// this one.
struct NoisePlaneUniforms: Sendable, Equatable {
    /// xyz the working primaries' luma weights, w 1 for extended-range input.
    var luma: SIMD4<Float> = SIMD4(0.2126, 0.7152, 0.0722, 0)
    /// Reserved, so this matches the head of `NoiseReductionUniforms`.
    var geometry: SIMD4<Float> = .zero

    /// Rec.709 weights for the SDR path; BT.2020 for everything that decodes
    /// into the extended-range linear working space.
    ///
    /// These are the same two sets of weights `Shaders.metal` carries as
    /// `kRec709LumaWeights` and `kBT2020LumaWeights`, and they have to stay
    /// that way: a luma/chroma split taken on the wrong primaries puts part of
    /// the luminance into the colour-difference channels, where the chroma
    /// slider would then quietly soften it.
    init(colorMode: ProjectColorMode) {
        let extended = colorMode.isHDR || colorMode.isAppleLog
        luma = extended
            ? SIMD4(0.2627, 0.6780, 0.0593, 1)
            : SIMD4(0.2126, 0.7152, 0.0722, 0)
    }

    init() {}
}

/// The per-neighbour half of the temporal pass, pushed with `setBytes` once per
/// accumulated frame rather than rebuilt into a table.
struct TemporalSampleUniforms: Sendable, Equatable {
    /// Signed distance in frames from the current frame. Never zero: the
    /// current frame seeds the accumulator rather than being accumulated.
    var offset: Float = 1
    /// `window.y ^ |offset|`, precomputed so the kernel does no `pow`.
    var distanceWeight: Float = 1
    /// 1 when a motion field is bound, 0 when the neighbour is compared where
    /// it lies.
    var usesFlow: Float = 1
    /// How far a forward/backward round trip may land from where it started,
    /// in flow-grid texels, before the sample is treated as occluded.
    var consistencyLimit: Float = 1.5
}

extension NoiseReductionUniforms {

    // MARK: - The slider curves

    /// A 0…100 strength as a 0…1 amount, weighted toward fine control at the
    /// bottom of the travel.
    ///
    /// At 30 the amount is 0.19, at 70 it is 0.61, at 100 it is 1, so the first
    /// third of the slider still buys a genuinely light touch rather than a
    /// third of the maximum.
    ///
    /// The exponent was 1.7, and that was too much of a good thing. What the
    /// slider says is not what the picture gets: this amount is then multiplied
    /// by the structure protection and the shadow weighting, both at or below
    /// one, so the delivered blend on a midtone is well under the curve. At 1.7
    /// the measured reduction from the shipping presets was 6% for Light and
    /// 19% for Medium while leaving 97% of the texture — a control that was
    /// protecting detail nobody had asked it to protect from a reduction that
    /// was not happening. `validatePresetStrength` is what now holds this
    /// honest, since every other measurement here drives 100.
    static func strength(_ value: Float) -> Float {
        let t = min(max(value, 0), 100) / 100
        return pow(t, 1.4)
    }

    /// A plain normalisation for the controls that are not strengths — the
    /// threshold and the two protections, where the middle of the travel really
    /// is meant to be the middle of the behaviour.
    static func normalized(_ value: Float) -> Float {
        min(max(value, 0), 100) / 100
    }

    /// How many noise sigmas a temporal difference may reach before the sample
    /// is rejected as motion rather than accepted as noise.
    ///
    /// The floor is not zero on purpose. A threshold below about one sigma
    /// rejects the noise it is supposed to be averaging, so the stage would
    /// cost a full pass and return the frame it was given. One and a bit sigma
    /// is the cautious end of useful.
    static func motionTolerance(_ value: Float) -> Float {
        1.2 + 5.0 * pow(normalized(value), 1.3)
    }

    /// The spatial filter's reach, in pixels of the frame being processed.
    ///
    /// Scaled by the picture rather than fixed, so the same slider means the
    /// same *fraction of the frame* at 1080p and at 4K — which is what makes a
    /// grade judged on a phone hold up in a 4K export.
    ///
    /// The ceiling is low by design. Past about twenty-four pixels an
    /// edge-aware filter stops reading as noise reduction and starts reading as
    /// a blur, and a control that can obviously wreck the picture is not a
    /// professional control.
    static func spatialRadius(_ value: Float, longEdge: Int) -> Float {
        let scale = Float(max(longEdge, 1)) / 1920
        let base = 1 + 15 * pow(normalized(value), 1.5)
        return min(base * max(scale, 0.5), 24)
    }

    // MARK: - Building the uniforms

    /// The resolved uniforms for one frame.
    ///
    /// - Parameters:
    ///   - settings: the authored values, already clamped.
    ///   - lumaWeights: the working primaries' luminance weights — Rec.709 for
    ///     the SDR path, BT.2020 for the extended-range one. Passing them in
    ///     rather than deriving them here is what keeps this file free of
    ///     colour-science decisions that belong to the pipeline.
    ///   - extendedRange: true when the input is the linear working space
    ///     rather than an encoded SDR signal.
    ///   - size: the luma plane's dimensions.
    ///   - chromaSize: the chroma plane's dimensions.
    init(
        settings: NoiseReduction,
        lumaWeights: SIMD3<Float>,
        extendedRange: Bool,
        size: (width: Int, height: Int),
        chromaSize: (width: Int, height: Int)
    ) {
        let value = settings.clamped
        let longEdge = max(size.width, size.height)
        let protection = Self.normalized(value.detailProtection)
        let radius = Self.spatialRadius(value.radius, longEdge: longEdge)

        temporal = SIMD4(
            value.temporalIsActive ? min(Self.strength(value.temporalLuma), 0.95) : 0,
            value.temporalIsActive ? min(Self.strength(value.temporalChroma), 0.98) : 0,
            Self.motionTolerance(value.motionThreshold),
            protection)
        spatial = SIMD4(
            value.spatialIsActive ? Self.strength(value.spatialLuma) : 0,
            value.spatialIsActive ? Self.strength(value.spatialChroma) : 0,
            radius,
            value.protectsEdges ? 1 : 0)
        detail = SIMD4(
            value.recoveryIsActive ? Self.normalized(value.detailRecovery) : 0,
            // What a residual has to clear, in sigmas, to be believed. Detail
            // Protection raises it: someone who has asked for texture to be
            // protected has also asked not to have noise handed back.
            // What a residual has to clear, in noise floors, to be believed.
            //
            // The floor is measured on a low-passed copy and is a minimum, so
            // it sits at roughly half the noise a full-resolution residual
            // actually carries — which is why the useful range for this number
            // is above one rather than around it. Detail Protection raises it:
            // someone who has asked for texture to be protected has also asked
            // not to have noise handed back.
            1.3 + 1.3 * protection,
            // Shadow bias. Sensor noise is worst in the dark, so the strengths
            // are scaled up there and eased down through the highlights. Fixed
            // rather than exposed: a control for it would mostly produce the
            // banded transition it exists to avoid.
            0.6,
            // Chroma is filtered on a half-resolution plane, so its radius is
            // expressed in that plane's own pixels.
            max(radius * 0.5, 1))
        window = SIMD4(
            Float(value.temporalIsActive ? value.frames.rawValue : 1),
            // How much less a frame counts for each step further away. Closer
            // frames are preferred because their alignment is more reliable,
            // not because they are better evidence — every accepted sample has
            // already passed the occlusion test. At 0.75 the outer pair of a
            // five-frame window was discounted to nine sixteenths and the
            // window measurably under-performed what five frames should give.
            0.85,
            // The measured noise floor is clamped into this band before
            // anything divides by it. The low end stops a perfectly clean
            // synthetic frame from producing an infinite threshold; the high
            // end stops a frame of pure static from denoising the whole picture
            // away.
            0.0008,
            0.25)
        luma = SIMD4(lumaWeights, extendedRange ? 1 : 0)
        geometry = SIMD4(
            1 / Float(max(size.width, 1)), 1 / Float(max(size.height, 1)),
            1 / Float(max(chromaSize.width, 1)), 1 / Float(max(chromaSize.height, 1)))
    }
}

extension TemporalSampleUniforms {
    /// The uniforms for one neighbour at `offset` frames away.
    init(offset: Int, falloff: Float, usesFlow: Bool) {
        self.offset = Float(offset)
        distanceWeight = pow(falloff, Float(abs(offset)))
        self.usesFlow = usesFlow ? 1 : 0
        // Half a flow texel of round-trip error is alignment noise; more than
        // about a texel and a half means the two directions disagree about what
        // moved, which is what an occlusion looks like from here.
        consistencyLimit = 1.5
    }
}
