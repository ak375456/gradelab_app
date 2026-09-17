# German (de-DE) App Store metadata

Translated from `../en-US/` on 2026-09-16. Everything here except `keywords.txt`
is a faithful translation of the approved English copy and is ready to paste
into App Store Connect.

## Character limits — all verified

| File | Chars | Limit |
|---|---|---|
| `name.txt` | 23 | 30 |
| `subtitle.txt` | 25 | 30 |
| `keywords.txt` | 94 | 100 |
| `promotional-text.txt` | 149 | 170 |
| `description.txt` | 3920 | 4000 |
| `whats-new.txt` | 810 | 4000 |

The German description needed trimming: a straight translation of the English
came to 4339 characters, over Apple's 4000 limit. It was tightened without
dropping any section or feature bullet.

## keywords.txt is NOT researched — validate before shipping

The other files are translation, which can be done accurately. Keywords are not
a translation problem: the right German keywords depend on real search volume
and competition, which cannot be known without data.

What is in `keywords.txt` is a **candidate list**, chosen on structure alone:

- It avoids repeating words already indexed from the app name and subtitle
  (Color, Grading, Video, Foto, Editor, LUTs). Apple indexes name + subtitle +
  keywords together, so repeats waste the 100-character budget.
- It uses German compounds (`Farbkorrektur`, `Videobearbeitung`,
  `Bildbearbeitung`) rather than translating the English terms word by word.
- Comma-separated, no spaces after commas, all lowercase.
- It keeps `apple log` from the English set: it is spelled identically in German
  and is the app's sharpest differentiator — someone who shot Apple Log on an
  iPhone and needs to grade it is a high-intent, low-competition search.

Reusing the English keywords in the German storefront wastes about half the
field. Of the 97 characters in the English set, ~48 are dead or duplicated for a
German user: `edit video` and `colour` are not words a German types, and
`editor`, `LUT`, `LUTs` and `color grading` are already indexed from the German
app name and subtitle, so repeating them buys nothing.

**Before shipping, check the volume for each candidate** in Apple Search Ads
(Keyword Planner shows Apple's own search-popularity figures for free, per
storefront) or an ASO tool such as AppTweak, Sensor Tower or App Radar. Terms
worth testing against the candidates: `videoschnitt`, `farbfilter`,
`videobearbeitung app`, `cinematic`, `belichtung`, `farbe bearbeiten`.

Do not ship the candidate list as-is on the assumption that it was researched.
