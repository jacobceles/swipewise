# Nearby stores

Google Places discovers potential purchase locations; Android geofences wake a bounded
arrival verifier. A nearby pin, elapsed timer, missing location or silent activity feed is
**not** proof of arrival. Recommendations use the same classifier and ranker as the Advisor.

## Fetch + tile cache

[`google_places_provider.dart`](../lib/nearby/google_places_provider.dart) calls
`places:searchNearby`, normally through the authenticated Places proxy. The field mask is
`id`, `displayName`, `location`, `primaryType` and `businessStatus`. Coordinates sent to the
service, including refinement centres, are rounded to three decimals (roughly 110 m).

- Requests contain at most 50 types and return at most 20 nearest results, with no next page.
  Base batches interleave the selected types. A saturated batch proves coverage only to its
  farthest result; a failed batch proves none for its types.
- Dense searches subdivide type batches, then use coarse offset queries to find additional
  known places, with **at most six extra requests per search**. Sparse searches incur none.
  Offset discoveries do not enlarge the original complete circle. Extra requests cost API
  quota; the budget is deliberately finite, not an exhaustive-city guarantee.
- `NearbySearchResult` separates known merchants, a conservative covered circle and partial
  failure. A partial result can provide useful fences but must remain retryable.
- [`tile_cache.dart`](../lib/nearby/tile_cache.dart) stores bounded snapshots in
  `merchant_search_cache` (DB v22): seven-day TTL, 200-cell LRU and at most eight footprints
  per approximately 1 km cell. The query identity includes selected types and radius.
- A normal cache hit requires 150 m of coverage remaining. Successful saturated searches
  can also be reused at the **same coarse centre**, without claiming adequate coverage:
  recovery still checks location, but does not repeatedly buy the identical capped query
  while stationary. Partial failures are not reused this way.
- Fresh matching snapshots in the 3×3 neighbourhood contribute known merchants, deduplicated
  and sorted by current distance. Their union is never declared one complete circle.
- Stale fallback returns nearby known merchants with **zero proven coverage**. Merchant
  distances cannot manufacture completeness. The old tile cache is disposable during the
  v21→v22 migration; wallets, mutes, picks and account settings are preserved.
- Network failures leave the shared circuit breaker alone. Upstream failures feed its
  three-failure/five-minute backoff. Authentication enforcement is not disabled for recovery.

## Place roots

[`place_roots.dart`](../lib/nearby/place_roots.dart) defines selectable groups of Google
types. The selection lives in `settings.nearby_place_type_ids` and affects both manual
search and automatic fencing. Google may return a more specific `primaryType` than the
parent type requested; downstream category mappings must retain those specific types.

Passive alerts exclude ATMs, roadside bus stops, generic `lodging`, apartment buildings
and apartment complexes. These remain available to manual search. Explicit hotel types
and train/subway/transit/bus stations remain eligible: a station is a potential ticket
purchase location, not evidence that the person intends to buy tickets. Generic native
Transit/Hotels metadata without a precise type stays suppressed until registration refreshes it.
Eligibility is enforced in Dart and native parsing/resolution, including cached results.

Travel ranking uses bundled public-domain US/Canada polygons for confident interiors,
with a conservative 40 km edge-uncertainty margin. Uncertain points geocode in the
background; foreground ranking does not wait for the OS geocoder. New searches still
need location and network access.

## Category labels

[`category_label_resolver.dart`](../lib/nearby/category_label_resolver.dart) and
[`google_place_type_map.dart`](../lib/nearby/google_place_type_map.dart) provide display
labels, with name heuristics as fallback. Reward classification also uses the catalog's
place-type/category registry and brand resolver; a display label alone is not an MCC
guarantee. EV charging is distinct from gas.

## Location & permissions

[`location_service.dart`](../lib/nearby/location_service.dart) obtains an area-level
Geolocator fix (medium accuracy, ten-second timeout). Its registration-only timeout
fallback permits last-known positions up to five minutes old, otherwise retries with
high accuracy for thirty seconds. This is **not** the arrival verifier's freshness policy.

The setup flow explains and asks notifications, foreground location and background
location separately, then offers physical activity, exact alarms and battery exemption.
Location permission is requested through Geolocator rather than competing plugins.
Denied/blocked grants lead to explicit UI/Settings paths. Empty wallets neither request
location nor register recommendation fences. Background paths never show permission dialogs.

Exact-alarm permission controls scheduling precision, not correctness. Inexact alarms and
WorkManager can run late. Battery exemption does not prove timely location or AR delivery.
Activity subscriptions are reasserted on boot, app resume, permission enablement and worker
startup. A failed subscription gets one bounded five-second retry, not perpetual polling.

