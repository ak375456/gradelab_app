#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Video scopes: analysis and visualisation.
//
// Input is the small analysis texture produced by the `scopeSample*` kernels in
// Shaders.metal, which hold the FINAL GRADED image — look/LUT, light, colour,
// curves, HSL, wheels and vignette all applied. Nothing here re-implements any
// grading maths, so a scope cannot drift from the picture.
//
// Counting is done with atomics into a plain buffer rather than into a texture,
// because Metal has no atomic texture writes. The visualisation then reads that
// buffer from a fragment shader, so the density never leaves the GPU: there is
// no readback, no `waitUntilCompleted`, and nothing for the CPU to iterate.
// ---------------------------------------------------------------------------

struct ScopeUniforms {
    uint width;         // analysis texture width
    uint height;        // analysis texture height
    uint bins;          // levels resolved on the value axis (256)
    uint cells;         // vectorscope grid resolution
    float intensity;    // user gain on the density mapping
    float kR;           // luma coefficients for the working colour space
    float kG;
    float kB;
    float chromaScale;  // 1 / radius of a fully saturated primary
};

inline float scopeLuma(float3 rgb, constant ScopeUniforms &u) {
    return dot(rgb, float3(u.kR, u.kG, u.kB));
}

inline uint scopeBin(float value, uint bins) {
    return uint(clamp(value, 0.0, 1.0) * float(bins - 1) + 0.5);
}

// --- Analysis -------------------------------------------------------------

