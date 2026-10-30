# Setup

Building and running SwipeWise locally. The essentials are in the
[README](../README.md#get-started); this is the detail.

## Feature availability: one binary, server authorization

There are **no product flavors**. One `applicationId` (`com.appsoflife.swipewise`, with a
`.dev` suffix on debug), one APK, both tiers inside it.

The public offering is the free card picker: manually add cards, rank them and optionally
enable nearby alerts. No bank connection or account is required. Optional Google sign-in
and opt-in wallet backup are separate from bank linking.

The source also includes bank-linking and transaction features used personally by the
maintainer, internally called Pro. There is no public subscription or bank-sync enrollment.
`proEntitlementProvider` reads a cached answer and refreshes it from the account service
for signed-in users. The service independently checks authorization before proxying bank
requests; the UI is not a security boundary.

An independent integration needs your own bank-aggregator/provider access and credentials,
a compatible backend, authentication configuration and integration work. The hosted
account-service implementation and its credentials are not included in this app repo.
This is not a turnkey bank-sync self-hosting guide.

Local configuration controls service URLs and can seed the UI for development, not grant
hosted-service access:

| Keys file | Behaves as | Used for |
|---|---|---|
| `keys.free.json` | Free UI by default; optional sign-in/backup; server-entitled accounts can show personal-use features | **the published release** and normal development |
| Optional `SWIPEWISE_PRO=true` in local config | Previews Pro UI; does not authorize bank requests | UI development only |

⚠️ **Build releases from `keys.free.json`.** Forcing the Pro UI on does not provide the
service access needed to fill those screens. `tool/verify_release_apk.py` checks release
configuration and scans the APK for credentials; CI runs it on matching pushes and PRs.

## Keys

Build configuration is supplied through `--dart-define` files at the project root.
The standard release configuration contains public URLs, not provider credentials.

**`keys.free.json` is committed.** It carries three public URLs and no credential. A fresh
clone can build the app and use bundled catalog/manual ranking; live hosted features have
their own authentication/attestation requirements, including App Check for nearby search:

```json
{
  "R2_BASE_URL": "https://swipewise-api.<subdomain>.workers.dev",
  "PLACES_PROXY_URL": "https://swipewise-api.<subdomain>.workers.dev/places/nearby",
  "ACCOUNT_API_URL": "https://swipewise-account.<subdomain>.workers.dev"
}
```

**`keys.pro.json` is an optional, gitignored UI-development config.** A minimal example
adds the UI flag below. Older local copies may contain obsolete settings or keys; do not
use them as release inputs. Neither this flag nor provider keys added to the app authorize
requests through the maintainer's account service:

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
APK, and it runs on matching app/workflow pull requests.

The additional client code ships in the same binary, but aggregator credentials stay on
the server. Signing in can authenticate a user; it does not itself grant bank-sync access.

- `PLACES_PROXY_URL` — the Worker's `/places/nearby` route. The app posts a Google-shaped
  body plus a Firebase App Check token; the Worker verifies the token, adds the Places key it
  holds as a secret, and forwards.

  ⚠️ **App Check is enforced, and how you test it differs per build type.** A locally-signed
  release is not equivalent to a Play-recognized, Play-signed release. Firebase supports
  distribution through both Play and external channels; see [GitHub releases](github-releases.md)
  for the settings and validation gates. Google's injected Play licensing is a separate control.

  | Build | Provider | To make it attest |
  |---|---|---|
  | debug (`.dev`) | debug provider | Register one token at Firebase Console → App Check → **Manage debug tokens**, put it in the git-ignored `keys.debug.json` (`{"APP_CHECK_DEBUG_TOKEN": "<uuid>"}`) and build with `--dart-define-from-file=keys.free.json --dart-define-from-file=keys.debug.json`. Without the file the build mints a random per-install secret (logged once: `Enter this debug secret (…)`) |
  | release, locally signed | Play Integrity | Not a supported attestation path for our production app; use a Play-recognized artifact |
  | release, Play-signed and sideloaded | Play Integrity | Supported by Firebase with the correct settings; fresh-install runtime testing is required, including Google's separate licensing protection |
  | release, testable | Play Integrity | Upload via Play **Internal App Sharing** (an install link, Play-signed, no release needed) or the internal-testing track |

  ⛔ **Never add a flag that lets a release build use the debug provider.** It would hand anyone a
  way to bypass the control that replaced the forgeable `X-Android-Package` header check.

  ⚠️ **Without `keys.debug.json`, a registered debug token dies with the install.** The secret is
  then a random UUID v4 minted by `DebugAppCheckProvider` into app-private storage — not derived
  from the device — so an uninstall or a clear-data mints a new one and the old console entry is
  orphaned (`403 App attestation failed` with a token "already registered"). The fixed token in
  `keys.debug.json` (read only in debug builds, `AppCheckService`) survives both; one console
  entry covers every dev install and emulator.

  ⛔ **Treat a registered debug token as a project credential.** Never commit one, never paste one
  into an issue or a log excerpt, and remove it from the console the moment you are done with it.
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

Places is not in this category at all — its key is never in the app; the Worker holds it and
requires a Play Integrity attestation instead.

> Measured reach per key, the Firebase auth posture, and what to re-test when Pro auth changes
> sign-up are recorded in the **private backend repo**, not here.

### ⚠️ Two Firebase traps that cost real time

**Deleting an API key silently repoints the Firebase app.** Each Firebase Android app stores an
`apiKeyId` naming one GCP key, and that is what lands in `google-services.json` as `api_key[0]`.
Delete the key an app points at and Firebase repoints it to *any* Android-restricted key matching
the package — it once grabbed the **Places-only** key, which blocks every Firebase call. Restoring
the deleted key does not undo it — the app has to be repointed explicitly through the Firebase
Management API, and for **both** the prod and the `.dev` app. So: **restrict keys, never delete
them.** The repair commands, with the project and app identifiers filled in, live in the private
backend repo alongside the rest of the key inventory.

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
a live 410 before anyone looked. Refresh it by copying the backend engine's built
`output/catalog/free.json` over `assets/catalog/free.json`, and commit it.

## Run & build

```bash
# debug — normal app configuration plus your authorized App Check debug token
flutter run --dart-define-from-file=keys.free.json --dart-define-from-file=keys.debug.json

# release — APK for the gate, AAB for Play. Same source, same defines.
flutter clean
flutter build apk --release --dart-define-from-file=keys.free.json
python3 tool/verify_release_apk.py     # gate: fails if the keys file carries credentials
flutter build appbundle --release --dart-define-from-file=keys.free.json
```

The gate only reads the APK (`build/app/outputs/flutter-apk/app-release.apk`), so build both —
the AAB carries the same compiled Dart and native code, so a clean APK gate covers it.
⚠️ **A versionCode can only be uploaded once.** Play consumes it the moment a bundle reaches any
track, including internal testing, so a re-upload always needs `version:` in `pubspec.yaml` bumped.

⚠️⚠️ **A release APK that builds, passes the credential gate and installs can still crash on
launch — always launch one before believing it.** The release build runs **R8** (minify +
obfuscate; Play flags DEX obfuscation under 25%). When AGP 9 first switched R8 on by default, with
no keep rules, it stripped the Room-generated constructor WorkManager instantiates reflectively,
and every release build died before reaching Flutter:

```
java.lang.RuntimeException: Unable to get provider androidx.startup.InitializationProvider
Caused by: java.lang.NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
    at androidx.work.WorkManagerInitializer.b(r8-map-id-…)
```

[`proguard-rules.pro`](../android/app/proguard-rules.pro) now keeps everything loaded by name: Room
databases' no-arg constructors, WorkManager workers (`ReregisterWorker` is stored by class name),
and `flutter_local_notifications`' Gson-persisted models (scheduled payment reminders are rebuilt
from JSON after a reboot; the plugin ships no rules). Resource shrinking stays **off** — that
plugin resolves notification icons by name. Nothing in the Dart toolchain sees an R8 break:
`flutter analyze`, the unit tests and `verify_release_apk.py` all pass. The obfuscated
`r8-map-id-` frames in a stack trace are the tell. **Any change to the keep rules, a new plugin, or
a new WorkManager worker needs an on-device launch of a release build** — and a check of the
background path (reboot → `ReregisterWorker` → `geofenceReregisterEntrypoint`). The R8 mapping
(`build/app/outputs/mapping/release/mapping.txt`) travels inside the AAB, so Play gets it with the
upload, and the Crashlytics Gradle plugin uploads it for release builds — no manual step.

