<div align="center">

<img src="icon_512.png" width="112" alt="SwipeWise app icon">

# SwipeWise — Play Store listing assets

*Which credit card to use at every store — for maximum cashback and points.*

</div>

Everything for the Google Play store listing, in one place. Reusable for future updates.
Each asset below maps to a field in Play Console → *Grow → Store presence → Main store
listing* (screenshots go on the *Internal testing* release).

## Feature graphic — `cover.png` · 1024×500

<img src="cover.png" width="640" alt="SwipeWise feature graphic">

## App icon — `icon_512.png` · 512×512

<img src="icon_512.png" width="120" alt="SwipeWise app icon">

## Screenshots — `screenshots/` · all ≤2:1

> ⛔ **Three of these advertise features the shipping app does not have.** The Play build is the
> **free** tier, which has no bank linking and therefore no transactions, no spending breakdown
> and no subscription detection. Uploading `3-transactions`, `4-breakdown` or `6-subscriptions`
> would be a misleading store listing — a policy violation, and a guaranteed 1-star review from
> anyone who installs expecting them.
>
> **Upload only 1, 2 and 5.** Play requires a minimum of 2, so that is already sufficient. Better:
> replace the three with free-tier screens — the issuer picker (`Add a Card`), the card-detail
> rewards view, and an arrival notification. `full_description.txt` has already been rewritten to
> match the free feature set.

Named in suggested carousel order (drag to reorder in Play Console).

<table>
  <tr>
    <td><img src="screenshots/1-best-card-stores.png" width="150" alt="Best card at stores"></td>
    <td><img src="screenshots/2-advisor-categories.png" width="150" alt="Per-category card ranking"></td>
    <td><img src="screenshots/5-cards.png" width="150" alt="Cards"></td>
    <td><img src="screenshots/3-transactions.png" width="150" alt="Transactions — PRO ONLY"></td>
    <td><img src="screenshots/4-breakdown.png" width="150" alt="Spending breakdown — PRO ONLY"></td>
    <td><img src="screenshots/6-subscriptions.png" width="150" alt="Subscriptions — PRO ONLY"></td>
  </tr>
  <tr align="center">
    <td>Best card at every store</td>
    <td>Ranked per category</td>
    <td>Your whole wallet</td>
    <td>⛔ Pro only</td>
    <td>⛔ Pro only</td>
    <td>⛔ Pro only</td>
  </tr>
</table>

