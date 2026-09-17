# In-App Purchases — German (de-DE)

A separate surface from the app listing. Each product carries its own localized
display name and description, shown in **Apple's own purchase sheet** and in the
customer's **Settings → Apple Account → Subscriptions** — not by GradeLab's code.
Leave these in English and a German customer sees an English product name on the
confirmation sheet even though the rest of the app is German.

Enter these in App Store Connect under each product → **App Store Localization**
→ add **German** (App Store Connect lists it as just "German", not "German (Germany)").

| Product ID | Display Name (30 max) | Description (45 max) |
|---|---|---|
| `com.aftab.gradelab.pro.lifetime` | Pro auf Lebenszeit | Einmal kaufen. Alle Pro-Funktionen für immer. |
| `com.aftab.gradelab.pro.weekly` | Wöchentlich | Alle Pro-Funktionen, wöchentlich abgerechnet. |
| `com.aftab.gradelab.pro.monthly` | Monatlich | Alle Pro-Funktionen, monatlich abgerechnet. |
| `com.aftab.gradelab.pro.yearly` | Jährlich | Alle Pro-Funktionen, jährlich abgerechnet. |

## Subscription group display name

The group is localized **separately** from the products inside it, and is easy to
miss. App Store Connect → Subscriptions → the `GradeLab Pro` group → **Localization**.

| English | German |
|---|---|
| GradeLab Pro | GradeLab Pro |

(A brand name, so unchanged — but the German localization still has to be added,
or the group falls back to English in the subscription-management UI.)

Under **App Name Display Options**, choose **Use App Name**, not **Use Custom
Name**. A custom name here would be a second copy of the app name that does not
follow it: if the German app name is ever changed — for example to a
`Farbkorrektur` variant after keyword research — the custom name would silently
keep saying "Color Grading". Use App Name tracks the localized app name on its
own.

## Local testing

`GradeLab.storekit` at the repo root now carries `de_DE` entries for all four
products, so running from Xcode with the German scheme language shows the German
names. That file drives local testing only; it is not read by App Store Connect.
