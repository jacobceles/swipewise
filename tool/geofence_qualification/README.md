# Geofence qualification — oracle and capability probe

## New executable OS smoke (debug fixture, not shipping qualification)

```sh
flutter pub get --offline
python3 -B tool/geofence_qualification/os_smoke.py --output /new/os-smoke.json
```

`/new` must exist; the output must not. There is no serial, old-AVD, saved-owner
or injected-receiver option. This command builds and installs a **different
entrypoint/config/test certificate** from the shipping app, on one newly owned
disposable AVD. It reads normal current defaults (10 s), seeds two synthetic
cash-back products and one operational restaurant through repository/cache APIs,
and delegates all manager registration, receiver, alarm, verifier and poster work
to the real app. It never initializes Firebase or App Check; the opt-in fixture
manifest removes FirebaseInitProvider and disables collection. No real account,
bank, Places request, wallet, signing material or debug-provider token is used.

The finite pair is **muted restaurant → precise no-post**, then public
disable/unmute/enable → **precise post**. Both require actual GMS task completion,
a new receiver ENTER/attempt, default balanced FLP verification, a precise
decision, a terminal native outcome, cleared attempt, continuous notification
listener with empty baseline before seed, and a complete 183 s observation after
arm (140 s attempt life + 30 s grace + 8 s acquisition + 5 s margin). The positive
requires exactly one real native poster call and one Android callback with exact
content; intermediate VERIFIED/POSTED alone is insufficient. The negative must
actually reach terminal MUTED, with zero poster calls and zero listener callbacks.

Inputs are explicitly **static console GPS stimuli**, not walking, AR sensor,
physical-arrival-latency or background-lifecycle qualification. Initial GPS and FLP
samples are observed separately, and their transient requests stop. If real GMS
does not ENTER during the initial 120 s centre stimulus, private location/GMS/
broadcast/alarm state is captured, then one explicitly recorded **foreground
companion HIGH_ACCURACY location demand** is tested for another bounded 120 s.
It is still real console GPS/GMS, not mock FLP; any passing result records that
environmental assistance. It must not be described as unassisted background
geofence delivery. No ENTER remains blocked, never silently injected or passed.

### CI executable contract

- Entrypoint/args: the two commands above; Python 3.10+, JDK 17+, Flutter SDK from
  this project's constraints, `adb` on PATH, `ANDROID_HOME`, `keytool`, `lsof`,
  cached pinned Gradle distribution and Maven/pub dependencies. Builds are offline
  and pass `android.builder.sdkDownload=false`; provision dependencies beforehand.
- Supported host/image allowlist: local macOS/arm64 uses the **already-installed**
  `system-images;android-36.1;google_apis;arm64-v8a`; Ubuntu 24.04/x86_64/KVM selects
  `system-images;android-36.1;google_apis;x86_64`. Linux support is not evidence of a
  Linux execution. CI provisioning can install its SDK; never install on the owner
  Mac. Require compile SDK 37.0, build-tools 36.0.0 and Flutter's pinned NDK.
- Set `TMPDIR` to an existing private runner temp directory and create its
  `opencode/` subdirectory first. The launcher creates its own nonce/path/inode,
  PID/birth, port-pair, serial and transport binding there. Retain the executable
  `emulator_adb_guard.py` (0755). No emulator-runner action may also own this AVD.
- Budget: one AVD, two scenarios, bounded acquisition/ENTER and full post/no-post
  windows; allow 25 minutes including offline builds/boot. There are no behavioral
  retries that convert failure to pass.
- Output: sanitized `--output` JSON with candidate/dirty-source, config, seed,
  classifier, image/GMS, installed-APK readback, route and artifact/certificate
  bindings plus stage outcomes and cleanup. Private raw JSONL/logs/AVD/test keys
  stay in the run directory **outside checkout**. Upload only the summary, never
  raw emulator logs (host ADB metadata), coordinates, notification logs or keys.
- Exit codes: 0 = both narrow debug scenarios PASS; 1 = assertion failure;
  2 = prerequisite/infrastructure/cancellation/cleanup block. A skipped, absent,
  cancelled, wrong-source or incomplete summary is not qualification. This local
  runner is not a trusted publication attestation; CI provenance is a separate gate.

The older capability command and offline oracle below retain their intentionally
limited meanings. Neither substitutes for executing this main-fixture pair.

