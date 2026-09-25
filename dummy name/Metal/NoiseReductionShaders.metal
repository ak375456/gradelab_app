#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Noise Reduction
//
// Everything here works on two planes — a full-resolution luma and a
// half-resolution chroma — and knows nothing about colour spaces. The
// conversion into and out of those planes lives in Shaders.metal beside the
// rest of the colour science, so there is exactly one copy of it and a Log
// frame, an HLG frame and an SDR frame reach this file in the same shape.
//
// The stages, in the order they run:
//
//   guide        a low-passed copy of the picture, plus how much high-frequency
//                energy each region carries. Every later decision is made on
//                the guide rather than on raw pixels, because a decision made
//                on raw pixels is a decision made on the noise.
//   noise field  a per-tile estimate of the noise FLOOR, taken as the smallest
//                of a tile's sub-block energies rather than the average. A
//                tile full of hair has high average energy and a low floor,
//                which is the distinction the whole engine turns on.
//   flow         pyramidal motion estimation between the current frame and each
//                neighbour, run in both directions.
//   temporal     a weighted combination of motion-compensated neighbours, with
//                every sample tested for occlusion before it is believed.
//   spatial      a fast guided filter on luma and a luma-guided bilateral on
//                chroma.
//   recovery     the difference the filtering removed, put back wherever it was
//                too large to have been noise.
//
// Nothing here is random and nothing depends on wall-clock time or on which
// frames happen to have been decoded, so the same frame with the same settings
// produces the same pixels every time it is rendered.
// ---------------------------------------------------------------------------

struct NoiseUniforms {
    /// x temporal luma, y temporal chroma, z motion tolerance in sigmas,
    /// w detail protection.
    float4 temporal;
    /// x spatial luma, y spatial chroma, z radius in pixels, w edge protection.
    float4 spatial;
    /// x detail recovery, y coring in sigmas, z shadow bias, w chroma radius.
    float4 detail;
    /// x frame count, y distance falloff, z noise floor, w noise ceiling.
    float4 window;
    /// xyz luma weights, w 1 for extended-range input.
    float4 luma;
    /// xy one luma texel, zw one chroma texel.
    float4 geometry;
    /// xy one flow texel, zw the flow grid's dimensions.
    float4 flow;
};

/// One accumulated neighbour.
struct TemporalSample {
    float offset;
    float distanceWeight;
    float usesFlow;
    float consistencyLimit;
};

constexpr sampler nrSampler(coord::normalized, address::clamp_to_edge, filter::linear);

/// Mean absolute deviation to standard deviation, for a Gaussian.
constant float kMADToSigma = 1.2533;

/// The most a neighbour may be trusted.
///
/// A sample that survived the occlusion test and matches the current frame is
/// as good evidence about this scene point as the current frame is, so it is
/// allowed a full vote. What decides how much a frame counts is its distance —
/// alignment gets less reliable the further out the window reaches — and that
/// is applied separately, per frame, rather than as a blanket discount here.
constant float kMaxSampleWeight = 1.0;

inline bool insideUnit(float2 uv) {
    return uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
}

/// How much harder to work in the shadows.
///
/// Sensor noise is strongest where there is least signal, so the strengths are
/// scaled up through the blacks and eased down through the highlights. Smooth
/// on purpose: a hard split would put a visible seam across a gradient, which
/// is a worse artefact than the noise it removed.
///
/// Pinned to exactly 1 at a midtone. An earlier form eased down from the
/// blacks, which meant the sliders never delivered what they said anywhere
/// except in shadow — the control read as weak, and the measured reduction on
/// a mid-grey was well short of what five frames should give. The bias is a
/// redistribution around the midtone, not a discount from it.
inline float shadowWeight(float value, float bias) {
    float t = smoothstep(0.0, 0.9, value);
    return max(1.0 + bias * (1.0 - 2.0 * t), 0.25);
}

/// 1 where the region is indistinguishable from noise, falling toward 0 where
/// it carries real structure.
///
/// `energy` is the guide's local high-frequency measure and `sigma` the noise
/// floor, so their ratio is "how many times more detail is here than noise
/// alone would explain".
///
/// The ramp starts at 1.4 rather than at 1, and that offset is not a fudge. The
/// floor is a MINIMUM — of the quietest quarter of a tile, then of the quietest
/// tile nearby — so on a frame of nothing but noise the local energy is
/// systematically a little above it. Ramping from 1 would therefore read plain
/// noise as texture and hold the reduction back everywhere, which is exactly
/// what a measured five-frame window falling short of its arithmetic turned out
/// to be. Real texture clears 1.4 immediately.
inline float structureProtection(float energy, float sigma, float protection) {
    float ratio = energy / max(sigma, 1e-5);
    return 1.0 - protection * saturate((ratio - 1.4) / 2.6);
}

