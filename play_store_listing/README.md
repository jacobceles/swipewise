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

## Data safety form (answer to MATCH the description)

Answer for the **free** tier — the only thing that goes to Play. There are no product flavors; one binary serves both tiers and Pro unlocks at runtime. It is a much lighter declaration
than the Pro build would need, because free omits bank connectivity entirely and so has **no
financial-account data to declare at all**.

- Data is processed **on device**; SwipeWise has **no backend** and collects nothing to its own servers.
- Location shared with a third party (Google Places) for nearby-store functionality, rounded to ~110 m; no location history.
- **Approximate + precise location**: collected, not shared beyond the above, not linked to an
  identity (there isn't one — no account), and used only for app functionality. Declare background
  use; the in-app prominent disclosure is `NearbyPermissionGate._showAlwaysAllowExplainer`.
- ⛔ Do **not** declare financial info / transactions / FDX. The free build cannot link a bank —
  those code paths are compiled out (Phase 1 verified zero aggregator references in the APK).
  Declaring collection the app doesn't do is its own policy problem.
- No analytics / telemetry. See [`../docs/PRIVACY.md`](../docs/PRIVACY.md).

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
> (~110 m) is sent to the Google Places API. No location history is retained: the only position
> stored at rest is a single row recording where geofences were last registered, overwritten on
> every refresh and deleted on uninstall. Location is never sent to a SwipeWise server — the
> app has no backend that receives it.

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
