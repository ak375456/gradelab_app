# Localization

GradeLab uses `dummy name/Localizable.xcstrings` for app UI and `dummy name/InfoPlist.xcstrings` for the app name and Photos save permission. Japanese is registered as `ja` in the project. English remains the source language.

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