// ---------------------------------------------------------------------------
// Guide and noise field
// ---------------------------------------------------------------------------

/// The low-passed picture and its local high-frequency energy, at half
/// resolution.
///
/// Half resolution is not a shortcut. The guide exists to answer "is this the
/// same thing as that", and asking it of individual noisy pixels is what makes
/// naive denoisers mistake noise for motion. Every tap is already a bilinear
/// average of four full-resolution pixels, and the 3x3 on top of that gives an
/// effective 6x6 support — wide enough that sensor noise has largely cancelled
/// and narrow enough that a moving edge still reads as one.
kernel void nrBuildGuide(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d<float, access::write> guide [[texture(2)]],
    constant NoiseUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = guide.get_width(), height = guide.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float2 step = u.geometry.xy;

    float taps[9];
    float mean = 0.0;
    uint index = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float value = luma.sample(nrSampler, uv + float2(dx, dy) * step).r;
            taps[index++] = value;
            mean += value;
        }
    }
    mean /= 9.0;
    float deviation = 0.0;
    for (uint i = 0; i < 9; ++i) { deviation += abs(taps[i] - mean); }
    deviation = deviation / 9.0 * kMADToSigma;

    // Chroma is measured on its own plane, which is already a 2x2 average of
    // the source and therefore already a guide.
    float2 chromaStep = u.geometry.zw;
    float2 chromaMean = 0.0;
    float2 chromaTaps[9];
    index = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 value = chroma.sample(nrSampler, uv + float2(dx, dy) * chromaStep).rg;
            chromaTaps[index++] = value;
            chromaMean += value;
        }
    }
    chromaMean /= 9.0;
    float chromaDeviation = 0.0;
    for (uint i = 0; i < 9; ++i) { chromaDeviation += length(chromaTaps[i] - chromaMean); }
    chromaDeviation = chromaDeviation / 9.0 * kMADToSigma;

    guide.write(float4(mean, deviation, chromaDeviation, 0.0), p);
}

