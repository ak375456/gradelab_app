# Spanish (es-ES) App Store metadata

Written 2026-09-19 against the app's own Spanish in `Localizable.xcstrings`.
Terminology is taken from the catalog rather than translated afresh, so the
store copy and the app agree.

## Character limits — all verified

| File | Chars | Limit |
|---|---|---|
| `name.txt` | 19 | 30 |
| `subtitle.txt` | 27 | 30 |
| `keywords.txt` | 95 | 100 |
| `promotional-text.txt` | 164 | 170 |
| `description.txt` | 3906 | 4000 |
| `whats-new.txt` | 787 | 4000 |

## Conventions carried over from the app

- **Grading is `etalonaje`** (verb `etalonar`), the professional term in
  Spanish-language colour work.
- **`vídeo` with the accent**, the peninsular spelling the app uses throughout
  (39 occurrences, zero of `video`).
- **`LUT` is invariable** — never `LUTs`. The app treats it as feminine:
  *tus propias LUT*, *LUT cinematográficas*.
- **Hue = `Tono`, Tint = `Matiz`**; `Vibrance` stays English, because the usual
  Spanish rendering "Intensidad" collides with *Intensidad del look*.
- Spanish punctuation: no space before `:`, `¿` opens questions, space before a
  literal `%`. No questions or percentages occur in this metadata.

## The app name is a decision, not a translation

`name.txt` reads **GradeLab: Etalonaje** (19 chars). Spanish, like French, has
native vocabulary here and the app uses it, so an English name would read as
unlocalized. The counter-argument is the same: *etalonaje* is a professional
term while consumers may search *edición de vídeo* or *filtros*.

**Validate in Apple Search Ads before submitting** — changing the app name later
costs another app version. `GradeLab: Color Grading` (23) also fits.

## keywords.txt is NOT researched

A candidate list chosen on structure, not search volume. It avoids repeating
what the name and subtitle already index (etalonaje, editor, vídeo, foto, LUT),
and uses single tokens where the pair is already covered — `edición` and
`retoque` rather than `edición de vídeo` and `retoque de fotos` — because
`vídeo` and `foto` come from the subtitle and the tokens combine.

Check each term in Apple Search Ads Keyword Planner. Worth testing against:
`corrección de color`, `editor de vídeo`, `filtros de cine`, `lut`.
