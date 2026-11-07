# Localization

GradeLab uses `dummy name/Localizable.xcstrings` for app UI and `dummy name/InfoPlist.xcstrings` for the app name and privacy permissions. Japanese (`ja`), Simplified Chinese (`zh-Hans`) and Traditional Chinese (`zh-Hant`) are registered in the project. English remains the source language.

Use localized display properties for enum labels; keep `rawValue` and `id` stable because they may identify saved settings. `GradePanel.title`, blend-mode titles and text-style display names keep this separation. Wrap developer-owned String copy in `String(localized:)` when it passes through a model or generic helper. SwiftUI cannot localize a runtime String automatically. Preserve user-authored text, media filenames, preset names and imported LUT identities.

The Japanese catalog includes help, accessibility, export, purchase status and onboarding copy. Japanese plural variations use `other`. Formatting arguments may be reordered with positions such as `%2$@`; their types, widths and precision must remain compatible with the source.

## Verify

```sh
python3 Scripts/validate-localizations.py --locale ja

xcodebuild -project "dummy name.xcodeproj" -scheme GradeLab \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  SWIFT_EMIT_LOC_STRINGS=NO build-for-testing

xcodebuild -project "dummy name.xcodeproj" -scheme GradeLab \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO \
  SWIFT_EMIT_LOC_STRINGS=NO -testLanguage ja -testRegion JP \
  -only-testing:GradeLabTests/JapaneseLocalizationTests \
  -only-testing:GradeLabTests/EditorWorkspaceBudgetTests \
  -only-testing:GradeLabTests/DesktopOnlySurfaceTests test
```

`JapaneseLocalizationTests` reads compiled resources and checks indirect display copy, the Photos permission, argument reordering and Japanese plural formatting. The Python check covers all Japanese translation units and compares formatting arguments. Passing these checks does not verify every screen on a device.

Check narrow and wide iPhone/iPad layouts, large text, multiline buttons, VoiceOver, gesture coexistence and unobstructed previews on physical devices. Check the signed Apple purchase sheet with the Japanese storefront metadata: translating the app catalog does not translate product or subscription-group metadata in App Store Connect.

The Japanese store package and screenshots live outside the repository at `/Users/aftab/Desktop/GradeLab Marketing/App Store/Japanese/`. Screenshot compositions currently have Japanese marketing copy over retained English editor captures; their manifest states that explicitly. Fresh Japanese device captures remain a release check.

## Simplified Chinese

The `zh-Hans` catalog covers all 2,496 translatable app entries and all five app-name/permission entries, including editor tools, camera, help, accessibility, exports and the Pro paywall. Preserve `GradeLab`, `Pro`, standard codec/color-space names and imported LUT identities. New default track/text names are localized when created; existing saved names remain untouched. Indirect HSL/wheel sliders, curve readouts and noise-section headings explicitly resolve their display copy. `noisePreset.light` distinguishes a light denoising strength from the Light grading panel.

`GradeLab.storekit` includes `zh_CN` display names and descriptions for lifetime, weekly, monthly and yearly products. These are local StoreKit fixtures. Live product and subscription-group localizations must be entered separately in App Store Connect using the prepared metadata files.

```sh
python3 Scripts/validate-localizations.py --locale zh-Hans

xcodebuild -project "dummy name.xcodeproj" -scheme GradeLab \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO \
  SWIFT_EMIT_LOC_STRINGS=NO -testLanguage zh-Hans -testRegion CN \
  -only-testing:GradeLabTests/SimplifiedChineseLocalizationTests \
  -only-testing:GradeLabTests/EditorWorkspaceBudgetTests \
  -only-testing:GradeLabTests/AdaptiveWorkspaceLayoutTests test
```

`SimplifiedChineseLocalizationTests` checks compiled Chinese resources, reordered discount arguments, plural frame formatting, privacy prompts, full catalog coverage and all four StoreKit product fixtures. `SimplifiedChineseCaptureTests` is opt-in via the Chinese test language; it renders the actual SwiftUI workspaces and reads their Metal drawables into snapshots in the temporary `gradelab-zh-captures` directory.

The prepared store package is `/Users/aftab/Desktop/GradeLab Marketing/App Store/Simplified Chinese/`. It includes Chinese listing copy, product/group metadata, screenshot compositions, headers, global product artwork and editable rendering sources. Its manifest distinguishes Mac captures from mobile layout renders and documents the remaining physical-device and signed-purchase-sheet checks. No live store metadata was changed.

## Traditional Chinese

The `zh-Hant` catalog covers the same 2,496 app entries and five name/privacy entries, using Taiwan terminology such as 影片, 專案, 影格, 時間軸, 遮罩 and 匯出. It was prepared from the reviewed Simplified catalog with OpenCC conversion, context-sensitive terminology and manual overrides for controls, permissions, purchase wording and marketing copy. Formatting arguments and all pre-existing locales, including `zh-Hans`, are preserved. This is a shared Traditional Chinese locale rather than a separate Hong Kong/Cantonese translation.

`GradeLab.storekit` adds `zh_TW` names and descriptions for the same four products without changing IDs, prices, durations or the main configuration's default locale/storefront. The prepared test copy uses the Taiwan test storefront; fixture prices are not live Taiwan prices.

```sh
python3 Scripts/validate-localizations.py --locale zh-Hant

xcodebuild -project "dummy name.xcodeproj" -scheme GradeLab \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO \
  SWIFT_EMIT_LOC_STRINGS=NO -testLanguage zh-Hant -testRegion TW \
  -only-testing:GradeLabTests/TraditionalChineseLocalizationTests \
  -only-testing:GradeLabTests/SimplifiedChineseLocalizationTests \
  -only-testing:GradeLabTests/EditorWorkspaceBudgetTests \
  -only-testing:GradeLabTests/AdaptiveWorkspaceLayoutTests test
```

The shared capture test retains its existing `SimplifiedChineseCaptureTests` name for compatibility and now chooses its locale, sample title and output folder from the selected Chinese writing system. With `-testLanguage zh-Hant -testRegion TW`, captures go to the temporary `gradelab-zh-Hant-captures` folder. Its stabilization composition uses a frame from the same selected video and test Pro access; production access policy is unchanged.

The Traditional package is `/Users/aftab/Desktop/GradeLab Marketing/App Store/Traditional Chinese/`, with its own fresh Chinese UI captures, 40 screenshot compositions, headers, listing/purchase/group metadata, editable sources and verification manifest. Mac captures use the normal workspace; mobile images are layout renders from an isolated capture helper. Physical-device, signed-purchase-sheet and native-language proofreading checks remain before public submission. No live App Store Connect changes were made.