/// The noise floor, per tile.
///
/// Each output texel covers an 8x8 block of the guide, and what is written is
/// the SMALLEST of that block's four quadrant energies — not the average. That
/// one choice is what separates a noise estimate from a texture measurement: a
/// tile containing hair against a wall has a high average energy and a low
/// minimum, and the wall is the part that tells the truth about the sensor.
/// Erodes the tile estimates into a local noise FLOOR.
///
/// The tile estimate above is the quietest quarter of a 16x16 block, which is
/// the right measurement everywhere except in a region that is textured all the
/// way through — hair, grass, fine fabric, a page of text. There, every block
/// contains structure and the "quietest" one is still measuring the texture.
///
/// That failure is not neutral, it is backwards: the protection that keeps
/// texture from being smoothed is the ratio of local energy to the noise floor,
/// so a floor inflated by the texture reports a ratio of one — "this is
/// nothing but noise" — for precisely the regions that most need protecting.
/// It cost a measured Detail Recovery pass its entire effect, and it would have
/// cost hair and grass their detail.
///
/// Taking the minimum over a neighbourhood of tiles fixes it, because noise is
/// a property of the sensor and the exposure rather than of the subject: it
/// does not vary from the hair to the wall behind it, and a hundred pixels in
/// any direction almost always reaches something flatter. Erring low is also
/// the safe direction — an underestimate reduces less, an overestimate destroys
/// detail.
kernel void nrNoiseFloor(
    texture2d<float, access::sample> field [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 size = float2(width, height);
    float2 uv = (float2(p) + 0.5) / size;
    float2 step = 1.0 / size;

    float4 centre = field.sample(nrSampler, uv);
    float lumaFloor = centre.x, chromaFloor = centre.y;
    for (int dy = -3; dy <= 3; ++dy) {
        for (int dx = -3; dx <= 3; ++dx) {
            float4 tile = field.sample(nrSampler, uv + float2(dx, dy) * step);
            lumaFloor = min(lumaFloor, tile.x);
            chromaFloor = min(chromaFloor, tile.y);
        }
    }
    // Brightness stays local: it is what the shadow weighting reads, and that
    // has to describe this part of the picture rather than the darkest part
    // within a hundred pixels.
    destination.write(float4(lumaFloor, chromaFloor, centre.z, 0.0), p);
}

kernel void nrNoiseField(
    texture2d<float, access::sample> guide [[texture(0)]],
    texture2d<float, access::write> field [[texture(1)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = field.get_width(), height = field.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 guideSize = float2(guide.get_width(), guide.get_height());
    float2 origin = float2(p) * 8.0;

    float quadrantLuma[4] = { 0.0, 0.0, 0.0, 0.0 };
    float quadrantChroma[4] = { 0.0, 0.0, 0.0, 0.0 };
    float brightness = 0.0;
    for (int y = 0; y < 8; ++y) {
        for (int x = 0; x < 8; ++x) {
            float2 uv = (origin + float2(x, y) + 0.5) / guideSize;
            float4 g = guide.sample(nrSampler, uv);
            uint quadrant = uint(y / 4) * 2u + uint(x / 4);
            quadrantLuma[quadrant] += g.y;
            quadrantChroma[quadrant] += g.z;
            brightness += g.x;
        }
    }
    float lumaSigma = quadrantLuma[0];
    float chromaSigma = quadrantChroma[0];
    for (uint i = 1; i < 4; ++i) {
        lumaSigma = min(lumaSigma, quadrantLuma[i]);
        chromaSigma = min(chromaSigma, quadrantChroma[i]);
    }
    field.write(float4(lumaSigma / 16.0, chromaSigma / 16.0, brightness / 64.0, 0.0), p);
}

// ---------------------------------------------------------------------------
// Motion estimation
// ---------------------------------------------------------------------------

/// Half-size box reduction with a light Gaussian weighting. Builds every level
/// of the matching pyramid, and also takes the frame down to the grid motion is
/// estimated on in the first place.
kernel void nrDownsampleLuma(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float2 step = 1.0 / float2(source.get_width(), source.get_height());
    // A 3x3 tent rather than a 2x2 box: aliasing in the matching pyramid shows
    // up as motion that is not there.
    float total = 0.0, weightSum = 0.0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float w = (dx == 0 ? 2.0 : 1.0) * (dy == 0 ? 2.0 : 1.0);
            total += w * source.sample(nrSampler, uv + float2(dx, dy) * step).r;
            weightSum += w;
        }
    }
    destination.write(float4(total / weightSum, 0.0, 0.0, 0.0), p);
}

kernel void nrDownsampleChroma(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float2 step = 0.5 / float2(source.get_width(), source.get_height());
    float2 total = source.sample(nrSampler, uv + float2(-1, -1) * step).rg
                 + source.sample(nrSampler, uv + float2( 1, -1) * step).rg
                 + source.sample(nrSampler, uv + float2(-1,  1) * step).rg
                 + source.sample(nrSampler, uv + float2( 1,  1) * step).rg;
    destination.write(float4(total * 0.25, 0.0, 0.0), p);
}

/// Patch difference between the two frames at one candidate displacement.
///
/// A 3x3 patch rather than a single pixel, because a single noisy pixel matches
/// a great many places equally well and block matching on one sample produces a
/// field of confident nonsense.
inline float patchCost(
    texture2d<float, access::sample> current,
    texture2d<float, access::sample> neighbour,
    float2 uv, float2 step, float2 displacement)
{
    float cost = 0.0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 offset = float2(dx, dy) * step;
            float a = current.sample(nrSampler, uv + offset).r;
            float b = neighbour.sample(nrSampler, uv + offset + displacement).r;
            cost += abs(a - b);
        }
    }
    return cost / 9.0;
}

