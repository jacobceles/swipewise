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
free file). It adds only the tier flag — there are no credentials left to add:

```json
{
  "R2_BASE_URL": "https://swipewise-api.<subdomain>.workers.dev",
  "PLACES_PROXY_URL": "https://swipewise-api.<subdomain>.workers.dev/places/nearby",
  "ACCOUNT_API_URL": "https://swipewise-account.<subdomain>.workers.dev",
  "SWIPEWISE_PRO": "true"
}
```

`SWIPEWISE_PRO` forces the Pro **UI** on for local work and grants nothing: entitlement is
decided by the account service, which checks it before signing any aggregator call. If your
account has an entitlement row you are Pro from `keys.free.json` anyway, which is why this
file is optional.

⛔ **Never add a Google Places key to either file.** Nearby search goes through the Worker,
which holds that key server-side. `tool/verify_release_apk.py` fails the build if
`GOOGLE_PLACES_KEY` appears in the keys file or if any unaccounted Google API key reaches the
APK, and it runs on every pull request.

Omitting the Sophtron keys from the release file is the entire point: a value that isn't in
the binary can't be extracted from it. The Pro *code* does ship — it has to, for a
subscription to unlock it — but it ships with nothing to authenticate with.

- `PLACES_PROXY_URL` — the Worker's `/places/nearby` route. The app posts a Google-shaped
  body plus a Firebase App Check token; the Worker verifies the token, adds the Places key it
  holds as a secret, and forwards.

  ⚠️ **App Check is enforced, and how you test it differs per build type.** Attestation is
  designed to fail for anything not distributed by Play, so a locally-signed APK never attests:

  | Build | Provider | To make it attest |
  |---|---|---|
  | debug (`.dev`) | debug provider | Register the per-install debug secret it prints to logcat on first run (`Enter this debug secret (…)`) at Firebase Console → App Check → **Manage debug tokens** |
  | release, sideloaded | Play Integrity | **Cannot** — Play Integrity only recognises Play-distributed builds; `getToken` returns `403 App attestation failed` |
  | release, testable | Play Integrity | Upload via Play **Internal App Sharing** (an install link, Play-signed, no release needed) or the internal-testing track |

  ⛔ **Never add a flag that lets a release build use the debug provider.** It would hand anyone a
  way to bypass the control that replaced the forgeable `X-Android-Package` header check.

  ⚠️ **A registered debug token dies with the install, and the console name lies about that.**
  The secret is a random UUID v4 minted by `DebugAppCheckProvider` into app-private storage — not
  derived from the device — so an uninstall or a clear-data mints a new one and the old console
  entry is orphaned. Verified 2026-08-13: the same app on the same Pixel produced
  `0d6389cc-…` before an uninstall and `065364f5-…` after. Naming an entry "Pixel 10 Pro" makes it
  read as device-scoped, so `403 App attestation failed` with a token "already registered" is the
  expected symptom, not a misconfiguration. **Re-register after any reinstall, and delete the
  stale entry** — an orphan is a permanent credential for nothing.

  ⚠️ It is a real credential for the project: whoever holds a registered one can mint valid App
  Check tokens from anywhere, and the Worker cannot distinguish those from Play Integrity's
  (`verifyAppCheck` checks signature, `aud`, `iss` and expiry — App Check tokens carry no provider
  claim). Never commit one; remove it when you are done.