Exported from [`../wireframe.pen`](../wireframe.pen) via the Pencil MCP, then padded to ≤2:1
(Play's max ratio) using each screen's own dark background.

## Upload map

| Play Console field | File | Spec / status |
|---|---|---|
| App icon | `icon_512.png` | 512×512, 32-bit PNG, opaque ✅ |
| Feature graphic | `cover.png` | 1024×500, watermark removed ✅ |
| Phone screenshots | `screenshots/{1,2,5}-*.png` | ⚠️ **Only these three** — 3/4/6 are Pro-only features the free build doesn't ship. ≤2:1, 320–3840 px/side ✅ |
| Short description | `short_description.txt` | ≤80 chars ✅ |
| Full description | `full_description.txt` | ≤4000 chars ✅ |
| App name | — | `SwipeWise` |

## Short description

Paste from [`short_description.txt`](short_description.txt):

> Which credit card to use at every store — for maximum cashback and points.

## Full description

Paste from [`full_description.txt`](full_description.txt) — single source of truth, edit that
file (not this one).

## Data safety form — answer sheet

> ⚠️ **REVIEW BEFORE THE NEXT SUBMISSION — 2026-08-12.** This sheet was written when the app
> had no accounts and sent nothing off the device. Both are now false: sign-in is available
> (optional) and wallet backup is available (opt-in). Answers marked **CHANGED** below were
> filed under the old premise and are wrong in the Play Console today. The authoritative list
> of what backup uploads is [`docs/BACKUP_SCHEMA.md`](../docs/BACKUP_SCHEMA.md) — answer from
> it rather than re-deriving, and keep the two in step.

Answer for the app **as submitted**: free tier, no billing SDK. Google reviews these against
the binary, and the three surfaces (this form, the store listing, the privacy policy) must
agree.

⚠️ **"Collected" means transmitted off the device** — to you *or* a third party. It does not
mean "stored". Everything SwipeWise keeps in `swipewise.db` stays on the phone unless the user
turns backup on.

**CHANGED — what now leaves the device:** the two originals below, plus, *for a user who signs
in*, their email and user id; plus, *for a user who also enables backup*, their cards, card
nicknames/edits, catalog links, preferences and muted stores. Transactions still never leave —
that claim is intact and there is a test enforcing it.

### Declare these two data types

| Data type | Collected | Shared | Ephemeral | Required? | Purpose | Linked? |
|---|---|---|---|---|---|---|
| **Precise location** | Yes | **Yes** | No | **Optional** | App functionality | No |
| **Crash logs** | Yes | No | No | **Required** | **Analytics** | No |

Plus, because Crashlytics sends them alongside a crash:

| Data type | Collected | Shared | Ephemeral | Required? | Purpose | Linked? |
|---|---|---|---|---|---|---|
| **Diagnostics** | Yes | No | No | **Required** | **Analytics** | No |
| **Device or other IDs** | Yes | No | No | **Required** | **Analytics** | No |

### Two more that are easy to get wrong

**5. Crash data is *Analytics*, not *App functionality*.** It reads like infrastructure, but
Google's own definition of Analytics says "to monitor app health, to **diagnose and fix bugs or
crashes**". That is crash reporting described exactly. Location stays App functionality — there
the data *is* the feature.

**6. Crash data is *required*; location is *optional*.** Location has a permission the user can
decline or revoke, and the app degrades gracefully — that is the whole point of the disclosure
dialog. Crashlytics has no in-app toggle and is never disabled, so "users can choose" would be
false.

### The four answers that are easy to get wrong

**1. Location is *Precise*, not *Approximate*.** The coordinate is rounded to ~110 m before it
leaves, which sounds approximate — but Google defines *approximate* as an area of **3 km² or
more**. A 110 m radius is ~0.04 km², so it is still precise by their definition, and the app
requests `ACCESS_FINE_LOCATION`. Declaring approximate here would be a misdeclaration.

**2. Location is *Shared*; crash logs are not.** Sharing means transfer to a **third party**.
Google Places is a genuine third party answering a query, so location is shared. Firebase
Crashlytics is Google acting as **your service provider**, processing on your behalf — which
Google's own guidance treats as collection, not sharing.

**3. Nothing is *linked to identity*, and that is real, not a technicality.** There is no
account, no email, no sign-in. The local id never leaves the device. Crashlytics' installation
id is pseudonymous and tied to no user record.

**4. Do not mark location *ephemeral*.** Our Worker genuinely processes it in memory and stores
nothing — but the ephemeral option asserts that about the whole path, and Google Places'
retention is not ours to promise. Ephemeral data is hidden from the listing, so claiming it
wrongly is exactly the kind of under-disclosure that gets enforced.

### Answer "no" to everything else

Personal info · Financial info · Health and fitness · Messages · Photos and videos · Audio ·
Files and docs · Calendar · Contacts · App activity · Web browsing history · Purchases.

Two that look like they might apply and do not:

- **Health and fitness** — the app holds `ACTIVITY_RECOGNITION`, but activity is used on-device
  to tell a real store visit from a traffic stop. Nothing is transmitted, so nothing is collected.
- **Financial info** — no card numbers and no payments. Card *products* a user owns (e.g.
  "Chase Sapphire Preferred") do leave the device in a backup, which is closer to a preference
  than a financial record, but decide it deliberately rather than by omission. Bank
  connectivity remains unavailable to anyone without an entitlement, which is granted by hand.

**CHANGED — Personal info → Email address.** Collected for users who sign in. Optional, not
required. Purpose: app functionality (it is the account). Linked to identity: yes.

**CHANGED — User IDs.** Same shape: collected when signed in, optional, app functionality.

### Security section

- **Encrypted in transit:** yes. Every request is HTTPS.
- **CHANGED — Users can request data deletion:** the old answer said there is no account and
  nothing server-side to delete. Accounts and server-side rows both exist now, so that answer
  is false. Google requires an in-app route **and** a public web URL once an app supports
  account creation. **This is a blocker for the next submission, not a "later" item.**
  Uninstalling still removes everything local, but it no longer removes a backup.

## ACTIVITY_RECOGNITION declaration — Play Console

⚠️ It appears under **Health data permissions**, because Android treats physical activity as
health-adjacent. Answering *"we provide no health features"* elsewhere is still correct; this
free-text box is where the non-health use gets explained.

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

Accurate as of 2026-08-10 against `ActivityState.kt` (transition subscription, the 30-minute
`isLikelyDriving` staleness window, SharedPreferences-only storage) and
`ActivityTransitionReceiver.kt`. **If that logic changes, change this.**

Note the consequence for Data safety: because the reading never leaves the device, it is *not*
collected, so **Health and fitness stays unticked**. Those two answers are consistent, not
contradictory — one describes a permission, the other describes transmission.

## Background location declaration — Play Console → App content → Location permissions

The schedule long pole. Review runs days-to-weeks and is commonly rejected on the first pass,
so submit it before the rest of the listing is finished. Rejections are usually about the
**video**, not the app.

### The other two declarations that appear alongside it

- **Advertising ID → No.** Verified against the merged release manifest: no `AD_ID` permission,
  no ads SDK, and nothing pulls one transitively (Crashlytics does not drag in the
  measurement/ads libraries).
- **`FOREGROUND_SERVICE_DATA_SYNC` → do not declare it.** The current build does **not** request
  it; it requests `FOREGROUND_SERVICE_SHORT_SERVICE`. If Play asks, it is reading a previously
  uploaded build — the pre-split one that still had bank sync. Uploading the current build
  should clear it. Declaring it would also contradict the privacy policy, which says the
  permission is Pro-only and absent from the free version.

### Form answers — paste these (both inside the 500-character limit)

**What is the main purpose of your app?**

> SwipeWise tells you which of your own credit cards to use at the store you are standing in, so
> you earn the most cashback and points. You add your cards from a built-in catalog — there is
> no bank connection, no account and no card numbers. It compares the reward rates those cards
> pay at that specific store or brand and shows you the best one. Everything is stored on your
> device.

**Describe one location-based feature that needs background location.**

> Arrival alerts. SwipeWise registers geofences around nearby stores where one of the user's
> cards earns extra rewards. When the user arrives and stays, Android wakes the app and it posts
> a notification naming the best card — for example "You're at Whole Foods, use your Prime Visa
> for 5%". That reminder is only useful at the moment of payment, with the phone in a pocket, so
> it has to work when the app is closed or not in use.

Both deliberately use Google's own phrase — *"when the app is closed or not in use"* — and
describe the same feature as the in-app disclosure, which is what reviewers cross-check.

### Longer-form answers (if a field allows more)

**Does your app access location in the background?** Yes — `ACCESS_BACKGROUND_LOCATION`.

**Which feature requires it?**

> Arrival alerts. SwipeWise notifies the user when they arrive at a nearby store where one of
> the credit cards in their wallet earns extra rewards — for example, arriving at a grocery
> store where their card earns 5% instead of 1%. The reminder is only useful at the moment of
> payment, so it has to reach the user when the app is not open.

**Why is foreground-only access insufficient?**

> The alert exists to reach the user as they walk into a shop, when the phone is in their
> pocket. Foreground-only access would require the user to open the app and keep it on screen
> at the moment of arrival — by which point they already know where they are, and the
> recommendation has no value. There is no version of this feature that works while the app is
> in the foreground.

**How is location handled?** Useful to state, because it pre-empts the obvious follow-up:

> Detection runs on the device. SwipeWise registers native Android geofences for nearby stores
> and the operating system performs the dwell detection; the app is woken only when an arrival
> fires. To find which stores are nearby, a latitude/longitude rounded to three decimal places
> (~110 m) is sent to a stateless SwipeWise lookup service, which forwards it to the Google
> Places API and returns the results; that service exists so the Google API key is held on a
> server rather than inside the app, and it stores and logs nothing it receives. No location
> history is retained anywhere: the only position stored at rest is a single row on the device
> recording where geofences were last registered, overwritten on every refresh and deleted on
> uninstall.

### The demo video — where first passes are lost

Host it unlisted on YouTube and paste the link. It must show, in this order and unambiguously:

1. **The prominent disclosure, before any system dialog.** This is
   `NearbyPermissionGate._showAlwaysAllowExplainer` — the dialog titled *"Allow location all the
   time?"*. Hold on it long enough to read. Its text contains Google's required phrasing,
   verbatim: *"even when the app is closed or not in use"*.
2. **The user tapping Continue** — affirmative consent, not a dismissal.
3. **The Android system permission dialog**, and *Allow all the time* being chosen.
4. **The feature actually working**: leave the app, and show the arrival notification firing
   with the recommended card. A screen recording that walks into a registered store, or a
   mock-location demo, both pass — what fails is a video that shows only the settings screen.

Three things that get first passes rejected, none of which are about the code:

- The video shows the system dialog but never the in-app disclosure. The disclosure is the
  thing being reviewed; the system dialog is Android's, not yours.
- The video never demonstrates the background behaviour, so the reviewer cannot see why
  foreground access would not do.
- The declared purpose does not match the store listing or the data safety form. Keep all three
  saying the same thing: arrival alerts for card rewards, nothing about advertising or
  analytics, because the app does neither.

## Regenerating assets

- **Icon** — flatten the adaptive foreground on white:
  `magick assets/icon_foreground.png -resize 512x512 -background white -alpha remove -flatten play_store_listing/icon_512.png`
- **Feature graphic** — generated with Gemini (attach [`../assets/logo.png`](../assets/logo.png)
  as the brand reference; 1024×500, dark background + orange card motif, no baked-in text).
  Gemini sparkle watermark removed via a feathered patch in the bottom-right corner.
- **Screenshots** — re-export the relevant frames from `../wireframe.pen` (Pencil must be
  open), then pad to ≤2:1.
