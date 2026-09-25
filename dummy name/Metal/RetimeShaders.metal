#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Time remapping: making the frame that is not there
//
// A retimed clip asks for pictures between the ones the media holds. There are
// three honest answers and this file implements the third:
//
//   sampling   show the nearer source frame. Correct, and what everything did
//              before retiming existed. Handled without a kernel at all.
//   blending   cross-dissolve the two. Removes the stepping; movement softens
//              into a double exposure rather than gaining detail.
//   flow       estimate where every pixel travelled between the two frames and
//              move it part of the way. This is the only one that produces a
//              picture of the moment rather than a picture of two moments.
//
// The motion estimate itself is NOT here. It is `nrFlowSearch` and
// `nrFlowSmooth` in NoiseReductionShaders.metal — a coarse-to-fine block match
// with a vector median between levels — which is general-purpose motion
// estimation that happened to be written for denoising first. Two engines share
// those kernels; neither owns them. What is here is the warp, and the judgement
// about when not to trust it.
//
// ## Why occlusion is the whole problem
//
// Interpolation fails where a pixel exists in one frame and not the other: an
// arm crossing a torso, hair against a background, water, smoke, confetti. The
// flow there is not wrong so much as meaningless — there is nothing to point
// at. A warp that believes it produces the melting and the torn edges that make
// people turn optical flow off.
//
// So every pixel is tested before it is believed, by running the motion
// estimate BOTH ways and asking whether the two agree. Where the forward vector
// at a pixel and the backward vector at the place it points to cancel out, the
// match describes a real correspondence. Where they do not, one of the two
// frames does not contain this pixel, and the kernel falls back — first to a
// dissolve, then, where even that would ghost, to the nearer frame on its own.
// A soft area is better than a warped one.
// ---------------------------------------------------------------------------

constexpr sampler retimeSampler(coord::normalized, address::clamp_to_edge, filter::linear);

struct RetimeUniforms {
    /// x phase 0…1 between the two frames, y consistency limit in flow-grid
    /// pixels, z match-cost limit, w 1 when a flow field is bound at all.
    float4 params;
    /// xy the flow grid's dimensions in pixels, zw unused.
    float4 geometry;
};

/// Interpolates one plane — luma or chroma — between two source frames.
///
/// Plane-agnostic on purpose. Luma arrives as a one-channel texture and chroma
/// as two, at half or full height depending on the subsampling, and both are
/// read and written through normalised coordinates, so the same kernel covers
/// 4:2:0 and 4:2:2 and both 8-bit and 10-bit without knowing which it has. That
/// is also why the result can be written back into a buffer of the source's own
/// format: nothing downstream — grading, masks, the Log and HDR paths — learns
/// that the frame was made rather than decoded.
kernel void retimeInterpolatePlane(
    texture2d<float, access::sample> planeA [[texture(0)]],
    texture2d<float, access::sample> planeB [[texture(1)]],
    texture2d<float, access::sample> flowForward [[texture(2)]],
    texture2d<float, access::sample> flowBackward [[texture(3)]],
    texture2d<float, access::write> destination [[texture(4)]],
    constant RetimeUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float t = clamp(u.params.x, 0.0, 1.0);

    // float4 throughout, so one kernel covers a one-channel luma plane, a
    // two-channel chroma plane and the four-channel half-float surface the HDR
    // path carries. A write to a narrower texture simply drops the components
    // that are not there.
    float4 a = planeA.sample(retimeSampler, uv);
    float4 b = planeB.sample(retimeSampler, uv);
    float4 dissolve = mix(a, b, t);

    if (u.params.w < 0.5 || is_null_texture(flowForward)) {
        destination.write(dissolve, p);
        return;
    }

    // The flow grid is a downscale of the picture, and a displacement is
    // measured in ITS pixels — so a vector becomes a normalised offset by
    // dividing through by the grid, never by the plane. The chroma plane is
    // subsampled and would give a different, wrong answer.
    float2 grid = max(u.geometry.xy, float2(1.0));
    float4 forward = flowForward.sample(retimeSampler, uv);
    float4 backward = flowBackward.sample(retimeSampler, uv);
    float2 F = forward.xy / grid;
    float2 G = backward.xy / grid;

    // ## Each side is warped by its OWN field, and trusted separately
    //
    // The obvious version reads both frames through the forward field: pull A
    // back by `t*F` and push B on by `(1-t)*F`. It is wrong wherever something
    // is uncovered. Behind a moving object the forward field says "nothing
    // moved here" — which is true of the background in A — and the B-side read
    // then lands inside the object in B and drags it along, leaving a copy of
    // it smeared across the ground it just left.
    //
    // Reading B through the BACKWARD field instead asks a different question:
    // where did the content now at this pixel come from? Behind the object
    // that answers correctly, because the backward field does know the object
    // moved. Each side is then believed only where its own field is
    // self-consistent, and at an edge exactly one of them is — which is what
    // removes the second copy instead of fading it.
    float2 forwardCheck = flowBackward.sample(retimeSampler, uv + F).xy;
    float2 backwardCheck = flowForward.sample(retimeSampler, uv + G).xy;
    float limit = max(u.params.y, 0.001);
    float costLimit = max(u.params.z, 0.0001);
    float trustA = saturate(1.0 - length(forward.xy + forwardCheck) / limit)
                 * saturate(1.0 - forward.z / costLimit);
    float trustB = saturate(1.0 - length(backward.xy + backwardCheck) / limit)
                 * saturate(1.0 - backward.z / costLimit);

    float4 sampleA = planeA.sample(retimeSampler, uv - F * t);
    float4 sampleB = planeB.sample(retimeSampler, uv - G * (1.0 - t));

    // Time weighting and trust in one sum: where both sides are equally
    // believed this is exactly `mix(sampleA, sampleB, t)`, and where one is not
    // believed at all the other carries the pixel on its own.
    float weightA = trustA * (1.0 - t);
    float weightB = trustB * t;
    float total = weightA + weightB;
    float4 warped = total > 1e-4 ? (sampleA * weightA + sampleB * weightB) / total : dissolve;
    float trust = max(trustA, trustB);

    // The ladder. Where neither side is trusted a dissolve is used, and where
    // even a dissolve would show two of something, the nearer frame is used
    // alone — soft beats doubled.
    float4 nearest = (t < 0.5) ? a : b;
    float4 safe = mix(nearest, dissolve, smoothstep(0.0, 0.35, trust));
    float4 result = mix(safe, warped, smoothstep(0.30, 0.75, trust));
    destination.write(result, p);
}

/// Converts a luma plane of any supported depth into the single-channel float
/// texture the motion search expects.
///
/// The search reads `.r` and compares patches, so it needs one consistent
/// representation; handing it a 10-bit plane in one clip and an 8-bit one in
/// the next would change the meaning of the match-cost limit between them.
kernel void retimePrepareLuma(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant float4 &weights [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float4 c = source.sample(retimeSampler, uv);
    // w selects the source layout: a YUV luma plane already IS luminance and is
    // taken as it is, while the HDR path's RGBA surface has to be reduced to
    // one. Matching on the picture's colour rather than its brightness would
    // make the search chase chroma noise.
    float value = (weights.w > 0.5) ? dot(c.rgb, weights.rgb) : c.r;
    destination.write(float4(value, 0.0, 0.0, 1.0), p);
}
