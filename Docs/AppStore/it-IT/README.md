# Italian (it-IT) App Store metadata

Written 2026-09-19 against the app's own Italian in `Localizable.xcstrings`.
Terminology is taken from the catalog rather than translated afresh.

## Character limits — all verified

| File | Chars | Limit |
|---|---|---|
| `name.txt` | 23 | 30 |
| `subtitle.txt` | 24 | 30 |
| `keywords.txt` | 95 | 100 |
| `promotional-text.txt` | 149 | 170 |
| `description.txt` | 3856 | 4000 |
| `whats-new.txt` | 777 | 4000 |

## Conventions carried over from the app

- **Grading stays the English loanword `grading`** — Italian post-production
  really does say *il grading*, and the native *correzione colore* is three
  times the length. Verb forms read *fai il grading*.
- **`LUT` is invariable** — never `LUTs`. Treated as feminine: *le tue LUT*,
  *LUT cinematografiche*.
- Hue = `Tonalità`, Tint = `Tinta`, Vibrance = `Vividezza` (Lightroom's Italian).
  No collisions, unlike French and Spanish.
- `Timeline` and `Canvas` stay English, as in the app.
- Italian attaches the percent sign — `94%`, no space. The opposite of French
  and Spanish. No percentages occur in this metadata.
- Address is `tu`.

## The app name keeps the English term — deliberately

`name.txt` reads **GradeLab: Color Grading**, the same as English and German,
and unlike French (`Étalonnage`) and Spanish (`Etalonaje`).

This is not an oversight. Italian is the one Romance language here that uses the
English loanword natively, which is why the app's Italian says *grading*
throughout. An Italian name of *Color Grading* reads as the professional term,
not as untranslated English.

Still worth validating in Apple Search Ads before submitting, since changing the
name later costs another app version. `GradeLab: Grading` (17) also fits if a
shorter name tests better.

## keywords.txt is NOT researched

A candidate list chosen on structure, not search volume. It avoids repeating
what the name and subtitle already index (color, grading, editor, video, foto,
LUT), and leads with `correzione colore` — the native term deliberately *not*
used in the app name, so the two fields cover both vocabularies instead of
duplicating one.

Check each term in Apple Search Ads Keyword Planner. Worth testing against:
`montaggio video`, `filtri video`, `editor video`, `lut`.
