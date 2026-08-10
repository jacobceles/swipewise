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
  full-precision fix never leaves the device. The rounded coordinate is sent to
  the SwipeWise lookup service, which forwards it to Google Places and returns
  the results — it holds the Google API key so the app does not have to, and it
  neither stores nor logs the coordinate. Your location is used only for nearby
  search and the on-device geofences, and no location *history* is kept (see
  *What we never store*).
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
- **Usage telemetry.** There is no analytics and no advertising. Nothing
  records which cards you are shown, which notifications fire, or what you tap.

## Crash reports

When the app fails, a crash report goes to **Firebase Crashlytics** so the failure
can be fixed. This is the only thing SwipeWise sends off your device that is not
a direct response to something you asked for, so it is worth being precise about
what it contains.

- **What is sent:** the stack trace, your device model, OS and app version, and
  a small set of diagnostic values — for example whether a location fix was
  fresh or stale, how many geofences were registered, and whether Google Play
  services were available.
- **What is not sent:** your wallet, your cards, your transactions, your
  coordinates, your email, or any account identifier. No latitude or longitude
  is ever attached to a report. (Two of the diagnostic values are *distances* —
  how far the device had moved, in kilometres — never positions.)
- **Identity:** reports carry the pseudonymous Firebase installation id that
  Crashlytics assigns. It is not your local SwipeWise id and is not linked to
  any account, because there is no account.

Google's handling is covered by <https://firebase.google.com/support/privacy>.

## Where data goes

- **The SwipeWise lookup service.** A Cloudflare Worker that receives your
  rounded coordinate, the search radius and a place-type filter, and forwards
  them to Google Places. It exists so the Google API key lives on a server
  instead of inside the app. It keeps no record of the request: nothing is
  written to storage, the response is marked `no-store`, and no request body is
  logged.
- **Google Places API.** Receives that same rounded coordinate via the service
  above, and returns nearby merchants. See <https://policies.google.com/privacy>
  for their terms.
- **Firebase Crashlytics.** Receives crash reports as described above.
- **The catalog service.** The app downloads the public credit-card catalog
  (which cards exist and what they earn). This is a plain file download: the
  request carries no wallet, no location and no identifier, so it says nothing
  about you beyond that some device asked for the catalog.
- **Your account provider. (Pro only)** Receives auth refresh requests and
  returns card/transaction data. Their privacy policy applies.
- **No SwipeWise account database.** The only SwipeWise-operated service is the
  stateless lookup/catalog Worker described above. It has no user accounts, no
  database and no storage of anything you send it, so there is nowhere on the
  SwipeWise side for your data to accumulate.

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

## Deleting your data

There is no "delete my account" button because there is no account, and no
server-side record of you to delete.

- **On your device** — your wallet, the local identifier and the single geofence
  boundary row live in `swipewise.db`. Uninstalling the app removes all of it.
  Android's *Clear storage* does the same without uninstalling.
- **Location** — nothing to delete. The lookup service stores and logs nothing,
  and no location history is kept anywhere.
- **Crash reports** — these are the only data retained on our behalf, and they
  are pseudonymous: they are keyed to a Firebase installation id that you do not
  see and that we cannot map back to a person. That means we could not identify
  your reports even if you asked us to remove them. They expire on Firebase's
  own retention schedule.

If you have a question about any of this, the contact route is below.

## Children

SwipeWise is not intended for children under 13.

## Contact

Questions: open an issue at <https://github.com/jacobceles/swipewise>.

---

_The published copy of this policy — the URL given to Google Play — lives at
<https://jacobcelestine.com/swipewise/privacy_policy.html>, generated from this
file. **Change both together**, or the version users are shown drifts from the
version the app actually implements._