`../test_geofence_e2e.py` is now an **offline, fail-closed oracle**, not a working
device qualification suite. Its `device` command writes an infrastructure block
and makes **no device calls**. Legacy `--serial`, scenario-number and automatic
device selection are deliberately removed. There are no app wipes, provider or
AppOps changes, installation, emulator creation/cleanup, or owner-device access.

```sh
python3 -B -m unittest discover -s tool -p 'test_*.py'
python3 -B tool/geofence_qualification/check_oracle_mutations.py --output /new/mutations.json
python3 -B tool/test_geofence_e2e.py device --output /new/result.json
# Exit 2, INFRASTRUCTURE-BLOCKED; /new must already exist.
python3 -B tool/test_geofence_e2e.py evaluate \
  --context /run/context.json --trace /run/trace.json --output /new/oracle.json
# Exit 1/2 on failed/blocked evidence; exit 3 even if the offline oracle passes.
```

Output paths must not exist. Files are size-bounded; JSON duplicate keys,
nonfinite numbers and unsupported schema versions are rejected. Input errors and
cancellation produce nonzero results where the output can still be created.
Only allowlisted stage/outcome codes, relative times, safe identity fields and a
hash of the sanitized summary are retained. Raw input/command/log text is never
copied to result files or error messages. A hash of a summary is **not** the full
trace's identity or an attestation of how it was collected.
Unknown scenario text is rejected before any context is retained; only the four
finite scenario codes below can appear in a result.

## Contract for the next collector

The discoverable `test_geofence_e2e_runner.py` builds a complete synthetic example.
It is a protocol example, **not real Android evidence**. Context version 1 pins
run/start time, candidate, artifact/config/certificate/classifier/seed/route and
observer digests, test-only entrypoint/build mode, input source, and environment.
Every event repeats the run ID and canonical-context digest, has a gapless sequence
and monotonic run-relative time, and names its actual observation boundary.
Events from different sources must be merged causally; notification callbacks may
precede the receiver's terminal outcome. Do not sort a reversed trace to make it pass.
The required edges are input→GPS/FLP, seed→ranking→GMS add→ENTER/route, and
ENTER→arm→verification→decision→terminal, with the listener active before posts.
GPS/FLP callback order and their position relative to ranking are not fixed: the
manager acquires its own location. The synthetic example observes location before
ranking. Cross-stream collection timing remains to be established by the first
real capability probe, not by holding callbacks to fit an invented total order.

The only implemented oracle is a one-store `precise_walkin` smoke. It requires:

- Successful, semantically checked ADB/log/native-diagnostic readiness and a
  continuous Android notification listener with an empty starting baseline before seeding.
- Synthetic wallet/identity/settings, pinned classifiers, current complete cache,
  remote catalog disabled, and **normal ranking** choosing the dining card.
  The seed pins an operational restaurant at 39.237148, −123.176090, a 100 m fence,
  and USD cash-back cards; it supplies normal classification inputs, not eligibility
  or decision overrides.
- Console input and separately observed GPS and FLP samples at the first route
  coordinate. Nominal/commanded speed, observed nullable speed, accuracy, elapsed
  sample identity/age, provider and nullable mock flag remain distinct. Console
  accuracy is unsupported (`null`), not an invented 5 m claim.
- Actual successful GMS add completion, not saved registration metadata/count or
  the native unchanged fast path; actual platform ENTER after replay begins; persisted attempt token,
  epoch, metadata generation, boot identity, original due/expiry times.
  Tokens are nonzero signed 64-bit Kotlin Long values, including negative values.
- Default balanced-power location verification, precise policy decision **and
  terminal receiver POSTED**, correct synthetic merchant/card, exactly one Android
  listener post callback with the complete expected channel/tag/id/title/text/
  expanded text, no removal/update/duplicate or observer gap, and completed replay.
  An independent local-plane distance check requires the sample inside this
  fixture's literal 100 m circle, and a supplied speed above 2 m/s contradicts this
  narrow precise-positive smoke. Null speed remains unsupported, not zero. These
  checks do not reproduce the production accuracy/slack reach, activity, stability
  or fallback policy; those paths are not qualified here.
- A full bounded observation through the larger of route completion or 223 s
  after arm (30 s dwell: 180 s attempt life + 30 s overdue grace + 8 s acquisition
  + 5 s observer margin). This is a conservative first oracle budget, not a measured
  latency promise or a universal requirement for every future scenario.

The original `driveby`, `premature_exit` and `adjacent_nextdoor` cases are explicitly NOT-COVERED;
no event-free negative case can pass. In particular, two centres 70 m apart with
overlapping circles do not imply another ENTER. Future replay must use W3's
`parse_gpx` / `replay_route`, not a second parser/speed/timing implementation.

