# GradeLab Finnish localization

## App Store Connect copy

| Field | Source |
| --- | --- |
| App name | `name.txt` |
| Subtitle | `subtitle.txt` |
| Keywords | `keywords.txt` |
| iPhone and iPad description | `description.txt` |
| Mac description | `mac-description.txt` |
| Promotional text | `promotional-text.txt` and `mac-promotional-text.txt` |
| What's New | `whats-new.txt` |
| Lifetime purchase, subscription group, and subscriptions | `in-app-purchases.md` |

## Screenshots

The upload-ready PNGs and ZIPs are in `../../../store_localizations/fi-FI/`.
There are six iPhone screenshots at 1242 × 2688, six iPad screenshots at
2064 × 2752, and five Mac screenshots at 2880 × 1800. The device artwork and
in-app screenshots remain identical to the English references; only marketing
titles and subtitles are localized, as requested.

## In-app strings

Finnish entries are present for all 1,729 translatable keys that have Swedish
localizations in `../../../dummy name/Localizable.xcstrings`. The other 16 keys
are marked as nontranslatable. Product strings are also present in
`../../../GradeLab.storekit`, and the photo-library permission message is in
`../../../dummy name/InfoPlist.xcstrings`.

The broad in-app string set began as machine translation. Core controls,
purchase copy, and common editing terms received an editorial pass, while
remaining entries are marked `needs_review` in the string catalog. Have a
native Finnish reviewer check the in-app copy before release, especially
longer technical guidance and error messages. The screenshots and App Store
copy were written separately and visually checked.

The `.storekit` file supports local testing. Enter the same localized in-app
purchase and subscription values in App Store Connect before submission.
