# Adding your own LUTs

There are two ways to add a look, and they are for different people.

**Ship it with the app** — drop `.cube` files in this folder, run
`Scripts/compile-luts.sh`, and rebuild. They appear in the **Look** tool for
everyone. No code change is needed; the app discovers every look in its bundle
at launch. Everything below applies to these.

The compile step is what keeps the download small: `.cube` files are text, and
the app ships the compiled `.gclut` form instead — same look, about a fifth of
the bytes. Files in this folder are build inputs and are never bundled, so a
look that has not been compiled will not appear. If you forget, the check in
`Scripts/compile-luts.sh --check` says so.

**Import it on the device** — in the editor, open **Look** and tap **Import**,
then pick `.cube` files from Files or iCloud Drive. They are validated, copied
into the app's Application Support folder, and appear in the picker alongside
the built-in looks. They survive relaunches, are private to that device, and can
be deleted again with **Remove**. The same format rules apply, and a file that
breaks them is refused at import with the reason rather than appearing and doing
nothing.

## What to download

| | |
| --- | --- |
| **Format** | 3D `.cube` (Adobe/IRIDAS Cube). This is the most common LUT download format. |
| **Type** | **Creative / look** LUTs for **Rec.709 or sRGB** footage. |
| **Size** | `LUT_3D_SIZE` between 2 and 65. 33 is the usual size; 17, 25, 64 and 65 also work. |
| **Domain** | `DOMAIN_MIN 0 0 0` and `DOMAIN_MAX 1 1 1`. |

If a download offers several formats, pick the one labelled **"3D LUT — .cube"**
or **"Rec.709"**.

## What will NOT work

**Other file formats.** `.3dl`, `.look`, `.csp`, `.vf`, `.mga`, `.dat`, `.icc`,
`.xmp`, `.lut`, `.png` HALD images. Only `.cube` is parsed. Convert first, or
download the `.cube` version.

**1D LUTs** (`LUT_1D_SIZE`). The file parses but cannot be used as a look — the
look stage is 3D only. You will get "Only 3D LUTs can be used as a look".

**Non-0...1 domains.** A file declaring something like `DOMAIN_MAX 4 4 4` is
rejected rather than applied wrongly. These are almost always log conversion
LUTs.

**Log / camera conversion LUTs.** Anything named for a camera transfer curve —
Apple Log, S-Log2/3, V-Log, D-Log, C-Log, N-Log, Log-C, HLG, PQ, "to Rec.709",
"709 conversion". These expect log-encoded input. The app applies looks to
footage that is already Rec.709, so a log LUT will look flat, crushed or
wrongly contrasted. That is not a bug in the LUT; it is the wrong stage. A
technical conversion stage is a separate piece of work.

**LUTs over 65 points.** Rejected by the parser.

## Naming

The display name comes from the filename, with underscores turned into spaces:

```
Night_Market.cube   ->   "Night Market"
Bleach.cube         ->   "Bleach"
```

So name the file the way you want it to read in the picker. Stick to letters,
numbers and underscores.

## Licensing — read this before shipping anything in this folder

This folder is **redistribution**: whatever is here gets copied into the app
binary and shipped to every user. That is a much higher bar than using a LUT on
your own footage.

Before adding a file, check:

- **The licence.** "Free to download" and "free for personal use" do **not**
  allow bundling in a paid app. You need explicit redistribution rights.
- **The file header.** Open the `.cube` in a text editor. Many carry a copyright
  line naming an author or pack. That is the rights holder, and it does not stop
  applying because the file is free.
- **The name.** Film stock names — Portra, Kodachrome, Velvia, Provia, Ektar,
  Cinestill — are manufacturer trademarks. Naming a look after one implies an
  association you do not have, even if the maths is your own.

Looks a user imports on their own device are a different matter: those never
enter your binary and stay on their phone, so their licence is between them and
whoever made the LUT.

## Check them before you commit

```bash
xcrun swiftc -O -o /tmp/validatelut Scripts/ValidateLUT.swift \
  "dummy name/Core/LUT/CubeLUT.swift" "dummy name/Core/LUT/CubeLUTParser.swift" \
  "dummy name/Core/LUT/LUTAsset.swift" "dummy name/Core/LUT/LUTTexture.swift" \
  "dummy name/Core/Grading/GradeSettings.swift" "dummy name/Core/Grading/AdvancedGrade.swift" \
  "dummy name/Core/Rendering/RenderUniforms.swift" "dummy name/Core/AppError.swift" && /tmp/validatelut
```

It checks every `.cube` under `Resources/LUTs`, including this folder, and
reports size, entry count, range, domain, GPU accuracy and smoothness. A LUT
that fails here will not work in the app.

## Size

`.cube` files are plain text and much larger than the numbers in them: a
33-point LUT is about 1 MB and a 64-point one about 7 MB. Compiling cuts that by
roughly 79% — a 64-point look ships as 1.5 MB — because the compiled form stores
the 16-bit samples the GPU actually uploads instead of decimal text.

That is a fixed saving, not a reason to stop caring about grid size: a 64-point
look is still eight times the weight of a 33-point one after compiling. 33 is
the usual size and is enough for almost every look. Prefer it unless a look
genuinely needs more resolution.

## Folder layout

```
LUTSources/                 build inputs - never bundled
    Warm_Cinema.cube        generated by Tools/LUTGenerator - do not edit by hand
    Teal_Orange.cube
    Soft_Film.cube
    Imported/               <- your downloaded .cube files go here

dummy name/Resources/LUTs/  build output - this is what ships
    *.cube.gclut            written by Scripts/compile-luts.sh
```

The split between the two source folders is for humans, so a regenerated
built-in look never overwrites something you added. The split between sources
and output is what keeps the text out of the app: `LUTSources/` sits outside the
app folder, so Xcode cannot bundle it even by accident.

A compiled look keeps its source filename — `Nomad.cube` becomes
`Nomad.cube.gclut` — because that filename is the look's identity and is what
every project using it has saved. Renaming a source renames the look, and
projects referring to the old name will not find it.