- `R2_BASE_URL` — base URL of the **catalog API** (`swipewise-api`),
  the Cloudflare Worker the app fetches `catalog.json` and `brands.json` from (e.g.
  `https://swipewise-api.<subdomain>.workers.dev`). The Worker reads those from R2 and
  serves them ETag-gated; card-art URLs inside the catalog still point at R2's public
  domain directly. See [reward-catalog.md](reward-catalog.md#distribution) for how the
  catalog is published and served.
- `ACCOUNT_API_URL` — the account service (wallet backup, entitlement, and the aggregator
  signing proxy). Unset means the app has no backup feature and cannot link a bank; it hides
  those affordances rather than failing at them.

The aggregator credentials are **not** here and must never come back. They live as Cloudflare
secrets on the account Worker, which signs on the app's behalf. There is also no customer
salt any more: the Customer id is stored server-side in `sophtron_customers` rather than
derived from an email, so there is nothing to keep stable and nothing to leak.

### Key scoping

The Firebase API key ships in the APK and in the committed `google-services.json`. That is normal
and unavoidable for an Android app — the key identifies the project, it does not authorise
anything by itself.

**A key's *application* restriction is not a security boundary.** `X-Android-Package` and
`X-Android-Cert` are headers the caller sets, and both values are public. Treat them as a filter
against casual scraping, never as protection. **What matters is the API allowlist: scope every key
to the minimum set of APIs it actually needs**, and re-check that scope whenever a key is touched.

Places is not in this category at all — its key is never in the app, and the Worker requires a
Play Integrity attestation instead (`swipewise-backend`).

> Measured reach per key, the Firebase auth posture, and what to re-test when Pro auth changes
> sign-up are recorded in the **private backend repo**, not here.

### ⚠️ Two Firebase traps that cost real time

**Deleting an API key silently repoints the Firebase app.** Each Firebase Android app stores an
`apiKeyId` naming one GCP key, and that is what lands in `google-services.json` as `api_key[0]`.
Delete the key an app points at and Firebase repoints it to *any* Android-restricted key matching
the package — it once grabbed the **Places-only** key, which blocks every Firebase call. Restoring
the deleted key does not undo it. Fix it explicitly (Cloud Shell has `gcloud`):

```bash
gcloud services api-keys list --project=swipewise-e5584 --format="table(uid,displayName)"
TOKEN=$(gcloud auth print-access-token)
curl -X PATCH "https://firebase.googleapis.com/v1beta1/projects/swipewise-e5584/androidApps/<appId>?updateMask=apiKeyId" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"apiKeyId":"<uid>"}'
```

Run it for **both** apps: prod `1:940339008944:android:aa99113dba501e8d7ef275`, dev
`1:940339008944:android:a6410217d3bc97bd7ef275`. So: **restrict keys, never delete them.**

**Flutter holds the Firebase config in TWO files.** `firebase apps:sdkconfig` refreshes
`android/app/google-services.json` but never touches `lib/firebase_options.dart`, which hardcodes
the key in Dart. When they disagree, the native SDK initialises `[DEFAULT]` from the JSON and the
Dart call throws `[core/duplicate-app]` — a message that names the wrong problem. Change both.

### ⚠️ Before a release build: check the bundled catalog floor

`assets/catalog/free.json` is the offline floor — what a first launch uses before the R2 fetch
lands, and what *every* install falls back to if the fetch ever fails. **Check it; do not assume.**

```bash
python3 -c "import json;a=json.load(open('assets/catalog/free.json'));print(a['dataVersion'],len(a['card_products']))"
```

Only local `make publish` refreshes it (the `cp` into `$(APP_DIR)`). **CI publish does not** — it
copies the file into a throwaway checkout to publish *from* and never commits it back, so every
CI-driven publish advances R2 and silently leaves the bundle behind. It reached 223 cards against
a live 410 before anyone looked. Refresh with
`cp cardcodex/output/catalog/free.json assets/catalog/free.json` and commit it.

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

⚠️⚠️ **A release APK that builds, passes the credential gate and installs can still crash on
launch — always launch one before believing it.** AGP 9 turned **R8 minification on by default**
for the release build type. We ship no keep rules, and R8 stripped the Room-generated constructor
WorkManager instantiates reflectively, so every release build died before reaching Flutter:

```
java.lang.RuntimeException: Unable to get provider androidx.startup.InitializationProvider
Caused by: java.lang.NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
    at androidx.work.WorkManagerInitializer.b(r8-map-id-…)
```

`isMinifyEnabled = false` / `isShrinkResources = false` in
[`build.gradle.kts`](../android/app/build.gradle.kts) pins the pre-AGP-9 behaviour. Nothing in the
Dart toolchain sees this: `flutter analyze` is clean, the unit tests pass, `verify_release_apk.py`
says ALL CLEAR — it checks for credentials, not for launchability. The obfuscated `r8-map-id-`
frames in a stack trace are the tell that minification ran. Turning shrinking back on is worth
doing deliberately, with keep rules and an on-device launch test, but never as a side effect of a
toolchain upgrade.

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

**Android toolchain — AGP 9 with built-in Kotlin.** `android.builtInKotlin=true` in
`android/gradle.properties` is required, not optional: `package_info_plus` guards its KGP
application on `agpMajor < 9` alone and then configures `KotlinAndroidProjectExtension`
unconditionally, so on AGP 9 with the flag *off* nothing provides that extension and its build
fails. The AGP floor is **9.1**, not 9.0, because 9.0 caps at API 36.1 and `permission_handler`
forces `compileSdk = 37`. `android.newDsl=false` is still set — AGP 10 removes that opt-out.

Every build prints `WARNING: … plugins that apply Kotlin Gradle Plugin (KGP): firebase_app_check`.
**It is a false positive — don't chase it.** Flutter detects KGP by running a regex over the
plugin's build file (`FlutterPluginUtils.getSubprojectPluginState`), and that plugin's
`apply plugin: 'kotlin-android'` sits inside an `if (agpMajor < 9 || !builtInKotlin)` guard the
text scan cannot evaluate. A Gradle probe of the configured build confirms `kotlin-android` is
applied to no module at all, so the warning's "future versions of Flutter will fail" does not
apply to us.

⚠️ **`flutter analyze` does not check Kotlin — run `./gradlew :app:lintDebug` after any `minSdk`
change.** A high `minSdk` silently legalises `NewApi` calls, so *lowering* it turns them into
crashes on every newly-reachable device with nothing in the Dart toolchain complaining. The
36 → 24 change surfaced 13 such errors. Watch for calls that only *look* defended: a
`try/catch (Exception)` does not catch a missing method, which throws `NoSuchMethodError`.

Debug builds carry an `applicationIdSuffix` of `.dev` (in
[`build.gradle.kts`](../android/app/build.gradle.kts)), so a local build sits side by side
on-device with the Play build — separate sandbox, separate SQLite db. Both packages are
registered in `google-services.json`; Google Sign-In needs a SHA-1 registered per package or
it fails on that package alone.

`FOREGROUND_SERVICE_DATA_SYNC` is in the main manifest, and the debug-only overlay that
used to hold it is gone. It was debug-only while no release build could start a sync;
server-side entitlement grants ended that, so a granted account on a release build would
have hit a `SecurityException` mid-link on Android 14+.

## Local data

The SQLite DB is `swipewise.db` ([database.md](database.md)). To wipe local data,
**uninstall + reinstall**.

⚠️ **A schema change is NOT just an `_onCreate` edit.** The app is in internal testing — real
installs with real databases exist and they never re-run `_onCreate`. Bump `version` in
`_initDatabase`, add an `if (oldVersion < N)` block to `_onUpgrade`, **and** mirror the change
into `_onCreate` so fresh installs land in the same end state. See
[database.md § Migrations](database.md#migrations).

⚠️ **Never `ConflictAlgorithm.replace` on a parent table** such as `users`. sqflite implements it
as DELETE + INSERT, which fires `ON DELETE CASCADE` and silently wipes the wallet. Update, then
insert if the update touched nothing.

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