// 256 bins per channel, laid out R then G then B. A bin can hold at most the
// pixel count of the analysis texture — around 150,000 — so a 32-bit counter
// cannot overflow however flat the frame is.
kernel void scopeHistogram(
    texture2d<float, access::read> analysis [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeUniforms &u [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= u.width || position.y >= u.height) { return; }
    float3 rgb = analysis.read(position).rgb;
    for (uint channel = 0; channel < 3; ++channel) {
        uint bin = scopeBin(rgb[channel], u.bins);
        atomic_fetch_add_explicit(&bins[channel * u.bins + bin], 1u, memory_order_relaxed);
    }
}

// A waveform is NOT a histogram: the horizontal axis stays the image's own
// horizontal axis, so a bright area on the right of the frame reads on the
// right of the scope. Every column of the analysis texture becomes a column of
// the density map, and each pixel adds one count at its luma height.
kernel void scopeWaveform(
    texture2d<float, access::read> analysis [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeUniforms &u [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= u.width || position.y >= u.height) { return; }
    float luma = scopeLuma(analysis.read(position).rgb, u);
    atomic_fetch_add_explicit(&bins[position.x * u.bins + scopeBin(luma, u.bins)], 1u, memory_order_relaxed);
}

// Three waveforms, one per channel, each keeping its own horizontal position.
kernel void scopeParade(
    texture2d<float, access::read> analysis [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeUniforms &u [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= u.width || position.y >= u.height) { return; }
    float3 rgb = analysis.read(position).rgb;
    uint plane = u.width * u.bins;
    for (uint channel = 0; channel < 3; ++channel) {
        uint index = channel * plane + position.x * u.bins + scopeBin(rgb[channel], u.bins);
        atomic_fetch_add_explicit(&bins[index], 1u, memory_order_relaxed);
    }
}

// Vectorscope: hue as angle, saturation as radius, brightness discarded.
//
// The chroma pair is the non-constant-luminance Y'CbCr difference of the
// working colour space — Cb = (B-Y)/(2(1-kB)), Cr = (R-Y)/(2(1-kR)) — which is
// the transform broadcast vectorscopes are defined on, not an invented
// difference of channels. Cb runs right, Cr runs up, which puts pure red near
// 104 degrees exactly as a Rec.709 graticule expects.
//
// `chromaScale` normalises so a fully saturated primary reaches the outer
// circle; anything beyond it is clamped to the boundary rather than being
// allowed to rescale the whole display.
kernel void scopeVectorscope(
    texture2d<float, access::read> analysis [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    constant ScopeUniforms &u [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= u.width || position.y >= u.height) { return; }
    float3 rgb = clamp(analysis.read(position).rgb, 0.0, 1.0);
    float y = scopeLuma(rgb, u);
    float cb = (rgb.b - y) / (2.0 * (1.0 - u.kB));
    float cr = (rgb.r - y) / (2.0 * (1.0 - u.kR));
    float2 point = float2(cb, cr) * u.chromaScale;
    float radius = length(point);
    if (radius > 1.0) { point /= radius; }
    uint2 cell = uint2(clamp((point * 0.5 + 0.5) * float(u.cells), 0.0, float(u.cells - 1)));
    atomic_fetch_add_explicit(&bins[cell.y * u.cells + cell.x], 1u, memory_order_relaxed);
}

// One shared peak for every scope, so channels stay comparable: normalising each
// channel separately would make a colour cast look balanced.
kernel void scopeMaximum(
    device const uint *bins [[buffer(0)]],
    device atomic_uint *peak [[buffer(1)]],
    constant uint &count [[buffer(2)]],
    uint index [[thread_position_in_grid]])
{
    if (index >= count) { return; }
    atomic_fetch_max_explicit(peak, bins[index], memory_order_relaxed);
}

// --- Visualisation --------------------------------------------------------

struct ScopeRaster {
    float4 position [[position]];
    float2 uv;
};

vertex ScopeRaster scopeVertex(uint id [[vertex_id]]) {
    // One oversized triangle: no vertex buffer, no geometry to keep alive.
    float2 corner = float2((id << 1) & 2, id & 2);
    ScopeRaster out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

// Density → brightness. A raw ratio is unreadable: one flat sky can hold orders
// of magnitude more samples than the detail around it. The cube root keeps sparse
// traces visible without letting a single dense bin wash the scope out.
inline float scopeDensity(uint value, uint peak, float intensity) {
    if (value == 0 || peak == 0) { return 0.0; }
    return saturate(pow(float(value) / float(peak), 0.34) * intensity);
}

fragment float4 scopeHistogramFragment(
    ScopeRaster in [[stage_in]],
    device const uint *bins [[buffer(0)]],
    device const uint *peak [[buffer(1)]],
    constant ScopeUniforms &u [[buffer(2)]])
{
    uint bin = min(u.bins - 1, uint(in.uv.x * float(u.bins)));
    float level = 1.0 - in.uv.y;
    float3 colour = 0.0;
    const float3 channelTint[3] = {
        float3(1.0, 0.22, 0.24), float3(0.28, 1.0, 0.36), float3(0.34, 0.52, 1.0)
    };
    for (uint channel = 0; channel < 3; ++channel) {
        float height = scopeDensity(bins[channel * u.bins + bin], peak[0], u.intensity);
        // A soft edge instead of a hard step, so a single-bin spike still reads.
        float coverage = smoothstep(level + 0.012, level - 0.012, height);
        colour += channelTint[channel] * coverage * 0.72;
    }
    return float4(colour, 1.0);
}

fragment float4 scopeWaveformFragment(
    ScopeRaster in [[stage_in]],
    device const uint *bins [[buffer(0)]],
    device const uint *peak [[buffer(1)]],
    constant ScopeUniforms &u [[buffer(2)]])
{
    uint column = min(u.width - 1, uint(in.uv.x * float(u.width)));
    uint bin = min(u.bins - 1, uint((1.0 - in.uv.y) * float(u.bins)));
    float density = scopeDensity(bins[column * u.bins + bin], peak[0], u.intensity);
    return float4(float3(0.62, 1.0, 0.72) * density, 1.0);
}

fragment float4 scopeParadeFragment(
    ScopeRaster in [[stage_in]],
    device const uint *bins [[buffer(0)]],
    device const uint *peak [[buffer(1)]],
    constant ScopeUniforms &u [[buffer(2)]])
{
    // Three panels side by side, with a thin gutter so they read separately.
    float section = in.uv.x * 3.0;
    uint channel = min(2u, uint(section));
    float local = section - float(channel);
    if (local < 0.012 || local > 0.988) { return float4(0.0, 0.0, 0.0, 1.0); }
    uint column = min(u.width - 1, uint(local * float(u.width)));
    uint bin = min(u.bins - 1, uint((1.0 - in.uv.y) * float(u.bins)));
    uint plane = u.width * u.bins;
    float density = scopeDensity(bins[channel * plane + column * u.bins + bin], peak[0], u.intensity);
    const float3 channelTint[3] = {
        float3(1.0, 0.30, 0.32), float3(0.36, 1.0, 0.44), float3(0.42, 0.58, 1.0)
    };
    return float4(channelTint[channel] * density, 1.0);
}

fragment float4 scopeVectorscopeFragment(
    ScopeRaster in [[stage_in]],
    device const uint *bins [[buffer(0)]],
    device const uint *peak [[buffer(1)]],
    constant ScopeUniforms &u [[buffer(2)]])
{
    float2 point = in.uv * 2.0 - 1.0;
    point.y = -point.y;
    if (length(point) > 1.0) { return float4(0.0, 0.0, 0.0, 1.0); }
    uint2 cell = uint2(clamp((point * 0.5 + 0.5) * float(u.cells), 0.0, float(u.cells - 1)));
    float density = scopeDensity(bins[cell.y * u.cells + cell.x], peak[0], u.intensity);
    return float4(float3(0.66, 1.0, 0.80) * density, 1.0);
}
