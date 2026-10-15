# App Store Connect: Finnish (fi-FI)

Add Finnish separately to the app listing, the Lifetime non-consumable, each subscription, and the subscription group. These fields in App Store Connect do not come from the app's string catalog or the local StoreKit test file.

| Product ID | Display name | Description |
|---|---|---|
| `com.aftab.gradelab.pro.lifetime` | Elinikäinen Pro | Kertaostos. Kaikki Pro-ominaisuudet. |
| `com.aftab.gradelab.pro.weekly` | Viikoittain | Pro-ominaisuudet, laskutus viikoittain. |
| `com.aftab.gradelab.pro.monthly` | Kuukausittain | Pro-ominaisuudet, laskutus kuukausittain. |
| `com.aftab.gradelab.pro.yearly` | Vuosittain | Pro-ominaisuudet, laskutus vuosittain. |

Subscription group **GradeLab Pro**: set the Finnish display name to `GradeLab Pro`. For the app name display option, use the localized app name (`GradeLab: Värimäärittely`).

The Lifetime purchase is a one-time purchase. Weekly, monthly and yearly are auto-renewing subscriptions. App Store Connect controls the live local prices; the prices in `GradeLab.storekit` are for Xcode testing only.
