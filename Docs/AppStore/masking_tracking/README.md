# Masking and tracking App Store screenshots

One combined feature card per device and language: **14 upload-ready RGB PNGs**.

- iPhone: 1242 × 2688, in `../../../ios_store_localizations/masking_tracking/`.
- iPad: 2064 × 2752, in `../../../ipad_store_localizations/masking_tracking/`.
- Languages: English (`en-US`), French (`fr-FR`), German (`de-DE`), Italian (`it-IT`), Spanish/Spain (`es-ES`), Swedish (`sv-SE`) and Finnish (`fi-FI`).
- Combined download: `GradeLab_Masking_Tracking_7_languages.zip`, organized by device and locale.
- Contact sheets: `iphone_contact_sheet.jpg` and `ipad_contact_sheet.jpg`.
- English comparison: `english_preview.jpg`.

Each card combines a real GradeLab editor view showing the freehand mask and its curve handles with a magnified crop of the real motion-tracking controls. The tracker was run on the demo clip and completed with **20 position keyframes**; the success notice in the artwork is the actual result. The photo is the existing alpine-lake marketing asset from `mac_store_localizations/color_warper/source_alpine_lake.png`.

Marketing headlines, subtitle and tracking callout are localized. In-app UI remains English, matching the existing App Store screenshot collections. Device frames and system status artwork are presentation elements.

## Rebuild the artwork

Run `build.py` using Python with Pillow and NumPy. The repository's bundled runtime can be found through the workspace dependencies tool. The build uses the preserved PNG captures in `sources/`, checks all text bounds and image dimensions, writes the contact sheets, and packages the two device archives plus the combined archive.

The native source captures were rendered from the shipping SwiftUI editor and controls under Mac Catalyst using iPhone and iPad layout settings. A CPU image snapshot cannot read a Metal drawable, so its picture surface uses the source frame while the editor chrome, mask path, anchors, curve handles, zoom controls and inspector come from native views. Temporary capture hooks were removed from app code after rendering. `sources/capture.swift` and `sources/make-demo.swift` preserve the capture procedure for reference; rebuilding the cards from the PNGs does not require Xcode or those hooks.

Dimensions follow [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), checked 2026-10-13. These files are ready for the iPhone Face ID large-display slot and the iPad 13-inch slot. Nothing was uploaded to App Store Connect.

## iPhone Dynamic Island medium-display upload

App Store Connect's **iPhone with Dynamic Island (medium display)** tab accepts portrait images at **1179 × 2556** or **1206 × 2622**, so it will reject the original 1242 × 2688 files in this collection. Those originals belong to **iPhone with Face ID (large display)**, available through **View All Sizes in Media Manager**.

For the medium-display tab, use the seven **1206 × 2622 RGB PNGs** in `../../../ios_store_localizations/masking_tracking/iphone_dynamic_island_medium/`, or extract `../../../ios_store_localizations/masking_tracking/GradeLab_iPhone_Masking_Tracking_1206x2622_7_languages.zip`. Select the matching language before uploading its PNG. These cards preserve the complete artwork on a slightly taller canvas. Run `build_medium.py` to rebuild them. `manifest_iphone_medium.json` and `iphone_medium_contact_sheet.jpg` record the dimensions, localized copy and visual check.

The faded images labeled **Using Existing Assets** are inherited from another screenshot size. To append to that existing gallery, locate its original size group in Media Manager and upload the matching-size card there; the new medium-display files can instead be used for a separate gallery in the medium-display tab. The original large-display and iPad assets have been preserved.

### Keep the existing English gallery in the medium-display tab

Uploading the masking screenshot directly into the medium-display tab overrides its inherited screenshot set, so the earlier six cards stop appearing in that tab. Their originals remain in the source size group.

`../../../ios_store_localizations/existing_gallery_1206x2622/GradeLab_iPhone_Existing_6_English_1206x2622.zip` contains the exact six English source cards exported at **1206 × 2622**, in the order visible in the supplied screenshot. The complete source artwork is scaled proportionally, with only six background rows added at the top and bottom. The cards are RGB PNGs with no alpha channel.

With English (U.S.) selected, extract that ZIP and upload its **six PNGs** into the current **iPhone with Dynamic Island (medium display)** tab alongside the masking screenshot already present. Reorder the old cards from 01 to 06, followed by the masking card. The tab should then show **7 of 10 App Screenshots**. This ZIP intentionally excludes the masking card to avoid uploading a duplicate. The app preview video is separate and is not changed by this package.

Run `build_existing_english.py` to rebuild the six exports. `manifest_existing_english_medium.json` records their original files and dimensions; `english_complete_medium_gallery.jpg` shows the resulting seven-image gallery. The preserved English originals are in `store_localizations/sv-SE/sources/ios/`; that folder holds the English source artwork used for the earlier Swedish localization.

### Remaining six languages

`../../../ios_store_localizations/existing_gallery_1206x2622/GradeLab_iPhone_Existing_6_Remaining_Languages_1206x2622.zip` contains **36 RGB PNGs at 1206 × 2622**, organized into six locale folders: `fr-FR`, `de-DE`, `it-IT`, `es-ES`, `sv-SE` and `fi-FI`. Each folder contains only the six cards to add beside the masking screenshot. Separate six-image ZIPs for each language are available in the same directory.

Choose the matching language in App Store Connect and upload the six PNGs into **iPhone with Dynamic Island (medium display)**. With that language's masking card already uploaded, the gallery should show **7 of 10 App Screenshots**. Arrange cards 01–06 first, followed by masking. If masking has not been uploaded for that language, use its seventh card from the separate masking ZIP described above.

Swedish and Finnish exports use their preserved localized cards. French, German, Italian and Spanish use their existing localized Color Warper card; their other five cards are rendered from the preserved English artwork with localized marketing text using the established layout, fonts and background restoration. In-app controls remain English. The full artwork is scaled proportionally, with six quiet background rows added at the top and bottom. All original assets remain unchanged.

Run `build_existing_languages.py` to rebuild these exports. It verifies image modes, dimensions, ZIP integrity, text bounds, and that the native artwork below each translated header stays identical before resizing. `manifest_existing_remaining_medium.json` records all sources and copy. The six `{locale}_complete_medium_gallery.jpg` contact sheets show all six cards alongside the corresponding masking card for visual review.
