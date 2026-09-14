# LUT Generator

A host-only Swift package that generates the creative `.cube` LUTs bundled with
GradeLab. It is not part of the app target and is never compiled into the
shipping binary.

## 1. How LUT generation works

A 3D LUT is a lookup table sampled on a regular grid over the RGB cube. The
generator walks that grid, feeds each grid point through a pure Swift
`(RGB) -> RGB` transform, clamps the result to `[0, 1]`, and writes the samples
out as `.cube` text. The GPU later reconstructs the full mapping by
interpolating between the stored samples, so the transform must be smooth —
anything with a hard edge in it will show up on screen as banding or a hue break.

Files:

| File | Role |
| --- | --- |
| `ColorOps.swift` | Reusable colour maths — tone curves, saturation, split toning, hue-selective operations, Rec.709 luma |
| `LUTGenerator.swift` | Grid sampling and `.cube` writing |
| `LUTValidator.swift` | Structural, numeric and continuity validation |
| `CubeSampler.swift` | Trilinear sampling, used by the identity check |
| `LUTCatalog.swift` | The list of LUTs to generate |
| `Looks/*.swift` | One file per look |
| `main.swift` | Runs the identity check, then generates, validates and reports every LUT |

**Sample ordering.** Red varies fastest, blue slowest — the `.cube` convention.
Entry `i` is `r = i % size`, `g = (i / size) % size`, `b = i / size²`. The app's
`CubeLUTParser` stores samples in file order without reinterpreting them, so a
future 3D-texture upload must use the same convention. Every run verifies this
by generating an identity LUT, re-parsing it, trilinearly sampling it and
checking that the output matches the input for the primaries, secondaries,
black, white, greys, representative skin/sky/foliage colours, and 200 random
samples. The identity LUT is used only for that check and is never written to
the resources folder.

## 2. How to run it

```bash
swift run --package-path Tools/LUTGenerator lutgen
```

It prints the identity check, then per LUT: the validation results and a
transformation table for representative colours. It exits non-zero if any check
fails. Pass a directory argument to write somewhere other than the default.

## 3. How to add another LUT

Add a file under `Sources/lutgen/Looks/`, then add its definition to
`LUTCatalog.definitions`. Nothing else changes.

```swift
// Sources/lutgen/Looks/Moody.swift
enum Moody {
    static let definition = LUTDefinition(
        name: "Moody",
        filename: "Moody.cube",
        category: "Cinematic",
        summary: "Cool, low-key look with deep shadows and restrained colour.",
        inputColorSpace: "Rec.709 / working SDR",
        type: "creative",
        transform: transform
    )

    private static let tone: @Sendable (Double) -> Double = ToneCurve.normalizedToWhite { x in
        ToneCurve.sCurve(ToneCurve.blackCompression(x, strength: 0.14, range: 0.20), amount: 0.30)
    }

    @Sendable static func transform(_ input: RGB) -> RGB {
        var color = input.mapChannels(tone)
        color = ColorOps.splitTone(
            color,
            shadow: RGB(0.000, 0.002, 0.016),
            mid: RGB(0.000, 0.000, 0.004),
            highlight: RGB(0.004, 0.002, 0.000)
        )
        color = ColorOps.saturation(color, 0.88)
        color = ColorOps.highlightDesaturation(color, amount: 0.30, start: 0.70)
        return ColorOps.clamped(color)
    }
}
```

```swift
// Sources/lutgen/LUTCatalog.swift
static let definitions: [LUTDefinition] = [
    WarmCinema.definition,
    TealOrange.definition,
    SoftFilm.definition,
    Moody.definition        // <- added
]
```

Then add a matching `LUTAsset` entry in `dummy name/Core/LUT/LUTAsset.swift` so
the app knows about it, and re-run the generator.

Two habits worth keeping when writing a transform:

- Fade tints out at the endpoints (`ColorOps.splitTone` already does this) so
  black stays black and white stays white instead of being clamped flat.
- Select colours with `ColorOps.hueWeight`, which is a raised-cosine lobe scaled
  by chroma. It has no hard edges and leaves greys alone, so it cannot introduce
  a visible LUT boundary.

## 4. Choosing a LUT size

