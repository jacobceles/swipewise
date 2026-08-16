<div align="center">

<img src="icon_512.png" width="112" alt="SwipeWise app icon">

# SwipeWise — Play Store listing

</div>

Everything to paste into Play Console. Filed 2026-08-16 for the free tier, no billing SDK.

Google checks this form, the store listing and the
[privacy policy](https://jacobcelestine.com/swipewise/privacy_policy.html) against each other.
Change one, change all three.

## Assets

| Console field | Source | Spec |
|---|---|---|
| App name | — | `SwipeWise` |
| App icon | `icon_512.png` | 512×512, opaque |
| Feature graphic | `cover.png` | 1024×500 |
| Phone screenshots | `screenshots/free/*.png` — all 5 | ≤2:1. **Never `screenshots/pro/`** |
| Short description | *Which credit card to use at every store — for maximum cashback and points.* | ≤80 |
| Full description | `full_description.txt` | ≤4000 |
| Category / tag | — | Finance / Personal finance |
| Target audience | — | **18+ only** — any younger band triggers Families policy |

⚠️ **Screenshots are tier-specific.** `shellTabs(isPro)` gives a free user three tabs; every original
wireframe frame draws four. `screenshots/free/` came from the `FREE — *` frames with the Transactions
tab disabled. Re-export from the originals and you ship a tab that doesn't exist. `screenshots/pro/`
is held for when Pro sells.

## Data safety

| Category → Type | Collected | Shared | Required? | Purpose | Linked |
|---|---|---|---|---|---|
| Location → Precise location | Yes | **Yes** | Optional | App functionality | No |
| Personal info → Name | Yes | No | Optional | App functionality | **Yes** |
| Personal info → Email address | Yes | No | Optional | App functionality | **Yes** |
| Personal info → User IDs | Yes | No | Optional | App functionality | **Yes** |
| Financial info → User payment info | Yes | No | Optional | App functionality | **Yes** |
| Financial info → Other financial info | Yes | No | Optional | App functionality | **Yes** |
| App info and performance → Crash logs | Yes | No | **Required** | **Analytics** | No |
| App info and performance → Diagnostics | Yes | No | **Required** | **Analytics** | No |
| Device or other IDs | Yes | No | **Required** | **Analytics** | No |

Everything else **No**. Nothing is **Ephemeral**.

- **Precise, not Approximate** — Google's "approximate" means ≥3 km²; 110 m is ~0.04 km².
- **Only location is Shared** — Places is a third party. Firebase and Cloudflare are service providers.
- **Crash data is Analytics**, not App functionality. Location stays App functionality.
- **Financial info is declared** because the backup carries last-four and manual credit limit
  (`docs/BACKUP_SCHEMA.md`), both reachable in the free tier via `manual_card_flow_screen.dart`.
- **Health and fitness stays No** — `ACTIVITY_RECOGNITION` never leaves the device, so it is not collected.

### Security

| Question | Answer |
|---|---|
| Allows account creation? | **Yes — OAuth only.** Not "Username and other authentication": that is the aggregator flow, unreachable as submitted |
| Log in with accounts made outside the app? | Yes |
| Encrypted in transit / at rest | Yes / Yes |
| Data deletion request? | **Yes** — https://jacobcelestine.com/swipewise/delete_account.html |
| Deletion *without* deleting the account? | No — turning backup off keeps the stored copy |

Answering "no account" makes the deletion question unreachable. Sign-out never deletes anything.

## Declarations

**Advertising ID → No.** No `AD_ID` permission, no ads SDK.

**`FOREGROUND_SERVICE_DATA_SYNC` → declare it**, as *user-initiated*: it holds a bank link the user
started while it waits on an OTP. There is no background sync in the app.

**ACTIVITY_RECOGNITION** — appears under *Health data permissions*. Answering "no health features"
elsewhere stays correct; this box is where the non-health use gets explained.

> SwipeWise notifies users when they arrive at a nearby store where one of their credit cards
> earns extra rewards. It uses activity recognition for one purpose: to tell an actual store
> visit apart from driving past one.
>
> The app subscribes to activity transitions for IN_VEHICLE, STILL and WALKING. When a
> transition fires, the app records only the most recent activity type and its timestamp. If
> the latest reading is IN_VEHICLE and less than 30 minutes old, arrival notifications are
> suppressed — this stops users being alerted at a red light beside a shop they are not
> visiting. The same signal is used to defer re-registering geofences until the user has
> stopped driving, which avoids doing location work mid-journey.
>
> SwipeWise does not provide health or fitness features. No activity history is collected,
> stored beyond the single most recent reading, aggregated, or transmitted off the device — the
> value is written to local app storage and read back by the notification logic. The permission
> is optional; declining it only makes arrival notifications less accurate.

Accurate against `ActivityState.kt` and `ActivityTransitionReceiver.kt`. **If that logic changes,
change this.**

## Background location

**What is the main purpose of your app?**

> SwipeWise tells you which of your own credit cards to use at the store you are standing in, so
> you earn the most cashback and points. You add your cards from a built-in catalog of US and
> Canadian cards — no bank connection and no card numbers. Signing in is optional and off by
> default. It compares the reward rates those cards pay at that specific store or brand and shows
> you the best one. Everything stays on your device unless you turn on backup.

**Describe one location-based feature that needs background location.**

> Arrival alerts. SwipeWise registers geofences around nearby stores where one of the user's
> cards earns extra rewards. When the user arrives and stays, Android wakes the app and it posts
> a notification naming the best card — for example "You're at Whole Foods, use your Prime Visa
> for 5%". That reminder is only useful at the moment of payment, with the phone in a pocket, so
> it has to work when the app is closed or not in use.

**Why is foreground-only access insufficient?**

> The alert exists to reach the user as they walk into a shop, when the phone is in their
> pocket. Foreground-only access would require the user to open the app and keep it on screen
> at the moment of arrival — by which point they already know where they are, and the
> recommendation has no value. There is no version of this feature that works while the app is
> in the foreground.

**How is location handled?**

> Detection runs on the device. SwipeWise registers native Android geofences for nearby stores
> and the operating system performs the dwell detection; the app is woken only when an arrival
> fires. To find which stores are nearby, a latitude/longitude rounded to three decimal places
> (~110 m) is sent to a stateless SwipeWise lookup service, which forwards it to the Google
> Places API and returns the results; that service exists so the Google API key is held on a
> server rather than inside the app, and it stores and logs nothing it receives. No location
> history is retained anywhere: the only position stored at rest is a single row on the device
> recording where geofences were last registered, overwritten on every refresh and deleted on
> uninstall.

Both short answers use Google's own phrase, *"when the app is closed or not in use"*, and match the
in-app disclosure — which is what reviewers cross-check.

### The video

Submitted showing the disclosure, the *Allow all the time* grant, and the Stores list — **not** the
alert firing. Deliberate: staging a real arrival on camera is awkward. The foreground-only answer
above carries that argument in text instead.

If review asks for the background behaviour, a passing clip needs, in order: the in-app disclosure
(`NearbyPermissionGate._showAlwaysAllowExplainer`, held long enough to read) → tapping Continue →
the system dialog with *Allow all the time* → the notification firing with the app closed. A
mock-location demo passes, so no travel is needed.

⚠️ **Internal testing is not a reviewed track**, so the declaration has nothing to attach to there.
Closed testing is the earliest track that starts the review.

## When Pro ships

| Form | Becomes |
|---|---|
| App access | "Some or all functionality is restricted" + a test account carrying the entitlement |
| Account creation | OAuth **+ Username and other authentication** |
| Data safety | Add Purchase history; much of it becomes **linked** |
| Financial features | ⚠️ **Re-open** — routes to a specialist review team, may need licensing docs up front |

Copy that becomes false: `full_description.txt`'s "No bank connection" and "no card numbers", and
the privacy policy's "the subscription is not on sale yet".

## Regenerating assets

- **Icon** — `magick assets/icon_foreground.png -resize 512x512 -background white -alpha remove -flatten play_store_listing/icon_512.png`
- **Feature graphic** — Gemini, with `../assets/logo.png` as the brand reference; 1024×500, dark
  background, no baked-in text.
- **Screenshots** — export the `FREE — *` frames from `../wireframe.pen` (Pencil MCP), then pad to
  ≤2:1 using each screen's own background.
