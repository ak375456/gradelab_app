# In-App Purchases — Italian (it-IT)

A separate surface from the app listing. Each product carries its own localized
display name and description, shown in **Apple's own purchase sheet** and in the
customer's **Settings → Apple Account → Subscriptions** — not by GradeLab's code.

App Store Connect → each product → **App Store Localization** → add **Italian**.

| Product ID | Display Name (30 max) | Description (45 max) |
|---|---|---|
| `com.aftab.gradelab.pro.lifetime` | Pro a vita | Un solo acquisto. Tutte le funzioni Pro. |
| `com.aftab.gradelab.pro.weekly` | Settimanale | Tutte le funzioni Pro, ogni settimana. |
| `com.aftab.gradelab.pro.monthly` | Mensile | Tutte le funzioni Pro, ogni mese. |
| `com.aftab.gradelab.pro.yearly` | Annuale | Tutte le funzioni Pro, ogni anno. |

Names match `ProPlan.title` in the catalog exactly, so the purchase sheet and the
paywall agree. `funzioni Pro` matches the app's own `Funzione Pro`.

## Subscription group

Subscriptions → the `GradeLab Pro` group → **Localization** → add Italian.

| Field | Value |
|---|---|
| Subscription Group Display Name | GradeLab Pro |
| App Name Display Options | **Use App Name** — not a custom name |
