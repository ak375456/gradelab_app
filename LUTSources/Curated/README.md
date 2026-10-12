# Curated looks

Added from the local FG Free Cine LUTs Pack v2 and ON1 All LUTs downloads on 2026-10-13. Original downloads are untouched. Copies retain their source comments and numerical samples; only filenames and TITLE metadata use the app display names. Source comments retain the original attribution.

Three looks are free and five use the existing Pro export policy. All can be previewed in the editor. The explicit catalog in `LUTAsset.bundledCuratedLooks` places them after the original three looks.

| App name | Source pack | Original filename | Access |
| --- | --- | --- | --- |
| Daylight | FG Free Cine v2 | `FG_CineBright.cube` | Free |
| Vivid Cinema | FG Free Cine v2 | `FG_CineVibrant.cube` | Free |
| Silver Mono | ON1 Black & White | `BW10.cube` | Free |
| Dramatic Cinema | FG Free Cine v2 | `FG_CineDrama.cube` | Pro |
| Cool Cinema | FG Free Cine v2 | `FG_CineCold.cube` | Pro |
| Vintage Chrome | ON1 / Lutify.me | `Vintage Chrome.cube` | Pro |
| Film Print | ON1 / Lutify.me | `Film Print 02.cube` | Pro |
| Studio Portrait | ON1 / Lutify.me | `Studio Skin Tone Shaper.cube` | Pro |

App resources are compiled `.cube.gclut` files in `dummy name/Resources/LUTs`. They use the same quantization as the GPU upload, avoiding runtime text parsing. Compile this directory to a temporary output directory with `Scripts/CompileLUTs.swift`, then copy its eight outputs to the resources directory. Compiling a subset directly into the shared resources directory would remove other looks as orphans.

The existing resource directory also contains older compiled looks whose text sources are absent. Preserve those resources when compiling this collection.