## Geofence registration

[`geofence_manager.dart`](../lib/nearby/geofence_manager.dart) reads location and cache,
searches if needed, ranks merchants and calls native `registerSet`.

- Merchants within 50 m share a stable place-ID-anchored cluster. Up to 50 closest clusters
  are registered. Each option retains its own position and mute flag.
- Merchant fences default to 100 m; big-box footprints add 80 m. Resolution measures to the
  estimated footprint edge rather than blindly comparing pins. The cluster uses the shortest
  configured wait; Department Stores/Wholesale use the Big-box setting.
- A boundary tripwire is clamped to 300 m–10 km. The minimum is for practical geofencing,
  **not a claim of 300 m search completeness**. Coverage is checked at the rounded boundary
  centre and against the merchant cap. Inadequate coverage explicitly leaves recovery owed.
- App/settings/sync changes, boundary exits, boot and periodic validation can register fences.
  `INITIAL_TRIGGER_ENTER` permits arrival verification when already inside a newly added fence.
- Native registration is serialized across engines and awaits OS add results. Identical
  merchant geometry keeps OS merchant fences even if only the boundary changes; metadata
  no-ops preserve arrival attempts. `GEOFENCE_NOT_AVAILABLE` forces OS registration recovery.
- Disable/empty-wallet/logout paths invalidate in-flight work and cancel arrival advice.
  Account epochs reject older searches and callbacks finishing after those transitions.

### Recovery deadlines

Pending recovery has a persisted generation, boot identity, reason and monotonic deadline.
Boundary deferral schedules the **remaining** five-minute foot cooldown; repeated requests
preserve the earliest deadline. An older registration can satisfy only its own generation.
The fallback leaves work owed while an engine runs and re-arms until success; it does not
depend on an AR transition. WorkManager `KEEP` coalesces workers instead of accumulating or
interrupting Flutter engines. Late execution remains an OS limitation.

Degraded dense coverage uses rate-limited one-shot recovery checks at that cadence.
At the same coarse point it reuses a successful capped search; at a new uncovered point
it searches and fences the destination. This is not a continuous GPS stream or FGS, but
does have background/battery cost. Short unmapped visits can still be missed between checks.
Partial empty results retain old fences and schedule recovery; complete empty results can
register an empty merchant set **with a current boundary**, avoiding a stranded tripwire.

## Dwell detection

[`DwellAlarms.kt`](../android/app/src/main/kotlin/com/appsoflife/swipewise/DwellAlarms.kt)
and `DwellCheckReceiver.kt` implement bounded ENTER→verification episodes:

1. ENTER arms the configured dwell (60 s by default). A repeated ENTER preserves the
   token/deadline, including while a location request is in flight. A fresh ENTER location
   may seed a baseline observation.
2. EXIT cancels the pending episode immediately. Tokens, phase, account epoch, metadata
   revision, boot count and in-flight process ownership guard late callbacks and retries.
   Replayed initial intents cannot trigger a recheck early. An overdue episode is discarded.
3. A location request has an eight-second budget and explicit maximum cached age of 15 s.
   Monotonic freshness, valid coordinates/accuracy and actual merchant candidates are checked
   independently. The recheck uses higher accuracy, not weaker acceptance rules.
   Overlapping requests with identical bounds share one in-flight SDK request; cancelling
   one consumer cannot cancel another, and the shared fix never counts as two timed samples.
4. [`ArrivalPolicy.kt`](../android/app/src/main/kotlin/com/appsoflife/swipewise/ArrivalPolicy.kt)
   applies the same policy on both attempts: accuracy must be at most 50 m, and motion or
   uncertainty cannot become notification permission merely by waiting. There is at most one
   existing delayed recheck. Null, timeout, exception, missing geometry, stale/coarse final fix
   or empty resolution fails closed without creating visit/cooldown state.
5. Stop evidence is recent STILL corroboration without contradictory speed/displacement,
   or independent stable observations. The latter require 10–150 s separation, each accuracy
   at most 25 m, combined uncertainty at most 40 m, displacement at most 20 m, implied speed
   at most 0.4 m/s and `(displacement + both accuracies)/seconds <= 0.6 m/s`. Reported speed
   above 0.5 m/s cannot establish stationarity. These are conservative heuristics, not exact
   physical bounds. Long custom waits can lack a usable baseline and be skipped without AR.
6. Resolution considers all registered eligible merchants, preserving muted candidates so a
   muted shop cannot be replaced by an unmuted neighbour. The nearest non-plaza footprint
   must be within 60 m plus accuracy. Options within 35 m of the nearest are ambiguous,
   capped at four and folded when card advice matches. A brand's main store can name its
   matching folded counters. Remembered picks reorder ambiguity, not proof of presence.

