# In-App Purchases — Spanish (es-ES)

A separate surface from the app listing. Each product carries its own localized
display name and description, shown in **Apple's own purchase sheet** and in the
customer's **Settings → Apple Account → Subscriptions** — not by GradeLab's code.

App Store Connect → each product → **App Store Localization** → add **Spanish**.

| Product ID | Display Name (30 max) | Description (45 max) |
|---|---|---|
| `com.aftab.gradelab.pro.lifetime` | Pro de por vida | Una sola compra. Todas las funciones Pro. |
| `com.aftab.gradelab.pro.weekly` | Semanal | Todas las funciones Pro, cada semana. |
| `com.aftab.gradelab.pro.monthly` | Mensual | Todas las funciones Pro, cada mes. |
| `com.aftab.gradelab.pro.yearly` | Anual | Todas las funciones Pro, cada año. |

Names match `ProPlan.title` in the catalog exactly, so the purchase sheet and the
paywall agree. `funciones Pro` matches the app's own `Función Pro`.

## Subscription group

Subscriptions → the `GradeLab Pro` group → **Localization** → add Spanish.

| Field | Value |
|---|---|
| Subscription Group Display Name | GradeLab Pro |
| App Name Display Options | **Use App Name** — not a custom name |
