# Sunset collection

Six creative 3D `.cube` looks selected from the user's local `IWLTBAP - Sedona
(Free LUT)` download on 2026-10-28. Only Standard / STD variants are used;
LOG, V-Log, camera conversion utilities and duplicate `.3dl` / `.look` versions
are not creative inputs for this collection.

The source headers say redistribution is prohibited. In this chat on 2026-10-28,
the user explicitly confirmed: “I have permission to redistribute these
LUTs—bundle them.” This collection is bundled on the basis of that separate
permission. The original copyright notices and source comments are retained.
Original Downloads files are untouched. No claim of GradeLab authorship is made.

Only filenames and TITLE metadata were changed. Numerical samples, original grid
sizes and ordering are preserved. New filenames are stable project identifiers;
change display names in `LUTAsset` if needed, without renaming these files.

| App name | Original Standard-profile source | Grid |
| --- | --- | --- |
| Desert Sunset | `IWLTBAP Sedona - Standard.cube` | 32³ |
| Evergreen Chrome | `BONUS/Aspen/IWLTBAP Aspen - Standard.cube` | 32³ |
| Amber Grove | `BONUS/Arapaho/IWLTBAP Arapaho - Standard.cube` | 33³ |
| Soft Bloom | `BONUS/Humble/IWLTBAP Humble - Standard.cube` | 33³ |
| Azure Film | `BONUS/8700/F-8700-STD.cube` | 32³ |
| Azure Film Deep | `BONUS/8700/F-8700-V2-STD.cube` | 32³ |

`provenance.json` records original paths and SHA-256 digests for audit and
regeneration. The explicit `LUTAsset.bundledSunsetLooks` catalog puts this set
after the existing curated eight. They follow the existing Pro export policy;
all are available for preview and camera looks.

Only compiled `.cube.gclut` data is shipped, approximately 1.2 MB in total.
Textures load on demand; the collection does not add startup preloading.
Compile this subfolder into a **temporary output directory** with the app's
`Scripts/CompileLUTs.swift`, verify it, then copy only its six `.gclut` outputs to
`dummy name/Resources/LUTs`. Do not compile a subset directly into the shared
resource folder: the compiler removes other resources as orphans.