/// One level of the coarse-to-fine search.
///
/// `params.x` is the search radius in this level's own pixels, `params.y` the
/// factor the seed field is scaled by on the way in (two when it arrives from
/// the level above, since a displacement measured there covers twice as much
/// ground here), and `params.z` the penalty that biases the result toward the
/// seed. The penalty is what keeps a flat, featureless region — where every
/// candidate matches equally well — from being assigned whichever displacement
/// noise happened to favour.
kernel void nrFlowSearch(
    texture2d<float, access::sample> current [[texture(0)]],
    texture2d<float, access::sample> neighbour [[texture(1)]],
    texture2d<float, access::sample> seed [[texture(2)]],
    texture2d<float, access::write> flow [[texture(3)]],
    constant float4 &params [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = flow.get_width(), height = flow.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 size = float2(width, height);
    float2 uv = (float2(p) + 0.5) / size;
    float2 step = 1.0 / size;

    float2 base = float2(0.0);
    if (!is_null_texture(seed)) {
        base = seed.sample(nrSampler, uv).xy * params.y;
    }

    int radius = int(params.x);
    float penalty = params.z;
    float2 best = base;
    float bestCost = patchCost(current, neighbour, uv, step, base * step) ;
    for (int dy = -radius; dy <= radius; ++dy) {
        for (int dx = -radius; dx <= radius; ++dx) {
            if (dx == 0 && dy == 0) { continue; }
            float2 candidate = base + float2(dx, dy);
            float cost = patchCost(current, neighbour, uv, step, candidate * step)
                       + penalty * (abs(float(dx)) + abs(float(dy)));
            if (cost < bestCost) { bestCost = cost; best = candidate; }
        }
    }
    flow.write(float4(best, bestCost, 0.0), p);
}

/// Vector median over a 3x3 neighbourhood: of the nine candidate vectors, keep
/// the one that is closest to all the others.
///
/// A component-wise median or a blur would both invent vectors that were never
/// measured, which along a motion boundary means inventing a displacement that
/// belongs to neither side. This can only ever return a vector one of the nine
/// pixels actually matched, so an outlier is replaced by its neighbour's
/// answer rather than by an average of two unrelated ones.
kernel void nrFlowSmooth(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 size = float2(width, height);
    float2 uv = (float2(p) + 0.5) / size;
    float2 step = 1.0 / size;

    float4 candidates[9];
    uint index = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            candidates[index++] = source.sample(nrSampler, uv + float2(dx, dy) * step);
        }
    }
    uint bestIndex = 4;
    float bestDistance = INFINITY;
    for (uint i = 0; i < 9; ++i) {
        float distance = 0.0;
        for (uint j = 0; j < 9; ++j) {
            distance += length(candidates[i].xy - candidates[j].xy);
        }
        if (distance < bestDistance) { bestDistance = distance; bestIndex = i; }
    }
    destination.write(candidates[bestIndex], p);
}

// ---------------------------------------------------------------------------
// Temporal combination
// ---------------------------------------------------------------------------

/// How much one aligned neighbour is worth at this pixel.
///
/// Three independent things have to agree before a sample is used at all:
///
///  1. the two motion fields have to describe the same displacement from either
///     end. Where they do not, something is visible in one frame and hidden in
///     the other, which is exactly what an occlusion is;
///  2. the aligned sample has to land inside the frame;
///  3. the low-passed pictures have to actually match there, to within a
///     tolerance measured in this tile's own noise.
///
/// A sample failing any one of them contributes nothing. That is what a
/// scene cut looks like from inside this function — every pixel fails the third
/// test at once — so a cut needs no special case to survive.
inline float sampleWeight(
    float currentGuide, float neighbourGuide,
    float sigma, float tolerance, float confidence, float distanceWeight)
{
    float difference = abs(neighbourGuide - currentGuide);
    float limit = max(tolerance * sigma, 1e-6);
    if (difference > limit * 2.0) { return 0.0; }
    float weight = exp(-(difference * difference) / (2.0 * limit * limit));
    return min(weight * confidence * distanceWeight, kMaxSampleWeight);
}

/// Forward/backward agreement at one pixel, as a 0…1 confidence.
inline float flowConfidence(
    texture2d<float, access::sample> forward,
    texture2d<float, access::sample> backward,
    float2 uv, float4 flowGeometry, float limit, thread float2 &motion)
{
    motion = float2(0.0);
    if (is_null_texture(forward)) { return 1.0; }
    float2 vector = forward.sample(nrSampler, uv).xy;
    motion = vector * flowGeometry.xy;
    if (is_null_texture(backward)) { return 1.0; }
    float2 back = backward.sample(nrSampler, uv + motion).xy;
    // A round trip that returns to where it started describes the same motion
    // from both ends. One that does not means the two frames disagree about
    // what moved, which is what an occlusion looks like from here.
    //
    // The first half texel is free. Motion is estimated on a coarser grid than
    // the picture and interpolated back up, so a disagreement that small is the
    // grid rather than the scene — and charging for it was measurably costing a
    // locked-off shot part of its reduction, because on a flat surface the two
    // searches have nothing to lock onto and wander by a fraction of a texel.
    float error = max(length(vector + back) - 0.5, 0.0);
    return saturate(1.0 - error / max(limit, 0.05));
}