Temporary baseline records are removed on completion/invalidation and pruned on lifecycle
access after expiry; removed/replaced metadata purges associated attempts. Only current
inferred visit state is retained, not a production chronological visit log.

### Visit identity and suppression

One verified stay should produce one alert. Only a verified same-store observation extends
its identity; uncertain suppressions cannot slide/reassign it. Time alone does not turn a
continuing known stay into a new arrival. A fresh fix well outside 250 m plus accuracy
confirms departure; raw fence EXIT may just be drift.

A different-advice store needs two independently timed samples, not two overlapping
callbacks returning one cached fix. Candidate checks do not move the original anchor or
extend its stay. An automatic confirmation cannot create an endless chain of further
confirmations. An unidentified legacy visit has a fixed five-minute correction window:
a timely sharp observation can adopt identities without another alert; a morning guess
cannot retain a sliding two-hour lock over lunch. Migration clears old frequency-based
resident bans while preserving explicit mutes and remembered picks. Frequent legitimate
visits are **not** evidence of residency.

## Recommendation

Payloads use the same brand/category/catch-all ranker as the Advisor: brand-specific advice
wins when matched, otherwise category advice, otherwise catch-all. Foreign-location ranking
includes FX-fee effects. Points and miles display `x points`/`x miles`, not cash-back `%`.
Geography/place type does not guarantee how the merchant ultimately codes a transaction.

## Notifications

There is a six-hour per-merchant cooldown; boundary exits do **not** clear all cooldowns.
The retired per-category cooldown table is unwritten. Visit identity handles overlapping
fences and continuing stays.

`NotificationHelper` submits one current arrival notification. New advice replaces earlier
arrival advice without touching bank-link progress/payment reminders. Its lifetime is
**30 minutes from the verification sample**, shortened by confirmed departure or disable.
Expired work cannot acquire a new lifetime through a retry. The advice remains available
manually in the app if an alert expires before a long checkout.

The channel stays HIGH, but watch forwarding, DND, sound/vibration settings and the OS
assistant control presentation. The app does not create a replacement channel to bypass
those choices. `posted` means **submitted to Android**, not heard, seen or delivered at
that exact time. Single-store wording says "near", not a guarantee of entering a building.
Taps carry the options JSON into the ranking/disambiguation sheet.

## Muted stores

The Nearby row bell and Profile's alert/mute controls write the device-level
`muted_merchants` table. Muted places remain in search, fence options and resolution;
if the nearest resolved option is muted, the alert is suppressed rather than naming a
neighbour. Remaining muted alternatives are removed before presentation. Mute changes
trigger registration refresh. Picks live separately in `store_picks` (newest 500 retained).

## Diagnostics and verification

`SW.walkin` logs decisions, exact/inexact scheduling, request failure kind/status,
fix/activity ages, attempts and notification channel/submission state. Activity events
use event monotonic time and ignore old/future-invalid batches; a saved old STILL is not
an all-clear. Silence alone does not prove a transition subscription failed.

**Debug only:** `files/walkin.log`, capped at 512 KB and trimmed to its newest half.
Extract with `adb exec-out run-as com.appsoflife.swipewise.dev cat files/walkin.log`.
Store builds never persist this history and remove legacy copies; release logcat is not
a reliable retrospective archive. Never commit phone dumps or tokens as fixtures.

Run `./.claude/quality-check.sh`, native `./gradlew :app:testDebugUnitTest` from `android`,
and the clean release/credential gates. CI runs Flutter, native/Robolectric and Python
tool tests. Sequence tests cover rejected arrivals, callback invalidation, next-door
confirmation, legacy suppression, dense discovery, cache migration and recovery races.
They do not establish real-device AR delivery, battery cost or audibility.

## Notes

- Horizontal accuracy cannot identify building floor or purchase intent. A stopped subway
  passenger can resemble a customer. Strict verification intentionally misses some indoor
  visits; it cannot promise zero false positives or instant advice for every short stop.
- The exact cause of the October activity silence and the historical production office
  notification's generation/presentation time remain unresolved. Neither blocks these fixes.
- App Check is activated in foreground and headless isolates. The SDK owns token storage/
  refresh; the app shares only an in-flight request and warms it without blocking startup.
  There is no additional app token cache or fallback to an embedded production Places key.
- Keep catalog-enforcement rollout separate: old clients must send tokens before catalog
  enforcement changes. That sequencing belongs to the backend, not this arrival batch.
