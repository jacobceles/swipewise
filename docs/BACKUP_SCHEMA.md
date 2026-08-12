# What a wallet backup contains

Wallet backup is **off by default** and does nothing until you sign in and switch it on in
*Profile → Back Up My Wallet*. This document is the complete and authoritative list of what
leaves your device when you do — written here, in the public app repository, so it can be
checked against the code that produces it.

The code is [`lib/sync/wallet_snapshot.dart`](../lib/sync/wallet_snapshot.dart), and the
guarantees below are enforced by tests in
[`test/sync/wallet_snapshot_test.dart`](../test/sync/wallet_snapshot_test.dart).

## What is uploaded

| Table | What it is | Example fields |
|---|---|---|
| `cards` | The cards in your wallet | display name, last four digits, network, issuer, card art URL |
| `card_overrides` | Your edits to those cards | nickname, manual credit limit, statement due day, per-card reminder settings |
| `card_links` | Which catalog product each card maps to | product id, how it was matched, confidence |
| `settings` | Your preferences — **allowlisted, see below** | default screen, search radius, preferred card order, reminder lead time |
| `muted_merchants` | Stores you silenced for arrival alerts | the place id and name of each muted store |

Plus two pieces of bookkeeping: a schema version, and the timestamp the backup was taken.

## What is never uploaded

- **Your transactions.** Spend history never leaves the device. This is the line the app is
  built around, and there is a test asserting a backup payload cannot contain a transaction.
- **Bank connections and credentials.** A bank link is bound to aggregator credentials that
  cannot follow a device; a restored phone re-links rather than pretending otherwise.
- **Full card numbers.** The app never has them — only the last four digits, which is all the
  bank ever provides.
- **Location, or anything derived from it.** Nearby-store lookups happen on the device and are
  never part of a backup.

> `muted_merchants` is the one table here with no user column — it is device-level, because
> the Android geofence receivers read it without a user context. It is still backed up: from
> your side it is a preference, and a new phone that starts alerting for every store you had
> silenced would look broken. Restoring **replaces** this device's mute list rather than
> merging into it.

## Settings: an allowlist, not a blocklist

Only settings that are genuinely *yours* travel. Everything else stays on the device that
wrote it, and any setting added to the app in future is device-local until someone
deliberately adds it to the list — the failure direction is "didn't sync" rather than
"leaked".

Travels: default screen, default advisor view, nearby enabled, search radius,
dwell time per category, nearby place types, preferred card order, dismissed recurring tips,
include debit accounts, payment reminders enabled, payment reminder lead days, card country.

Card country travels deliberately: it is a statement about which country's cards you hold,
not about the handset, so a new phone should inherit it rather than re-guess from the locale
it happens to boot with.

Deliberately stays on the device:

| Setting | Why |
|---|---|
| `permissions_asked` | OS permissions are granted per device |
| `onboarding_seen` | A per-install fact |
| `backup_enabled` | Restoring a backup must never silently switch backup *on* for the phone receiving it |
| `last_sync_at`, `popular_banks_cache`, `catalog_data_version` | Caches and bookkeeping about one device, meaningless on another |

## When data moves

| Direction | When |
|---|---|
| Up | Only while backup is switched on, and only for a signed-in account |
| Down, automatically | Only onto an **empty** wallet — the new-phone case |
| Down, on request | *Profile → Restore From Backup*, after a confirmation that says what it replaces |

If both your phone and your backup hold cards, **nothing happens automatically**. Silently
replacing cards you can see would destroy edits you never agreed to lose, so that collision is
always yours to resolve with the two manual buttons.

## Deleting a backup

Nothing here is deleted as a side effect of anything else. Two actions look like they might
delete a backup and deliberately do not:

- **Signing out** leaves your data on the phone and your backup on the server. Changing phones
  is not a request to throw your data away.
- **Turning backup off** stops further uploads. The copy already stored is kept, so you can
  still restore it later or onto a new phone — it pauses backup rather than discarding it.

**Deleting your account is what erases it**, along with everything else: *Profile → Delete my
account*, or the [account deletion page](https://jacobcelestine.com/swipewise/delete_account.html)
if you no longer have the app.

## Where it goes

A Cloudflare Worker backed by a D1 database, keyed on your Google account id. Every request
carries two proofs: a Firebase ID token (which account) and a Firebase App Check token (a
genuine copy of the app). Neither substitutes for the other.

The service lives in a private repository — not to hide what it stores, which is this
document, but to keep user-data infrastructure separate from the public, unauthenticated
catalog API, so that a mistake in one cannot reach the other.
