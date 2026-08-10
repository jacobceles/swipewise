# SwipeWise Privacy Policy

_Last updated: 2026-08-10._

SwipeWise is a credit-card recommendation app. This document explains what
data the app handles, where it goes, and what we never store.

**Which parts apply to you.** SwipeWise on Google Play has **no account and no
bank connectivity**. Sections below marked **(Pro only)** describe bank-linking
features planned as a future in-app subscription; they are not available today.
The app ships as a single binary for both tiers, so that code is present in your
install but dormant — it holds no credentials and connects to nothing. It is
documented here in advance so this policy already covers you if you subscribe
later. Until then, none of it applies to you.

## What we collect on your device

- **Your wallet.** The cards you pick from the built-in catalog, plus anything
  optional you add about them (last four digits, credit limit, statement due
  day). Stored exclusively in a local SQLite database on your device
  (`swipewise.db`).
- **A local identifier.** A random ID generated on your device on first launch
  so the local database has something to key your wallet to. It is not an
  account, it is never sent anywhere, and it is destroyed when you uninstall.
  The free version asks for **no email, no password, and no sign-in**.
- **Card and transaction data. (Pro only)** Linked card metadata, balances and
  transactions from the third-party account provider you authorize, using the
  FDX open-finance data standard, stored exclusively in the same local
  database. (Recurring-payment detection and reward estimates are computed
  locally from this data, not collected from the provider.)
- **Authentication tokens. (Pro only)** Issued by the same third-party
  provider so the app can refresh your data. Stored locally; refresh requests
  go back to the provider, not to SwipeWise.

## What we collect for nearby-store features

- **Location.** When you open the Stores tab or move out of a
  pre-registered zone, the app reads a one-shot location fix on your
  device. Before it asks Google Places for stores near you, the
  latitude/longitude are **rounded to 3 decimal places** (~110 m) — the
  full-precision fix never leaves the device. Your location is used only
  for nearby search and the on-device geofences; SwipeWise has no server,
  so it is never sent anywhere except Google Places, and no location
  *history* is kept (see *What we never store*).
- **Foreground vs. background.** "While using the app" permission is
  enough to populate the Stores list. "Allow all the time" is required
  only if you want notifications when you arrive at a registered
  merchant — Android's geofence service runs the dwell detection inside
  the OS; SwipeWise is woken only when an arrival fires.

## What we never store

- **Location history, or any location off your device.** SwipeWise keeps
  no trail of where you've been and never transmits your location except
  the rounded Google Places nearby-search request described above. The one
  place a location is *at rest* is a single-row on-device geofence
  boundary (`boundary_geofence` in `swipewise.db`): your position —
  rounded to ~110 m — when geofences were last registered, overwritten on
  every refresh and used only to detect when you've left the area. It
  never leaves your device and is removed when you uninstall.
- **Usage telemetry.** The app does not phone home — not which cards
  you're shown, which notifications fire, nor what you tap. There is no
  analytics service.

## Where data goes

- **Google Places API.** Receives your latitude/longitude rounded to
  ~110 m, the search radius, and a place-type filter. Returns nearby merchants.
  See <https://policies.google.com/privacy> for their terms.
- **The catalog service.** The app downloads the public credit-card catalog
  (which cards exist and what they earn). This is a plain file download: the
  request carries no wallet, no location and no identifier, so it says nothing
  about you beyond that some device asked for the catalog.
- **Your account provider. (Pro only)** Receives auth refresh requests and
  returns card/transaction data. Their privacy policy applies.
- **No SwipeWise server.** SwipeWise has no backend. There is nowhere on
  the SwipeWise side for your data to leak to.

## Permissions we ask for and why

| Permission | Purpose | Required? |
|---|---|---|
| `ACCESS_FINE_LOCATION` | Find stores near you | Required for nearby-stores |
| `ACCESS_COARSE_LOCATION` | Approximate-location fallback for nearby stores | Required for nearby-stores |
| `ACCESS_BACKGROUND_LOCATION` | Geofence dwell detection while app closed | Optional (notifications won't fire without it) |
| `ACTIVITY_RECOGNITION` | Tell a real store visit from driving past, so you aren't pinged at red lights | Optional (improves notification accuracy) |
| `POST_NOTIFICATIONS` | "You're at Kohl's, use Citi Custom Cash" alerts | Optional (Android 13+) |
| `RECEIVE_BOOT_COMPLETED` | Re-arm geofences after a phone reboot | Required for the notification feature to survive reboots |
| `SCHEDULE_EXACT_ALARM` | Fire the arrival alert about a minute after you walk in, rather than whenever the OS gets round to it | Optional (alerts land late without it) |
| `FOREGROUND_SERVICE` | Keep a short-lived task alive if you background the app mid-operation | Required |
| `FOREGROUND_SERVICE_DATA_SYNC` **(Pro only)** | Finish syncing your accounts if you background the app mid-sync — shown as a visible "syncing" notification. No data leaves the device; this only keeps the on-device sync alive so the OS doesn't suspend it. **Not present in the free version** | Pro only |
| `INTERNET` | Google Places API, the card catalog, and (Pro only) your account provider | Required |

You can revoke any of these in Android Settings → Apps → SwipeWise →
Permissions at any time. The app degrades gracefully (e.g. denying
background location keeps the Stores tab working but disables arrival
notifications).

## Children

SwipeWise is not intended for children under 13.

## Contact

Questions: open an issue at <https://github.com/jacobceles/swipewise>.

---

_The published copy of this policy — the URL given to Google Play — lives at
<https://jacobcelestine.com/swipewise/privacy_policy.html>, generated from this
file. **Change both together**, or the version users are shown drifts from the
version the app actually implements._