**Known, harmless Play validator warning — missing `FOREGROUND_SERVICE_LOCATION`.** It is about a
service the `geolocator` plugin declares in its own manifest
(`com.baseflow.geolocator.GeolocatorLocationService`, `foregroundServiceType="location"`), which
manifest merging copies into ours. The plugin only *starts* it for a position stream with
`foregroundNotificationConfig`, which the app never uses; one-shot positions, permissions and the
walk-in geofences (`GeofencePlugin.kt`, `DwellCheckReceiver.kt`) never touch it. Don't silence it
by adding the permission — Play then wants a foreground-service declaration for a feature that
doesn't exist. Removing the service with `tools:node="remove"` would also clear it, but the plugin
binds/unbinds that service in **every** Flutter engine, including the geofence re-registration
worker, so that change needs an on-device check of walk-in notifications after a reboot.

**After a plugin major upgrade, `flutter clean` first.** `GeneratedPluginRegistrant.java` keeps the
old plugin class names until regenerated, and the build fails with `cannot find symbol` there
(seen on the 2026-10-16 Firebase 5 upgrade, whose Android side moved to Kotlin).

⚠️ **`flutter clean` before any release build you intend to measure.** The release AOT
snapshot has been observed going stale — source edits silently absent from the APK while the
debug build picked the same edits up fine. Symptoms look like a logic bug, so it costs real
time to diagnose. If you are verifying something about a release APK (that a string is gone,
that a screen changed), grep the built APK for a canary rather than trusting behaviour, and
confirm the installed bytes with `md5 -q <apk>` against
`adb shell md5sum $(adb shell pm path <pkg>)` — `adb install` can also race the build's final
file write.

