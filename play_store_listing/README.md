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

Answer for the app **as submitted**: free tier, no billing SDK, no bank connectivity. Google
reviews these against the binary, and the three surfaces (this form, the store listing, the
privacy policy) must agree.

⚠️ **"Collected" means transmitted off the device** — to you *or* a third party. It does not
mean "stored". Everything SwipeWise keeps in `swipewise.db` stays on the phone and is therefore
**not** collected. Only two things leave the device.

### Declare these two data types

| Data type | Collected | Shared | Purpose | Linked to identity? |
|---|---|---|---|---|
| **Precise location** (Location) | Yes | **Yes** | App functionality | **No** |
| **Crash logs** (App info and performance) | Yes | **No** | App functionality | **No** |

Plus, because Crashlytics sends them alongside a crash:

| Data type | Collected | Shared | Purpose | Linked to identity? |
|---|---|---|---|---|
| **Diagnostics** (App info and performance) | Yes | No | App functionality | No |
| **Device or other IDs** | Yes | No | App functionality | No |

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
- **Financial info** — no bank connection, no card numbers, no payments. The bank-sync code
  ships dormant in the binary, but data safety asks what the app **collects**, and without
  credentials it collects nothing. (See the note below; the old "compiled out" reasoning was
  wrong and would not survive a reviewer decompiling.)

### Security section

- **Encrypted in transit:** yes. Every request is HTTPS.
- **Users can request data deletion:** there is no account and no server-side record to delete.
  Everything lives on the device and uninstalling removes it. Say so rather than claiming a
  deletion mechanism that does not exist.

## Background location declaration — Play Console → App content → Location permissions

The schedule long pole. Review runs days-to-weeks and is commonly rejected on the first pass,
so submit it before the rest of the listing is finished. Rejections are usually about the
**video**, not the app.

### Form answers

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
