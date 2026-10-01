#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Relight geometry
//
// The depth that reaches here was estimated a few hundred pixels across and
// temporally fused during analysis. These kernels turn it into the surface
// orientation the light kernel reads, at a "geometry" resolution between the
// analysis grid and the frame:
//
//   relightGuide          a perceptual luminance of the frame being drawn, at
//                         the analysis size and at the geometry size.
//   relightUpsample       joint bilateral upsampling: each geometry pixel takes
//                         depth from the analysis texels around it weighted by
//                         how alike their luminance is. A silhouette in the
//                         picture therefore stays a silhouette in the depth —
//                         a face does not bleed into the wall behind it — which
//                         plain bilinear scaling cannot do. The two stored
//                         frames either side of this moment are blended here.
//   relightNormals        surface orientation from depth slope, rotated into
//                         the upright picture, with one-sided differences at a
//                         depth break so an edge pixel takes the slope of its
//                         own surface rather than of the gap.
//   relightSmoothNormals  edge-aware smoothing, twice: a fine set for hard
//                         light and a broad set for soft light. Neither ever
//                         averages across a depth discontinuity.
//
// Nothing here knows about colour. The light kernel itself is in Shaders.metal,
// beside the mask geometry it shares with the grade.
// ---------------------------------------------------------------------------

struct RelightGeometryUniforms {
    float4 orientU;   // upright u = dot(orientU.xy, uv) + orientU.z
    float4 orientV;   // upright v = dot(orientV.xy, uv) + orientV.z
    float4 shape;     // x upright aspect, y relief, z depth range, w spare
    float4 temporal;  // x blend toward the second stored frame, y luminance sigma, zw spare
};

constant float3 kRelightRec709Luma = float3(0.2126, 0.7152, 0.0722);
constant float3 kRelightBT2020Luma = float3(0.2627, 0.6780, 0.0593);

// A luminance that is roughly perceptual in both representations, so one
// similarity threshold means the same thing on an SDR frame and an HDR one.
inline float relightGuideLuma(float3 rgb, bool extended) {
    if (extended) {
        float y = max(dot(rgb, kRelightBT2020Luma), 0.0);
        return log2(1.0 + 8.0 * y) / log2(9.0);
    }
    return dot(saturate(rgb), kRelightRec709Luma);
}

kernel void relightGuide(
    texture2d<float, access::sample> working [[texture(0)]],
    texture2d<float, access::write> guide [[texture(1)]],
    constant float4 &params [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    if (p.x >= guide.get_width() || p.y >= guide.get_height()) { return; }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(guide.get_width(), guide.get_height());
    bool extended = params.x > 0.5;
    float total = 0.0;
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            float2 uv = (float2(p) + (float2(i, j) + 0.5) / 4.0) / size;
            total += relightGuideLuma(working.sample(s, uv).rgb, extended);
        }
    }
    guide.write(float4(total / 16.0, 0.0, 0.0, 0.0), p);
}

kernel void relightUpsample(
    texture2d<float, access::read> depthA [[texture(0)]],
    texture2d<float, access::read> depthB [[texture(1)]],
    texture2d<float, access::read> guideLow [[texture(2)]],
    texture2d<float, access::read> guideHigh [[texture(3)]],
    texture2d<float, access::write> geometry [[texture(4)]],
    constant RelightGeometryUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    uint width = geometry.get_width(), height = geometry.get_height();
    if (p.x >= width || p.y >= height) { return; }
    int2 low = int2(depthA.get_width(), depthA.get_height());
    float2 position = (float2(p) + 0.5) / float2(width, height) * float2(low) - 0.5;
    int2 base = int2(floor(position));
    float centre = guideHigh.read(p).r;
    float sigma = max(u.temporal.y, 1e-3);
    float phase = saturate(u.temporal.x);

    float weightSum = 0.0, depthSum = 0.0, trustSum = 0.0;
    float nearestDistance = 1e9;
    float2 nearest = float2(0.0);
    for (int j = -1; j <= 2; ++j) {
        for (int i = -1; i <= 2; ++i) {
            int2 tap = base + int2(i, j);
            uint2 q = uint2(clamp(tap, int2(0), low - 1));
            float2 offset = float2(tap) - position;
            float spatial = exp(-dot(offset, offset) / 1.8);
            float difference = guideLow.read(q).r - centre;
            float range = exp(-(difference * difference) / (2.0 * sigma * sigma));
            float2 a = depthA.read(q).rg;
            float2 b = depthB.read(q).rg;
            float2 value = mix(a, b, phase);
            float w = spatial * range * (0.15 + value.y);
            weightSum += w;
            depthSum += w * value.x;
            trustSum += w * value.y;
            float d = dot(offset, offset);
            if (d < nearestDistance) { nearestDistance = d; nearest = value; }
        }
    }
    float2 result = weightSum > 1e-6 ? float2(depthSum, trustSum) / weightSum : nearest;
    geometry.write(float4(result, 0.0, 0.0), p);
}

