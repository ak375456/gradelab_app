# French (fr-FR) App Store metadata

Written 2026-09-19, matching the app's own French (889 strings in
`Localizable.xcstrings`). Terminology is taken from the catalog rather than
translated afresh, so the store copy and the app agree: étalonnage, hautes
lumières, ombres, nuance (Tint), teinte (Hue), images clés, calques, préréglage,
suivi, forme d'onde, parade RVB.

## Character limits — all verified

| File | Chars | Limit |
|---|---|---|
| `name.txt` | 21 | 30 |
| `subtitle.txt` | 28 | 30 |
| `keywords.txt` | 93 | 100 |
| `promotional-text.txt` | 164 | 170 |
| `description.txt` | 3969 | 4000 |
| `whats-new.txt` | 845 | 4000 |

The description needed real trimming: a full translation of the English came to
**4430 characters**, 430 over Apple's limit. It was tightened to 3969 without
dropping a single section or feature bullet. French expands like German.

## French typography is applied

A no-break space (U+00A0) sits before `:` `;` `?` `!`, matching the convention
used inside the app. It was inserted only where a space already stood, so URLs
(`https://`) are untouched. If you retype any of this by hand in App Store
Connect, keep those spaces non-breaking.

## The app name is a decision, not a translation

`name.txt` reads **GradeLab : Étalonnage** (21 chars), which diverges from the
German, where `Color Grading` was kept in English.

The reason is that the two languages behave differently. German video
professionals say "Color Grading" untranslated, so keeping it there costs
nothing. French has strong native vocabulary and uses it — the app's own French
says *étalonnage* throughout — so an English name would read as unlocalized.

The counter-argument is that *étalonnage* is a professional term, while
consumers searching the French App Store may type *montage vidéo* or *filtres*.
**Validate in Apple Search Ads before submitting**, because changing the app name
later costs another app version. `GradeLab: Color Grading` (23 chars) also fits
if the data says otherwise.

## keywords.txt is NOT researched

Same caveat as German. This is a candidate list chosen on structure, not on
search volume:

- It avoids repeating what the name and subtitle already index (étalonnage,
  éditeur, vidéo, photo, LUTs). Apple indexes all three fields together.
- It uses single tokens where the pair is already covered — `montage` rather
  than `montage vidéo`, `retouche` rather than `retouche photo` — because
  `vidéo` and `photo` come from the subtitle and the tokens combine.
- It keeps `apple log`, spelled identically in French and the app's sharpest
  differentiator.

Check each term in Apple Search Ads Keyword Planner before shipping. Worth
testing against: `étalonnage vidéo`, `correction couleur`, `filtre cinéma`,
`montage vidéo`, `lut`.