/// The temporal stage for luma. Every neighbour is bound at once and combined
/// in registers, so there is no accumulation buffer and one pass over the frame
/// does the whole window.
kernel void nrTemporalLuma(
    texture2d<float, access::sample> currentLuma [[texture(0)]],
    texture2d<float, access::sample> currentGuide [[texture(1)]],
    texture2d<float, access::sample> field [[texture(2)]],
    texture2d<float, access::sample> luma0 [[texture(3)]],
    texture2d<float, access::sample> luma1 [[texture(4)]],
    texture2d<float, access::sample> luma2 [[texture(5)]],
    texture2d<float, access::sample> luma3 [[texture(6)]],
    texture2d<float, access::sample> guide0 [[texture(7)]],
    texture2d<float, access::sample> guide1 [[texture(8)]],
    texture2d<float, access::sample> guide2 [[texture(9)]],
    texture2d<float, access::sample> guide3 [[texture(10)]],
    texture2d<float, access::sample> forward0 [[texture(11)]],
    texture2d<float, access::sample> forward1 [[texture(12)]],
    texture2d<float, access::sample> forward2 [[texture(13)]],
    texture2d<float, access::sample> forward3 [[texture(14)]],
    texture2d<float, access::sample> backward0 [[texture(15)]],
    texture2d<float, access::sample> backward1 [[texture(16)]],
    texture2d<float, access::sample> backward2 [[texture(17)]],
    texture2d<float, access::sample> backward3 [[texture(18)]],
    texture2d<float, access::write> destination [[texture(19)]],
    constant NoiseUniforms &u [[buffer(0)]],
    constant TemporalSample *samples [[buffer(1)]],
    constant uint &count [[buffer(2)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);

    float centre = currentLuma.sample(nrSampler, uv).r;
    float4 guide = currentGuide.sample(nrSampler, uv);
    float4 noise = field.sample(nrSampler, uv);
    float sigma = clamp(noise.x, u.window.z, u.window.w);

    // The current frame seeds the accumulation with a weight of one, so it can
    // never be outvoted into insignificance however many neighbours agree.
    float sum = centre, total = 1.0;

    for (uint i = 0; i < count && i < 4u; ++i) {
        texture2d<float, access::sample> neighbourLuma =
            i == 0u ? luma0 : i == 1u ? luma1 : i == 2u ? luma2 : luma3;
        texture2d<float, access::sample> neighbourGuide =
            i == 0u ? guide0 : i == 1u ? guide1 : i == 2u ? guide2 : guide3;
        texture2d<float, access::sample> forward =
            i == 0u ? forward0 : i == 1u ? forward1 : i == 2u ? forward2 : forward3;
        texture2d<float, access::sample> backward =
            i == 0u ? backward0 : i == 1u ? backward1 : i == 2u ? backward2 : backward3;
        if (is_null_texture(neighbourLuma)) { continue; }

        TemporalSample s = samples[i];
        float2 motion = float2(0.0);
        float confidence = s.usesFlow > 0.5
            ? flowConfidence(forward, backward, uv, u.flow, s.consistencyLimit, motion)
            : 1.0;
        float2 aligned = uv + motion;
        if (!insideUnit(aligned)) { continue; }

        float weight = sampleWeight(
            guide.x, neighbourGuide.sample(nrSampler, aligned).x,
            sigma, u.temporal.z, confidence, s.distanceWeight);
        if (weight <= 0.0) { continue; }
        sum += weight * neighbourLuma.sample(nrSampler, aligned).r;
        total += weight;
    }

    float combined = sum / total;
    float strength = saturate(u.temporal.x
        * structureProtection(guide.y, sigma, u.temporal.w)
        * shadowWeight(guide.x, u.detail.z));
    destination.write(float4(mix(centre, combined, strength), 0.0, 0.0, 0.0), p);
}

/// The chroma half of the same stage, on the chroma plane's own grid.
///
/// Held apart from luma throughout rather than sharing one weight: colour noise
/// is far coarser and far less structured than luminance noise, so it survives
/// a much wider tolerance and a much stronger blend — which is the whole reason
/// the two controls are separate in the first place.
kernel void nrTemporalChroma(
    texture2d<float, access::sample> currentChroma [[texture(0)]],
    texture2d<float, access::sample> currentGuide [[texture(1)]],
    texture2d<float, access::sample> field [[texture(2)]],
    texture2d<float, access::sample> chroma0 [[texture(3)]],
    texture2d<float, access::sample> chroma1 [[texture(4)]],
    texture2d<float, access::sample> chroma2 [[texture(5)]],
    texture2d<float, access::sample> chroma3 [[texture(6)]],
    texture2d<float, access::sample> guide0 [[texture(7)]],
    texture2d<float, access::sample> guide1 [[texture(8)]],
    texture2d<float, access::sample> guide2 [[texture(9)]],
    texture2d<float, access::sample> guide3 [[texture(10)]],
    texture2d<float, access::sample> forward0 [[texture(11)]],
    texture2d<float, access::sample> forward1 [[texture(12)]],
    texture2d<float, access::sample> forward2 [[texture(13)]],
    texture2d<float, access::sample> forward3 [[texture(14)]],
    texture2d<float, access::sample> backward0 [[texture(15)]],
    texture2d<float, access::sample> backward1 [[texture(16)]],
    texture2d<float, access::sample> backward2 [[texture(17)]],
    texture2d<float, access::sample> backward3 [[texture(18)]],
    texture2d<float, access::write> destination [[texture(19)]],
    constant NoiseUniforms &u [[buffer(0)]],
    constant TemporalSample *samples [[buffer(1)]],
    constant uint &count [[buffer(2)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);

    float2 centre = currentChroma.sample(nrSampler, uv).rg;
    float4 guide = currentGuide.sample(nrSampler, uv);
    float4 noise = field.sample(nrSampler, uv);
    float sigma = clamp(noise.y, u.window.z, u.window.w);

    float2 sum = centre;
    float total = 1.0;

    for (uint i = 0; i < count && i < 4u; ++i) {
        texture2d<float, access::sample> neighbourChroma =
            i == 0u ? chroma0 : i == 1u ? chroma1 : i == 2u ? chroma2 : chroma3;
        texture2d<float, access::sample> neighbourGuide =
            i == 0u ? guide0 : i == 1u ? guide1 : i == 2u ? guide2 : guide3;
        texture2d<float, access::sample> forward =
            i == 0u ? forward0 : i == 1u ? forward1 : i == 2u ? forward2 : forward3;
        texture2d<float, access::sample> backward =
            i == 0u ? backward0 : i == 1u ? backward1 : i == 2u ? backward2 : backward3;
        if (is_null_texture(neighbourChroma)) { continue; }

        TemporalSample s = samples[i];
        float2 motion = float2(0.0);
        float confidence = s.usesFlow > 0.5
            ? flowConfidence(forward, backward, uv, u.flow, s.consistencyLimit, motion)
            : 1.0;
        float2 aligned = uv + motion;
        if (!insideUnit(aligned)) { continue; }

        // Colour is compared on the luminance guide as well as on its own.
        // Two regions that differ in brightness are different regions whatever
        // their hue, and chroma alone is too smooth to notice a cut.
        float4 neighbourGuideValue = neighbourGuide.sample(nrSampler, aligned);
        float2 neighbourValue = neighbourChroma.sample(nrSampler, aligned).rg;
        float structural = abs(neighbourGuideValue.x - guide.x);
        float lumaSigma = clamp(noise.x, u.window.z, u.window.w);
        if (structural > u.temporal.z * lumaSigma * 2.5) { continue; }

        float difference = length(neighbourValue - centre);
        float limit = max(u.temporal.z * sigma * 1.8, 1e-6);
        if (difference > limit * 2.0) { continue; }
        float weight = min(exp(-(difference * difference) / (2.0 * limit * limit))
                           * confidence * s.distanceWeight, kMaxSampleWeight);
        if (weight <= 0.0) { continue; }
        sum += weight * neighbourValue;
        total += weight;
    }

    float2 combined = sum / total;
    // Chroma detail is protected far more weakly than luma: coloured speckle
    // and coloured texture look alike at this resolution, and erring toward
    // cleaning is the right error for colour.
    float strength = saturate(u.temporal.y
        * structureProtection(guide.z, sigma, u.temporal.w * 0.4)
        * shadowWeight(guide.x, u.detail.z));
    destination.write(float4(mix(centre, combined, strength), 0.0, 0.0), p);
}

// ---------------------------------------------------------------------------
// Spatial filtering — luma
//
// A guided filter, run over statistics gathered at a quarter of each edge and
// applied at full resolution. It is a genuinely edge-preserving filter rather
// than a weighted blur: within a region it behaves like a local linear model of
// the picture, so it removes noise without the gradient reversal an aggressive
// bilateral produces at a strong edge, and it costs the same whatever the
// radius because every window is a pair of box sums.
// ---------------------------------------------------------------------------

/// The signal and its square, at the resolution the statistics are gathered on.
kernel void nrGuidedSeed(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float value = luma.sample(nrSampler, uv).r;
    destination.write(float4(value, value * value, 0.0, 0.0), p);
}

/// Separable box sum over the first two channels. `params.x` is the radius in
/// this texture's own texels and `params.yz` the direction.
kernel void nrBoxBlur(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant float4 &params [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 size = float2(width, height);
    float2 uv = (float2(p) + 0.5) / size;
    float2 step = params.yz / size;
    int radius = int(params.x);

    float2 total = float2(0.0);
    for (int i = -radius; i <= radius; ++i) {
        total += source.sample(nrSampler, uv + float(i) * step).rg;
    }
    destination.write(float4(total / float(2 * radius + 1), 0.0, 0.0), p);
}

/// The local linear model: how much of what is here is signal.
///
/// `a` is the variance of the region weighted against the noise it is expected
/// to contain. Where the two are equal the region is noise and `a` goes to
/// zero, which replaces the pixel with its neighbourhood mean; where the
/// variance is far above the noise there is an edge, `a` approaches one, and
/// the pixel is left where it was.
kernel void nrGuidedCoefficients(
    texture2d<float, access::sample> means [[texture(0)]],
    texture2d<float, access::sample> field [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant NoiseUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float2 m = means.sample(nrSampler, uv).rg;
    float variance = max(m.y - m.x * m.x, 0.0);
    float sigma = clamp(field.sample(nrSampler, uv).x, u.window.z, u.window.w);
    // How much variance the noise alone accounts for, scaled by strength: a
    // stronger setting claims more of what it sees as noise.
    float epsilon = sigma * sigma * (0.5 + 12.0 * u.spatial.x);
    // Edge protection widens the gap between "noise" and "structure" rather
    // than capping the strength, so a protected edge stays sharp at every
    // strength instead of softening gradually.
    if (u.spatial.w > 0.5) { epsilon = min(epsilon, variance * 0.85 + sigma * sigma * 0.5); }
    float a = variance / (variance + epsilon + 1e-9);
    destination.write(float4(a, m.x * (1.0 - a), 0.0, 0.0), p);
}

/// The filtered picture, at full resolution.
///
/// The coefficients arrive from the quarter-resolution grid and are interpolated
/// here, which is the standard fast form of the filter: the model is smooth by
/// construction, so sampling it more finely than it was built adds nothing but
/// work.
kernel void nrGuidedApply(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> coefficients [[texture(1)]],
    texture2d<float, access::sample> guide [[texture(2)]],
    texture2d<float, access::sample> field [[texture(3)]],
    texture2d<float, access::write> destination [[texture(4)]],
    constant NoiseUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float value = luma.sample(nrSampler, uv).r;
    float2 model = coefficients.sample(nrSampler, uv).rg;
    float filtered = model.x * value + model.y;

    float4 guideValue = guide.sample(nrSampler, uv);
    float sigma = clamp(field.sample(nrSampler, uv).x, u.window.z, u.window.w);
    float strength = saturate(u.spatial.x
        * structureProtection(guideValue.y, sigma, u.temporal.w)
        * shadowWeight(guideValue.x, u.detail.z));
    destination.write(float4(mix(value, filtered, strength), 0.0, 0.0, 0.0), p);
}

// ---------------------------------------------------------------------------
// Spatial filtering — chroma
// ---------------------------------------------------------------------------

/// Separable cross-bilateral on the chroma plane, guided by the LUMINANCE.
///
/// Guiding colour by brightness is the point: colour noise is low-frequency and
/// wants a wide filter, but a wide filter run on colour alone drags the red of
/// a lip across the skin beside it. The luminance edge is where the real
/// boundary is — at any chroma resolution, and in any subsampling the source
/// arrived in — so it is what decides where the filter is allowed to reach.
kernel void nrChromaFilter(
    texture2d<float, access::sample> chroma [[texture(0)]],
    texture2d<float, access::sample> guide [[texture(1)]],
    texture2d<float, access::sample> field [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    texture2d<float, access::sample> original [[texture(4)]],
    constant NoiseUniforms &u [[buffer(0)]],
    constant float4 &params [[buffer(1)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 size = float2(width, height);
    float2 uv = (float2(p) + 0.5) / size;
    float2 step = params.yz / size;
    int radius = int(params.x);

    float2 centre = chroma.sample(nrSampler, uv).rg;
    float centreGuide = guide.sample(nrSampler, uv).x;
    float sigma = clamp(field.sample(nrSampler, uv).x, u.window.z, u.window.w);
    // How far apart in brightness two pixels may be and still be the same
    // surface. Proportional to the measured noise, so a clean picture holds a
    // tight edge and a noisy one does not mistake its own grain for a boundary.
    float edgeSigma = max(sigma * (u.spatial.w > 0.5 ? 3.0 : 12.0), 1e-4);
    float spatialSigma = max(float(radius) * 0.5, 0.5);

    float2 total = centre;
    float weightSum = 1.0;
    for (int i = -radius; i <= radius; ++i) {
        if (i == 0) { continue; }
        float2 offset = float(i) * step;
        float neighbourGuide = guide.sample(nrSampler, uv + offset).x;
        float difference = neighbourGuide - centreGuide;
        float range = exp(-(difference * difference) / (2.0 * edgeSigma * edgeSigma));
        float spatial = exp(-float(i * i) / (2.0 * spatialSigma * spatialSigma));
        float weight = range * spatial;
        total += weight * chroma.sample(nrSampler, uv + offset).rg;
        weightSum += weight;
    }
    float2 filtered = total / weightSum;
    // Only the second pass blends, and it blends against the plane as it
    // arrived rather than against the half-filtered intermediate it was handed
    // — otherwise the horizontal pass would always be applied at full strength
    // and the Chroma slider would only govern one of the two directions.
    if (params.w > 0.5) {
        float2 source = original.sample(nrSampler, uv).rg;
        destination.write(float4(mix(source, filtered, saturate(u.spatial.y)), 0.0, 0.0), p);
    } else {
        destination.write(float4(filtered, 0.0, 0.0), p);
    }
}

// ---------------------------------------------------------------------------
// Detail recovery
// ---------------------------------------------------------------------------

/// Puts back what the filtering took, minus what was only ever noise.
///
/// This is not a sharpen and is deliberately not built like one. The difference
/// between the original and the denoised frame is exactly the signal that was
/// removed, and it contains both the noise — which was the point — and whatever
/// real detail went with it. Soft-thresholding that difference at a multiple of
/// the measured noise keeps the second and discards the first: a residual small
/// enough to be noise is removed entirely, and everything above it is returned
/// at full amplitude less the threshold, so there is no step where detail
/// suddenly reappears.
kernel void nrDetailRecovery(
    texture2d<float, access::sample> original [[texture(0)]],
    texture2d<float, access::sample> denoised [[texture(1)]],
    texture2d<float, access::sample> field [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    constant NoiseUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = destination.get_width(), height = destination.get_height();
    if (p.x >= width || p.y >= height) { return; }
    float2 uv = (float2(p) + 0.5) / float2(width, height);
    float source = original.sample(nrSampler, uv).r;
    float filtered = denoised.sample(nrSampler, uv).r;
    float sigma = clamp(field.sample(nrSampler, uv).x, u.window.z, u.window.w);

    float residual = source - filtered;
    float threshold = u.detail.y * sigma;
    float cored = sign(residual) * max(abs(residual) - threshold, 0.0);
    // Two tests, not one. The threshold asks whether this particular difference
    // is too large to have been noise; the structure term asks whether this
    // part of the picture had anything worth recovering in the first place.
    //
    // Both are needed. Coring alone returns the tail of the noise everywhere,
    // because a flat area has as many large excursions as it has pixels — which
    // is exactly what a measured flat region did, gaining back half the noise
    // that had just been removed.
    //
    // The structure is measured on the DENOISED picture rather than on the
    // original. That is the whole trick: the original's local energy is its
    // detail and its noise added together, so in a noisy flat area it says
    // "structure" — while the denoised picture has had the noise taken out of
    // it already, so what is left there really is structure or really is
    // nothing.
    float deviation = 0.0;
    float centre = filtered;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            deviation += abs(denoised.sample(nrSampler, uv + float2(dx, dy) * u.geometry.xy).r - centre);
        }
    }
    deviation = deviation / 9.0 * kMADToSigma;
    float structure = saturate((deviation / max(sigma, 1e-5) - 1.0) / 3.0);
    float amount = u.detail.x * (0.12 + 0.88 * structure);
    destination.write(float4(filtered + cored * amount, 0.0, 0.0, 0.0), p);
}
