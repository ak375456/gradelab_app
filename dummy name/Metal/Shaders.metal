#include <metal_stdlib>
using namespace metal;

struct VideoVertex {
    float2 position;
    float2 textureCoordinate;
};

struct RasterData {
    float4 position [[position]];
    float2 textureCoordinate;
};

struct GradeUniforms {
    float4 lightA; // exposure EV, contrast, highlights, shadows
    float4 lightB; // whites, blacks
    float4 color;  // temperature, tint, saturation, vibrance
    float4 options; // x = bypass, y = look strength, z = active-curve mask
    float4 gradeMaskA; // centre x/y, width/height in normalised source coordinates
    float4 gradeMaskB; // rotation, feather, opacity (-1 = disabled), shape/invert flags
    float4 viewerAssist;  // x = assist mode, y = zebra threshold. Display only.
    float4 offsetWheel;   // hue, colour strength, brightness. Both retired curve slots.
    float4 hsl0, hsl1, hsl2, hsl3, hsl4, hsl5, hsl6, hsl7;
    float4 shadowWheel, midtoneWheel, highlightWheel;
    float4 vignette;
    float4 effectsA;   // fade, grain, sharpen, grain seed
    float4 effectsB;   // bloom, glow, halation, spare
    float4 colorWarp;  // Color Warper: strength, active-plane mask, preserve luminance
};

struct YUVUniforms {
    float4 column0;
    float4 column1;
    float4 column2;
    float4 offset;
};

struct BackgroundRemovalUniforms {
    float4 keyColor; // RGB key, alpha spare
    float4 controls; // similarity, smoothness, spill, mode (1 = color)
    float4 edge;     // feather radius, signed shift, invert, enabled
};

vertex RasterData videoVertex(
    uint vertexID [[vertex_id]],
    constant VideoVertex *vertices [[buffer(0)]])
{
    RasterData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].textureCoordinate;
    return out;
}

inline float3 rec709ToLinear(float3 value) {
    value = max(value, 0.0);
    return select(value / 4.5,
                  pow((value + 0.099) / 1.099, float3(1.0 / 0.45)),
                  value >= 0.081);
}

inline float3 linearToRec709(float3 value) {
    value = max(value, 0.0);
    return select(value * 4.5,
                  1.099 * pow(value, float3(0.45)) - 0.099,
                  value >= 0.018);
}