### Why the Dart code is not obfuscated

This is Dart's `--obfuscate`, separate from R8 above (which obfuscates the Java/Kotlin side).

`--obfuscate --split-debug-info` was here to raise the cost of recovering keys baked in next to
readable symbols, on the stated condition that "true rotation needs a server proxy, which doesn't
exist yet". **The proxy exists now** — the Places key is a Cloudflare secret, the aggregator
credentials never ship, and `verify_release_apk.py` proves it on every build. The premise expired,
so the flags went with it. Three reasons not to bring them back:

- **They were not hiding much.** `--obfuscate` renames *symbols*, not *string literals*, so type
  names in error paths and route constants survive anyway. An obfuscated 1.0.0+6 build still
  contained `CatalogLoadResult`, `EngineLayer`, `RewardCategory`, all four `Sophtron*Exception`
  types and `sophtron_protocol_drift`.
- **This repo is public**, and the source — with comments, tests and docs — is strictly more
  informative than any recovered symbol. There is no attacker for whom the binary is the easier
  path.
- **Binary tampering is already a designed-for non-threat.** `entitlement_provider.dart`: "A
  patched binary can force this true… Forcing this true buys a set of empty screens." The gate is
  server-side.

The cost was real: obfuscated Dart frames in Crashlytics are unreadable without the exact
`.symbols` files for that one build, matched by hand with `flutter symbolize`. Readable traces are
worth more than protection that was already zero.

⚠️ Builds made **before** this change still need their archived symbols to symbolicate —
`1.0.0+6` in particular, which went to internal testing obfuscated.

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
