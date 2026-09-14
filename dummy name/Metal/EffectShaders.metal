#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Spatial finishing effects: sharpen, bloom, glow, halation.
//
// These need the pixels around them, and the three glows need a wide blur, so
// they cannot live in the grading functions the way fade and grain do. They run
// as a post-grade pass over the graded frame instead.
//
// The blur is separable and runs at quarter resolution. A glow is low-frequency
// by definition, so the resolution it is built at is not visible in the result,
// and a quarter-res pass is sixteen times less work than a full-res one.
//
// The stage is used by preview, export and both compositors, so what is seen is
// what is written.
// ---------------------------------------------------------------------------

struct EffectUniforms {
    float sharpness;
    float bloom;
    float glow;
    float halation;
    /// Below this the blur seed keeps nothing. Diffuse white is 1.0 in both the
    /// SDR encoded signal and the HDR working space, so one threshold serves
    /// both.
    float bloomThreshold;
    /// 1 when the frame is HDR working space, where values run above 1.0.
    float extendedRange;
    /// Texel step for the blur, in normalised coordinates.
    float2 step;
};

constant float3 kLumaRec709 = float3(0.2126, 0.7152, 0.0722);

// Quarter-resolution seed for the glows.
//
// Two things are carried: the whole image, which `glow` diffuses, and the part
// above the threshold, which `bloom` and `halation` bleed. Keeping both in one
// texture means one blur pyramid serves all three rather than three.
kernel void effectPrepare(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> seed [[texture(1)]],
    constant EffectUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= seed.get_width() || position.y >= seed.get_height()) { return; }
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(seed.get_width(), seed.get_height());
    // A 2x2 tap of the full-res image: at quarter resolution a single bilinear
    // sample would step over three pixels out of four and make the glow crawl.
    float3 colour = 0.0;
    for (int j = 0; j < 2; ++j) {
        for (int i = 0; i < 2; ++i) {
            float2 offset = (float2(i, j) - 0.5) * u.step * 0.5;
            colour += source.sample(linearSampler, uv + offset).rgb;
        }
    }
    colour *= 0.25;
    float luma = dot(max(colour, 0.0), kLumaRec709);
    // Soft knee rather than a hard cut, so a highlight rolling past the
    // threshold does not switch its halo on in one frame.
    float excess = smoothstep(u.bloomThreshold, u.bloomThreshold + 0.35, luma);
    seed.write(float4(colour * excess, luma), position);
}

// One direction of a separable Gaussian. Run twice for a two-dimensional blur,
// and the caller runs the pair more than once to widen the radius without
// paying for more taps.
kernel void effectBlur(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant EffectUniforms &u [[buffer(0)]],
    constant float2 &direction [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    // Nine-tap Gaussian using linear-filter tap pairs, which reaches the same
    // support as seventeen point samples.
    const float weights[5] = { 0.2270270270, 0.1945945946, 0.1216216216, 0.0540540541, 0.0162162162 };
    const float offsets[5] = { 0.0, 1.4545454545, 3.2307692308, 5.1764705882, 7.1333333333 };
    float4 sum = source.sample(linearSampler, uv) * weights[0];
    for (int i = 1; i < 5; ++i) {
        float2 delta = direction * u.step * offsets[i];
        sum += source.sample(linearSampler, uv + delta) * weights[i];
        sum += source.sample(linearSampler, uv - delta) * weights[i];
    }
    destination.write(sum, position);
}

// Full resolution: sharpening against the graded frame itself, and the three
// glows against the blur.
//
// The body lives in `effectComposeAt` so that the tiled still-image path can run
// the identical arithmetic while reading its halo at a different coordinate —
// see `effectCompositeTile`. There is one implementation of these four effects,
// not two.
//
// `uv` locates the pixel in `source`; `blurUV` locates it in `blurred`. For a
// whole frame they are the same coordinate. For one tile of a large photograph
// they are not: the tile holds a piece of the picture while the halo covers all
// of it, and using the tile's own coordinate against a whole-image halo would
// repeat the glow inside every tile.
inline float4 effectComposeAt(
    texture2d<float, access::sample> source,
    texture2d<float, access::sample> blurred,
    float2 uv,
    float2 blurUV,
    constant EffectUniforms &u)
{
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 centre = source.sample(linearSampler, uv);
    float3 colour = centre.rgb;

    // Unsharp mask against the four neighbours. A one-pixel radius is what keeps
    // this reading as detail rather than as an outline.
    if (u.sharpness > 0.0) {
        float3 neighbours =
            source.sample(linearSampler, uv + float2(u.step.x, 0)).rgb +
            source.sample(linearSampler, uv - float2(u.step.x, 0)).rgb +
            source.sample(linearSampler, uv + float2(0, u.step.y)).rgb +
            source.sample(linearSampler, uv - float2(0, u.step.y)).rgb;
        colour += (colour - neighbours * 0.25) * u.sharpness * 1.6;
    }

    float4 halo = blurred.sample(linearSampler, blurUV);

    // Bloom and glow are additive light: bright areas bleed outward, they do not
    // replace what is under them.
    colour += halo.rgb * u.bloom * 0.9;

    if (u.glow > 0.0) {
        // Glow diffuses the whole image, not only the highlights, so it uses the
        // blurred luma the seed carried alongside the thresholded colour.
        float3 diffuse = float3(halo.a);
        colour = mix(colour, max(colour, diffuse), u.glow * 0.55);
    }

    // Halation is red-weighted because that is what it is: long-wavelength light
    // passes through the emulsion, scatters off the back of the base and
    // re-exposes it, so the halo film gets around a bright edge is orange-red.
    if (u.halation > 0.0) {
        float3 tint = float3(1.0, 0.34, 0.12);
        colour += halo.rgb * tint * u.halation * 1.5;
    }

    // SDR is a display signal and has a ceiling; HDR working space does not, and
    // clamping there would throw away the range the pipeline exists to keep.
    if (u.extendedRange < 0.5) { colour = saturate(colour); }
    return float4(max(colour, u.extendedRange > 0.5 ? -65504.0 : 0.0), centre.a);
}

kernel void effectComposite(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::sample> blurred [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant EffectUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    destination.write(effectComposeAt(source, blurred, uv, uv, u), position);
}

// One tile of a full-resolution still, composited against a halo that was blurred
// over the WHOLE picture.
//
// Building the blur per tile would be wrong twice over: each tile's halo would
// stop at its own edge, leaving a seam, and the radius would be a fraction of a
// tile rather than of the picture, so the glow would shrink as the export got
// larger. Blurring once over the whole image removes both problems, and the
// composite here is the same function the whole-frame path uses.
//
// tile = (originX, originY, imageWidth, imageHeight), in pixels.
kernel void effectCompositeTile(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::sample> blurred [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant EffectUniforms &u [[buffer(0)]],
    constant float4 &tile [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    float2 blurUV = (float2(position) + tile.xy + 0.5) / tile.zw;
    destination.write(effectComposeAt(source, blurred, uv, blurUV, u), position);
}

// Copies a finished frame into an 8-bit display surface.
kernel void effectWriteBGRA(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    destination.write(float4(saturate(source.read(position).rgb), 1.0), position);
}