inline float luminance709(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// White balance is performed in Bradford cone-response space. Temperature shifts
// the warm/cool opposition; tint moves the green/magenta axis.
inline float3 applyWhiteBalance(float3 linearRGB, float temperature, float tint) {
    const float3x3 rgbToXYZ = float3x3(
        float3(0.4123908, 0.2126390, 0.0193308),
        float3(0.3575843, 0.7151687, 0.1191948),
        float3(0.1804808, 0.0721923, 0.9505322));
    const float3x3 xyzToRGB = float3x3(
        float3( 3.2409699, -0.9692436,  0.0556301),
        float3(-1.5373832,  1.8759675, -0.2039770),
        float3(-0.4986108,  0.0415551,  1.0569715));
    const float3x3 xyzToBradford = float3x3(
        float3( 0.8951, -0.7502,  0.0389),
        float3( 0.2664,  1.7135, -0.0685),
        float3(-0.1614,  0.0367,  1.0296));
    const float3x3 bradfordToXYZ = float3x3(
        float3( 0.9869929,  0.4323053, -0.0085287),
        float3(-0.1470543,  0.5183603,  0.0400428),
        float3( 0.1599627,  0.0492912,  0.9684867));

    float3 lms = xyzToBradford * (rgbToXYZ * linearRGB);
    float3 gains = exp2(float3(
        temperature * 0.18 - tint * 0.035,
        tint * 0.14,
        -temperature * 0.18 - tint * 0.035));
    return max(xyzToRGB * (bradfordToXYZ * (lms * gains)), 0.0);
}

// ---------------------------------------------------------------------------
// Viewer assist: false colour and zebras
//
// A DISPLAY aid, not a grade. It runs at the very end of each display fragment,
// on the pixel that is about to be shown, and nothing that writes a file passes
// through those fragments — so an assist can never reach an exported frame.
// That is also why it is driven from `reservedC` rather than from the grade
// model: it belongs to the viewer, not to the clip, and must not travel with a
// copied grade, a preset or a saved project.
//
// `reservedC.x` selects it (0 off, 1 false colour, 2 zebras) and `reservedC.y`
// is the zebra threshold.
//
// The zone boundaries are the ones a Log shooter already reads on an ARRI or
// Blackmagic body: green sits on 18% grey and pink on average skin, so exposing
// with this matches exposing on set. On an HDR project the displayed value is
// an HLG signal rather than Rec.709, so the clipping ends stay honest but the
// middle zones do not line up with scene IRE - see the note in ViewerAssist.
inline float3 falseColorZone(float luma) {
    if (luma < 0.020) { return float3(0.36, 0.10, 0.56); }  // crushed black
    if (luma < 0.100) { return float3(0.12, 0.30, 0.85); }  // deep shadow
    if (luma < 0.380) { return float3(0.26, 0.26, 0.29); }  // shadow
    if (luma < 0.420) { return float3(0.15, 0.80, 0.25); }  // 18% grey
    if (luma < 0.520) { return float3(0.53, 0.53, 0.56); }  // midtone
    if (luma < 0.580) { return float3(0.96, 0.62, 0.71); }  // skin
    if (luma < 0.900) { return float3(0.80, 0.80, 0.82); }  // highlight
    if (luma < 0.950) { return float3(0.98, 0.85, 0.15); }  // near clipping
    return float3(0.95, 0.15, 0.12);                        // clipped
}

inline float3 applyViewerAssist(float3 rgb, float2 pixel, constant GradeUniforms &grade) {
    uint mode = uint(max(grade.viewerAssist.x, 0.0) + 0.5);
    if (mode == 0) { return rgb; }
    float luma = saturate(luminance709(saturate(rgb)));
    if (mode == 1) { return falseColorZone(luma); }
    // Zebras mark what is at or above the threshold and leave everything else
    // as the picture, so the shot stays watchable while it is switched on.
    if (luma < grade.viewerAssist.y) { return rgb; }
    return fract((pixel.x + pixel.y) / 12.0) < 0.5 ? float3(1.0) : float3(0.0);
}

inline float3 preserveHueLuminance(float3 color, float oldLuma, float newLuma) {
    return color * (newLuma / max(oldLuma, 0.00001));
}

// ---------------------------------------------------------------------------
// Curve lookup
//
// Every curve is a row of a small r16Unorm texture built on the CPU from its
// control points (see `CurveLUTTexture.swift`). No spline maths runs per pixel:
// one filtered fetch per active curve is the whole cost, and a curve the user
// has not touched is skipped entirely by the mask in options.z.
//
// Hue rows need no wrap-aware sampler. The evaluator treats hue as a circle, so
// the row's first and last samples are equal and clamp-to-edge addressing is
// continuous across the red boundary.
// ---------------------------------------------------------------------------

constant float kCurveSamples = 1025.0;

// Row indices. These match `CurveType.row`.
constant uint kCurveMaster = 0u;
constant uint kCurveRed = 1u;
constant uint kCurveGreen = 2u;
constant uint kCurveBlue = 3u;
constant uint kCurveHueVsHue = 4u;
constant uint kCurveHueVsSat = 5u;
constant uint kCurveHueVsLuma = 6u;
constant uint kCurveLumaVsSat = 7u;
constant uint kCurveSatVsSat = 8u;
constant uint kCurveSatVsLuma = 9u;

constant uint kToneCurveMask = 0x0Fu;    // master, red, green, blue
constant uint kColorCurveMask = 0x3F0u;  // the six hue/sat/luma curves

// ±1 on a hue-shift curve is ±60°, matching `CurveType.hueShiftDegrees`.
constant float kHueShiftTurns = 60.0 / 360.0;
// A luma-adjustment curve moves HSL lightness. The same 0.35 scale the eight
// HSL bands use for their lightness slider, so the two tools feel the same.
constant float kLumaLift = 0.35;

// The curve texture holds one block of ten rows - one per curve - for each
// grading context:
// the clip's global grade first, then one block for each masked local grade. A
// caller addresses its own block by adding `rowBase` to the fixed row index, so
// the row COUNT is read from the texture rather than assumed - with no masks the
// texture is ten rows tall and this is exactly what it always was.
inline float curveRaw(texture2d<float, access::sample> curveLUT, uint row, float x) {
    constexpr sampler curveSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // Samples sit at texel centres, so input 0 belongs at 0.5/N and input 1 at
    // (N-0.5)/N - the same half-texel remap the 3D look LUT needs.
    float u = (saturate(x) * (kCurveSamples - 1.0) + 0.5) / kCurveSamples;
    float v = (float(row) + 0.5) / float(max(curveLUT.get_height(), 1u));
    return curveLUT.sample(curveSampler, float2(u, v)).r;
}

/// A mapping curve: input and output are in the same units, stored directly.
inline float curveMap(texture2d<float, access::sample> curveLUT, uint row, float x) {
    return curveRaw(curveLUT, row, x);
}

/// An adjustment curve: a signed offset around neutral, stored biased into
/// 0...1 because the texture format is unsigned.
inline float curveAdjust(texture2d<float, access::sample> curveLUT, uint row, float x) {
    return curveRaw(curveLUT, row, x) * 2.0 - 1.0;
}

/// Master then per-channel, exactly the order the old two lines applied them.
inline float3 applyToneCurves(float3 color,
                              texture2d<float, access::sample> curveLUT,
                              uint active,
                              uint rowBase) {
    if ((active & kToneCurveMask) == 0u) { return color; }
    if (active & (1u << kCurveMaster)) {
        color = float3(curveMap(curveLUT, rowBase + kCurveMaster, color.r),
                       curveMap(curveLUT, rowBase + kCurveMaster, color.g),
                       curveMap(curveLUT, rowBase + kCurveMaster, color.b));
    }
    if (active & (1u << kCurveRed))   { color.r = curveMap(curveLUT, rowBase + kCurveRed, color.r); }
    if (active & (1u << kCurveGreen)) { color.g = curveMap(curveLUT, rowBase + kCurveGreen, color.g); }
    if (active & (1u << kCurveBlue))  { color.b = curveMap(curveLUT, rowBase + kCurveBlue, color.b); }
    return color;
}

inline float3 hueRGB(float h) {
    return saturate(abs(fract(h + float3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0);
}

inline float3 rgbToHSL(float3 rgb) {
    float hi = max(rgb.r, max(rgb.g, rgb.b));
    float lo = min(rgb.r, min(rgb.g, rgb.b));
    float d = hi - lo;
    float l = (hi + lo) * 0.5;
    float h = 0.0;
    if (d > 0.00001) {
        if (hi == rgb.r) h = (rgb.g - rgb.b) / d;
        else if (hi == rgb.g) h = 2.0 + (rgb.b - rgb.r) / d;
        else h = 4.0 + (rgb.r - rgb.g) / d;
        h = fract(h / 6.0 + 1.0);
    }
    return float3(h, d / max(1.0 - abs(2.0*l - 1.0), 0.00001), l);
}

inline float3 hslToRGB(float3 hsl) {
    float c = (1.0 - abs(2.0*hsl.z - 1.0)) * hsl.y;
    return (hueRGB(hsl.x) - 0.5) * c + hsl.z;
}

// ---------------------------------------------------------------------------
// Advanced colour curves
//
// Hue vs Hue / Sat / Luma, Luma vs Sat, Sat vs Sat and Sat vs Luma, applied
// inside the HSL visit the grade already makes - so all six cost one RGB->HSL
// round trip between them, and none at all when the mask says they are neutral.
//
// Every curve is read at the pixel's SOURCE hue, saturation and luma, captured
// before anything is changed. That is what keeps them independent: shifting a
// hue with Hue vs Hue does not move which pixels Hue vs Saturation then acts on,
// so the two controls do not fight each other depending on which was touched
// last.
//
// `luma` is the caller's luminance for its own working space - Rec.709
// coefficients on the SDR path, BT.2020 on the HDR one - because that is what
// each space's primaries call brightness. It is also the value the app's scopes
// plot, so the Luma vs Saturation x axis lines up with the waveform.
//
// The hue-keyed curves fade out as saturation approaches zero. A near-neutral
// pixel has no meaningful hue - it is whichever channel happened to win by a
// thousandth - and rotating it would be noise. The same guard, with the same
// threshold, that the eight HSL bands already use.
// ---------------------------------------------------------------------------
inline float3 applyColorCurves(float3 hsl,
                               float luma,
                               texture2d<float, access::sample> curveLUT,
                               uint active,
                               uint rowBase) {
    if ((active & kColorCurveMask) == 0u) { return hsl; }

    float sourceHue = hsl.x;
    float sourceSat = hsl.y;
    float key = saturate(luma);
    float chroma = smoothstep(0.0, 0.1, sourceSat);

    float hueShift = 0.0;
    float satAdjust = 0.0;
    float lumaAdjust = 0.0;
    if (active & (1u << kCurveHueVsHue)) {
        hueShift += curveAdjust(curveLUT, rowBase + kCurveHueVsHue, sourceHue) * chroma;
    }
    if (active & (1u << kCurveHueVsSat)) {
        satAdjust += curveAdjust(curveLUT, rowBase + kCurveHueVsSat, sourceHue) * chroma;
    }
    if (active & (1u << kCurveHueVsLuma)) {
        lumaAdjust += curveAdjust(curveLUT, rowBase + kCurveHueVsLuma, sourceHue) * chroma;
    }
    if (active & (1u << kCurveLumaVsSat)) {
        satAdjust += curveAdjust(curveLUT, rowBase + kCurveLumaVsSat, key);
    }
    if (active & (1u << kCurveSatVsLuma)) {
        lumaAdjust += curveAdjust(curveLUT, rowBase + kCurveSatVsLuma, sourceSat);
    }

    hsl.x = fract(sourceHue + hueShift * kHueShiftTurns + 1.0);
    // Saturation adjustments are proportional, so -1 fully desaturates and +1
    // doubles; `max` keeps a stacked pair from folding through zero into a
    // complementary hue.
    float saturation = sourceSat * max(0.0, 1.0 + satAdjust);
    // Sat vs Sat is a mapping, and it runs last so it can act as the limiter it
    // is meant to be: it sees the saturation the other curves produced.
    if (active & (1u << kCurveSatVsSat)) {
        saturation = curveMap(curveLUT, rowBase + kCurveSatVsSat, saturate(saturation));
    }
    hsl.y = saturate(saturation);
    hsl.z = saturate(hsl.z + lumaAdjust * kLumaLift);
    return hsl;
}

// ---------------------------------------------------------------------------
// The Color Warper
//
// A two-dimensional deformation of colour, and the reason it is not another
// curve: a curve maps one coordinate to one coordinate, so Hue vs Sat can say
// "oranges get more saturated" but cannot say "the orange AT 70% saturation
// goes to that red at 82% while the orange at 20% stays where it is". This
// reads two coordinates of the source colour and displaces the pair.
//
// None of the deformation maths runs here. The authored points are solved on
// the CPU into a small two-channel table (see ColorWarpField.swift) and this is
// one filtered fetch per active plane - so the per-pixel cost does not depend on
// how many points the grade carries, and dragging one point rebuilds 36 KB
// rather than re-deriving a field for every pixel on screen.
//
// Two planes, stacked as blocks in one texture the way masked local grades stack
// curve blocks:
//
//   block 0   hue x saturation   angle and distance on the colour wheel
//   block 1   chroma x luma      how colourful against how bright
//
// Column 0 and column W-1 of the hue plane hold the same hue, because the
// builder measures hue the short way round. Clamp-to-edge addressing is then
// continuous across the red boundary and there is no seam - the same property
// the curve texture's hue rows rely on.
// ---------------------------------------------------------------------------

constant uint kWarpHueSaturation = 0u;
constant uint kWarpChromaLuma = 1u;
constant uint kWarpBlockCount = 2u;
constant float kWarpFieldWidth = 192.0;

// Matching the two `luminance` helpers in this file. Passed in rather than
// chosen inside the warper so one implementation serves both working spaces:
// Rec.709-encoded on the SDR path, BT.2020 on the HDR one.
constant float3 kRec709LumaWeights = float3(0.2126, 0.7152, 0.0722);
constant float3 kBT2020LumaWeights = float3(0.2627, 0.6780, 0.0593);

/// The displacement one plane asks for at `coordinate`, both axes 0...1.
inline float2 warpDisplacement(texture2d<float, access::sample> field,
                               uint block,
                               float2 coordinate) {
    constexpr sampler warpSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float totalHeight = float(max(field.get_height(), 1u));
    float rows = max(totalHeight / float(kWarpBlockCount), 1.0);
    // Samples sit at texel centres, so input 0 belongs at 0.5/N and input 1 at
    // (N-0.5)/N - the same half-texel remap the curve rows and the 3D look LUT
    // both need, and for the same reason: without it an identity table shifts
    // every colour by half a texel.
    float u = (saturate(coordinate.x) * (kWarpFieldWidth - 1.0) + 0.5) / kWarpFieldWidth;
    float v = (float(block) * rows + saturate(coordinate.y) * (rows - 1.0) + 0.5) / totalHeight;
    return field.sample(warpSampler, float2(u, v)).rg;
}

/// Warps a pixel toward wherever the authored points pull it.
///
/// `source` is the hue and saturation captured BEFORE anything in this HSL visit
/// changed them. That is what keeps the warper and the colour curves from
/// fighting: moving a hue with one does not move which pixels the other then
/// acts on, so the result does not depend on which was touched last.
///
/// `luma` is the caller's own luminance - Rec.709 on the SDR path, BT.2020 on
/// the HDR one - because that is what each space's primaries call brightness,
/// and it is the value the app's scopes plot, so the chroma/luma plane's y axis
/// lines up with the waveform.
inline float3 applyColorWarp(float3 hsl,
                             float2 source,
                             float luma,
                             texture2d<float, access::sample> field,
                             float4 params,
                             float3 lumaWeights) {
    uint active = uint(max(params.y, 0.0) + 0.5);
    float strength = saturate(params.x);
    if (active == 0u || strength <= 0.0) { return hsl; }

    if (active & (1u << kWarpHueSaturation)) {
        // A near-neutral pixel has no hue worth moving - it is whichever channel
        // happened to win by a thousandth - so the plane fades out as saturation
        // approaches zero. The same guard, at the same threshold, that the eight
        // HSL bands and the hue-keyed curves already use.
        float chroma = smoothstep(0.0, 0.1, source.y);
        float2 displacement = warpDisplacement(field, kWarpHueSaturation, source) * chroma * strength;

        bool preserve = params.z > 0.5;
        float3 before = preserve ? hslToRGB(hsl) : float3(0.0);
        float lumaBefore = preserve ? dot(before, lumaWeights) : 0.0;

        hsl.x = fract(hsl.x + displacement.x + 1.0);
        hsl.y = saturate(hsl.y + displacement.y);

        // Preserve Luminance. Colours are not equally bright: carrying blue
        // across to purple carries its brightness with it, and the picture lifts
        // for a reason the user did not ask for. When it is on, the pixel is put
        // back on the brightness it arrived with, through the same ratio-preserving
        // restore the tonal controls use.
        //
        // Only THIS plane is corrected. On the chroma/luma plane below, changing
        // brightness is the entire point of the control.
        if (preserve) {
            float3 after = hslToRGB(hsl);
            float lumaAfter = dot(after, lumaWeights);
            if (lumaAfter > 0.00001 && lumaBefore > 0.00001) {
                hsl = rgbToHSL(saturate(preserveHueLuminance(after, lumaAfter, lumaBefore)));
            }
        }
    }

    if (active & (1u << kWarpChromaLuma)) {
        // Keyed on how colourful and how bright the pixel is rather than on which
        // hue it happens to be, so it reaches near-neutrals too and takes no
        // chroma guard - "lift the dark saturated blues" has to work on a pixel
        // the hue plane would rightly refuse to touch.
        float2 displacement =
            warpDisplacement(field, kWarpChromaLuma, float2(source.y, saturate(luma))) * strength;
        hsl.y = saturate(hsl.y + displacement.x);
        hsl.z = saturate(hsl.z + displacement.y);
    }
    return hsl;
}

inline float3 wheelGrade(float3 rgb, float4 wheel, float weight) {
    float3 tint = hueRGB(wheel.x);
    tint -= luminance709(tint);
    return rgb * exp2((tint * wheel.y * 0.8 + wheel.z) * weight);
}

// The offset wheel. Deliberately ADDITIVE, and deliberately unweighted, which
// is the whole difference between it and the three tonal wheels: those are
// multiplicative and fall off with tonal position, so they leave black alone.
// An offset moves black exactly as far as it moves white, which is what makes
// it the control for neutralising a cast in the toe of a Log clip.
//
// Applied before the tonal wheels so their weights read the offset picture -
// otherwise lifting the blacks here would leave the shadow wheel still acting
// on where the shadows used to be.
inline float3 offsetGrade(float3 rgb, float4 wheel) {
    float3 tint = hueRGB(wheel.x);
    tint -= luminance709(tint);
    return rgb + tint * wheel.y * 0.25 + wheel.z * 0.25;
}

// ---------------------------------------------------------------------------
// Per-pixel finishing effects
//
// These need only the pixel they are on, so they live in the grading functions
// and reach every render path without plumbing: preview, export, both
// compositors and the scopes all get them from the same lines.
// ---------------------------------------------------------------------------

// Fade: lift the black point, ease the white point down. A washed print has a
// floor it never goes below and a ceiling it never quite reaches.
inline float3 applyFade(float3 colour, float amount) {
    if (amount <= 0.0) { return colour; }
    float floorLevel = 0.12 * amount;
    float ceilingLevel = 1.0 - 0.05 * amount;
    return floorLevel + colour * (ceilingLevel - floorLevel);
}

// The same, for extended-range HDR values: only the part up to diffuse white is
// faded, and anything above it is carried through and re-joined. Compressing
// specular highlights toward a matte ceiling would throw away the range the HDR
// pipeline exists to keep.
inline float3 applyFadeExtended(float3 working, float amount) {
    if (amount <= 0.0) { return working; }
    float3 base = clamp(working, 0.0, 1.0);
    return applyFade(base, amount) + (working - base);
}

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Grain: monochrome, and weighted toward the midtones the way film is — silver
// halide has nothing to develop in clipped white and nothing to lose in black.
// The coordinate is frame-relative rather than pixel-relative, so grain is the
// same size in the preview as in a 4K export instead of turning to fine noise.
inline float3 applyGrain(float3 colour, float2 uv, float amount, float seed, float luma) {
    if (amount <= 0.0) { return colour; }
    float noise = hash21(uv * 1440.0 + seed) - 0.5;
    float weight = 4.0 * saturate(luma) * (1.0 - saturate(luma));
    return colour + noise * amount * 0.16 * weight;
}

// ---------------------------------------------------------------------------
// Masked local grades (power windows)
//
// A clip carries one global grade plus up to `kMaxLocalGrades` masked local
// grades. Each layer is a window and a NEUTRAL-BY-DEFAULT grade that acts on the
// globally graded pixel; it is not a second copy of the global grade, and the
// global grade is never computed twice.
//
// The whole stack arrives as one inline argument block on every grading pass -
// preview, scopes, compositor, transitions, still tiles and every export format
// alike - so there is exactly one implementation of mask geometry and exactly
// one of local colour, and preview and export cannot drift apart.
//
// Geometry is normalised to the source frame. `header.y` carries that frame's
// aspect so rotation and feather are measured in a square space: a window on a
// 16:9 frame rotates rigidly instead of shearing.
// ---------------------------------------------------------------------------

constant uint kMaxLocalGrades = 8u;
constant uint kLocalPointWords = 96u; // two polygon vertices per word

struct LocalGradeUniforms {
    float4 lightA;  // exposure EV, contrast, highlights, shadows
    float4 lightB;  // whites, blacks, then qualifier luma min/max
    float4 color;   // temperature, tint, saturation, vibrance
    float4 options; // x = qualifier softness, y = qualifier flags,
                    // z = active-curve mask, w = first curve row for this layer
    float4 maskA;   // centre x/y, width/height, normalised to the source frame
    float4 maskB;   // rotation, feather, strength, packed shape/invert flags
    float4 maskC;   // primitives: corner radius. Polygons: pivot x, first vertex,
                    // vertex count, pivot y - a polygon has no corner radius and
                    // a primitive has no pivot, so the slots are shared.
    float4 hsl0, hsl1, hsl2, hsl3, hsl4, hsl5, hsl6, hsl7;
    float4 shadowWheel, midtoneWheel, highlightWheel;
    // Hue centre, hue half-width (turns), sat min, sat max. The rest of the key
    // is in lightB.zw and options.xy - see LocalGradeUniforms.swift for why a
    // local layer cannot afford a second word, and why it has no offset wheel.
    float4 qualifier;
};

// Only the clip grade has an offset wheel; a masked layer has no word to spare
// for one. Overloads rather than a field on both, so the shared grading template
// compiles for each uniform type without a second copy of the maths.
inline float4 offsetWheelFor(constant GradeUniforms &grade) { return grade.offsetWheel; }
inline float4 offsetWheelFor(constant LocalGradeUniforms &) { return float4(0.0); }

// Only the clip grade carries a Color Warper. A masked layer has no word to
// spare for one: the whole stack travels as a single 4 KB `setBytes`, which
// with eight layers and the shared point pool allows exactly the words
// `LocalGradeUniforms` already uses, and the colour qualifier had to spill into
// the last of them. Overloads rather than a field on both, so the shared
// grading template compiles for each uniform type without a second copy of the
// maths - the same mechanism the offset wheel uses, for the same reason.
inline float4 colorWarpFor(constant GradeUniforms &grade) { return grade.colorWarp; }
inline float4 colorWarpFor(constant LocalGradeUniforms &) { return float4(0.0); }

struct LocalGradeStack {
    // x = live layer count, y = source aspect, z = 1 + matte layer index
    //
    // Every field is chosen so that an all-zero block is INERT: no layers, and
    // no matte. A grading pass that somehow reached the GPU without this buffer
    // populated then renders the ordinary picture rather than a black frame.
    float4 header;
    LocalGradeUniforms layers[kMaxLocalGrades];
    float4 points[kLocalPointWords];
};

inline float2 localPolygonVertex(constant float4 *points, uint index) {
    float4 pair = points[min(index >> 1, kLocalPointWords - 1u)];
    return (index & 1u) != 0u ? pair.zw : pair.xy;
}

// Exact signed distance to a closed polygon: negative inside, positive outside,
// in the same aspect-corrected units the primitives use. Evaluated per pixel
// rather than rasterised into a cached texture, so a freehand mask needs no
// invalidation rules and is identical at every render size.
inline float localPolygonDistance(float2 p, constant float4 *points, uint first, uint count,
                                  float2 pivot, float aspect) {
    float2 firstVertex = (localPolygonVertex(points, first) - pivot) * float2(aspect, 1.0);
    float squared = dot(p - firstVertex, p - firstVertex);
    float sign = 1.0;
    uint previous = count - 1u;
    for (uint i = 0u; i < count; ++i) {
        float2 a = (localPolygonVertex(points, first + i) - pivot) * float2(aspect, 1.0);
        float2 b = (localPolygonVertex(points, first + previous) - pivot) * float2(aspect, 1.0);
        float2 edge = b - a;
        float2 offset = p - a;
        float2 nearest = offset - edge * clamp(dot(offset, edge) / max(dot(edge, edge), 1e-12), 0.0, 1.0);
        squared = min(squared, dot(nearest, nearest));
        bool3 crossing = bool3(p.y >= a.y, p.y < b.y, edge.x * offset.y > edge.y * offset.x);
        if (all(crossing) || all(!crossing)) { sign = -sign; }
        previous = i;
    }
    return sign * sqrt(squared);
}

// 0 outside, 1 fully inside, feathered between. Invert is `1 - mask`, done here
// rather than by building a second window.
inline float localMaskWeight(float2 uv, constant LocalGradeUniforms &layer,
                             constant float4 *points, float aspect) {
    float strength = saturate(layer.maskB.z);
    if (strength <= 0.0) { return 0.0; }

    uint flags = uint(max(layer.maskB.w, 0.0) + 0.5);
    uint shape = flags & 3u;
    bool inverted = (flags & 4u) != 0u;
    float feather = clamp(layer.maskB.y, 0.0, 1.0);

    float2 centre = layer.maskA.xy;
    float2 halfSize = max(layer.maskA.zw * 0.5, float2(0.0005)) * float2(aspect, 1.0);
    float angle = -layer.maskB.x;
    float sine = sin(angle), cosine = cos(angle);
    float2 p = (uv - centre) * float2(aspect, 1.0);
    p = float2(cosine * p.x - sine * p.y, sine * p.x + cosine * p.y);

    float inside;
    if (shape == 3u) {
        uint count = uint(max(layer.maskC.z, 0.0) + 0.5);
        if (count < 3u) { return 0.0; }
        // Width and height are scale factors for a polygon, applied around the
        // pivot the mask was drawn about - which is what lets a future tracker
        // move, scale and rotate the whole path with three keyframed numbers.
        float2 scaled = p / max(layer.maskA.zw, float2(0.01));
        // Vertices are absolute frame coordinates measured about the pivot the
        // path was drawn around; the pixel is measured about the mask's centre.
        // Moving the centre away from the pivot therefore translates the whole
        // path, which is what makes a freehand mask animate as one object.
        float2 pivot = float2(layer.maskC.x, layer.maskC.w);
        float distance = localPolygonDistance(
            scaled, points, uint(max(layer.maskC.y, 0.0) + 0.5), count, pivot, aspect);
        // Polygon softness is measured against the frame rather than the shape,
        // because a drawn path has no single radius to be a fraction of.
        float softness = max(feather * 0.15, 1e-4);
        inside = 1.0 - smoothstep(-softness, softness, distance);
    } else if (shape == 2u) {
        // Graduated window: fully affected on one side of the line, nothing on
        // the other, with the transition spanning `feather` of the frame.
        float softness = max(feather * 0.5, 1e-4);
        inside = 1.0 - smoothstep(-softness, softness, p.y);
    } else if (shape == 1u) {
        float radius = clamp(layer.maskC.x, 0.0, 1.0) * min(halfSize.x, halfSize.y);
        float2 corner = abs(p) - (halfSize - radius);
        float distance = length(max(corner, 0.0)) + min(max(corner.x, corner.y), 0.0) - radius;
        float softness = max(feather * min(halfSize.x, halfSize.y), 1e-4);
        inside = 1.0 - smoothstep(-softness, softness, distance);
    } else {
        float2 unit = p / halfSize;
        float shortest = min(halfSize.x, halfSize.y);
        float distance = (length(unit) - 1.0) * shortest;
        float softness = max(feather * shortest, 1e-4);
        inside = 1.0 - smoothstep(-softness, softness, distance);
    }
    if (inverted) { inside = 1.0 - inside; }
    return saturate(inside) * strength;
}

/// Show Mask: white where a layer grades, black where it does not, grey through
/// the feather. Returns -1 when no matte is requested, which is always the case
/// on every export path - the matte is named by the editor and by nothing else.
inline float localMatte(float2 uv, constant LocalGradeStack &stack) {
    // Stored as 1 + index, so zero - the value an unpopulated block carries -
    // means no matte.
    uint selected = uint(max(stack.header.z, 0.0) + 0.5);
    if (selected == 0u) { return -1.0; }
    uint index = selected - 1u;
    if (index >= min(uint(max(stack.header.x, 0.0) + 0.5), kMaxLocalGrades)) { return -1.0; }
    return localMaskWeight(uv, stack.layers[index], stack.points, max(stack.header.y, 1e-4));
}

// Soft geometric grading window. This is deliberately evaluated inside the
// shared colour pipeline, rather than in a preview overlay, so scopes, layered
// compositions, still-image tiles and every export format receive the same
// mask. Width/height are source-relative; rotation is around the window centre.
inline float softShapeMaskWeight(float2 uv, float4 geometry, float4 options) {
    if (options.z < 0.0) { return 1.0; }

    float2 point = uv - geometry.xy;
    float angle = -options.x;
    float sine = sin(angle), cosine = cos(angle);
    point = float2(cosine * point.x - sine * point.y,
                   sine * point.x + cosine * point.y);
    float2 halfSize = max(geometry.zw * 0.5, float2(0.005));
    float2 unit = abs(point) / halfSize;

    uint flags = uint(max(options.w, 0.0) + 0.5);
    uint shape = flags & 3u;
    bool inverted = (flags & 4u) != 0u;
    float feather = clamp(options.y, 0.0, 1.0);
    float inside;
    if (shape == 2u) {
        // Infinite split line. With no rotation the left side is retained, and
        // moving centre X from 0 to 1 creates the familiar swipe reveal.
        float softness = feather * 0.25;
        inside = softness <= 0.0001
            ? (point.x <= 0.0 ? 1.0 : 0.0)
            : 1.0 - smoothstep(-softness, softness, point.x);
    } else {
        float distance = shape == 1u ? max(unit.x, unit.y) : length(unit);
        inside = feather <= 0.0001
            ? (distance <= 1.0 ? 1.0 : 0.0)
            : 1.0 - smoothstep(max(0.0, 1.0 - feather), 1.0, distance);
    }
    if (inverted) { inside = 1.0 - inside; }
    return inside * saturate(options.z);
}

// The colour qualifier: how much this pixel belongs to the selected colour.
//
// Hue, saturation and luma are keyed independently and multiplied, which is
// what makes the three controls feel separate - widening the luma range does
// not drag in a hue the user excluded. Hue is measured the short way round the
// circle so a key centred on red is continuous across the 0/360 boundary
// instead of splitting in two.
//
// Softness fades each edge outward rather than inward, so widening it only ever
// ADDS partially selected pixels. Narrowing a selection by softening it would
// be the opposite of what the control says.
//
// Near-neutral pixels are excluded by the saturation term on its own: a grey
// pixel has no meaningful hue, and the same guard the HSL bands already use
// would otherwise have to be repeated here.
inline float qualifierWeight(float3 encodedRGB, constant LocalGradeUniforms &layer) {
    uint flags = uint(max(layer.options.y, 0.0) + 0.5);
    if ((flags & 1u) == 0u) { return 1.0; }

    float3 hsl = rgbToHSL(saturate(encodedRGB));
    float soft = max(layer.options.x, 0.0);

    float hueDistance = abs(hsl.x - layer.qualifier.x);
    hueDistance = min(hueDistance, 1.0 - hueDistance);
    float hueHalf = max(layer.qualifier.y, 0.0005);
    float hueSoft = max(soft * 0.5, 0.0005);
    float hueWeight = 1.0 - smoothstep(hueHalf, hueHalf + hueSoft, hueDistance);

    // Saturation and luma are ranges rather than centres, so each keys its two
    // edges and takes the smaller - inside the range both read 1.
    float satSoft = max(soft * 0.35, 0.0005);
    float satWeight = smoothstep(layer.qualifier.z - satSoft, layer.qualifier.z + satSoft, hsl.y)
        * (1.0 - smoothstep(layer.qualifier.w - satSoft, layer.qualifier.w + satSoft, hsl.y));

    float lumaSoft = max(soft * 0.35, 0.0005);
    float lumaWeight = smoothstep(layer.lightB.z - lumaSoft, layer.lightB.z + lumaSoft, hsl.z)
        * (1.0 - smoothstep(layer.lightB.w - lumaSoft, layer.lightB.w + lumaSoft, hsl.z));

    float weight = saturate(hueWeight * satWeight * lumaWeight);
    return (flags & 2u) != 0u ? 1.0 - weight : weight;
}

/// True when this layer's key replaces its shape rather than narrowing it.
inline bool qualifierIgnoresShape(constant LocalGradeUniforms &layer) {
    uint flags = uint(max(layer.options.y, 0.0) + 0.5);
    return (flags & 5u) == 5u;
}

inline float gradeMaskWeight(float2 uv, constant GradeUniforms &grade) {
    return softShapeMaskWeight(uv, grade.gradeMaskA, grade.gradeMaskB);
}

// The grade splits in two on purpose.
//
// `applyGradeCore` is every stage that depends only on the pixel's colour:
// white balance, exposure, the tonal controls, contrast, saturation, the wheels,
// the curves and the HSL bands. `applyGradeFinish` is everything that depends on
// WHERE the pixel is or on the frame as a whole: the print fade, the lens
// vignette and the grain field.
//
// Masked local grades run between the two, which is what puts the pipeline in
// the order it should be - source, colour management, global grade, local
// grades, finishing - and is also why a mask can reuse the core unchanged
// instead of carrying a second implementation of the colour maths.
//
// The core is templated over the uniform type so the global grade and a masked
// local grade are literally the same instructions. `GradeUniforms` and
// `LocalGradeUniforms` name their colour fields identically for that reason.
// With no masks on a clip the two halves run back to back and the result is
// what it has always been.
template <typename Grade>
inline float3 applyGradeCore(float3 encodedRGB,
                             constant Grade &grade,
                             texture2d<float, access::sample> curveLUT,
                             texture2d<float, access::sample> warpField) {
    float3 color = rec709ToLinear(encodedRGB);
    color = applyWhiteBalance(color, grade.color.x, grade.color.y);
    color *= exp2(grade.lightA.x);

    float luma = max(luminance709(color), 0.0);
    float shadowMask = 1.0 - smoothstep(0.08, 0.50, luma);
    float highlightMask = smoothstep(0.32, 1.0, luma);
    float blackMask = 1.0 - smoothstep(0.0, 0.18, luma);
    float whiteMask = smoothstep(0.62, 1.0, luma);
    float tonalDelta = grade.lightA.w * shadowMask * max(luma, 0.035) * 0.75
        + grade.lightA.z * highlightMask * max(luma, 0.08) * 0.65
        + grade.lightB.y * blackMask * 0.045
        + grade.lightB.x * whiteMask * 0.085;
    float adjustedLuma = max(luma + tonalDelta, 0.0);
    color = luma > 0.00001
        ? preserveHueLuminance(color, luma, adjustedLuma)
        : float3(adjustedLuma);

    // Contrast pivots around photographic middle gray (18%) in linear light.
    float contrastSlope = exp2(grade.lightA.y * 0.85);
    color = max((color - 0.18) * contrastSlope + 0.18, 0.0);

    luma = luminance709(color);
    float maxChannel = max(color.r, max(color.g, color.b));
    float minChannel = min(color.r, min(color.g, color.b));
    float chroma = (maxChannel - minChannel) / max(maxChannel, 0.0001);
    float saturationScale = max(0.0, 1.0 + grade.color.z);
    float vibranceScale = 1.0 + grade.color.w * (1.0 - saturate(chroma)) * 0.75;
    color = mix(float3(luma), color, max(0.0, saturationScale * vibranceScale));

    color = offsetGrade(color, offsetWheelFor(grade));
    float tonalPosition = saturate(luminance709(color));
    float sw = 1.0 - smoothstep(0.02, 0.35, tonalPosition);
    float hw = smoothstep(0.35, 0.95, tonalPosition);
    float mw = max(0.0, 1.0 - sw - hw);
    color = wheelGrade(color, grade.shadowWheel, sw);
    color = wheelGrade(color, grade.midtoneWheel, mw);
    color = wheelGrade(color, grade.highlightWheel, hw);
    color = saturate(linearToRec709(color));
    uint activeCurves = uint(grade.options.z + 0.5);
    uint curveRowBase = uint(max(grade.options.w, 0.0) + 0.5);
    color = applyToneCurves(color, curveLUT, activeCurves, curveRowBase);
    float3 hsl = rgbToHSL(color);
    // Advanced colour curves, then the eight HSL bands, in one visit to HSL.
    // The working space here is Rec.709-encoded, so Y' uses Rec.709 luma
    // coefficients - the same ones this file's `luminance709` already carries
    // and the same ones the waveform is plotted with.
    float2 warpSource = hsl.xy;
    hsl = applyColorCurves(hsl, luminance709(color), curveLUT, activeCurves, curveRowBase);
    hsl = applyColorWarp(hsl, warpSource, luminance709(color), warpField,
                         colorWarpFor(grade), kRec709LumaWeights);
    float4 bands[8] = {grade.hsl0, grade.hsl1, grade.hsl2, grade.hsl3, grade.hsl4, grade.hsl5, grade.hsl6, grade.hsl7};
    float3 delta = 0.0;
    for (int i = 0; i < 8; ++i) {
        float distance = abs(hsl.x - bands[i].w);
        distance = min(distance, 1.0 - distance);
        float weight = 1.0 - smoothstep(0.0, 1.0/6.0, distance);
        delta += bands[i].xyz * weight;
    }
    float colorMask = smoothstep(0.0, 0.1, hsl.y);
    hsl.x = fract(hsl.x + delta.x * colorMask + 1.0);
    hsl.y = saturate(hsl.y * (1.0 + delta.y));
    hsl.z = saturate(hsl.z + delta.z * 0.3 * colorMask);
    return saturate(hslToRGB(hsl));
}

/// Frame-absolute finishing. Only ever driven by the clip's own grade: a mask
/// carries no vignette and no grain, because neither can be composited through
/// a window without misrepresenting what it is.
inline float3 applyGradeFinish(float3 color, float2 uv, constant GradeUniforms &grade) {
    // Fade is a print process: it comes before the lens vignette, and before
    // grain, which is in the emulsion and sees whatever the print did.
    color = applyFade(color, grade.effectsA.x);
    float radius = length((uv - 0.5) * 1.41421356);
    float midpoint = mix(0.1, 0.85, grade.vignette.y);
    float feather = mix(0.05, 0.65, grade.vignette.z);
    float mask = smoothstep(max(0.0, midpoint - feather), min(1.0, midpoint + feather), radius);
    color *= exp2(grade.vignette.x * mask * 1.5);
    color = applyGrain(color, uv, grade.effectsA.y, grade.effectsA.w, luminance709(color));
    return saturate(color);
}

inline float3 applyGrade(float3 encodedRGB,
                         float2 uv,
                         constant GradeUniforms &grade,
                         texture2d<float, access::sample> curveLUT,
                         texture2d<float, access::sample> warpField) {
    if (grade.options.x > 0.5) {
        return saturate(encodedRGB);
    }
    return applyGradeFinish(applyGradeCore(encodedRGB, grade, curveLUT, warpField), uv, grade);
}

/// Every masked local grade, in list order, each mixed in through its own window.
///
/// Sequential composition is deliberate and is what the UI promises: mask 2 sees
/// the picture mask 1 produced, so two overlapping windows stack the way two
/// grades would rather than fighting over the pixel.
inline float3 applyLocalGrades(float3 color,
                               float2 uv,
                               constant LocalGradeStack &stack,
                               texture2d<float, access::sample> curveLUT,
                               texture2d<float, access::sample> warpField) {
    uint count = min(uint(max(stack.header.x, 0.0) + 0.5), kMaxLocalGrades);
    if (count == 0u) { return color; }
    float aspect = max(stack.header.y, 1e-4);
    for (uint i = 0u; i < count; ++i) {
        float weight = qualifierIgnoresShape(stack.layers[i])
            ? 1.0
            : localMaskWeight(uv, stack.layers[i], stack.points, aspect);
        // Keyed on the colour this layer RECEIVES, so a selection stays on the
        // thing it was pointed at as earlier layers move it.
        weight *= qualifierWeight(color, stack.layers[i]);
        if (weight <= 0.0005) { continue; }
        color = mix(color, applyGradeCore(color, stack.layers[i], curveLUT, warpField), weight);
    }
    return color;
}

// Samples a creative 3D LUT. Input and output are Rec.709-encoded, which is the
// domain these LUTs were authored in.
//
// The half-texel remap matters: a size-N LUT stores its samples at texel
// *centres*, so input 0 belongs at 0.5/N and input 1 at (N-0.5)/N. Sampling the
// raw 0...1 coordinate instead would shift every colour by half a texel and even
// an identity LUT would tint the image.
inline float3 applyLUT(float3 encodedRGB,
                       texture3d<float, access::sample> lut,
                       float amount) {
    float3 source = saturate(encodedRGB);
    if (amount <= 0.0) {
        return source;
    }
    constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float size = float(lut.get_width());
    float3 coordinate = (source * (size - 1.0) + 0.5) / size;
    return mix(source, lut.sample(lutSampler, coordinate).rgb, saturate(amount));
}

// The full look pipeline: creative LUT first, then the manual grading tools, so
// the sliders behave as adjustments on top of the chosen look. Bypass (the
// Original comparison) skips both.
inline float3 applyLookAndGrade(float3 encodedRGB,
                                float2 uv,
                                constant GradeUniforms &grade,
                                texture3d<float, access::sample> lut,
                                texture2d<float, access::sample> curveLUT,
                                texture2d<float, access::sample> warpField,
                                constant LocalGradeStack &locals) {
    if (grade.options.x > 0.5) {
        return saturate(encodedRGB);
    }
    // Show Mask replaces the picture with the matte. It is checked after bypass
    // so the Original comparison still wins, and it can only be requested by the
    // editor - no export path ever names a matte layer.
    float matte = localMatte(uv, locals);
    if (matte >= 0.0) { return float3(matte); }
    float3 original = saturate(encodedRGB);
    float3 core = applyGradeCore(applyLUT(original, lut, grade.options.y), grade, curveLUT, warpField);
    core = applyLocalGrades(core, uv, locals, curveLUT, warpField);
    float3 graded = applyGradeFinish(core, uv, grade);
    return mix(original, graded, gradeMaskWeight(uv, grade));
}

// ---------------------------------------------------------------------------
// HDR display path
//
// Input is extended-range LINEAR light, already de-matrixed and
// transfer-converted by AVFoundation, scaled so HLG signal 1.0 -> 12.0 (see
// Docs/HDR_PIPELINE_PLAN.md 2). It may exceed 1.0 (highlights) and go below 0.0
// (colour outside the P3 gamut). Nothing here may clamp either away.
// ---------------------------------------------------------------------------

struct HDRDisplayUniforms {
    // x = 1 / referenceWhiteSceneLight   scene light -> working space
    // y = referenceWhiteSceneLight       working space -> scene light
    // z = peak in working space (~3.774)
    // w unused
    float4 params;
    float4 transfer;   // reserved
};

constant float kHLG_A = 0.17883277;
constant float kHLG_B = 0.28466892;
constant float kHLG_C = 0.55991073;

inline float maxChannel(float3 c) {
    return max(c.r, max(c.g, c.b));
}

// BT.2020 luminance weights: the decoder is asked for BT.2020 primaries, so
// these are the matching coefficients.
inline float luminanceBT2020(float3 c) {
    return dot(c, float3(0.2627, 0.6780, 0.0593));
}

// BT.2100 HLG inverse OETF: signal -> scene light.
inline float hlgSceneLightChannel(float e) {
    if (e <= 0.0) {
        return 0.0;
    }
    if (e <= 0.5) {
        return e * e / 3.0;
    }
    return (exp((e - kHLG_C) / kHLG_A) + kHLG_B) / 12.0;
}

// BT.2100 HLG OETF: scene light -> signal.
inline float hlgSignalChannel(float e) {
    if (e <= 0.0) {
        return 0.0;
    }
    if (e <= 1.0 / 12.0) {
        return sqrt(3.0 * e);
    }
    return kHLG_A * log(12.0 * e - kHLG_B) + kHLG_C;
}

// AVFoundation is asked for the HLG representation, so every source - HLG or
// Rec.709 SDR - arrives as a correctly referenced HLG signal, with SDR white
// already mapped to signal 0.75 (measured; Docs/HDR_PIPELINE_PLAN.md 2). This
// converts that signal to the linear working space where diffuse white is 1.0.
//
// No OOTF here. For an HLG file the stored value IS the signal; the OOTF belongs
// to the display and the system applies it. Doing it here as well would
// double-count it.
inline float3 toWorkingSpace(float3 signal, constant HDRDisplayUniforms &hdr) {
    float3 scene = float3(hlgSceneLightChannel(signal.r),
                          hlgSceneLightChannel(signal.g),
                          hlgSceneLightChannel(signal.b));
    return scene * hdr.params.x;
}

// Working space -> HLG signal, for display and for encoding. The same transform
// serves both, so what is previewed is what is written.
inline float3 workingToSignal(float3 working, constant HDRDisplayUniforms &hdr) {
    float3 scene = max(working, 0.0) * hdr.params.y;
    return saturate(float3(hlgSignalChannel(scene.r),
                           hlgSignalChannel(scene.g),
                           hlgSignalChannel(scene.b)));
}

// ---------------------------------------------------------------------------
// HDR grading helpers
//
// A parallel implementation of the SDR grading maths for extended-range linear
// input. Deliberately not a modification of applyGrade: the SDR path and its
// regression harness must stay byte-identical.
// ---------------------------------------------------------------------------

// Bradford white balance without the final clamp to zero, so wide-gamut colour
// is not silently discarded on every frame.
inline float3 applyWhiteBalanceExtended(float3 linearRGB, float temperature, float tint) {
    const float3x3 rgbToXYZ = float3x3(
        float3(0.4123908, 0.2126390, 0.0193308),
        float3(0.3575843, 0.7151687, 0.1191948),
        float3(0.1804808, 0.0721923, 0.9505322));
    const float3x3 xyzToRGB = float3x3(
        float3( 3.2409699, -0.9692436,  0.0556301),
        float3(-1.5373832,  1.8759675, -0.2039770),
        float3(-0.4986108,  0.0415551,  1.0569715));
    const float3x3 xyzToBradford = float3x3(
        float3( 0.8951, -0.7502,  0.0389),
        float3( 0.2664,  1.7135, -0.0685),
        float3(-0.1614,  0.0367,  1.0296));
    const float3x3 bradfordToXYZ = float3x3(
        float3( 0.9869929,  0.4323053, -0.0085287),
        float3(-0.1470543,  0.5183603,  0.0400428),
        float3( 0.1599627,  0.0492912,  0.9684867));

    float3 lms = xyzToBradford * (rgbToXYZ * linearRGB);
    float3 gains = exp2(float3(
        temperature * 0.18 - tint * 0.035,
        tint * 0.14,
        -temperature * 0.18 - tint * 0.035));
    return xyzToRGB * (bradfordToXYZ * (lms * gains));
}

// Invertible shaper for the curve and HSL stages, which need a bounded 0..1
// domain. working/(1+working) maps 0 to 0, diffuse white to exactly 0.5 - a
// natural midpoint for curve controls - and unbounded highlights toward 1
// without ever clipping. Exactly invertible, so nothing is lost round-tripping.
inline float3 workingToShaper(float3 working) {
    return working / (1.0 + abs(working));
}

inline float3 shaperToWorking(float3 shaped) {
    return shaped / max(1.0 - abs(shaped), 0.0001);
}

// Applies an SDR-authored look to extended-range HDR.
//
// The looks are 0...1 Rec.709 transforms, and HDR carries roughly 4.9x diffuse
// white, so most of the highlight range has no entry in the table. Rather than
// clamping it away or leaving it ungraded, the signal is split at diffuse white:
//
//   - everything up to white is Rec.709-encoded - exactly the domain the look
//     was authored in - passed through the LUT, and decoded back. This is where
//     skin, foliage and midtones live, so the look lands as intended.
//   - the excess above white is carried through and re-joined, scaled by the
//     tint the look gives white itself. That keeps the join continuous and gives
//     highlights the same cast as the rest of the image.
//
// An identity LUT is exactly identity under this split, at every level including
// above white and below black, which is what Scripts/ValidateHDRGrade.swift
// checks.
inline float3 applyLUTHDR(float3 working,
                          texture3d<float, access::sample> lut,
                          float amount) {
    if (amount <= 0.0) {
        return working;
    }
    float3 base = clamp(working, 0.0, 1.0);
    float3 excess = working - base;
    float3 graded = rec709ToLinear(applyLUT(linearToRec709(base), lut, amount));
    float3 whitePoint = rec709ToLinear(applyLUT(float3(1.0), lut, amount));
    return graded + excess * whitePoint;
}

/// The extended-range core. Same split, and for the same reasons, as the SDR
/// `applyGradeCore`: colour-only stages here, frame-absolute ones in
/// `applyGradeFinishHDR`, masked local grades between the two.
template <typename Grade>
inline float3 applyGradeCoreHDR(float3 working,
                                constant Grade &grade,
                                texture2d<float, access::sample> curveLUT,
                                texture2d<float, access::sample> warpField) {
    float3 color = applyWhiteBalanceExtended(working, grade.color.x, grade.color.y);
    color *= exp2(grade.lightA.x);

    // Tonal masks are relative to diffuse white, which is 1.0 here, so the SDR
    // thresholds keep their meaning. Highlights above 1.0 sit at the top of the
    // highlight mask rather than being clipped into it.
    float luma = max(luminanceBT2020(color), 0.0);
    float shadowMask = 1.0 - smoothstep(0.08, 0.50, luma);
    float highlightMask = smoothstep(0.32, 1.0, luma);
    float blackMask = 1.0 - smoothstep(0.0, 0.18, luma);
    float whiteMask = smoothstep(0.62, 1.0, luma);
    float tonalDelta = grade.lightA.w * shadowMask * max(luma, 0.035) * 0.75
        + grade.lightA.z * highlightMask * max(luma, 0.08) * 0.65
        + grade.lightB.y * blackMask * 0.045
        + grade.lightB.x * whiteMask * 0.085;
    float adjustedLuma = max(luma + tonalDelta, 0.0);
    color = luma > 0.00001
        ? preserveHueLuminance(color, luma, adjustedLuma)
        : float3(adjustedLuma);

    // Contrast pivots on photographic middle grey in linear light, exactly as
    // the SDR path does. No clamp to zero: negatives are wide-gamut colour.
    float contrastSlope = exp2(grade.lightA.y * 0.85);
    color = (color - 0.18) * contrastSlope + 0.18;

    luma = luminanceBT2020(color);
    float maxCh = maxChannel(color);
    float minCh = min(color.r, min(color.g, color.b));
    float chroma = (maxCh - minCh) / max(abs(maxCh), 0.0001);
    float saturationScale = max(0.0, 1.0 + grade.color.z);
    float vibranceScale = 1.0 + grade.color.w * (1.0 - saturate(chroma)) * 0.75;
    color = mix(float3(luma), color, max(0.0, saturationScale * vibranceScale));

    color = offsetGrade(color, offsetWheelFor(grade));
    float tonalPosition = saturate(luminanceBT2020(color));
    float sw = 1.0 - smoothstep(0.02, 0.35, tonalPosition);
    float hw = smoothstep(0.35, 0.95, tonalPosition);
    float mw = max(0.0, 1.0 - sw - hw);
    color = wheelGrade(color, grade.shadowWheel, sw);
    color = wheelGrade(color, grade.midtoneWheel, mw);
    color = wheelGrade(color, grade.highlightWheel, hw);

    // Curves and HSL need a bounded domain. The shaper is invertible, so this
    // costs no highlight detail - unlike the SDR path's saturate().
    float3 shaped = workingToShaper(color);
    // curveValue and rgbToHSL both clamp at zero, which would delete the
    // negative coordinates that carry colour outside the P3 gamut - and would
    // make even a neutral grade shift those pixels. Split them off, grade the
    // in-gamut part, and add them back untouched.
    float3 outOfGamut = min(shaped, 0.0);
    shaped = max(shaped, 0.0);
    uint activeCurves = uint(grade.options.z + 0.5);
    uint curveRowBase = uint(max(grade.options.w, 0.0) + 0.5);
    shaped = applyToneCurves(shaped, curveLUT, activeCurves, curveRowBase);
    float3 inGamut = saturate(shaped);
    float3 hsl = rgbToHSL(inGamut);
    // The shaper's working space is BT.2020, so brightness is measured with
    // BT.2020 coefficients here rather than the SDR path's Rec.709 ones.
    float2 warpSource = hsl.xy;
    hsl = applyColorCurves(hsl, luminanceBT2020(inGamut), curveLUT, activeCurves, curveRowBase);
    hsl = applyColorWarp(hsl, warpSource, luminanceBT2020(inGamut), warpField,
                         colorWarpFor(grade), kBT2020LumaWeights);
    float4 bands[8] = {grade.hsl0, grade.hsl1, grade.hsl2, grade.hsl3, grade.hsl4, grade.hsl5, grade.hsl6, grade.hsl7};
    float3 delta = 0.0;
    for (int i = 0; i < 8; ++i) {
        float distance = abs(hsl.x - bands[i].w);
        distance = min(distance, 1.0 - distance);
        float weight = 1.0 - smoothstep(0.0, 1.0/6.0, distance);
        delta += bands[i].xyz * weight;
    }
    float colorMask = smoothstep(0.0, 0.1, hsl.y);
    hsl.x = fract(hsl.x + delta.x * colorMask + 1.0);
    hsl.y = saturate(hsl.y * (1.0 + delta.y));
    hsl.z = saturate(hsl.z + delta.z * 0.3 * colorMask);
    shaped = hslToRGB(hsl) + outOfGamut;
    // No clamp. The display transform is the only place highlights are touched.
    return shaperToWorking(shaped);
}

inline float3 applyGradeFinishHDR(float3 color, float2 uv, constant GradeUniforms &grade) {
    color = applyFadeExtended(color, grade.effectsA.x);

    // Vignette is multiplicative in linear light, so it needs no clamp.
    float radius = length((uv - 0.5) * 1.41421356);
    float midpoint = mix(0.1, 0.85, grade.vignette.y);
    float feather = mix(0.05, 0.65, grade.vignette.z);
    float mask = smoothstep(max(0.0, midpoint - feather), min(1.0, midpoint + feather), radius);
    color *= exp2(grade.vignette.x * mask * 1.5);

    // Grain is weighted against diffuse white, so a specular highlight three
    // stops above it is left alone rather than being the noisiest thing on
    // screen.
    return applyGrain(color, uv, grade.effectsA.y, grade.effectsA.w, luminanceBT2020(color));
}

inline float3 applyGradeHDR(float3 working,
                            float2 uv,
                            constant GradeUniforms &grade,
                            texture2d<float, access::sample> curveLUT,
                            texture2d<float, access::sample> warpField) {
    if (grade.options.x > 0.5) {
        // Original comparison: untouched, and crucially not clamped.
        return working;
    }
    return applyGradeFinishHDR(applyGradeCoreHDR(working, grade, curveLUT, warpField), uv, grade);
}

/// Extended-range masked local grades. A mask is geometry, so it is identical to
/// the SDR path; only the colour core differs, which is what keeps a window in
/// the same place whether the project is Rec.709, HLG or Apple Log.
inline float3 applyLocalGradesHDR(float3 color,
                                  float2 uv,
                                  constant LocalGradeStack &stack,
                                  texture2d<float, access::sample> curveLUT,
                                  texture2d<float, access::sample> warpField) {
    uint count = min(uint(max(stack.header.x, 0.0) + 0.5), kMaxLocalGrades);
    if (count == 0u) { return color; }
    float aspect = max(stack.header.y, 1e-4);
    for (uint i = 0u; i < count; ++i) {
        float weight = qualifierIgnoresShape(stack.layers[i])
            ? 1.0
            : localMaskWeight(uv, stack.layers[i], stack.points, aspect);
        // Keyed through the shaper, not on the raw working value: the shaper is
        // the bounded BT.2020 domain this path's curves and HSL bands already
        // measure hue and saturation in, so a qualifier selects the same pixels
        // the HSL controls beside it would.
        weight *= qualifierWeight(workingToShaper(color), stack.layers[i]);
        if (weight <= 0.0005) { continue; }
        color = mix(color, applyGradeCoreHDR(color, stack.layers[i], curveLUT, warpField), weight);
    }
    return color;
}

/// HDR/Log equivalent of `applyLookAndGrade`. Keeping the ungraded working
/// value here is important: outside an enabled mask we must restore the true
/// source, not the source after a creative LUT.
inline float3 applyLookAndGradeHDR(float3 working,
                                   float2 uv,
                                   constant GradeUniforms &grade,
                                   texture3d<float, access::sample> lut,
                                   texture2d<float, access::sample> curveLUT,
                                   texture2d<float, access::sample> warpField,
                                   constant LocalGradeStack &locals) {
    if (grade.options.x > 0.5) { return working; }
    float matte = localMatte(uv, locals);
    // Diffuse white is 1.0 in working space, so the matte reads as the same
    // greyscale it does on the SDR path rather than as a dim grey.
    if (matte >= 0.0) { return float3(matte); }
    float3 core = applyGradeCoreHDR(applyLUTHDR(working, lut, grade.options.y), grade, curveLUT, warpField);
    core = applyLocalGradesHDR(core, uv, locals, curveLUT, warpField);
    float3 graded = applyGradeFinishHDR(core, uv, grade);
    return mix(working, graded, gradeMaskWeight(uv, grade));
}

// ---------------------------------------------------------------------------
// Apple Log
//
// Constants and both branches come from Apple's "Apple Log Profile White Paper",
// September 2023 v1.1, sections "Transfer Function" and "Color Space". They are
// the same values as Core/Grading/AppleLog.swift, which is the CPU reference
// used to verify this against Apple's published table and against Apple's own
// 4096-entry decode LUT.
//
// Apple Log is scene-referred: the decoded value is proportional to scene
// reflectance, 0.18 being an 18% grey card, running up to 12.0 at 1200%. None of
// that range is clamped here, because the highlight latitude it carries is the
// entire reason to shoot Log.
// ---------------------------------------------------------------------------

constant float kAppleLogR0 = -0.05641088;
constant float kAppleLogRt = 0.01;
constant float kAppleLogC  = 47.28711236;
constant float kAppleLogBeta  = 0.00964052;
constant float kAppleLogGamma = 0.08550479;
constant float kAppleLogDelta = 0.69336945;
// c * (Rt - R0)^2, the encoded value where the toe meets the log curve.
constant float kAppleLogPt = kAppleLogC * (kAppleLogRt - kAppleLogR0) * (kAppleLogRt - kAppleLogR0);
// A 90% diffuse white card, which the working space places at 1.0.
constant float kAppleLogDiffuseWhite = 0.9;

// Decoding function, white paper "Decoding function".
inline float appleLogDecodeChannel(float p) {
    if (p < 0.0) {
        return kAppleLogR0;
    }
    if (p < kAppleLogPt) {
        return sqrt(p / kAppleLogC) + kAppleLogR0;
    }
    return exp2((p - kAppleLogDelta) / kAppleLogGamma) - kAppleLogBeta;
}

// Encoding function, white paper "Encoding function". Needed to put a graded
// image back into Log so Apple's own display-rendering LUT can be applied to it.
inline float appleLogEncodeChannel(float r) {
    if (r < kAppleLogR0) {
        return 0.0;
    }
    if (r < kAppleLogRt) {
        return kAppleLogC * (r - kAppleLogR0) * (r - kAppleLogR0);
    }
    return kAppleLogGamma * log2(r + kAppleLogBeta) + kAppleLogDelta;
}

inline float3 appleLogDecode(float3 p) {
    return float3(appleLogDecodeChannel(p.r),
                  appleLogDecodeChannel(p.g),
                  appleLogDecodeChannel(p.b));
}

inline float3 appleLogEncode(float3 r) {
    return float3(appleLogEncodeChannel(r.r),
                  appleLogEncodeChannel(r.g),
                  appleLogEncodeChannel(r.b));
}

// 10-bit samples arrive in 16-bit textures left-shifted by six, so a full-range
// code of 1023 reads as 65472/65535 rather than 1.0. This puts it back.
constant float kTenBitIn16 = 65535.0 / 65472.0;

// Y'C'BC'R -> R'G'B', inverted from the white paper's forward equations:
//   Y' = 0.2627R' + 0.6780G' + 0.0593B'
//   C'B = (B' - Y') / 1.8814,  C'R = (R' - Y') / 1.4746
// Full range: no footroom or headroom scaling, which is why the decoder is
// asked for the full-range format.
inline float3 appleLogYCbCrToRGB(float y, float2 cbcr) {
    float luma = y * kTenBitIn16;
    float cb = cbcr.x * kTenBitIn16 - 0.5;
    float cr = cbcr.y * kTenBitIn16 - 0.5;
    float r = luma + 1.4746 * cr;
    float b = luma + 1.8814 * cb;
    float g = (luma - 0.2627 * r - 0.0593 * b) / 0.6780;
    return float3(r, g, b);
}

// ---------------------------------------------------------------------------
// Apple Log 2
//
// Apple Log 2 is the Apple Log transfer function on Apple Wide Gamut primaries
// rather than BT.2020 — that is the whole of the difference, per Apple's
// Apple Log 2 white paper and the ACES OCIO config, which reuses the Apple Log
// curve for it and differs only by a 3x3.
//
// So the curve above is shared verbatim and this adds one matrix, selected by a
// function constant. A function constant rather than a uniform for two reasons:
// the choice is a property of the source file and cannot change between frames,
// and specialisation means the Apple Log pipelines compile to *exactly* the code
// they compiled to before — the branch does not exist in the v1 variant, so the
// validated v1 path is untouched by construction rather than by inspection.
// ---------------------------------------------------------------------------

constant bool kAppleLog2Requested [[function_constant(0)]];
constant bool kSourceIsAppleLog2 =
    is_function_constant_defined(kAppleLog2Requested) ? kAppleLog2Requested : false;

// Linear Apple Wide Gamut -> linear BT.2020, D65 to D65 so no chromatic
// adaptation is involved. Written as columns, which is what float3x3 takes; the
// rows are the matrix in Core/Grading/AppleLog.swift, which is the CPU reference
// this is verified against.
constant float3x3 kAppleWideGamutToBT2020 = float3x3(
    float3( 1.0281009382,  0.0025203419, -0.0220875732),
    float3( 0.0989788177,  1.1708496433, -0.0640503834),
    float3(-0.1270797558, -0.1733699853,  1.0861379567));

// The complete input transform: camera samples to the linear working space the
// grading stage already uses, with diffuse white at 1.0.
//
// The gamut matrix is applied after the curve is undone and before the diffuse
// white normalisation, because a primaries conversion is only meaningful in
// linear light. Out-of-BT.2020 colour is carried through negative, not clipped:
// the grade runs in unclamped float and can pull it back, and the display encode
// at the end of the chain is where clamping already happens.
inline float3 appleLogToWorking(float y, float2 cbcr) {
    float3 encoded = appleLogYCbCrToRGB(y, cbcr);
    float3 scene = appleLogDecode(encoded);
    if (kSourceIsAppleLog2) {
        scene = kAppleWideGamutToBT2020 * scene;
    }
    return scene / kAppleLogDiffuseWhite;
}

// Working space -> Rec.709 display, through Apple's own rendering.
//
// The white paper defines the encoding, the decoding and the colour space, but
// no display transform, so one is not invented here. The graded image is put
// back into Log — the round trip is exact — and handed to Apple's published
// Apple Log to Rec.709 LUT, which carries Apple's own tone rendering and
// highlight rolloff. An ungraded frame therefore comes out exactly as Apple
// renders it.
inline float3 appleLogWorkingToRec709(float3 working,
                                      texture3d<float, access::sample> renderingLUT) {
    float3 scene = working * kAppleLogDiffuseWhite;
    float3 encoded = saturate(appleLogEncode(scene));
    constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float size = float(renderingLUT.get_width());
    // Every caller must bind Apple's LUT. CPU preparation refuses otherwise;
    // there is no alternative display transform for this input format.
    float3 coordinate = (encoded * (size - 1.0) + 0.5) / size;
    return renderingLUT.sample(lutSampler, coordinate).rgb;
}

// Apple Log preview. The input transform differs; everything after it is the
// same extended-range path HLG already uses, so the grading tools, the look
// stage and the finishing effects are shared rather than duplicated.
fragment float4 previewFragmentAppleLog(
    RasterData in [[stage_in]],
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture3d<float, access::sample> renderingLUT [[texture(4)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(1)]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = lumaTexture.sample(videoSampler, in.textureCoordinate).r;
    float2 cbcr = chromaTexture.sample(videoSampler, in.textureCoordinate).rg;
    float3 working = appleLogToWorking(y, cbcr);
    if (grade.options.x > 0.5) {
        // Original comparison bypasses the creative grade but NOT the input
        // transform: raw Log is not a picture, and showing it would make the
        // comparison meaningless.
        return float4(applyViewerAssist(appleLogWorkingToRec709(working, renderingLUT),
                                        in.position.xy, grade), 1.0);
    }
    working = applyLookAndGradeHDR(
        working, in.textureCoordinate, grade, lutTexture, curveLUT, warpField, locals);
    return float4(applyViewerAssist(appleLogWorkingToRec709(working, renderingLUT),
                                    in.position.xy, grade), 1.0);
}

// The drawable is an HLG-tagged surface with CAEDRMetadata.hlg attached, so the
// output here is the HLG signal and the system applies the OOTF and the
// display's own tone mapping - the same path Photos uses, which is what makes
// the preview match it rather than approximate it.
fragment float4 previewFragmentHDR(
    RasterData in [[stage_in]],
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant HDRDisplayUniforms &hdr [[buffer(0)]],
    constant GradeUniforms &grade [[buffer(1)]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 sample = sourceTexture.sample(videoSampler, in.textureCoordinate);
    if (grade.options.x > 0.5) {
        // Original: untouched signal
        return float4(applyViewerAssist(saturate(sample.rgb), in.position.xy, grade), 1.0);
    }
    float3 working = toWorkingSpace(sample.rgb, hdr);
    working = applyLookAndGradeHDR(
        working, in.textureCoordinate, grade, lutTexture, curveLUT, warpField, locals);
    return float4(applyViewerAssist(workingToSignal(working, hdr), in.position.xy, grade), 1.0);
}


// ---------------------------------------------------------------------------
// HDR layer compositing
//
// The SDR compositor grades each layer to 8-bit BGRA and composites with Core
// Image in Rec.709. Neither step can carry an HDR image, so this is a parallel
// Metal path that composites in the SAME working space the HDR preview and the
// HDR encoder already share: linear light, BT.2020 primaries, diffuse white at
// 1.0. Compositing there is also more correct than the SDR path is - opacity
// and frame blending are linear-light operations - so nothing is being traded
// away for the sake of HDR.
//
// The canvas is an rgba16Float texture in working space. Layers are composited
// into it back to front, and one final pass converts it to the HLG signal.
// ---------------------------------------------------------------------------

struct HDRLayerUniforms {
    // Canvas pixel (top-left origin) -> source texture uv, as three rows of an
    // affine matrix. SIMD4 rows keep Swift and Metal alignment identical, the
    // same reason YUVUniforms uses them.
    float4 row0;
    float4 row1;
    float4 params;   // x = opacity, y = blend amount, z = source is SDR, w = premultiplied
    float4 matte;    // x = track matte is inverted (coverage is 1 - alpha); y..w spare
};

struct LayerMaskUniforms {
    float4 geometry; // centre x/y and width/height in source coordinates
    float4 options;  // rotation, feather, enabled amount, shape/invert flags
};

inline float layerMaskWeight(float2 uv, constant LayerMaskUniforms &mask) {
    return softShapeMaskWeight(uv, mask.geometry, mask.options);
}

// Track matte coverage at a CANVAS pixel.
//
// The matte is rendered full-canvas, in the same top-left pixel order the
// destination is written in, so the lookup is the pixel's own position and no
// per-layer transform is involved: the target and the source agree only in
// canvas space, which is the whole reason the matte is built there.
//
// ALPHA only. The source's colour never reaches this - opaque black and opaque
// white cut identically - and where no matte is set the bound texture is a 1x1
// opaque pixel, so this returns 1 and coverage is unchanged.
//
// `inverted` is 0 or 1 and selects between alpha and 1 - alpha. A branchless
// mix, and nothing is thresholded: a glyph edge at 0.15 becomes 0.85 and stays
// exactly as smooth, which is the whole point of reading alpha rather than a
// binary mask.
inline float trackMatteCoverage(texture2d<float, access::sample> matte, float2 canvasUV, float inverted) {
    // An UNBOUND matte samples as zero, which reads as "no coverage" and blacks
    // the layer out entirely. The compositor always binds something - a 1x1
    // opaque pixel when a layer has no matte - but a caller that drives these
    // kernels directly need not know that, and a silently black frame is the
    // worst possible way to tell it. No matte means full coverage.
    if (is_null_texture(matte)) { return 1.0; }
    constexpr sampler matteSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float coverage = matte.sample(matteSampler, canvasUV).a;
    return mix(coverage, 1.0 - coverage, inverted);
}

inline float trackMatteCoverage(texture2d<float, access::sample> matte, uint2 position,
                                float2 canvasSize, float inverted) {
    return trackMatteCoverage(matte, (float2(position) + 0.5) / canvasSize, inverted);
}

inline float backgroundRemovalCoverage(texture2d<float, access::sample> matte, float2 uv) {
    if (is_null_texture(matte)) return 1.0;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return matte.sample(s, uv).r;
}

inline float3 suppressBackgroundSpill(float3 color, float coverage,
                                      constant BackgroundRemovalUniforms &u) {
    if (u.controls.w <= 0.5 || u.controls.z <= 0.0 || coverage <= 0.01 || coverage >= 0.995) {
        return color;
    }
    float edge = (1.0 - abs(coverage * 2.0 - 1.0)) * u.controls.z;
    uint dominant = u.keyColor.g >= u.keyColor.r && u.keyColor.g >= u.keyColor.b ? 1
                  : (u.keyColor.b >= u.keyColor.r ? 2 : 0);
    float others = dominant == 0 ? max(color.g, color.b)
                 : dominant == 1 ? max(color.r, color.b) : max(color.r, color.g);
    color[dominant] = mix(color[dominant], min(color[dominant], others), edge);
    return color;
}

// ITU-R BT.2087 Rec.709 -> BT.2020, derived from the two sets of primaries with
// a D65 white point and cross-checked against the matrix published in BT.2087.
// White maps to white exactly, so an SDR white lands on diffuse white and, after
// the output transform, on BT.2408 reference white - the same place AVFoundation
// puts it on the direct path (measured, Docs/HDR_PIPELINE_PLAN.md 2).
constant float3x3 kRec709ToBT2020 = float3x3(
    float3(0.627404, 0.069097, 0.016391),
    float3(0.329283, 0.919540, 0.088013),
    float3(0.043313, 0.011362, 0.895595));

// An SDR layer - a Rec.709 video source, rendered text, a still image - enters
// the working space through its own transfer function and a gamut conversion.
// No scaling is needed: the working space is normalised so diffuse white is 1.0,
// which is exactly what an SDR 1.0 means.
inline float3 sdrToWorking(float3 encoded) {
    return kRec709ToBT2020 * rec709ToLinear(encoded);
}

inline float2 layerCoordinate(constant HDRLayerUniforms &layer, uint2 position) {
    float3 p = float3(float(position.x) + 0.5, float(position.y) + 0.5, 1.0);
    return float2(dot(layer.row0.xyz, p), dot(layer.row1.xyz, p));
}

// Preview-only bottom canvas for communicating transparency. Export-created
// render state never enables it, so these pixels cannot reach an output file.
kernel void fillEditorCheckerboard(
    texture2d<float, access::write> destination [[texture(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) return;
    uint square = 14;
    bool alternate = ((position.x / square) + (position.y / square)) & 1;
    float level = alternate ? 0.0331 : 0.0152; // roughly sRGB 0.20 / 0.13 in linear light
    destination.write(float4(level, level, level, 1.0), position);
}

// Composites one video layer onto the working-space canvas.
//
// Frame blending happens here, between the two frames' WORKING-space values,
// before grading. Mixing in the encoded signal would weight the two frames by a
// non-linear function of their brightness, and grading each side separately and
// mixing afterwards would apply the tone curves twice.
kernel void compositeVideoHDR(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::sample> partner [[texture(1)]],
    texture2d<float, access::read> base [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    texture3d<float, access::sample> lutTexture [[texture(4)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    texture2d<float, access::sample> trackMatte [[texture(8)]],
    texture2d<float, access::sample> backgroundMatte [[texture(9)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(1)]],
    constant HDRLayerUniforms &layer [[buffer(2)]],
    constant LayerMaskUniforms &mask [[buffer(3)]],
    constant BackgroundRemovalUniforms &backgroundRemoval [[buffer(4)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) {
        return;
    }
    float3 under = base.read(position).rgb;
    float2 uv = layerCoordinate(layer, position);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        destination.write(float4(under, 1.0), position);
        return;
    }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 working = layer.params.z > 0.5
        ? sdrToWorking(source.sample(videoSampler, uv).rgb)
        : toWorkingSpace(source.sample(videoSampler, uv).rgb, hdr);
    if (layer.params.y > 0.0) {
        float3 next = layer.params.z > 0.5
            ? sdrToWorking(partner.sample(videoSampler, uv).rgb)
            : toWorkingSpace(partner.sample(videoSampler, uv).rgb, hdr);
        working = mix(working, next, layer.params.y);
    }
    working = applyLookAndGradeHDR(working, uv, grade, lutTexture, curveLUT, warpField, locals);
    float backgroundCoverage = backgroundRemovalCoverage(backgroundMatte, uv);
    working = suppressBackgroundSpill(working, backgroundCoverage, backgroundRemoval);
    float alpha = layer.params.x * backgroundCoverage
        * layerMaskWeight(uv, mask)
        * trackMatteCoverage(trackMatte, position,
                             float2(destination.get_width(), destination.get_height()),
                             layer.matte.x);
    destination.write(float4(mix(under, working, alpha), 1.0), position);
}

// Composites a rendered SDR image - text, or a still - onto the canvas. It
// carries its own alpha, premultiplied by Core Image, so it is unpremultiplied
// before the transfer function and re-applied as coverage afterwards.
kernel void compositeImageHDR(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::read> base [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    texture2d<float, access::sample> trackMatte [[texture(8)]],
    texture2d<float, access::sample> backgroundMatte [[texture(9)]],
    constant HDRLayerUniforms &layer [[buffer(2)]],
    constant LayerMaskUniforms &mask [[buffer(3)]],
    constant BackgroundRemovalUniforms &backgroundRemoval [[buffer(4)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) {
        return;
    }
    float3 under = base.read(position).rgb;
    float2 uv = layerCoordinate(layer, position);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        destination.write(float4(under, 1.0), position);
        return;
    }
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 sample = source.sample(imageSampler, uv);
    float backgroundCoverage = backgroundRemovalCoverage(backgroundMatte, uv);
    float alpha = sample.a * layer.params.x * backgroundCoverage
        * layerMaskWeight(uv, mask)
        * trackMatteCoverage(trackMatte, position,
                             float2(destination.get_width(), destination.get_height()),
                             layer.matte.x);
    float3 straight = layer.params.w > 0.5 && sample.a > 0.0001 ? sample.rgb / sample.a : sample.rgb;
    straight = suppressBackgroundSpill(straight, backgroundCoverage, backgroundRemoval);
    destination.write(float4(mix(under, sdrToWorking(straight), alpha), 1.0), position);
}

// The canvas is finished: convert working space to the HLG signal the drawable
// and the encoder both expect. This is the same `workingToSignal` the direct
// HDR preview and the HDR export use, so a composited frame and a
// non-composited one reach the display through identical maths.
kernel void resolveHDRCanvas(
    texture2d<float, access::read> canvas [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant HDRDisplayUniforms &hdr [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) {
        return;
    }
    destination.write(float4(workingToSignal(canvas.read(position).rgb, hdr), 1.0), position);
}

// ---------------------------------------------------------------------------
// HDR encode path: working space -> HLG BT.2020 10-bit 4:2:0 video range.
//
// The decoder was asked for BT.2020 primaries, so no gamut conversion is needed
// and no OOTF is involved: the file stores the HLG signal, exactly what the
// preview presents.
// ---------------------------------------------------------------------------

// BT.2020 non-constant-luminance YCbCr.
inline float3 hlgSignalToYCbCr2020(float3 signal) {
    float y = luminanceBT2020(signal);
    return float3(y, (signal.b - y) / 1.8814, (signal.r - y) / 1.4746);
}

// A 10-bit code as an r16Unorm/rg16Unorm value. 'x420' keeps 10-bit samples in
// the high bits of a 16-bit word - which is why the decode path treats a
// unorm16 read as code/1023 - so writing code<<6 puts the intended code where
// the encoder looks for it.
inline float encodeVideoRange10(float code) {
    // Rounded to a whole 10-bit code before packing, so the sample lands exactly
    // in the top 10 bits of its 16-bit container with the low 6 zero, which is
    // what the 'x420'/'x422' layouts mean. Without the round, a fractional code
    // kept sub-code precision in those low bits and a reader taking the top ten
    // truncated instead of rounding — a consistent downward bias of up to one
    // code on every 10-bit frame this writes.
    return round(clamp(code, 0.0, 1023.0)) * 64.0 / 65535.0;
}

// One thread per chroma sample, i.e. per 2x2 luma block, so 4:2:0 subsampling
// happens by averaging the four graded colours rather than by point-sampling
// one of them.
kernel void gradeExportHDR(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> lumaOut [[texture(1)]],
    texture2d<float, access::write> chromaOut [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(1)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= chromaOut.get_width() || position.y >= chromaOut.get_height()) {
        return;
    }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 lumaSize = float2(lumaOut.get_width(), lumaOut.get_height());

    float3 signals[4];
    float3 signalSum = 0.0;
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            float2 uv = (float2(p) + 0.5) / lumaSize;
            float3 working = toWorkingSpace(source.sample(videoSampler, uv).rgb, hdr);
            working = applyLookAndGradeHDR(working, uv, grade, lutTexture, curveLUT, warpField, locals);
            float3 signal = workingToSignal(working, hdr);
            signals[j * 2 + i] = signal;
            signalSum += signal;
        }
    }

    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            if (p.x >= uint(lumaSize.x) || p.y >= uint(lumaSize.y)) {
                continue;
            }
            float luma = hlgSignalToYCbCr2020(signals[j * 2 + i]).x;
            lumaOut.write(float4(encodeVideoRange10(64.0 + luma * 876.0)), p);
        }
    }

    float3 chroma = hlgSignalToYCbCr2020(signalSum * 0.25);
    chromaOut.write(float4(encodeVideoRange10(512.0 + chroma.y * 896.0),
                           encodeVideoRange10(512.0 + chroma.z * 896.0),
                           0.0, 1.0), position);
}

inline float3 decodeYUV(float y, float2 uv, constant YUVUniforms &transform) {
    float3 sample = float3(y, uv) + transform.offset.xyz;
    return transform.column0.xyz * sample.x
         + transform.column1.xyz * sample.y
         + transform.column2.xyz * sample.z;
}

inline float keyDistance(float3 rgb, float3 key) {
    // Chroma-only Y'CbCr distance. Luma is intentionally absent: a shadowed
    // green and a lit green remain the same screen colour.
    float2 c = float2(-0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b,
                       0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b);
    float2 k = float2(-0.168736 * key.r - 0.331264 * key.g + 0.5 * key.b,
                       0.5 * key.r - 0.418688 * key.g - 0.081312 * key.b);
    return distance(c, k);
}

inline float colorKeyCoverage(float3 rgb, constant BackgroundRemovalUniforms &u) {
    float low = u.controls.x;
    return smoothstep(low, low + max(u.controls.y, 0.0005), keyDistance(rgb, u.keyColor.rgb));
}

inline float sampledMask(texture2d<float, access::sample> mask, float2 uv, float fallback) {
    if (is_null_texture(mask)) return fallback;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return mask.sample(s, uv).r;
}

inline float finishBackgroundCoverage(float base, float2 uv,
                                      texture2d<float, access::sample> addMask,
                                      texture2d<float, access::sample> removeMask,
                                      constant BackgroundRemovalUniforms &u) {
    base = max(base, sampledMask(addMask, uv, 0.0));
    base *= 1.0 - sampledMask(removeMask, uv, 0.0);
    return mix(saturate(base), 1.0 - saturate(base), u.edge.z);
}

kernel void buildBackgroundMaskYUV(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d<float, access::sample> automaticMask [[texture(2)]],
    texture2d<float, access::sample> addMask [[texture(3)]],
    texture2d<float, access::sample> removeMask [[texture(4)]],
    texture2d<float, access::write> output [[texture(5)]],
    constant BackgroundRemovalUniforms &u [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(output.get_width(), output.get_height());
    float2 uv = (float2(p) + 0.5) / size;
    float radius = abs(u.edge.y);
    float feather = u.edge.x;
    float base = u.controls.w > 0.5
        ? colorKeyCoverage(decodeYUV(luma.sample(s, uv).r, chroma.sample(s, uv).rg, yuv), u)
        : sampledMask(automaticMask, uv, 1.0);
    const float2 directions[8] = { float2(-1,-1), float2(0,-1), float2(1,-1), float2(-1,0),
                                   float2(1,0), float2(-1,1), float2(0,1), float2(1,1) };
    if (radius > 0.00001) {
        float shifted = base;
        for (uint i = 0; i < 8; ++i) {
            float2 q = uv + directions[i] * radius;
            float v = u.controls.w > 0.5
                ? colorKeyCoverage(decodeYUV(luma.sample(s, q).r, chroma.sample(s, q).rg, yuv), u)
                : sampledMask(automaticMask, q, 1.0);
            shifted = u.edge.y > 0 ? max(shifted, v) : min(shifted, v);
        }
        base = shifted;
    }
    if (feather > 0.00001) {
        float total = base;
        for (uint i = 0; i < 8; ++i) {
            float2 q = uv + directions[i] * feather;
            total += u.controls.w > 0.5
                ? colorKeyCoverage(decodeYUV(luma.sample(s, q).r, chroma.sample(s, q).rg, yuv), u)
                : sampledMask(automaticMask, q, 1.0);
        }
        base = total / 9.0;
    }
    output.write(float4(finishBackgroundCoverage(base, uv, addMask, removeMask, u)), p);
}

kernel void buildBackgroundMaskBGRA(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::sample> automaticMask [[texture(2)]],
    texture2d<float, access::sample> addMask [[texture(3)]],
    texture2d<float, access::sample> removeMask [[texture(4)]],
    texture2d<float, access::write> output [[texture(5)]],
    constant BackgroundRemovalUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
    float base = u.controls.w > 0.5 ? colorKeyCoverage(source.sample(s, uv).rgb, u)
                                    : sampledMask(automaticMask, uv, 1.0);
    const float2 directions[8] = { float2(-1,-1), float2(0,-1), float2(1,-1), float2(-1,0),
                                   float2(1,0), float2(-1,1), float2(0,1), float2(1,1) };
    float radius = abs(u.edge.y);
    if (radius > 0.00001) {
        float shifted = base;
        for (uint i = 0; i < 8; ++i) {
            float2 q = uv + directions[i] * radius;
            float v = u.controls.w > 0.5 ? colorKeyCoverage(source.sample(s, q).rgb, u)
                                         : sampledMask(automaticMask, q, 1.0);
            shifted = u.edge.y > 0 ? max(shifted, v) : min(shifted, v);
        }
        base = shifted;
    }
    if (u.edge.x > 0.00001) {
        float total = base;
        for (uint i = 0; i < 8; ++i) {
            float2 q = uv + directions[i] * u.edge.x;
            total += u.controls.w > 0.5 ? colorKeyCoverage(source.sample(s, q).rgb, u)
                                        : sampledMask(automaticMask, q, 1.0);
        }
        base = total / 9.0;
    }
    output.write(float4(finishBackgroundCoverage(base, uv, addMask, removeMask, u)), p);
}

kernel void applyBackgroundRemovalBGRA(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::sample> matte [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant BackgroundRemovalUniforms &u [[buffer(0)]],
    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= destination.get_width() || p.y >= destination.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(destination.get_width(), destination.get_height());
    float coverage = backgroundRemovalCoverage(matte, uv);
    float4 pixel = source.read(p);
    float3 straight = pixel.a > 0.00001 ? pixel.rgb / pixel.a : float3(0);
    if (u.controls.w > 0.5 && u.controls.z > 0 && coverage > 0.01 && coverage < 0.995) {
        float edge = (1.0 - abs(coverage * 2.0 - 1.0)) * u.controls.z;
        uint dominant = u.keyColor.g >= u.keyColor.r && u.keyColor.g >= u.keyColor.b ? 1
                      : (u.keyColor.b >= u.keyColor.r ? 2 : 0);
        float others = dominant == 0 ? max(straight.g, straight.b)
                     : dominant == 1 ? max(straight.r, straight.b) : max(straight.r, straight.g);
        straight[dominant] = mix(straight[dominant], min(straight[dominant], others), edge);
    }
    float alpha = pixel.a * coverage;
    destination.write(float4(straight * alpha, alpha), p);
}

fragment float4 gradeFragmentYUV(
    RasterData in [[stage_in]],
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = lumaTexture.sample(videoSampler, in.textureCoordinate).r;
    float2 uv = chromaTexture.sample(videoSampler, in.textureCoordinate).rg;
    float3 graded = applyLookAndGrade(decodeYUV(y, uv, yuv), in.textureCoordinate,
                                      grade, lutTexture, curveLUT, warpField, locals);
    return float4(applyViewerAssist(graded, in.position.xy, grade), 1.0);
}

fragment float4 gradeFragmentBGRA(
    RasterData in [[stage_in]],
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 pixel = sourceTexture.sample(videoSampler, in.textureCoordinate);
    float3 straight = pixel.a > 0.00001 ? pixel.rgb / pixel.a : float3(0);
    float3 graded = applyViewerAssist(
        applyLookAndGrade(straight, in.textureCoordinate, grade, lutTexture, curveLUT, warpField, locals),
        in.position.xy, grade);
    float2 cell = floor(in.position.xy / 14.0);
    float checker = fmod(cell.x + cell.y, 2.0) < 1.0 ? 0.16 : 0.24;
    return float4(mix(float3(checker), graded, pixel.a), 1.0);
}

kernel void gradeExportBGRA(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 coordinate = (float2(position) + 0.5) /
        float2(outputTexture.get_width(), outputTexture.get_height());
    float y = lumaTexture.sample(videoSampler, coordinate).r;
    float2 uv = chromaTexture.sample(videoSampler, coordinate).rg;
    outputTexture.write(float4(applyLookAndGrade(decodeYUV(y, uv, yuv), coordinate, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}

// ---------------------------------------------------------------------------
// Grade into a texture
//
// Every output path grades and writes in one pass, which is the cheapest thing
// to do and is what happens whenever no spatial effect is switched on. When one
// is, the spatial stage needs the graded frame as a texture it can read
// neighbours from, so these produce exactly that and the output conversion
// happens afterwards.
//
// SDR writes the encoded RGB the display receives. HDR writes WORKING SPACE,
// not the signal: a glow is light adding to light, and adding it in the signal
// would weight it by a non-linear function of brightness.
// ---------------------------------------------------------------------------

kernel void gradeToTextureYUV(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    float3 rgb = decodeYUV(lumaTexture.sample(videoSampler, uv).r,
                           chromaTexture.sample(videoSampler, uv).rg, yuv);
    destination.write(float4(applyLookAndGrade(rgb, uv, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}

kernel void gradeToTextureBGRA(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    float4 pixel = source.sample(videoSampler, uv);
    float3 straight = pixel.a > 0.00001 ? pixel.rgb / pixel.a : float3(0);
    destination.write(float4(applyLookAndGrade(straight, uv, grade, lutTexture, curveLUT, warpField, locals), pixel.a), position);
}

kernel void gradeToTextureHDR(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(2)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    float3 working = toWorkingSpace(source.sample(videoSampler, uv).rgb, hdr);
    destination.write(float4(applyLookAndGradeHDR(
        working, uv, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}

// ---------------------------------------------------------------------------
// Output conversions from a finished frame
// ---------------------------------------------------------------------------

// Preview: draw a finished SDR frame straight to the drawable.
fragment float4 presentFragmentSDR(
    RasterData in [[stage_in]],
    texture2d<float, access::sample> source [[texture(0)]],
    constant GradeUniforms &grade [[buffer(0)]])
{
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 pixel = source.sample(videoSampler, in.textureCoordinate);
    // Editor-only transparency furniture. The exported pixels never pass this
    // fragment; it simply makes a cutout legible when no lower layer exists.
    float2 cell = floor(in.position.xy / 14.0);
    float checker = fmod(cell.x + cell.y, 2.0) < 1.0 ? 0.16 : 0.24;
    float3 straight = applyViewerAssist(saturate(pixel.rgb), in.position.xy, grade);
    return float4(mix(float3(checker), straight, pixel.a), 1.0);
}

// Preview: a finished HDR frame is in working space, so the display transform
// still has to run — the same `workingToSignal` the direct path uses.
fragment float4 presentFragmentHDR(
    RasterData in [[stage_in]],
    texture2d<float, access::sample> source [[texture(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(0)]],
    constant GradeUniforms &grade [[buffer(1)]])
{
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 signal = workingToSignal(source.sample(videoSampler, in.textureCoordinate).rgb, hdr);
    return float4(applyViewerAssist(signal, in.position.xy, grade), 1.0);
}

// ---------------------------------------------------------------------------
// Scope analysis sampling
//
// Scopes analyse the FINAL GRADED image, so these run the same grading
// functions the preview fragment shaders run — `applyLookAndGrade` for SDR
// (look/LUT, light, colour, curves, HSL, wheels, vignette) and the working-space
// chain for HDR. Only the resolution differs: the result is written to a small
// analysis texture instead of the drawable.
//
// They live here rather than in ScopeShaders.metal because they need the
// grading helpers, and a second copy of that maths is the one thing that could
// make the scopes disagree with the picture.
//
// Sampling is NEAREST, deliberately. Averaging 4K down to 512 would soften
// clipped highlights and crushed blacks into mid values, and a scope that hides
// clipping is worse than no scope. Point-sampling a regular grid reports real
// pixel values.
// ---------------------------------------------------------------------------

inline float2 scopeCoordinate(texture2d<float, access::write> analysis, uint2 position) {
    return (float2(position) + 0.5) / float2(analysis.get_width(), analysis.get_height());
}

kernel void scopeSampleYUV(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> analysis [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= analysis.get_width() || position.y >= analysis.get_height()) {
        return;
    }
    constexpr sampler scopeSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = scopeCoordinate(analysis, position);
    float3 rgb = decodeYUV(lumaTexture.sample(scopeSampler, uv).r,
                           chromaTexture.sample(scopeSampler, uv).rg, yuv);
    analysis.write(float4(applyLookAndGrade(rgb, uv, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}

kernel void scopeSampleBGRA(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::write> analysis [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= analysis.get_width() || position.y >= analysis.get_height()) {
        return;
    }
    constexpr sampler scopeSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = scopeCoordinate(analysis, position);
    float3 rgb = sourceTexture.sample(scopeSampler, uv).rgb;
    analysis.write(float4(applyLookAndGrade(rgb, uv, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}

// HDR: the analysis texture carries the HLG SIGNAL, which is what the display
// receives and what the encoder writes. Scope readings are therefore signal
// values, not scene light, and the panel says so rather than implying an
// absolute-brightness reading it cannot make.
kernel void scopeSampleHDR(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::write> analysis [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(2)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= analysis.get_width() || position.y >= analysis.get_height()) {
        return;
    }
    constexpr sampler scopeSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = scopeCoordinate(analysis, position);
    float3 signal = sourceTexture.sample(scopeSampler, uv).rgb;
    if (grade.options.x > 0.5) {
        analysis.write(float4(saturate(signal), 1.0), position);
        return;
    }
    float3 working = toWorkingSpace(signal, hdr);
    working = applyLookAndGradeHDR(working, uv, grade, lutTexture, curveLUT, warpField, locals);
    analysis.write(float4(workingToSignal(working, hdr), 1.0), position);
}

// Frame blending and grading in one pass.
//
// Blending used to be a separate Core Image render into a full-size buffer,
// which at 4K cost an entire extra surface and pass per frame — the difference
// between a preview that keeps up and one that does not. The two frames are
// decoded and mixed here instead, before grading, so the tone curves are still
// applied once to the blended image.
kernel void gradeBlendedBGRA(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> partnerLuma [[texture(4)]],
    texture2d<float, access::sample> partnerChroma [[texture(5)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    constant float &amount [[buffer(2)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= outputTexture.get_width() || position.y >= outputTexture.get_height()) {
        return;
    }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 coordinate = (float2(position) + 0.5) /
        float2(outputTexture.get_width(), outputTexture.get_height());
    float3 first = decodeYUV(lumaTexture.sample(videoSampler, coordinate).r,
                             chromaTexture.sample(videoSampler, coordinate).rg, yuv);
    float3 second = decodeYUV(partnerLuma.sample(videoSampler, coordinate).r,
                              partnerChroma.sample(videoSampler, coordinate).rg, yuv);
    float3 mixed = mix(first, second, clamp(amount, 0.0, 1.0));
    outputTexture.write(float4(applyLookAndGrade(mixed, coordinate, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}

// 10-bit Rec.709 SDR export.
//
// Identical colour handling to the 8-bit path — the same `applyLookAndGrade` —
// with the only difference being that the result is written as 10-bit 4:2:0
// video range instead of 8-bit BGRA. Precision is carried, not the look changed.
inline float3 rec709ToYCbCr(float3 encoded) {
    float y = dot(encoded, float3(0.2126, 0.7152, 0.0722));
    return float3(y, (encoded.b - y) / 1.8556, (encoded.r - y) / 1.5748);
}

kernel void gradeExportSDR10(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> lumaOut [[texture(4)]],
    texture2d<float, access::write> chromaOut [[texture(5)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= chromaOut.get_width() || position.y >= chromaOut.get_height()) {
        return;
    }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 lumaSize = float2(lumaOut.get_width(), lumaOut.get_height());

    float3 graded[4];
    float3 sum = 0.0;
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            float2 uv = (float2(p) + 0.5) / lumaSize;
            float y = lumaTexture.sample(videoSampler, uv).r;
            float2 c = chromaTexture.sample(videoSampler, uv).rg;
            float3 rgb = applyLookAndGrade(decodeYUV(y, c, yuv), uv, grade, lutTexture, curveLUT, warpField, locals);
            graded[j * 2 + i] = rgb;
            sum += rgb;
        }
    }

    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            if (p.x >= uint(lumaSize.x) || p.y >= uint(lumaSize.y)) {
                continue;
            }
            float luma = rec709ToYCbCr(graded[j * 2 + i]).x;
            lumaOut.write(float4(encodeVideoRange10(64.0 + luma * 876.0)), p);
        }
    }

    float3 chroma = rec709ToYCbCr(sum * 0.25);
    chromaOut.write(float4(encodeVideoRange10(512.0 + chroma.y * 896.0),
                           encodeVideoRange10(512.0 + chroma.z * 896.0),
                           0.0, 1.0), position);
}

kernel void gradeStillBGRA(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> output [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    uint2 p [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float4 pixel = source.read(p);
    float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
    float3 straight = pixel.a > 0.00001 ? pixel.rgb / pixel.a : float3(0);
    output.write(float4(applyLookAndGrade(straight, uv, grade, lutTexture, curveLUT, warpField, locals) * pixel.a, pixel.a), p);
}

/// Applies structural layer coverage after grading and spatial effects. Keeping
/// this separate from the grading mask is what lets a transparent area reveal
/// already-composited tracks below without changing their colour.
kernel void applyLayerMaskBGRA(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant LayerMaskUniforms &mask [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    float2 uv = (float2(position) + 0.5) /
        float2(destination.get_width(), destination.get_height());
    float4 pixel = source.read(position);
    float coverage = layerMaskWeight(uv, mask);
    destination.write(float4(pixel.rgb * coverage, pixel.a * coverage), position);
}

// ---------------------------------------------------------------------------
// Timeline transitions
//
// Both inputs have already passed through their own complete clip grade. This
// kernel only performs visual transition maths, so preview and AVAssetReader
// export use the exact same pixels and normalized progress.
// ---------------------------------------------------------------------------

struct TransitionUniforms {
    uint type;
    float progress;
    float aspectRatio;
    float padding;
};

inline float easeTransition(float t) {
    return t * t * (3.0 - 2.0 * t);
}

inline float4 transitionSample(texture2d<float, access::sample> image, float2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return float4(0.0);
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return image.sample(s, uv);
}

inline float4 directionalBlur(texture2d<float, access::sample> image, float2 uv, float2 direction, float amount) {
    float4 value = float4(0.0);
    const int taps = 9;
    for (int i = 0; i < taps; ++i) {
        float offset = (float(i) / float(taps - 1) - 0.5) * amount;
        value += transitionSample(image, uv + direction * offset);
    }
    return value / float(taps);
}

inline float2 rotateTransitionUV(float2 uv, float angle, float scale, float aspect) {
    float2 p = uv - 0.5;
    p.x *= aspect;
    float c = cos(angle), s = sin(angle);
    p = float2(c * p.x - s * p.y, s * p.x + c * p.y) / max(scale, 0.001);
    p.x /= aspect;
    return p + 0.5;
}

/// A narrow highlight along a procedural reveal boundary. Besides giving the
/// wipe a polished edge, this keeps it readable when an edit was created by
/// splitting one continuous source and both sides contain nearly identical
/// adjacent frames.
inline float4 transitionEdgeGlow(float4 color, float signedDistance, float width, float amount) {
    float glow = 1.0 - smoothstep(0.0, width, abs(signedDistance));
    color.rgb = mix(color.rgb, float3(max(color.a, 0.001)), glow * amount);
    return color;
}

inline float4 timelineTransition(
    texture2d<float, access::sample> outgoing,
    texture2d<float, access::sample> incoming,
    float2 uv,
    constant TransitionUniforms &u)
{
    float p = clamp(u.progress, 0.0, 1.0);
    float e = easeTransition(p);
    float4 a = transitionSample(outgoing, uv);
    float4 b = transitionSample(incoming, uv);

    switch (u.type) {
        case 0: // Cross dissolve
            return mix(a, b, e);
        case 1: { // Dip to black
            float side = p < 0.5 ? p * 2.0 : (p - 0.5) * 2.0;
            return p < 0.5 ? mix(a, float4(0, 0, 0, max(a.a, b.a)), easeTransition(side))
                           : mix(float4(0, 0, 0, max(a.a, b.a)), b, easeTransition(side));
        }
        case 2: { // Dip to white
            float side = p < 0.5 ? p * 2.0 : (p - 0.5) * 2.0;
            float4 white = float4(max(a.a, b.a));
            return p < 0.5 ? mix(a, white, easeTransition(side)) : mix(white, b, easeTransition(side));
        }
        case 3: // Slide left: incoming lays over outgoing
            return mix(a, transitionSample(incoming, uv + float2(1.0 - e, 0)),
                       step(1.0 - e, uv.x));
        case 4:
            return mix(a, transitionSample(incoming, uv - float2(1.0 - e, 0)),
                       step(uv.x, e));
        case 5:
            return mix(a, transitionSample(incoming, uv - float2(0, 1.0 - e)),
                       step(uv.y, e));
        case 6:
            return mix(a, transitionSample(incoming, uv + float2(0, 1.0 - e)),
                       step(1.0 - e, uv.y));
        case 7: { // Push left
            float4 first = transitionSample(outgoing, uv + float2(e, 0));
            float4 second = transitionSample(incoming, uv - float2(1.0 - e, 0));
            return uv.x < 1.0 - e ? second : first;
        }
        case 8: { // Zoom in
            float2 auv = (uv - 0.5) / (1.0 + 0.16 * e) + 0.5;
            float2 buv = (uv - 0.5) / (0.92 + 0.08 * e) + 0.5;
            return mix(transitionSample(outgoing, auv), transitionSample(incoming, buv), e);
        }
        case 9: { // Zoom out
            float2 auv = (uv - 0.5) / (1.0 - 0.08 * e) + 0.5;
            float2 buv = (uv - 0.5) / (1.16 - 0.16 * e) + 0.5;
            return mix(transitionSample(outgoing, auv), transitionSample(incoming, buv), e);
        }
        case 10: { // Blur dissolve
            float blur = sin(p * M_PI_F) * 0.035;
            float4 first = directionalBlur(outgoing, uv, float2(1, 0), blur);
            float4 second = directionalBlur(incoming, uv, float2(0, 1), blur);
            return mix(first, second, e);
        }
        case 11: { // Whip pan left
            float velocity = sin(p * M_PI_F);
            float4 first = directionalBlur(outgoing, uv + float2(e, 0), float2(1, 0), 0.10 * velocity);
            float4 second = directionalBlur(incoming, uv - float2(1.0 - e, 0), float2(1, 0), 0.10 * velocity);
            return uv.x < 1.0 - e ? second : first;
        }
        case 12: { // Whip pan right
            float velocity = sin(p * M_PI_F);
            float4 first = directionalBlur(outgoing, uv - float2(e, 0), float2(1, 0), 0.10 * velocity);
            float4 second = directionalBlur(incoming, uv + float2(1.0 - e, 0), float2(1, 0), 0.10 * velocity);
            return uv.x > e ? second : first;
        }
        case 13: { // Controlled spin
            float angle = sin(p * M_PI_F) * 0.32;
            float scale = 1.0 + sin(p * M_PI_F) * 0.08;
            float2 auv = rotateTransitionUV(uv, angle, scale, u.aspectRatio);
            float2 buv = rotateTransitionUV(uv, angle - 0.32 * (1.0 - p), scale, u.aspectRatio);
            return mix(transitionSample(outgoing, auv), transitionSample(incoming, buv), e);
        }
        case 14: { // Flash
            float flash = exp(-pow((p - 0.5) / 0.13, 2.0));
            float4 mixed = mix(a, b, e);
            mixed.rgb = mix(mixed.rgb, float3(max(mixed.a, 0.001)), flash * 0.92);
            return mixed;
        }
        case 15: { // Feathered wipe left
            float reveal = 1.0 - smoothstep(e - 0.025, e + 0.025, uv.x);
            return transitionEdgeGlow(mix(a, b, reveal), uv.x - e, 0.032, 0.18);
        }
        case 16: { // Feathered wipe right
            float reveal = smoothstep(1.0 - e - 0.025, 1.0 - e + 0.025, uv.x);
            return transitionEdgeGlow(mix(a, b, reveal), uv.x - (1.0 - e), 0.032, 0.18);
        }
        case 17: { // Feathered wipe up
            float reveal = smoothstep(1.0 - e - 0.025, 1.0 - e + 0.025, uv.y);
            return transitionEdgeGlow(mix(a, b, reveal), uv.y - (1.0 - e), 0.032, 0.18);
        }
        case 18: { // Feathered wipe down
            float reveal = 1.0 - smoothstep(e - 0.025, e + 0.025, uv.y);
            return transitionEdgeGlow(mix(a, b, reveal), uv.y - e, 0.032, 0.18);
        }
        case 19: { // Iris reveal
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float radius = e * sqrt(0.25 * u.aspectRatio * u.aspectRatio + 0.25);
            float reveal = 1.0 - smoothstep(radius - 0.025, radius + 0.025, length(point));
            return transitionEdgeGlow(mix(a, b, reveal), length(point) - radius, 0.034, 0.16);
        }
        case 20: { // Clock wipe
            float angle = (atan2(uv.x - 0.5, uv.y - 0.5) + M_PI_F) / (2.0 * M_PI_F);
            float reveal = 1.0 - smoothstep(e - 0.015, e + 0.015, angle);
            float edgeDistance = min(abs(angle - e), 1.0 - abs(angle - e));
            return transitionEdgeGlow(mix(a, b, reveal), edgeDistance, 0.018, 0.16);
        }
        case 21: { // Horizontal split from centre
            float distance = abs(uv.y - 0.5);
            float reveal = 1.0 - smoothstep(e * 0.5 - 0.02, e * 0.5 + 0.02, distance);
            return transitionEdgeGlow(mix(a, b, reveal), distance - e * 0.5, 0.026, 0.18);
        }
        case 22: { // Vertical split from centre
            float distance = abs(uv.x - 0.5);
            float reveal = 1.0 - smoothstep(e * 0.5 - 0.02, e * 0.5 + 0.02, distance);
            return transitionEdgeGlow(mix(a, b, reveal), distance - e * 0.5, 0.026, 0.18);
        }
        case 23: { // Controlled warm film burn
            float4 mixed = mix(a, b, e);
            float flare = exp(-pow((p - 0.52) / 0.19, 2.0));
            float edge = smoothstep(0.0, 0.32, uv.x + uv.y * 0.35 + p - 0.55);
            float3 burn = float3(1.0, 0.30, 0.035) * max(mixed.a, 0.001);
            mixed.rgb = mix(mixed.rgb, burn, flare * edge * 0.78);
            return mixed;
        }
        case 24: { // Subtle RGB split
            float offset = sin(p * M_PI_F) * 0.018;
            float4 baseMix = mix(a, b, e);
            float4 redMix = mix(transitionSample(outgoing, uv + float2(offset, 0)),
                                transitionSample(incoming, uv + float2(offset, 0)), e);
            float4 blueMix = mix(transitionSample(outgoing, uv - float2(offset, 0)),
                                 transitionSample(incoming, uv - float2(offset, 0)), e);
            baseMix.r = redMix.r; baseMix.b = blueMix.b;
            return baseMix;
        }
        case 25: { // Soft light dissolve
            float4 mixed = mix(a, b, e);
            float lift = sin(p * M_PI_F) * 0.30;
            mixed.rgb = mix(mixed.rgb, float3(max(mixed.a, 0.001)), lift);
            return mixed;
        }
        case 26: { // Restrained digital glitch
            float band = floor(uv.y * 28.0);
            float jitter = (hash21(float2(band, floor(p * 18.0))) - 0.5) * 0.08 * sin(p * M_PI_F);
            float stepped = clamp(e + (hash21(float2(band, 7.0)) - 0.5) * 0.14, 0.0, 1.0);
            return mix(transitionSample(outgoing, uv + float2(jitter, 0)),
                       transitionSample(incoming, uv - float2(jitter, 0)), stepped);
        }
        case 27: { // Soft diagonal wipe from the upper-left corner
            float axis = (uv.x + uv.y) * 0.5;
            float reveal = 1.0 - smoothstep(e - 0.025, e + 0.025, axis);
            return transitionEdgeGlow(mix(a, b, reveal), axis - e, 0.032, 0.20);
        }
        case 28: { // Diamond reveal from the centre
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float distance = abs(point.x) + abs(point.y);
            float radius = e * (0.5 * u.aspectRatio + 0.5);
            float reveal = 1.0 - smoothstep(radius - 0.025, radius + 0.025, distance);
            return transitionEdgeGlow(mix(a, b, reveal), distance - radius, 0.034, 0.20);
        }
        case 29: { // Horizontal venetian blinds
            float stripe = fract(uv.y * 8.0);
            float reveal = 1.0 - smoothstep(e - 0.035, e + 0.035, stripe);
            return transitionEdgeGlow(mix(a, b, reveal), stripe - e, 0.042, 0.16);
        }
        case 30: { // Vertical venetian blinds
            float stripe = fract(uv.x * 10.0);
            float reveal = 1.0 - smoothstep(e - 0.035, e + 0.035, stripe);
            return transitionEdgeGlow(mix(a, b, reveal), stripe - e, 0.042, 0.16);
        }
        case 31: { // Alternating checkerboard dissolve
            float2 cell = floor(uv * float2(10.0, 8.0));
            float phase = fmod(cell.x + cell.y, 2.0) * 0.16;
            float local = clamp((e - phase) / 0.84, 0.0, 1.0);
            float reveal = smoothstep(0.0, 1.0, local);
            float4 mixed = mix(a, b, reveal);
            mixed.rgb = mix(mixed.rgb, float3(max(mixed.a, 0.001)), sin(local * M_PI_F) * 0.12);
            return mixed;
        }
        case 32: { // Pixelate through the edit
            float strength = sin(p * M_PI_F);
            float2 fineGrid = float2(720.0 * max(u.aspectRatio, 1.0), 720.0);
            float2 grid = mix(fineGrid, float2(24.0 * max(u.aspectRatio, 1.0), 24.0), strength);
            float2 pixelUV = (floor(uv * grid) + 0.5) / grid;
            return mix(transitionSample(outgoing, pixelUV), transitionSample(incoming, pixelUV), e);
        }
        case 33: { // Concentric water ripple
            float2 point = uv - 0.5;
            point.x *= u.aspectRatio;
            float distance = length(point);
            float2 direction = point / max(distance, 0.001);
            direction.x /= max(u.aspectRatio, 0.001);
            float2 offset = direction * sin(distance * 48.0 - p * 10.0) * 0.018 * sin(p * M_PI_F);
            return mix(transitionSample(outgoing, uv + offset * (1.0 - e)),
                       transitionSample(incoming, uv - offset * e), e);
        }
        case 34: { // Flowing horizontal wave
            float wave = sin((uv.y * 7.0 + p * 2.0) * 2.0 * M_PI_F) * 0.028 * sin(p * M_PI_F);
            return mix(transitionSample(outgoing, uv + float2(wave * (1.0 - e), 0)),
                       transitionSample(incoming, uv - float2(wave * e, 0)), e);
        }
        case 35: { // Horizontal squeeze through the centre
            float firstScale = 1.0 - 0.36 * e;
            float secondScale = 0.64 + 0.36 * e;
            float2 firstUV = float2((uv.x - 0.5) / firstScale + 0.5, uv.y);
            float2 secondUV = float2((uv.x - 0.5) / secondScale + 0.5, uv.y);
            return mix(transitionSample(outgoing, firstUV), transitionSample(incoming, secondUV), e);
        }
        case 36: { // Radial cross zoom with a light two-tap trail
            float2 trail = (uv - 0.5) * 0.14 * sin(p * M_PI_F);
            float4 first = (a + transitionSample(outgoing, uv - trail)) * 0.5;
            float4 second = (b + transitionSample(incoming, uv + trail)) * 0.5;
            return mix(first, second, e);
        }
        case 37: { // Incoming frame settles with a restrained overshoot
            float q = p - 1.0;
            float settle = 1.0 + 2.70158 * q * q * q + 1.70158 * q * q;
            float edge = 1.0 - settle;
            float reveal = smoothstep(edge - 0.012, edge + 0.012, uv.y);
            return mix(a, transitionSample(incoming, uv - float2(0, edge)), reveal);
        }
        case 38: { // Fine-grained organic noise dissolve
            float2 cell = floor(uv * float2(160.0 * max(u.aspectRatio, 1.0), 160.0));
            float noise = hash21(cell);
            float reveal = smoothstep(noise - 0.08, noise + 0.08, e);
            float energy = sin(p * M_PI_F);
            float band = floor(uv.y * 90.0);
            float jitter = (hash21(float2(band, floor(p * 36.0))) - 0.5) * 0.055 * energy;
            float4 mixed = mix(transitionSample(outgoing, uv + float2(jitter, 0)),
                               transitionSample(incoming, uv - float2(jitter, 0)), reveal);
            float staticNoise = (hash21(cell + floor(p * 48.0)) - 0.5) * 0.24 * energy;
            mixed.rgb += staticNoise * max(mixed.a, 0.001);
            return mixed;
        }
        case 39: { // Radial chromatic prism
            float energy = sin(p * M_PI_F);
            float2 point = uv - 0.5;
            float distance = length(point);
            float2 direction = point / max(distance, 0.001);
            float2 split = direction * 0.038 * energy;
            float4 mixed = mix(a, b, e);
            float4 red = mix(transitionSample(outgoing, uv + split),
                             transitionSample(incoming, uv + split), e);
            float4 blue = mix(transitionSample(outgoing, uv - split),
                              transitionSample(incoming, uv - split), e);
            mixed.r = red.r; mixed.b = blue.b;
            return mixed;
        }
        case 40: { // Animated barrel/pincushion lens warp
            float energy = sin(p * M_PI_F);
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float radius2 = dot(point, point);
            float2 firstPoint = point * (1.0 + radius2 * 0.62 * energy);
            float2 secondPoint = point * (1.0 - radius2 * 0.34 * energy);
            firstPoint.x /= max(u.aspectRatio, 0.001);
            secondPoint.x /= max(u.aspectRatio, 0.001);
            return mix(transitionSample(outgoing, firstPoint + 0.5),
                       transitionSample(incoming, secondPoint + 0.5), e);
        }
        case 41: { // Mirrored kaleidoscope at the midpoint
            float energy = sin(p * M_PI_F);
            float2 mirrored = abs(fract((uv - 0.5) * 3.0 + 0.5) * 2.0 - 1.0);
            float2 effectUV = mix(uv, mirrored, energy * 0.88);
            return mix(transitionSample(outgoing, effectUV),
                       transitionSample(incoming, effectUV), e);
        }
        case 42: { // Multi-axis liquid displacement
            float energy = sin(p * M_PI_F);
            float flowX = sin((uv.y * 5.0 + p * 1.7) * 2.0 * M_PI_F);
            float flowY = cos((uv.x * 4.0 - p * 1.3) * 2.0 * M_PI_F);
            float2 offset = float2(flowX * 0.040, flowY * 0.024) * energy;
            float organic = sin((uv.x * 3.0 + uv.y * 4.0 + p) * 2.0 * M_PI_F) * 0.13 * energy;
            float reveal = smoothstep(0.0, 1.0, clamp(e + organic, 0.0, 1.0));
            return mix(transitionSample(outgoing, uv + offset * (1.0 - e)),
                       transitionSample(incoming, uv - offset * e), reveal);
        }
        case 43: { // Centre-weighted vortex
            float energy = sin(p * M_PI_F);
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float reach = 1.0 - smoothstep(0.08, 0.78, length(point));
            float angle = energy * reach * 1.55;
            return mix(transitionSample(outgoing, rotateTransitionUV(uv, angle, 1.0, u.aspectRatio)),
                       transitionSample(incoming, rotateTransitionUV(uv, -angle, 1.0, u.aspectRatio)), e);
        }
        case 44: { // Dimensional page-turn style fold
            float fold = e;
            float signedEdge = uv.x - fold;
            float curl = exp(-pow(signedEdge / 0.13, 2.0)) * sin(p * M_PI_F);
            float2 outgoingUV = uv + float2(curl * 0.065, curl * (uv.y - 0.5) * 0.035);
            float reveal = 1.0 - smoothstep(-0.018, 0.018, signedEdge);
            float4 mixed = mix(transitionSample(outgoing, outgoingUV), b, reveal);
            float shadow = exp(-pow(signedEdge / 0.055, 2.0)) * sin(p * M_PI_F);
            mixed.rgb *= 1.0 - shadow * 0.28;
            return transitionEdgeGlow(mixed, signedEdge, 0.018, 0.32);
        }
        default:
            return mix(a, b, e);
    }
}

kernel void transitionBGRA(
    texture2d<float, access::sample> outgoing [[texture(0)]],
    texture2d<float, access::sample> incoming [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant TransitionUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) return;
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    destination.write(timelineTransition(outgoing, incoming, uv, uniforms), position);
}

inline float4 gradedHDRTransitionSample(
    texture2d<float, access::sample> source,
    float2 screenUV,
    uint2 outputSize,
    constant GradeUniforms &grade,
    constant HDRDisplayUniforms &hdr,
    constant HDRLayerUniforms &layer,
    constant LayerMaskUniforms &mask,
    texture3d<float, access::sample> lutTexture,
    texture2d<float, access::sample> curveLUT,
    texture2d<float, access::sample> warpField,
    texture2d<float, access::sample> trackMatte,
    texture2d<float, access::sample> backgroundMatte,
    constant BackgroundRemovalUniforms &backgroundRemoval,
    constant LocalGradeStack &locals)
{
    if (screenUV.x < 0.0 || screenUV.x > 1.0 || screenUV.y < 0.0 || screenUV.y > 1.0) return float4(0.0);
    float2 pixel = screenUV * float2(outputSize) - 0.5;
    float3 point = float3(pixel, 1.0);
    float2 uv = float2(dot(layer.row0.xyz, point), dot(layer.row1.xyz, point));
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return float4(0.0);
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 signal = source.sample(s, uv).rgb;
    float3 working = layer.params.z > 0.5 ? sdrToWorking(signal) : toWorkingSpace(signal, hdr);
    working = applyLookAndGradeHDR(working, uv, grade, lutTexture, curveLUT, warpField, locals);
    // The matte is sampled at the SCREEN coordinate this sample is being drawn
    // from, not the layer's, so a wipe that reads a displaced part of the clip
    // still reads the matte where the pixel lands.
    float backgroundCoverage = backgroundRemovalCoverage(backgroundMatte, uv);
    working = suppressBackgroundSpill(working, backgroundCoverage, backgroundRemoval);
    float alpha = layer.params.x * backgroundCoverage
        * layerMaskWeight(uv, mask)
        * trackMatteCoverage(trackMatte, screenUV, layer.matte.x);
    return float4(working * alpha, alpha);
}

kernel void compositeTransitionHDR(
    texture2d<float, access::sample> outgoing [[texture(0)]],
    texture2d<float, access::sample> incoming [[texture(1)]],
    texture2d<float, access::read> base [[texture(2)]],
    texture2d<float, access::write> destination [[texture(3)]],
    texture3d<float, access::sample> outgoingLUT [[texture(4)]],
    texture3d<float, access::sample> incomingLUT [[texture(5)]],
    texture2d<float, access::sample> outgoingCurve [[texture(6)]],
    texture2d<float, access::sample> incomingCurve [[texture(7)]],
    texture2d<float, access::sample> outgoingMatte [[texture(8)]],
    texture2d<float, access::sample> incomingMatte [[texture(9)]],
    texture2d<float, access::sample> outgoingBackground [[texture(10)]],
    texture2d<float, access::sample> incomingBackground [[texture(11)]],
    // The transition kernel is the one place two grades meet in a single
    // dispatch, so it needs both clips' warp fields. 6/7 already pair off this
    // way for the curve tables.
    texture2d<float, access::sample> outgoingWarp [[texture(12)]],
    texture2d<float, access::sample> incomingWarp [[texture(13)]],
    constant GradeUniforms &outgoingGrade [[buffer(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(1)]],
    constant HDRLayerUniforms &outgoingLayer [[buffer(2)]],
    constant LayerMaskUniforms &outgoingMask [[buffer(3)]],
    constant GradeUniforms &incomingGrade [[buffer(4)]],
    constant HDRLayerUniforms &incomingLayer [[buffer(5)]],
    constant LayerMaskUniforms &incomingMask [[buffer(6)]],
    constant TransitionUniforms &u [[buffer(7)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &outgoingLocals [[buffer(8)]],
    constant LocalGradeStack &incomingLocals [[buffer(9)]],
    constant BackgroundRemovalUniforms &outgoingBackgroundRemoval [[buffer(10)]],
    constant BackgroundRemovalUniforms &incomingBackgroundRemoval [[buffer(11)]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) return;
    uint2 size = uint2(destination.get_width(), destination.get_height());
    float2 uv = (float2(position) + 0.5) / float2(size);
    float p = clamp(u.progress, 0.0, 1.0), e = easeTransition(p);
    auto sampleA = [&](float2 coordinate) {
        return gradedHDRTransitionSample(outgoing, coordinate, size, outgoingGrade, hdr,
            outgoingLayer, outgoingMask, outgoingLUT, outgoingCurve, outgoingWarp, outgoingMatte,
            outgoingBackground, outgoingBackgroundRemoval, outgoingLocals);
    };
    auto sampleB = [&](float2 coordinate) {
        return gradedHDRTransitionSample(incoming, coordinate, size, incomingGrade, hdr,
            incomingLayer, incomingMask, incomingLUT, incomingCurve, incomingWarp, incomingMatte,
            incomingBackground, incomingBackgroundRemoval, incomingLocals);
    };
    float4 a = sampleA(uv), b = sampleB(uv), mixed;
    switch (u.type) {
        case 0: mixed = mix(a, b, e); break;
        case 1:
        case 2: {
            float side = p < 0.5 ? p * 2.0 : (p - 0.5) * 2.0;
            float alpha = max(a.a, b.a);
            float3 color = u.type == 2 ? float3(alpha) : float3(0.0);
            float4 dip = float4(color, alpha);
            mixed = p < 0.5 ? mix(a, dip, easeTransition(side)) : mix(dip, b, easeTransition(side));
            break;
        }
        case 3: {
            float4 entering = sampleB(uv + float2(1.0 - e, 0));
            mixed = uv.x >= 1.0 - e ? entering : a; break;
        }
        case 4: {
            float4 entering = sampleB(uv - float2(1.0 - e, 0));
            mixed = uv.x <= e ? entering : a; break;
        }
        case 5: {
            float4 entering = sampleB(uv - float2(0, 1.0 - e));
            mixed = uv.y <= e ? entering : a; break;
        }
        case 6: {
            float4 entering = sampleB(uv + float2(0, 1.0 - e));
            mixed = uv.y >= 1.0 - e ? entering : a; break;
        }
        case 7:
            mixed = uv.x < 1.0 - e ? sampleB(uv - float2(1.0 - e, 0)) : sampleA(uv + float2(e, 0));
            break;
        case 8:
            mixed = mix(sampleA((uv - 0.5) / (1.0 + 0.16 * e) + 0.5),
                        sampleB((uv - 0.5) / (0.92 + 0.08 * e) + 0.5), e); break;
        case 9:
            mixed = mix(sampleA((uv - 0.5) / (1.0 - 0.08 * e) + 0.5),
                        sampleB((uv - 0.5) / (1.16 - 0.16 * e) + 0.5), e); break;
        case 10: {
            float blur = sin(p * M_PI_F) * 0.035;
            // HDR grading is substantially heavier than sampling an already
            // graded SDR canvas. Two-tap directional softness preserves the
            // transition without multiplying the full HDR grade nine times per
            // pixel, which can trip the device GPU watchdog during playback.
            float4 first = (a + sampleA(uv + float2(blur, 0))) * 0.5;
            float4 second = (b + sampleB(uv + float2(0, blur))) * 0.5;
            mixed = mix(first, second, e); break;
        }
        case 11:
        case 12: {
            float direction = u.type == 11 ? 1.0 : -1.0;
            float velocity = sin(p * M_PI_F) * 0.10;
            float2 firstUV = uv + float2(direction * e, 0);
            float2 secondUV = uv - float2(direction * (1.0 - e), 0);
            float4 first = (sampleA(firstUV) + sampleA(firstUV + float2(velocity, 0))) * 0.5;
            float4 second = (sampleB(secondUV) + sampleB(secondUV - float2(velocity, 0))) * 0.5;
            mixed = u.type == 11 ? (uv.x < 1.0 - e ? second : first)
                                 : (uv.x > e ? second : first);
            break;
        }
        case 13: {
            float angle = sin(p * M_PI_F) * 0.32;
            float scale = 1.0 + sin(p * M_PI_F) * 0.08;
            mixed = mix(sampleA(rotateTransitionUV(uv, angle, scale, u.aspectRatio)),
                        sampleB(rotateTransitionUV(uv, angle - 0.32 * (1.0 - p), scale, u.aspectRatio)), e);
            break;
        }
        case 14: {
            mixed = mix(a, b, e);
            float flash = exp(-pow((p - 0.5) / 0.13, 2.0));
            mixed.rgb = mix(mixed.rgb, float3(max(mixed.a, 0.001)), flash * 0.92); break;
        }
        case 15: {
            float reveal = 1.0 - smoothstep(e - 0.025, e + 0.025, uv.x);
            mixed = transitionEdgeGlow(mix(a, b, reveal), uv.x - e, 0.032, 0.18); break;
        }
        case 16: {
            float reveal = smoothstep(1.0 - e - 0.025, 1.0 - e + 0.025, uv.x);
            mixed = transitionEdgeGlow(mix(a, b, reveal), uv.x - (1.0 - e), 0.032, 0.18); break;
        }
        case 17: {
            float reveal = smoothstep(1.0 - e - 0.025, 1.0 - e + 0.025, uv.y);
            mixed = transitionEdgeGlow(mix(a, b, reveal), uv.y - (1.0 - e), 0.032, 0.18); break;
        }
        case 18: {
            float reveal = 1.0 - smoothstep(e - 0.025, e + 0.025, uv.y);
            mixed = transitionEdgeGlow(mix(a, b, reveal), uv.y - e, 0.032, 0.18); break;
        }
        case 19: {
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float radius = e * sqrt(0.25 * u.aspectRatio * u.aspectRatio + 0.25);
            float reveal = 1.0 - smoothstep(radius - 0.025, radius + 0.025, length(point));
            mixed = transitionEdgeGlow(mix(a, b, reveal), length(point) - radius, 0.034, 0.16); break;
        }
        case 20: {
            float angle = (atan2(uv.x - 0.5, uv.y - 0.5) + M_PI_F) / (2.0 * M_PI_F);
            float reveal = 1.0 - smoothstep(e - 0.015, e + 0.015, angle);
            float edgeDistance = min(abs(angle - e), 1.0 - abs(angle - e));
            mixed = transitionEdgeGlow(mix(a, b, reveal), edgeDistance, 0.018, 0.16); break;
        }
        case 21: {
            float distance = abs(uv.y - 0.5);
            float reveal = 1.0 - smoothstep(e * 0.5 - 0.02, e * 0.5 + 0.02, distance);
            mixed = transitionEdgeGlow(mix(a, b, reveal), distance - e * 0.5, 0.026, 0.18); break;
        }
        case 22: {
            float distance = abs(uv.x - 0.5);
            float reveal = 1.0 - smoothstep(e * 0.5 - 0.02, e * 0.5 + 0.02, distance);
            mixed = transitionEdgeGlow(mix(a, b, reveal), distance - e * 0.5, 0.026, 0.18); break;
        }
        case 23: {
            mixed = mix(a, b, e);
            float flare = exp(-pow((p - 0.52) / 0.19, 2.0));
            float edge = smoothstep(0.0, 0.32, uv.x + uv.y * 0.35 + p - 0.55);
            mixed.rgb = mix(mixed.rgb, float3(1.0, 0.30, 0.035) * max(mixed.a, 0.001),
                            flare * edge * 0.78); break;
        }
        case 24: {
            float offset = sin(p * M_PI_F) * 0.018;
            float4 redMix = mix(sampleA(uv + float2(offset, 0)), sampleB(uv + float2(offset, 0)), e);
            float4 blueMix = mix(sampleA(uv - float2(offset, 0)), sampleB(uv - float2(offset, 0)), e);
            mixed = mix(a, b, e); mixed.r = redMix.r; mixed.b = blueMix.b; break;
        }
        case 25: {
            mixed = mix(a, b, e);
            mixed.rgb = mix(mixed.rgb, float3(max(mixed.a, 0.001)), sin(p * M_PI_F) * 0.30); break;
        }
        case 26: {
            float band = floor(uv.y * 28.0);
            float jitter = (hash21(float2(band, floor(p * 18.0))) - 0.5) * 0.08 * sin(p * M_PI_F);
            float stepped = clamp(e + (hash21(float2(band, 7.0)) - 0.5) * 0.14, 0.0, 1.0);
            mixed = mix(sampleA(uv + float2(jitter, 0)), sampleB(uv - float2(jitter, 0)), stepped); break;
        }
        case 27: {
            float axis = (uv.x + uv.y) * 0.5;
            float reveal = 1.0 - smoothstep(e - 0.025, e + 0.025, axis);
            mixed = transitionEdgeGlow(mix(a, b, reveal), axis - e, 0.032, 0.20); break;
        }
        case 28: {
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float distance = abs(point.x) + abs(point.y);
            float radius = e * (0.5 * u.aspectRatio + 0.5);
            float reveal = 1.0 - smoothstep(radius - 0.025, radius + 0.025, distance);
            mixed = transitionEdgeGlow(mix(a, b, reveal), distance - radius, 0.034, 0.20); break;
        }
        case 29: {
            float stripe = fract(uv.y * 8.0);
            float reveal = 1.0 - smoothstep(e - 0.035, e + 0.035, stripe);
            mixed = transitionEdgeGlow(mix(a, b, reveal), stripe - e, 0.042, 0.16); break;
        }
        case 30: {
            float stripe = fract(uv.x * 10.0);
            float reveal = 1.0 - smoothstep(e - 0.035, e + 0.035, stripe);
            mixed = transitionEdgeGlow(mix(a, b, reveal), stripe - e, 0.042, 0.16); break;
        }
        case 31: {
            float2 cell = floor(uv * float2(10.0, 8.0));
            float phase = fmod(cell.x + cell.y, 2.0) * 0.16;
            float local = clamp((e - phase) / 0.84, 0.0, 1.0);
            float reveal = smoothstep(0.0, 1.0, local);
            mixed = mix(a, b, reveal);
            mixed.rgb = mix(mixed.rgb, float3(max(mixed.a, 0.001)), sin(local * M_PI_F) * 0.12); break;
        }
        case 32: {
            float strength = sin(p * M_PI_F);
            float2 fineGrid = float2(720.0 * max(u.aspectRatio, 1.0), 720.0);
            float2 grid = mix(fineGrid, float2(24.0 * max(u.aspectRatio, 1.0), 24.0), strength);
            float2 pixelUV = (floor(uv * grid) + 0.5) / grid;
            mixed = mix(sampleA(pixelUV), sampleB(pixelUV), e); break;
        }
        case 33: {
            float2 point = uv - 0.5;
            point.x *= u.aspectRatio;
            float distance = length(point);
            float2 direction = point / max(distance, 0.001);
            direction.x /= max(u.aspectRatio, 0.001);
            float2 offset = direction * sin(distance * 48.0 - p * 10.0) * 0.018 * sin(p * M_PI_F);
            mixed = mix(sampleA(uv + offset * (1.0 - e)), sampleB(uv - offset * e), e); break;
        }
        case 34: {
            float wave = sin((uv.y * 7.0 + p * 2.0) * 2.0 * M_PI_F) * 0.028 * sin(p * M_PI_F);
            mixed = mix(sampleA(uv + float2(wave * (1.0 - e), 0)),
                        sampleB(uv - float2(wave * e, 0)), e); break;
        }
        case 35: {
            float firstScale = 1.0 - 0.36 * e;
            float secondScale = 0.64 + 0.36 * e;
            float2 firstUV = float2((uv.x - 0.5) / firstScale + 0.5, uv.y);
            float2 secondUV = float2((uv.x - 0.5) / secondScale + 0.5, uv.y);
            mixed = mix(sampleA(firstUV), sampleB(secondUV), e); break;
        }
        case 36: {
            float2 trail = (uv - 0.5) * 0.14 * sin(p * M_PI_F);
            float4 first = (a + sampleA(uv - trail)) * 0.5;
            float4 second = (b + sampleB(uv + trail)) * 0.5;
            mixed = mix(first, second, e); break;
        }
        case 37: {
            float q = p - 1.0;
            float settle = 1.0 + 2.70158 * q * q * q + 1.70158 * q * q;
            float edge = 1.0 - settle;
            float reveal = smoothstep(edge - 0.012, edge + 0.012, uv.y);
            mixed = mix(a, sampleB(uv - float2(0, edge)), reveal); break;
        }
        case 38: {
            float2 cell = floor(uv * float2(160.0 * max(u.aspectRatio, 1.0), 160.0));
            float noise = hash21(cell);
            float reveal = smoothstep(noise - 0.08, noise + 0.08, e);
            float energy = sin(p * M_PI_F);
            float band = floor(uv.y * 90.0);
            float jitter = (hash21(float2(band, floor(p * 36.0))) - 0.5) * 0.055 * energy;
            mixed = mix(sampleA(uv + float2(jitter, 0)), sampleB(uv - float2(jitter, 0)), reveal);
            float staticNoise = (hash21(cell + floor(p * 48.0)) - 0.5) * 0.24 * energy;
            mixed.rgb += staticNoise * max(mixed.a, 0.001); break;
        }
        case 39: {
            float energy = sin(p * M_PI_F);
            float2 point = uv - 0.5;
            float distance = length(point);
            float2 direction = point / max(distance, 0.001);
            float2 split = direction * 0.038 * energy;
            float4 red = mix(sampleA(uv + split), sampleB(uv + split), e);
            float4 blue = mix(sampleA(uv - split), sampleB(uv - split), e);
            mixed = mix(a, b, e); mixed.r = red.r; mixed.b = blue.b; break;
        }
        case 40: {
            float energy = sin(p * M_PI_F);
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float radius2 = dot(point, point);
            float2 firstPoint = point * (1.0 + radius2 * 0.62 * energy);
            float2 secondPoint = point * (1.0 - radius2 * 0.34 * energy);
            firstPoint.x /= max(u.aspectRatio, 0.001);
            secondPoint.x /= max(u.aspectRatio, 0.001);
            mixed = mix(sampleA(firstPoint + 0.5), sampleB(secondPoint + 0.5), e); break;
        }
        case 41: {
            float energy = sin(p * M_PI_F);
            float2 mirrored = abs(fract((uv - 0.5) * 3.0 + 0.5) * 2.0 - 1.0);
            float2 effectUV = mix(uv, mirrored, energy * 0.88);
            mixed = mix(sampleA(effectUV), sampleB(effectUV), e); break;
        }
        case 42: {
            float energy = sin(p * M_PI_F);
            float flowX = sin((uv.y * 5.0 + p * 1.7) * 2.0 * M_PI_F);
            float flowY = cos((uv.x * 4.0 - p * 1.3) * 2.0 * M_PI_F);
            float2 offset = float2(flowX * 0.040, flowY * 0.024) * energy;
            float organic = sin((uv.x * 3.0 + uv.y * 4.0 + p) * 2.0 * M_PI_F) * 0.13 * energy;
            float reveal = smoothstep(0.0, 1.0, clamp(e + organic, 0.0, 1.0));
            mixed = mix(sampleA(uv + offset * (1.0 - e)), sampleB(uv - offset * e), reveal); break;
        }
        case 43: {
            float energy = sin(p * M_PI_F);
            float2 point = uv - 0.5; point.x *= u.aspectRatio;
            float reach = 1.0 - smoothstep(0.08, 0.78, length(point));
            float angle = energy * reach * 1.55;
            mixed = mix(sampleA(rotateTransitionUV(uv, angle, 1.0, u.aspectRatio)),
                        sampleB(rotateTransitionUV(uv, -angle, 1.0, u.aspectRatio)), e); break;
        }
        case 44: {
            float fold = e;
            float signedEdge = uv.x - fold;
            float curl = exp(-pow(signedEdge / 0.13, 2.0)) * sin(p * M_PI_F);
            float2 outgoingUV = uv + float2(curl * 0.065, curl * (uv.y - 0.5) * 0.035);
            float reveal = 1.0 - smoothstep(-0.018, 0.018, signedEdge);
            mixed = mix(sampleA(outgoingUV), b, reveal);
            float shadow = exp(-pow(signedEdge / 0.055, 2.0)) * sin(p * M_PI_F);
            mixed.rgb *= 1.0 - shadow * 0.28;
            mixed = transitionEdgeGlow(mixed, signedEdge, 0.018, 0.32); break;
        }
        default: mixed = mix(a, b, e); break;
    }
    float3 under = base.read(position).rgb;
    destination.write(float4(mixed.rgb + under * (1.0 - mixed.a), 1.0), position);
}

// 10-bit Rec.709 export from a finished frame.
// Apple Log source to Rec.709 10-bit, for export.
//
// The same three stages as the preview — Apple's input transform, the shared
// extended-range grading path, then Apple's rendering LUT — writing straight
// into the encoder's 10-bit planes. Preview and export therefore run identical
// colour maths and cannot disagree about the picture.
kernel void gradeExportAppleLogSDR10(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::write> lumaOut [[texture(4)]],
    texture2d<float, access::write> chromaOut [[texture(5)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    texture3d<float, access::sample> renderingLUT [[texture(7)]],
    constant GradeUniforms &grade [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= chromaOut.get_width() || position.y >= chromaOut.get_height()) {
        return;
    }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 lumaSize = float2(lumaOut.get_width(), lumaOut.get_height());

    float3 rendered[4];
    float3 sum = 0.0;
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            float2 uv = (float2(p) + 0.5) / lumaSize;
            float y = lumaTexture.sample(videoSampler, uv).r;
            float2 c = chromaTexture.sample(videoSampler, uv).rg;
            float3 working = appleLogToWorking(y, c);
            working = applyLookAndGradeHDR(working, uv, grade, lutTexture, curveLUT, warpField, locals);
            float3 rgb = appleLogWorkingToRec709(working, renderingLUT);
            rendered[j * 2 + i] = rgb;
            sum += rgb;
        }
    }

    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            if (p.x >= uint(lumaSize.x) || p.y >= uint(lumaSize.y)) {
                continue;
            }
            float luma = rec709ToYCbCr(rendered[j * 2 + i]).x;
            lumaOut.write(float4(encodeVideoRange10(64.0 + luma * 876.0)), p);
        }
    }

    // Chroma from the average of the four rendered colours, matching the SDR
    // path: subsampling by averaging rather than point-sampling one of them.
    float3 chroma = rec709ToYCbCr(sum * 0.25);
    chromaOut.write(float4(encodeVideoRange10(512.0 + chroma.y * 896.0),
                           encodeVideoRange10(512.0 + chroma.z * 896.0),
                           0.0, 1.0), position);
}

kernel void encodeSDR10FromTexture(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> lumaOut [[texture(1)]],
    texture2d<float, access::write> chromaOut [[texture(2)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= chromaOut.get_width() || position.y >= chromaOut.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 lumaSize = float2(lumaOut.get_width(), lumaOut.get_height());
    float3 colours[4];
    float3 sum = 0.0;
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            float3 c = saturate(source.sample(videoSampler, (float2(p) + 0.5) / lumaSize).rgb);
            colours[j * 2 + i] = c;
            sum += c;
        }
    }
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            if (p.x >= uint(lumaSize.x) || p.y >= uint(lumaSize.y)) { continue; }
            float luma = rec709ToYCbCr(colours[j * 2 + i]).x;
            lumaOut.write(float4(encodeVideoRange10(64.0 + luma * 876.0)), p);
        }
    }
    float3 chroma = rec709ToYCbCr(sum * 0.25);
    chromaOut.write(float4(encodeVideoRange10(512.0 + chroma.y * 896.0),
                           encodeVideoRange10(512.0 + chroma.z * 896.0), 0.0, 1.0), position);
}

// HLG BT.2020 10-bit export from a finished frame, which arrives in working
// space and goes through the same display transform the preview uses.
kernel void encodeHDRFromTexture(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> lumaOut [[texture(1)]],
    texture2d<float, access::write> chromaOut [[texture(2)]],
    constant HDRDisplayUniforms &hdr [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= chromaOut.get_width() || position.y >= chromaOut.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 lumaSize = float2(lumaOut.get_width(), lumaOut.get_height());
    float3 signals[4];
    float3 sum = 0.0;
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            float3 s = workingToSignal(source.sample(videoSampler, (float2(p) + 0.5) / lumaSize).rgb, hdr);
            signals[j * 2 + i] = s;
            sum += s;
        }
    }
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            if (p.x >= uint(lumaSize.x) || p.y >= uint(lumaSize.y)) { continue; }
            float luma = hlgSignalToYCbCr2020(signals[j * 2 + i]).x;
            lumaOut.write(float4(encodeVideoRange10(64.0 + luma * 876.0)), p);
        }
    }
    float3 chroma = hlgSignalToYCbCr2020(sum * 0.25);
    chromaOut.write(float4(encodeVideoRange10(512.0 + chroma.y * 896.0),
                           encodeVideoRange10(512.0 + chroma.z * 896.0), 0.0, 1.0), position);
}

// ---------------------------------------------------------------------------
// Still images
//
// A still is graded by exactly the same function a video frame is:
// `applyLookAndGrade`. The only thing these kernels add is the ability to tell
// that function WHERE in the picture a pixel is, independently of which piece
// of the picture is currently in the texture.
//
// That matters because a full-resolution photograph is rendered in tiles. Three
// of the grading stages are frame-absolute — the vignette, the grain field and
// (through them) anything that reads `uv` — so a tile that reported its own
// local coordinates would restart the vignette and the grain inside every tile
// and leave visible seams between them. `tile` carries the tile's origin and
// the size of the whole image, so the coordinate handed to the shared grading
// function is always the coordinate in the finished picture.
//
// tile = (originX, originY, imageWidth, imageHeight), in pixels.
// A single-tile render passes (0, 0, width, height) and is then bit-identical
// to the preview's own path.
// ---------------------------------------------------------------------------

kernel void gradeStillTileBGRA(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant float4 &tile [[buffer(1)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    float2 uv = (float2(position) + tile.xy + 0.5) / tile.zw;
    float3 rgb = source.read(position).rgb;
    destination.write(float4(applyLookAndGrade(rgb, uv, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}

// Apple Log layers keep camera code values until sampling. Decoding an already
// resized RGB texture would change the sampling order versus direct preview.
inline float3 logLayerWorking(texture2d<float, access::sample> y,
                             texture2d<float, access::sample> c, float2 uv,
                             constant HDRLayerUniforms &layer,
                             constant YUVUniforms &yuv) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float luma = y.sample(s, uv).r;
    float2 chroma = c.sample(s, uv).rg;
    return layer.params.z > 0.5 ? sdrToWorking(decodeYUV(luma, chroma, yuv))
                              : appleLogToWorking(luma, chroma);
}

kernel void compositeVideoAppleLog(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lut [[texture(3)]],
    texture2d<float, access::sample> partnerLuma [[texture(4)]],
    texture2d<float, access::sample> partnerChroma [[texture(5)]],
    texture2d<float, access::sample> curves [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    texture2d<float, access::sample> trackMatte [[texture(8)]],
    texture2d<float, access::sample> backgroundMatte [[texture(9)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    constant HDRLayerUniforms &layer [[buffer(2)]],
    constant LayerMaskUniforms &mask [[buffer(3)]],
    constant BackgroundRemovalUniforms &backgroundRemoval [[buffer(4)]],
    constant uint2 &origin [[buffer(7)]],
    constant LocalGradeStack &locals [[buffer(8)]],
    uint2 tid [[thread_position_in_grid]]) {
    uint2 p = tid + origin;
    if (p.x >= destination.get_width() || p.y >= destination.get_height()) return;
    float2 uv = layerCoordinate(layer, p);
    if (any(uv < 0.0) || any(uv > 1.0)) { destination.write(float4(0), p); return; }
    float3 working = logLayerWorking(luma, chroma, uv, layer, yuv);
    if (layer.params.y > 0.0) {
        working = mix(working, logLayerWorking(partnerLuma, partnerChroma, uv, layer, yuv), layer.params.y);
    }
    working = applyLookAndGradeHDR(working, uv, grade, lut, curves, warpField, locals);
    float backgroundCoverage = backgroundRemovalCoverage(backgroundMatte, uv);
    working = suppressBackgroundSpill(working, backgroundCoverage, backgroundRemoval);
    float alpha = layer.params.x * backgroundCoverage
        * layerMaskWeight(uv, mask)
        * trackMatteCoverage(trackMatte, p,
                             float2(destination.get_width(), destination.get_height()),
                             layer.matte.x);
    destination.write(float4(working * alpha, alpha), p);
}

kernel void compositeImageAppleLog(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lut [[texture(3)]],
    texture2d<float, access::sample> curves [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    texture2d<float, access::sample> trackMatte [[texture(8)]],
    texture2d<float, access::sample> backgroundMatte [[texture(9)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant HDRLayerUniforms &layer [[buffer(2)]],
    constant LayerMaskUniforms &mask [[buffer(3)]],
    constant BackgroundRemovalUniforms &backgroundRemoval [[buffer(4)]],
    constant uint2 &origin [[buffer(7)]],
    constant LocalGradeStack &locals [[buffer(8)]],
    uint2 tid [[thread_position_in_grid]]) {
    uint2 p = tid + origin;
    if (p.x >= destination.get_width() || p.y >= destination.get_height()) return;
    float2 uv = layerCoordinate(layer, p);
    if (any(uv < 0.0) || any(uv > 1.0)) { destination.write(float4(0), p); return; }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 sample = source.sample(s, uv);
    float3 straight = layer.params.w > 0.5 && sample.a > 0.0001 ? sample.rgb / sample.a : sample.rgb;
    float backgroundCoverage = backgroundRemovalCoverage(backgroundMatte, uv);
    straight = suppressBackgroundSpill(straight, backgroundCoverage, backgroundRemoval);
    float3 working = applyLookAndGradeHDR(sdrToWorking(straight), uv, grade, lut, curves, warpField, locals);
    float alpha = sample.a * layer.params.x * backgroundCoverage
        * layerMaskWeight(uv, mask)
        * trackMatteCoverage(trackMatte, p,
                             float2(destination.get_width(), destination.get_height()),
                             layer.matte.x);
    destination.write(float4(working * alpha, alpha), p);
}

// Blend algebra is evaluated in linear light relative to diffuse white, with
// no saturation of either operand or result. Clamping to the SDR interval here
// would discard latitude before the user can lower exposure.
inline float3 blendLogLayer(float3 base, float3 layer, uint mode) {
    switch (mode) {
        case 1: return base * layer;
        case 2: return base + layer - base * layer;
        case 3: return select(2.0 * base * layer, 1.0 - 2.0 * (1.0 - base) * (1.0 - layer), base > 0.5);
        case 4: {
            float3 d = select(((16.0 * base - 12.0) * base + 4.0) * base,
                              sqrt(max(base, 0.0)), base > 0.25);
            return select(base - (1.0 - 2.0 * layer) * base * (1.0 - base),
                          base + (2.0 * layer - 1.0) * (d - base), layer > 0.5);
        }
        case 5: return select(2.0 * base * layer, 1.0 - 2.0 * (1.0 - base) * (1.0 - layer), layer > 0.5);
        case 6: return min(base, layer);
        case 7: return max(base, layer);
        default: return layer;
    }
}

kernel void blendAppleLogLayer(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> base [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant uint &mode [[buffer(0)]],
    constant uint2 &origin [[buffer(7)]], uint2 tid [[thread_position_in_grid]]) {
    uint2 p = tid + origin;
    if (p.x >= destination.get_width() || p.y >= destination.get_height()) return;
    float4 over = source.read(p);
    float3 under = base.read(p).rgb;
    float3 straight = over.a > 0.0001 ? over.rgb / over.a : float3(0);
    destination.write(float4(mix(under, blendLogLayer(under, straight, mode), over.a), 1), p);
}

// Both transition inputs have already been graded, transformed and masked in
// working space. The shared transition sampler therefore carries highlights,
// SDR artwork, still-image transitions and retimed partners without regrading.
kernel void compositeTransitionAppleLog(
    texture2d<float, access::sample> outgoing [[texture(0)]],
    texture2d<float, access::sample> incoming [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant TransitionUniforms &u [[buffer(0)]],
    constant uint2 &origin [[buffer(7)]], uint2 tid [[thread_position_in_grid]]) {
    uint2 p = tid + origin;
    if (p.x >= destination.get_width() || p.y >= destination.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(destination.get_width(), destination.get_height());
    destination.write(timelineTransition(outgoing, incoming, uv, u), p);
}

kernel void resolveAppleLogCanvas(
    texture2d<float, access::read> canvas [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    texture3d<float, access::sample> renderingLUT [[texture(4)]],
    constant uint2 &origin [[buffer(7)]], uint2 tid [[thread_position_in_grid]]) {
    uint2 p = tid + origin;
    if (p.x >= destination.get_width() || p.y >= destination.get_height()) return;
    destination.write(float4(appleLogWorkingToRec709(canvas.read(p).rgb, renderingLUT), 1), p);
}

// Export's compositor surface is 10-bit 4:2:2 Rec.709 video range. Each thread
// owns a chroma pair, avoiding competing writes from neighbouring luma pixels.
kernel void resolveAppleLogCanvas422(
    texture2d<float, access::read> canvas [[texture(0)]],
    texture2d<float, access::write> luma [[texture(1)]],
    texture2d<float, access::write> chroma [[texture(2)]],
    texture3d<float, access::sample> renderingLUT [[texture(4)]],
    constant uint2 &origin [[buffer(7)]], uint2 tid [[thread_position_in_grid]]) {
    uint2 p = tid + origin;
    if (p.x >= chroma.get_width() || p.y >= chroma.get_height()) return;
    float3 sum = 0;
    for (uint i = 0; i < 2; ++i) {
        uint2 q = uint2(p.x * 2 + i, p.y);
        float3 rgb = appleLogWorkingToRec709(canvas.read(q).rgb, renderingLUT);
        sum += rgb;
        luma.write(float4(encodeVideoRange10(64.0 + rec709ToYCbCr(rgb).x * 876.0)), q);
    }
    float3 c = rec709ToYCbCr(sum * 0.5);
    chroma.write(float4(encodeVideoRange10(512.0 + c.y * 896.0),
                       encodeVideoRange10(512.0 + c.z * 896.0), 0, 1), p);
}

// Spatial finishing effects share HLG's linear stage; only the input and final
// display rendering differ. These also keep effected direct frames in parity
// with the compositor's working-space canvas.
kernel void gradeToTextureAppleLog(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lut [[texture(3)]],
    texture2d<float, access::sample> curves [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant LocalGradeStack &locals [[buffer(8)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= destination.get_width() || p.y >= destination.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(p) + 0.5) / float2(destination.get_width(), destination.get_height());
    float3 working = appleLogToWorking(luma.sample(s, uv).r, chroma.sample(s, uv).rg);
    destination.write(float4(applyLookAndGradeHDR(working, uv, grade, lut, curves, warpField, locals), 1), p);
}

fragment float4 presentFragmentAppleLog(
    RasterData in [[stage_in]], texture2d<float, access::sample> source [[texture(0)]],
    texture3d<float, access::sample> renderingLUT [[texture(4)]],
    constant GradeUniforms &grade [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 rec709 = appleLogWorkingToRec709(source.sample(s, in.textureCoordinate).rgb, renderingLUT);
    return float4(applyViewerAssist(rec709, in.position.xy, grade), 1);
}

kernel void encodeAppleLogFromTexture(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> lumaOut [[texture(1)]],
    texture2d<float, access::write> chromaOut [[texture(2)]],
    texture3d<float, access::sample> renderingLUT [[texture(4)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= chromaOut.get_width() || position.y >= chromaOut.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 lumaSize = float2(lumaOut.get_width(), lumaOut.get_height());
    float3 colours[4];
    float3 sum = 0.0;
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            float3 c = appleLogWorkingToRec709(source.sample(videoSampler, (float2(p) + 0.5) / lumaSize).rgb, renderingLUT);
            colours[j * 2 + i] = c;
            sum += c;
        }
    }
    for (uint j = 0; j < 2; ++j) {
        for (uint i = 0; i < 2; ++i) {
            uint2 p = uint2(position.x * 2 + i, position.y * 2 + j);
            if (p.x >= uint(lumaSize.x) || p.y >= uint(lumaSize.y)) { continue; }
            float luma = rec709ToYCbCr(colours[j * 2 + i]).x;
            lumaOut.write(float4(encodeVideoRange10(64.0 + luma * 876.0)), p);
        }
    }
    float3 chroma = rec709ToYCbCr(sum * 0.25);
    chromaOut.write(float4(encodeVideoRange10(512.0 + chroma.y * 896.0),
                           encodeVideoRange10(512.0 + chroma.z * 896.0), 0.0, 1.0), position);
}

// HLG BT.2020 10-bit export from a finished frame, which arrives in working
// space and goes through the same display transform the preview uses.

// ---------------------------------------------------------------------------
// Shot Match analysis
//
// One job: put every source family into ONE space so two pictures can be
// compared as pictures.
//
// The space is Rec.709-encoded RGB on Rec.709 primaries, 0...1 — the picture as
// a viewer sees it. A 10-bit HLG clip, an Apple Log clip, an 8-bit Rec.709 clip
// and an imported JPEG all arrive here as the same kind of number, which is the
// only footing on which "this shot is warmer than that one" is a statement
// about grading rather than about encoding. Comparing S-Log code values against
// Rec.709 code values would report a flat, desaturated, green-biased reference
// that is nothing but the transfer function.
//
// These write the picture WITH its grade applied, through the same
// `applyLookAndGrade` the preview uses, for the same reason the scopes do: a
// reference shot is a GRADED shot, and the thing to match is what is on screen.
//
// Nothing here ever touches a delivered frame. The output goes to a small
// rgba32Float texture the CPU reads and throws away. So the highlight handling
// below normalises a measurement, never a picture: an HDR frame's headroom is
// counted into the alpha channel rather than being compressed away, which is
// what stops the solver from reading a specular highlight as a blown one and
// "rescuing" a highlight that was never in trouble.
// ---------------------------------------------------------------------------

// BT.2020 -> Rec.709 for linear light, D65 throughout (ITU-R BT.2087). The
// inverse of `kRec709ToBT2020` above; both are written out so neither is a
// matrix inversion performed at runtime on values that are already known.
constant float3x3 kBT2020ToRec709 = float3x3(
    float3( 1.660491, -0.124550, -0.018151),
    float3(-0.587641,  1.132900, -0.100579),
    float3(-0.072850, -0.008349,  1.118730));

// Working space (linear BT.2020, diffuse white at 1.0) -> the analysis space.
//
// Alpha carries the headroom flag: 1 when this pixel was above diffuse white
// before the encode clamped it. Averaged over the frame on the CPU, that is the
// share of the picture living in HDR headroom, which the solver needs in order
// to tell "this is an HDR highlight" from "this is clipped".
inline float4 workingToAnalysis(float3 working) {
    float headroom = maxChannel(working) > 1.0 ? 1.0 : 0.0;
    float3 rec709 = max(kBT2020ToRec709 * working, 0.0);
    return float4(saturate(linearToRec709(rec709)), headroom);
}

kernel void shotMatchSampleYUV(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> analysis [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= analysis.get_width() || position.y >= analysis.get_height()) { return; }
    // Point sampling, not linear. A bilinear fetch between two pixels invents a
    // colour that is in neither of them, and an average of a red and a green
    // pixel reads as a desaturated yellow the scene never contained - which
    // would quietly pull every saturation measurement toward grey.
    constexpr sampler analysisSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = (float2(position) + 0.5) / float2(analysis.get_width(), analysis.get_height());
    float3 rgb = decodeYUV(lumaTexture.sample(analysisSampler, uv).r,
                           chromaTexture.sample(analysisSampler, uv).rg, yuv);
    float3 graded = applyLookAndGrade(rgb, uv, grade, lutTexture, curveLUT, warpField, locals);
    analysis.write(float4(saturate(graded), 0.0), position);
}

kernel void shotMatchSampleBGRA(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::write> analysis [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= analysis.get_width() || position.y >= analysis.get_height()) { return; }
    constexpr sampler analysisSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = (float2(position) + 0.5) / float2(analysis.get_width(), analysis.get_height());
    float4 pixel = sourceTexture.sample(analysisSampler, uv);
    float3 straight = pixel.a > 0.00001 ? pixel.rgb / pixel.a : float3(0.0);
    float3 graded = applyLookAndGrade(straight, uv, grade, lutTexture, curveLUT, warpField, locals);
    // A transparent pixel is not part of the picture, so it is marked for the
    // CPU to drop rather than measured as black - a title card's empty corner
    // would otherwise be read as a crushed shadow.
    analysis.write(float4(saturate(graded), pixel.a < 0.5 ? -1.0 : 0.0), position);
}

kernel void shotMatchSampleHDR(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::write> analysis [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(2)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= analysis.get_width() || position.y >= analysis.get_height()) { return; }
    constexpr sampler analysisSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = (float2(position) + 0.5) / float2(analysis.get_width(), analysis.get_height());
    float3 working = toWorkingSpace(sourceTexture.sample(analysisSampler, uv).rgb, hdr);
    working = applyLookAndGradeHDR(working, uv, grade, lutTexture, curveLUT, warpField, locals);
    analysis.write(workingToAnalysis(working), position);
}

kernel void shotMatchSampleAppleLog(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d<float, access::write> analysis [[texture(2)]],
    texture3d<float, access::sample> lut [[texture(3)]],
    texture3d<float, access::sample> renderingLUT [[texture(4)]],
    texture2d<float, access::sample> curves [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    constant LocalGradeStack &locals [[buffer(8)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= analysis.get_width() || position.y >= analysis.get_height()) { return; }
    constexpr sampler analysisSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = (float2(position) + 0.5) / float2(analysis.get_width(), analysis.get_height());
    float3 working = appleLogToWorking(luma.sample(analysisSampler, uv).r,
                                       chroma.sample(analysisSampler, uv).rg);
    working = applyLookAndGradeHDR(working, uv, grade, lut, curves, warpField, locals);
    // Through Apple's own rendering LUT, which is the transform the preview
    // uses. Analysing the Log code values instead would measure the camera's
    // encoding rather than the picture, and would report every Log clip as flat
    // and green whatever grade was on it.
    float headroom = maxChannel(working) > 1.0 ? 1.0 : 0.0;
    analysis.write(float4(saturate(appleLogWorkingToRec709(working, renderingLUT)), headroom),
                   position);
}

// ---------------------------------------------------------------------------
// Noise Reduction: into and out of the working planes
//
// The denoising engine itself lives in NoiseReductionShaders.metal and works on
// a luma plane and a chroma plane, knowing nothing about colour. These are the
// two ends of it, and they are here rather than there so that every transform
// they use — the YUV matrix, the HLG and Apple Log input transforms, the
// shaper — is the same one the grading path uses, from the same source.
//
// WHERE THIS SITS. Noise reduction runs after the input transform and before
// the creative grade. That is the only defensible place for it: noise is a
// property of the signal the camera produced, so it has to be removed in terms
// of that signal, and it has to be removed before a grade lifts the shadows it
// is hiding in. Placing it after the grade would mean denoising a picture whose
// noise had already been stretched, clipped and had a look applied to it.
//
// WHAT THE PLANES ARE. A luminance/colour-difference pair built on the working
// primaries — Rec.709 for the SDR path, BT.2020 for the extended-range one —
// so luma and chroma can be filtered independently, which is the whole point.
// The matrix is exactly invertible, so a frame with every strength at zero
// round-trips to itself.
//
// For the extended-range paths the signal is put through the shaper first. In
// linear light the amplitude of sensor noise follows the signal, so a single
// threshold would be far too loose in the highlights and far too tight in the
// blacks; the shaper compresses the range enough that one measured noise floor
// describes the whole picture. It is the same invertible shaper the curve and
// HSL stages already use, not a new one.
// ---------------------------------------------------------------------------

struct NoisePlaneUniforms {
    /// xyz the working primaries' luma weights, w 1 for extended-range input.
    float4 luma;
    /// x how much colour cleaning was asked for, 0...1. The rest is reserved so
    /// this matches the head of `NoiseUniforms`.
    float4 geometry;
};

inline float3 noiseToPlanes(float3 rgb, constant NoisePlaneUniforms &u) {
    float3 signal = u.luma.w > 0.5 ? workingToShaper(rgb) : rgb;
    float3 w = u.luma.xyz;
    float y = dot(signal, w);
    return float3(y,
                  (signal.b - y) / (2.0 * (1.0 - w.b)),
                  (signal.r - y) / (2.0 * (1.0 - w.r)));
}

inline float3 noiseFromPlanes(float3 ycc, constant NoisePlaneUniforms &u) {
    float3 w = u.luma.xyz;
    float r = ycc.x + ycc.z * 2.0 * (1.0 - w.r);
    float b = ycc.x + ycc.y * 2.0 * (1.0 - w.b);
    float g = (ycc.x - w.r * r - w.b * b) / w.g;
    float3 signal = float3(r, g, b);
    return u.luma.w > 0.5 ? shaperToWorking(signal) : signal;
}

inline void writeNoisePlanes(float3 rgb, constant NoisePlaneUniforms &u,
                             texture2d<float, access::write> lumaOut,
                             texture2d<float, access::write> chromaOut,
                             uint2 position) {
    float3 ycc = noiseToPlanes(rgb, u);
    lumaOut.write(float4(ycc.x, 0.0, 0.0, 0.0), position);
    chromaOut.write(float4(ycc.y, ycc.z, 0.0, 0.0), position);
}

kernel void nrPrepareYUV(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> lumaOut [[texture(2)]],
    texture2d<float, access::write> chromaOut [[texture(3)]],
    constant NoisePlaneUniforms &u [[buffer(0)]],
    constant YUVUniforms &yuv [[buffer(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= lumaOut.get_width() || position.y >= lumaOut.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(lumaOut.get_width(), lumaOut.get_height());
    float3 rgb = decodeYUV(lumaTexture.sample(videoSampler, uv).r,
                           chromaTexture.sample(videoSampler, uv).rg, yuv);
    writeNoisePlanes(rgb, u, lumaOut, chromaOut, position);
}

kernel void nrPrepareBGRA(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> lumaOut [[texture(2)]],
    texture2d<float, access::write> chromaOut [[texture(3)]],
    constant NoisePlaneUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= lumaOut.get_width() || position.y >= lumaOut.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(lumaOut.get_width(), lumaOut.get_height());
    float4 pixel = source.sample(videoSampler, uv);
    float3 straight = pixel.a > 0.00001 ? pixel.rgb / pixel.a : float3(0.0);
    writeNoisePlanes(straight, u, lumaOut, chromaOut, position);
}

kernel void nrPrepareHDR(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> lumaOut [[texture(2)]],
    texture2d<float, access::write> chromaOut [[texture(3)]],
    constant NoisePlaneUniforms &u [[buffer(0)]],
    constant HDRDisplayUniforms &hdr [[buffer(2)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= lumaOut.get_width() || position.y >= lumaOut.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(lumaOut.get_width(), lumaOut.get_height());
    float3 working = toWorkingSpace(source.sample(videoSampler, uv).rgb, hdr);
    writeNoisePlanes(working, u, lumaOut, chromaOut, position);
}

kernel void nrPrepareAppleLog(
    texture2d<float, access::sample> lumaTexture [[texture(0)]],
    texture2d<float, access::sample> chromaTexture [[texture(1)]],
    texture2d<float, access::write> lumaOut [[texture(2)]],
    texture2d<float, access::write> chromaOut [[texture(3)]],
    constant NoisePlaneUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= lumaOut.get_width() || position.y >= lumaOut.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(lumaOut.get_width(), lumaOut.get_height());
    float3 working = appleLogToWorking(lumaTexture.sample(videoSampler, uv).r,
                                       chromaTexture.sample(videoSampler, uv).rg);
    writeNoisePlanes(working, u, lumaOut, chromaOut, position);
}

/// The denoised planes, back to the representation the grade expects.
///
/// Chroma is applied as a DIFFERENCE rather than substituted. The chroma stages
/// work on a half-resolution plane, which is right — colour noise is
/// low-frequency and a 4:2:0 source has no more colour resolution than that
/// anyway — but substituting the result would also throw away the full-
/// resolution colour a 4:4:4 source really does carry. Adding back only what
/// the filtering changed keeps that detail exactly, and means chroma strengths
/// of zero leave the colour bit-identical.
kernel void nrReconstruct(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chromaFull [[texture(1)]],
    texture2d<float, access::sample> chromaOriginal [[texture(2)]],
    texture2d<float, access::sample> chromaDenoised [[texture(3)]],
    texture2d<float, access::write> destination [[texture(4)]],
    constant NoisePlaneUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    float y = luma.sample(s, uv).r;
    float2 chroma = chromaFull.sample(s, uv).rg;
    if (!is_null_texture(chromaDenoised)) {
        float2 before = chromaOriginal.sample(s, uv).rg;
        float2 after = chromaDenoised.sample(s, uv).rg;
        // Everything the half-resolution plane could see, cleaned.
        //
        // What is left over — the difference between the full-resolution colour
        // and what survives a trip through half resolution — is colour detail
        // finer than two pixels. In a 4:4:4 source that is real and must be
        // kept; in a 4:2:0 source it is an artefact of the upsample and is
        // where the last of the speckle hides. Rather than guess which, it is
        // faded out by how much colour cleaning was asked for: at zero the
        // colour is untouched to the bit, and at full strength fine chroma
        // structure is exactly what the control said to remove.
        float2 fine = chroma - before;
        chroma = after + fine * (1.0 - saturate(u.geometry.x));
    }
    destination.write(float4(noiseFromPlanes(float3(y, chroma), u), 1.0), position);
}

/// Grades a frame that is ALREADY in the extended-range working space.
///
/// `gradeToTextureHDR` cannot serve here because it starts by applying the
/// input transform, and a denoised frame has been through that already. The
/// same kernel serves HLG and both Apple Log variants, because after their
/// respective input transforms all three are the same working space — which is
/// the arrangement the Apple Log path was built on in the first place.
kernel void gradeToTextureWorking(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(2)]],
    texture3d<float, access::sample> lutTexture [[texture(3)]],
    texture2d<float, access::sample> curveLUT [[texture(6)]],
    texture2d<float, access::sample> warpField [[texture(12)]],
    constant GradeUniforms &grade [[buffer(0)]],
    uint2 position [[thread_position_in_grid]],
    constant LocalGradeStack &locals [[buffer(8)]])
{
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) { return; }
    constexpr sampler videoSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(position) + 0.5) / float2(destination.get_width(), destination.get_height());
    float3 working = source.sample(videoSampler, uv).rgb;
    destination.write(float4(applyLookAndGradeHDR(
        working, uv, grade, lutTexture, curveLUT, warpField, locals), 1.0), position);
}
