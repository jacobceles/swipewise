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
> **free** flavor, which has no bank linking and therefore no transactions, no spending breakdown
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

Answer for the **free** flavor — the only one that goes to Play. It is a much lighter declaration
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

## Regenerating assets

- **Icon** — flatten the adaptive foreground on white:
  `magick assets/icon_foreground.png -resize 512x512 -background white -alpha remove -flatten play_store_listing/icon_512.png`
- **Feature graphic** — generated with Gemini (attach [`../assets/logo.png`](../assets/logo.png)
  as the brand reference; 1024×500, dark background + orange card motif, no baked-in text).
  Gemini sparkle watermark removed via a feathered patch in the bottom-right corner.
- **Screenshots** — re-export the relevant frames from `../wireframe.pen` (Pencil must be
  open), then pad to ≤2:1.
