# Setup

Building and running SwipeWise locally. The essentials are in the
[README](../README.md#run-it); this is the detail.

## Tiers — one binary, runtime entitlement

There are **no product flavors**. One `applicationId` (`com.appsoflife.swipewise`, with a
`.dev` suffix on debug), one APK, both tiers inside it.

Pro is sold as an in-app subscription, which means one app on Play whose features unlock at
runtime — nobody subscribes in app A and installs app B. So the Pro code is *present and
dormant* for everyone and `proEntitlementProvider` decides whether to show it. Today that
provider answers from a `--dart-define`; when the entitlement service exists it asks the
server, and only that provider's body changes.

Which tier a local build behaves as is chosen entirely by the keys file:

| Keys file | Behaves as | Used for |
|---|---|---|
| `keys.free.json` | 3 tabs, no sign-in, no bank connectivity | **the published release** |
| `keys.pro.json` | 5 tabs, sign-in, bank sync | local development |

⚠️ **The one real footgun**: building a *release* with `keys.pro.json` produces a perfectly
working APK that contains every aggregator credential. Nothing about the artifact looks
wrong. `tool/verify_release_apk.py` exists to catch exactly that, and CI runs it on every
push to main.

## Keys

Keys are baked in at build time via `--dart-define`, from two files at the project root.

**`keys.free.json` is committed.** It carries no credential — only two URLs that are already
in every published APK — so a fresh clone builds a working app with nothing to obtain:

```json
{
  "R2_BASE_URL": "https://swipewise-api.<subdomain>.workers.dev",
  "PLACES_PROXY_URL": "https://swipewise-api.<subdomain>.workers.dev/places/nearby"
}
```

**`keys.pro.json` is gitignored** (`.gitignore` covers `keys*.json`, with an exception for the
free file). It adds the aggregator credentials and the tier flag:

```json
{
  "R2_BASE_URL": "https://swipewise-api.<subdomain>.workers.dev",
  "PLACES_PROXY_URL": "https://swipewise-api.<subdomain>.workers.dev/places/nearby",
  "SOPHTRON_USER_ID": "<sophtron-user-id>",
  "SOPHTRON_ACCESS_KEY": "<sophtron-access-key>",
  "SOPHTRON_CUSTOMER_SALT": "<random-base64-string>",
  "SWIPEWISE_PRO": "true"
}
```

⛔ **Never add a Google Places key to either file.** Nearby search goes through the Worker,
which holds that key server-side. `tool/verify_release_apk.py` fails the build if
`GOOGLE_PLACES_KEY` appears in the keys file or if any unaccounted Google API key reaches the
APK, and it runs on every pull request.

Omitting the Sophtron keys from the release file is the entire point: a value that isn't in
the binary can't be extracted from it. The Pro *code* does ship — it has to, for a
subscription to unlock it — but it ships with nothing to authenticate with.

- `PLACES_PROXY_URL` — the Worker's `/places/nearby` route. The app posts a Google-shaped
  body plus a Firebase App Check token; the Worker verifies the token, adds the Places key it
  holds as a secret, and forwards. Nothing to configure locally, but note that App Check is
  **enforced**: a debug build needs its debug token registered in the Firebase console
  (App Check → Manage debug tokens) or the Stores tab will 401.
- `R2_BASE_URL` — base URL of the **catalog API** (`swipewise-api`),
  the Cloudflare Worker the app fetches `catalog.json` and `brands.json` from (e.g.
  `https://swipewise-api.<subdomain>.workers.dev`). The Worker reads those from R2 and
  serves them ETag-gated; card-art URLs inside the catalog still point at R2's public
  domain directly. See [reward-catalog.md](reward-catalog.md#distribution) for how the
  catalog is published and served.
- `SOPHTRON_USER_ID` + `SOPHTRON_ACCESS_KEY` — the HMAC API-account credentials, sent on
  every Sophtron request and shared across all installs of a build (they identify the app's
  API account, not the human). Get them from sophtron.com → Account → API Keys.
- `SOPHTRON_CUSTOMER_SALT` — mixed into the `email → Customer uniqueId` hash so the
  derivation isn't reproducible from the email alone. Generate once with `openssl rand
  -base64 32` and **keep it stable** — changing it orphans every user's existing Customer.

## Run & build

```bash
# debug — the keys file picks the tier
flutter run --dart-define-from-file=keys.pro.json     # with bank sync
flutter run --dart-define-from-file=keys.free.json    # as it ships

# release (obfuscated; split debug info to a gitignored folder for symbolication)
flutter clean
flutter build apk --release \
  --dart-define-from-file=keys.free.json \
  --obfuscate --split-debug-info=build/symbols
python3 tool/verify_release_apk.py     # gate: fails if the keys file carries credentials
```

⚠️ **`flutter clean` before any release build you intend to measure.** The release AOT
snapshot has been observed going stale — source edits silently absent from the APK while the
debug build picked the same edits up fine. Symptoms look like a logic bug, so it costs real
time to diagnose. If you are verifying something about a release APK (that a string is gone,
that a screen changed), grep the built APK for a canary rather than trusting behaviour, and
confirm the installed bytes with `md5 -q <apk>` against
`adb shell md5sum $(adb shell pm path <pkg>)` — `adb install` can also race the build's final
file write.

`--obfuscate` raises the cost of recovering the baked-in keys next to readable symbols (the
literals are still inlined — true rotation needs a server proxy, which doesn't exist yet).
`.vscode/launch.json` has one config per keys file, so F5 works once they exist.

Debug builds carry an `applicationIdSuffix` of `.dev` (in
[`build.gradle.kts`](../android/app/build.gradle.kts)), so a local build sits side by side
on-device with the Play build — separate sandbox, separate SQLite db. Both packages are
registered in `google-services.json`; Google Sign-In needs a SHA-1 registered per package or
it fails on that package alone.

`FOREGROUND_SERVICE_DATA_SYNC` is declared only in
[`src/debug/AndroidManifest.xml`](../android/app/src/debug/AndroidManifest.xml) — the
release has no subscription yet, so nothing there can start a sync, and an unusable
permission is one more thing to justify on the data-safety form. It moves to the main
manifest in the update that turns Pro on.

## Local data

The SQLite DB is `swipewise.db`, established in a single `_onCreate` pass
([database.md](database.md)). To wipe local data, **uninstall + reinstall**. A schema change
is folded into `_onCreate`, so it also needs a reinstall to take effect locally.

To remove a single bank without uninstalling, use **Disconnect** in the bank-info sheet — it
calls Sophtron `deleteMember` and wipes that bank's local rows.

## Logging

App logs are tagged `SW.<area>` (`SW.sync`, `SW.repo`, `SW.ui`, …); a release-mode PII
scrubber lives in [`logger.dart`](../lib/util/logger.dart).

```bash
adb logcat -c && adb logcat | grep SW\\.
```

## Google Places category map

The nearby feature maps Google Places `primaryType` strings → display labels via
[`google_place_type_map.dart`](../lib/nearby/google_place_type_map.dart). To add a new
type, add an entry to `kGooglePlaceTypeToLabel`. See [nearby.md](nearby.md).