`LUT_3D_SIZE` is the number of samples per axis. Size *n* stores *n³* entries,
so cost grows cubically: 17 → 4,913 entries, 33 → 35,937, 65 → 274,625. Larger
sizes track sharper transforms more accurately but cost memory and file size.
Set it in `LUTCatalog.size`; `LUTGenerator` and `LUTValidator` both read it.

## 5. Why 33 points

33 is the industry-standard size for creative looks and the best trade-off here:
it resolves smooth tonal and hue transforms with no visible error under trilinear
interpolation, keeps each file under 1 MB of text, and is comfortably inside the
2–65 range `CubeLUTParser` accepts. Our looks are smooth by construction, so a
65-point LUT would multiply the size by eight for no visible benefit. 17 points
would start to show error in the shoulder and in the hue-selective work.

## 6. Where the files go

`dummy name/Resources/LUTs/`, resolved from the tool's own source location so it
works from any working directory. That folder is inside the app target's
file-system-synchronized group, so Xcode bundles the `.cube` files automatically;
they land at the app bundle root and resolve via
`Bundle.main.url(forResource:withExtension:)`.

## 7. These LUTs expect SDR input

All three bundled LUTs are **creative looks** for footage already in the app's
working SDR / Rec.709 space, matching the app's validated V1 support boundary.
They assume display-encoded (gamma) input and are applied in that domain.

## 8. Technical conversions are a separate concern

Apple Log, S-Log, D-Log, HDR-to-SDR and other camera or colour-space conversions
are **not** creative looks and must not be added to this catalogue. They belong
to a technical stage that runs before the creative LUT, and they carry accuracy
requirements — correct transfer functions, gamut mapping, and often larger LUTs
or analytic transforms — that this tool does not attempt to meet.

## 9. Validation

Every run checks, for each generated file and again after writing it to disk:

- `LUT_3D_SIZE` equals the configured size
- entry count equals size³ (35,937 at size 33)
- every data line holds exactly three numeric values
- no NaN, no infinity, no negatives, nothing above 1
- `DOMAIN_MIN 0 0 0` and `DOMAIN_MAX 1 1 1`
- a non-empty `TITLE`, and valid overall `.cube` structure
- continuity: no neighbouring grid samples differ by more than four input steps

The parsing rules in `LUTValidator` mirror the app's `CubeLUTParser`.
`GradeLabTests/BundledLUTTests.swift` runs the **real** parser over the same
files, so the two cannot drift apart.

## 10. How the app applies these files

The generator's job ends at the `.cube` file, but it is worth knowing what reads
it, because the two have to agree on ordering.

`LUTTextureFactory` uploads a parsed cube straight into an `rgba16Unorm` 3D
texture with no reshuffling: a 3D texture stores x fastest, then y, then z, which
is exactly the red-fastest order written here. The shader's `applyLUT` then maps
the 0...1 input onto texel *centres* — `(v * (N - 1) + 0.5) / N` — before
sampling, because a size-N LUT stores its samples at centres rather than at the
edges of the texture.

`Scripts/ValidateLUT.swift` checks that end to end on the GPU: it compiles the
real `Shaders.metal`, uploads a size-33 identity LUT, and confirms the output
matches the input to under 0.0001. Run it after changing anything about the
ordering, the texture layout or the sampling maths:

```bash
xcrun swiftc -O -o /tmp/validatelut Scripts/ValidateLUT.swift \
  "dummy name/Core/LUT/CubeLUT.swift" "dummy name/Core/LUT/CubeLUTParser.swift" \
  "dummy name/Core/LUT/LUTAsset.swift" "dummy name/Core/LUT/LUTTexture.swift" \
  "dummy name/Core/Grading/GradeSettings.swift" "dummy name/Core/Grading/AdvancedGrade.swift" \
  "dummy name/Core/Rendering/RenderUniforms.swift" "dummy name/Core/AppError.swift" && /tmp/validatelut
```

One caveat that is easy to get wrong: an identity LUT is only exact if it is big
enough. Metal's linear filter interpolates with fixed-point weights of about
1/256 of a texel, so a 2×2×2 identity — mathematically perfect — comes back off
the GPU with a ~0.002 error, because one texel spans half the range. That is why
the no-look fallback texture is size 17 rather than size 2.