## Actual run-owned capability collector

```sh
python3 -B tool/geofence_qualification/probe_device.py
```

This separate, explicitly device-mutating command creates **one new disposable
AVD**, using the installed API-36.1 Google APIs ARM64 image and a free ordinary
`-port` pair starting at 5570. It accepts no serial, existing AVD, PID or saved
manifest. Every install/grant/start/injection/shutdown rechecks the in-memory
run's nonce, directory inode, QEMU PID/birth/SDK executable/arguments, both owned
ports, AVD name, serial and ADB transport. W3 replay uses its optional sender
callback to recheck ownership before each injection. SDK-internal ADB device
commands are disabled via `-adb-path` and the test-only shield; only its host
`adb version` query is forwarded. Both normal and headless QEMU executable names
are matched exactly within the installed SDK, not by an arbitrary name prefix.

The standalone observer APK builds/lints offline with cached dependencies and a
new disposable test certificate. It has no Flutter/Firebase dependency. Build
evidence includes HEAD **plus** tracked-patch and dirty working-tree hashes,
artifact/certificate/config hashes and the installed APK's read-back hash. Its
NotificationListener records actual connect/disconnect, post/update/remove
callbacks and full target-channel text, plus baseline/end snapshots. Its transient
GPS/FLP preflight requests stop before the GMS geofence observation window.

The bounded local capability execution observed fresh console-stimulated GPS and
FLP samples, observer shutdown, real GMS add completion and listener continuity.
GPS and FLP shared one elapsed sample identity; these were two delivery boundaries,
not independent fixes. The run used the same AVD across explicit harness corrections,
not an uninterrupted execution of the final committed collector.
The later static centre stimulus produced **no platform ENTER within 120 s**.
That lane is INFRASTRUCTURE-BLOCKED; its cause is unproven. Two static points are a
capability stimulus, not a walking trajectory, activity-classification test or
physical GPS claim. No controlled-FLP mock experiment has been run.

The first real run exposed and preserved a headless-executable guard rejection
and a duplicate-ADB-path guard rejection. Both were corrected; the same one AVD
was continued under explicitly checked current-run nonce/inode/process evidence,
not by enabling a general manifest-resume interface or silently retrying an app
failure. Before the shield was added, SDK-internal unscoped `adb -e` device commands
failed with "more than one emulator"; the shield now refuses them outright.
All attempts remain in private evidence. Shutdown stops only the proven
owned process and retains its AVD files for review; there is no recursive cleanup
or global ADB/provider reset. SDK emulator logs can include host ADB public-key
metadata: redact those lines before sharing, and never upload raw device logs.
Cleanup cannot be reported complete if a launcher exited but its QEMU child is
still present, or if the launched QEMU was never identified. These cases fail
closed without signalling an unproven process.

The capability collector exits 2 when a prerequisite is blocked, or 3 if its
prerequisites pass but app qualification is still NOT-COVERED. It never claims the
helper's own GMS registration is the main app's `GeofenceManager` registration.

## Historical capability-only boundary (`b6c96a7`)

At that checkpoint the launcher/observer existed, but the repository/cache fixture
and complete app ENTER→alarm→verification→notification proof were absent. Use the
new smoke's actual result, not existence of source, to assess that proof now.
No shipping artifact, background/lifecycle claim,
backend access or production attestation has been qualified. The offline oracle's context is caller-supplied
and `identity_verified` is always false: even a complete synthetic example returns
NOT-COVERED with `oracle_status=PASS`. W6 must never accept it as trusted provenance.

The launcher creates one new disposable AVD from the already-installed image and
binds run ID, PID, free console/ADB ports, AVD name/path and serial, revalidating
them **before every** setup/injection/cleanup call.
No arbitrary `--serial` escape, owner AVD, global ADB/provider reset or ordinary
wallet is permitted. Future collectors must emit the fields they actually observe;
current bounded diagnostics alone cannot establish this correlated protocol.
Listener callbacks alone also cannot prove that arbitrarily rapid native
`notify()` calls were never coalesced; retain native poster-count evidence for
that claim instead of treating a single active notification as an oracle.
The test-only Dart entrypoint must seed inputs through repositories/cache APIs,
not verdicts, visit locks or final native registration metadata. The fixture build
must be labelled as different entrypoint/config/signature from the shipping APK.
