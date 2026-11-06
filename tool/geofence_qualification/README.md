# Geofence qualification — first checkpoint

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

## Deliberately unfinished

There is **no** run-owned AVD launcher, fixture APK or NotificationListener APK in
this checkpoint. No fresh device run, GPS→FLP→GMS chain, notification, controlled
FLP experiment, shipping artifact, background/lifecycle claim, backend access or
production attestation has been qualified. The oracle's context is caller-supplied
and `identity_verified` is always false: even a complete synthetic example returns
NOT-COVERED with `oracle_status=PASS`. W6 must never accept it as trusted provenance.

Before enabling mutation, the launcher must create one new disposable AVD from the
already-installed image and bind run ID, PID, free console/ADB ports, AVD name/path
and serial, revalidating all of them **before every** setup/injection/cleanup call.
No arbitrary `--serial` escape, owner AVD, global ADB/provider reset or ordinary
wallet is permitted. Future collectors must emit the fields they actually observe;
current bounded diagnostics alone cannot establish this correlated protocol.
Listener callbacks alone also cannot prove that arbitrarily rapid native
`notify()` calls were never coalesced; retain native poster-count evidence for
that claim instead of treating a single active notification as an oracle.
The test-only Dart entrypoint must seed inputs through repositories/cache APIs,
not verdicts, visit locks or final native registration metadata. The fixture build
must be labelled as different entrypoint/config/signature from the shipping APK.
