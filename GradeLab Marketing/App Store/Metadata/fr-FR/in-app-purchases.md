# In-App Purchases — French (fr-FR)

A separate surface from the app listing. Each product carries its own localized
display name and description, shown in **Apple's own purchase sheet** and in the
customer's **Settings → Apple Account → Subscriptions** — not by GradeLab's code.
Leave these in English and a French customer sees an English product name on the
confirmation sheet even though the rest of the app is French.

App Store Connect → each product → **App Store Localization** → add **French**.

| Product ID | Display Name (30 max) | Description (45 max) |
|---|---|---|
| `com.aftab.gradelab.pro.lifetime` | Pro à vie | Un seul achat. Toutes les fonctions Pro. |
| `com.aftab.gradelab.pro.weekly` | Hebdomadaire | Toutes les fonctions Pro, chaque semaine. |
| `com.aftab.gradelab.pro.monthly` | Mensuel | Toutes les fonctions Pro, chaque mois. |
| `com.aftab.gradelab.pro.yearly` | Annuel | Toutes les fonctions Pro, chaque année. |

The names match the app exactly — `ProPlan.title` in the catalog already renders
Pro à vie / Hebdomadaire / Mensuel / Annuel, so the purchase sheet and the
paywall agree.

`fonctions` is used rather than the app's `fonctionnalités` because the longer
word breaks the 45-character limit on three of the four rows. Better that all
four read alike than that two use one word and two another.

## Subscription group

Localized separately from the products inside it, and easy to miss.
Subscriptions → the `GradeLab Pro` group → **Localization** → add French.

| Field | Value |
|---|---|
| Subscription Group Display Name | GradeLab Pro |
| App Name Display Options | **Use App Name** — not a custom name |

The group name is a brand name, so it is unchanged. Choose **Use App Name** so
it tracks the French app name automatically; a custom name is a frozen copy that
will not follow if the name is ever changed.

## Local testing

Add `fr_FR` entries to `GradeLab.storekit` to see these locally. That file drives
the Xcode scheme only; it is not read by App Store Connect.