kernel void relightNormals(
    texture2d<float, access::read> geometry [[texture(0)]],
    texture2d<float, access::write> normals [[texture(1)]],
    constant RelightGeometryUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]])
{
    int2 size = int2(geometry.get_width(), geometry.get_height());
    if (int(p.x) >= size.x || int(p.y) >= size.y) { return; }
    int2 q = int2(p);
    float c = geometry.read(p).r;
    float left = geometry.read(uint2(clamp(q + int2(-1, 0), int2(0), size - 1))).r;
    float right = geometry.read(uint2(clamp(q + int2(1, 0), int2(0), size - 1))).r;
    float up = geometry.read(uint2(clamp(q + int2(0, -1), int2(0), size - 1))).r;
    float down = geometry.read(uint2(clamp(q + int2(0, 1), int2(0), size - 1))).r;
    // One-sided at a break: of the two differences, the smaller is the one
    // along this pixel's own surface.
    float gx = abs(c - left) < abs(right - c) ? c - left : right - c;
    float gy = abs(c - up) < abs(down - c) ? c - up : down - c;
    float2 perUV = float2(gx * float(size.x), gy * float(size.y));
    // Into the upright picture. The orientation is a rotation or reflection,
    // so the gradient transforms by the same matrix the coordinates do.
    float2 upright = float2(dot(u.orientU.xy, perUV), dot(u.orientV.xy, perUV));
    float aspect = max(u.shape.x, 1e-3);
    float slope = u.shape.y * u.shape.z;
    float3 normal = normalize(float3(-slope * upright.x / aspect, -slope * upright.y, 1.0));
    float discontinuity = max(max(abs(c - left), abs(right - c)), max(abs(c - up), abs(down - c)));
    float edge = smoothstep(0.012, 0.05, discontinuity);
    normals.write(float4(normal, edge), p);
}

kernel void relightSmoothNormals(
    texture2d<float, access::read> raw [[texture(0)]],
    texture2d<float, access::read> geometry [[texture(1)]],
    texture2d<float, access::write> sharp [[texture(2)]],
    texture2d<float, access::write> soft [[texture(3)]],
    uint2 p [[thread_position_in_grid]])
{
    int2 size = int2(raw.get_width(), raw.get_height());
    if (int(p.x) >= size.x || int(p.y) >= size.y) { return; }
    float centre = geometry.read(p).r;
    float3 sharpSum = 0.0, softSum = 0.0;
    float edge = 0.0;
    for (int j = -2; j <= 2; ++j) {
        for (int i = -2; i <= 2; ++i) {
            float spatial = exp(-float(i * i + j * j) / 4.5);
            uint2 near = uint2(clamp(int2(p) + int2(i, j), int2(0), size - 1));
            float4 n = raw.read(near);
            float dn = geometry.read(near).r - centre;
            float similar = exp(-(dn * dn) / (2.0 * 0.02 * 0.02));
            sharpSum += n.xyz * spatial * similar * (1.0 - 0.8 * n.w);
            if (abs(i) <= 1 && abs(j) <= 1) { edge = max(edge, n.w); }

            uint2 far = uint2(clamp(int2(p) + int2(i, j) * 4, int2(0), size - 1));
            float4 m = raw.read(far);
            float df = geometry.read(far).r - centre;
            float alike = exp(-(df * df) / (2.0 * 0.05 * 0.05));
            softSum += m.xyz * spatial * alike * (1.0 - 0.8 * m.w);
        }
    }
    float3 sharpNormal = length(sharpSum) > 1e-5 ? normalize(sharpSum) : float3(0.0, 0.0, 1.0);
    float3 softNormal = length(softSum) > 1e-5 ? normalize(softSum) : sharpNormal;
    sharp.write(float4(sharpNormal, edge), p);
    soft.write(float4(softNormal, edge), p);
}
