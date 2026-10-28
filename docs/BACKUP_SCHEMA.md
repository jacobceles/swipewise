# What a wallet backup contains

Wallet backup is **off by default** and does nothing until you sign in and switch it on in
*Profile → Account & backup → Back up my wallet*. This document is the complete and authoritative list of what
leaves your device when you do — written here, in the public app repository, so it can be
checked against the code that produces it.

The code is [`lib/sync/wallet_snapshot.dart`](../lib/sync/wallet_snapshot.dart), and the
guarantees below are enforced by tests in
[`test/sync/wallet_snapshot_test.dart`](../test/sync/wallet_snapshot_test.dart).

## What is uploaded

Every exported table and column is allowlisted in `WalletBackupRepository.capture()`. Columns not listed here (`user_id`, `account_slug`, `sub_type`, `originated_manual`, `created_at`, `updated_at`, `linked_at`) are never exported.

| Table | What it is | Exported columns (complete list) |
|---|---|---|
| `cards` | The cards in your wallet | `id`, `source`, `provider`, `name`, `last_four`, `network`, `image_url`, `institution_id`, `institution_logo`, `account_type` |
| `card_overrides` | Your edits to those cards | `card_id`, `manual_credit_limit`, `custom_name`, `product_identification`, `identification_source`, `due_day`, `reminder_enabled`, `reminder_lead_days` |
| `card_links` | Which catalog product each card maps to | `card_id`, `card_product_id`, `source`, `confidence` |
| `settings` | Your preferences — **allowlisted, see below** | `key`, `value` (exported as a `{key: value}` map for the allowlisted keys below) |
| `muted_merchants` | Stores you silenced for arrival alerts | `merchant_id` (Google Place ID), `name` (store display name), `muted_at` (mute timestamp) |
| `rotating_activations` | Quarterly bonus activation records | *(not exported)* |

Plus two pieces of bookkeeping on the root JSON object: `schemaVersion` and `capturedAt`.

## What is never uploaded

- **Your transactions.** Spend history never leaves the device. This is the line the app is
  built around, and there is a test asserting a backup payload cannot contain a transaction.
- **Bank connections and credentials.** A bank link is bound to aggregator credentials that
  cannot follow a device; a restored phone re-links rather than pretending otherwise.
- **Full card numbers.** The app never has them — only the last four digits, which is all the
  bank ever provides.
- **GPS history or coordinates.** Nearby-store lookups happen on the device and raw GPS
  coordinates or location history are never part of a backup. Note that `muted_merchants`
  does include the Google Place ID (`merchant_id`) and store name (`name`) of stores you
  explicitly muted for arrival alerts.

> `muted_merchants` is the one table here with no user column — it is device-level, because
> the Android geofence receivers read it without a user context. It is still backed up: from
> your side it is a preference, and a new phone that starts alerting for every store you had
> silenced would look broken. Restoring **replaces** this device's mute list rather than
> merging into it.

## Settings: an allowlist, not a blocklist

Only settings that are genuinely *yours* travel (`SettingsRepository.syncableSettingsKeys`). Everything else stays on the device that
wrote it, and any setting added to the app in future is device-local until someone
deliberately adds it to the list — the failure direction is "didn't sync" rather than
"leaked".

Travels (`syncableSettingsKeys`):
- `default_screen` (default screen on launch)
- `default_advisor_view` (default Advisor tab)
- `nearby_enabled` (arrival alerts master switch)
- `nearby_radius_mi` (nearby search radius)
- `nearby_dwell_by_category` (dwell time per category)
- `nearby_place_type_ids` (enabled nearby place types)
- `card_preference_order` (preferred card tie-break order)
- `dismissed_recurring_tips` (dismissed recurring-payment tips)
- `include_debit_accounts` (include debit accounts toggle)
- `payment_reminders_enabled` (payment reminders master toggle)
- `payment_reminder_lead_days` (default reminder lead days)
- `activation_reminders_enabled` (quarterly activation reminders toggle)

An old backup may still carry `catalog_country` (the Profile "Card Country" setting, removed
for an on-screen filter in Add a Card); restore drops it because it is no longer listed.

Deliberately stays on the device:

| Setting | Why |
|---|---|
| `permissions_asked` | OS permissions are granted per device |
| `onboarding_seen` | A per-install fact |
| `backup_enabled` | A choice made on one phone. Restoring never sets it. One exception keeps phones on one account in step: a phone that has **never** set it starts with it on when the signed-in account already has a backup. Automatic backup then still won't replace a backup holding cards that phone lacks (see below) |
| `last_backup_at` | When *this* phone last uploaded; on another phone it would claim a backup that phone never made |
| `backup_fingerprint`, `backup_held_cards` | This phone's view of the stored backup, used by automatic backup |
| `last_sync_at`, `popular_banks_cache`, `catalog_data_version` | Caches and bookkeeping about one device, meaningless on another |

## When data moves

| Direction | When |
|---|---|
| Up | Only while backup is switched on, and only for a signed-in account: when you switch it on, on *Back up now*, and automatically when you leave the app if the wallet changed |
| Down, automatically | Only onto an **empty** wallet — the new-phone case |
| Down, on request | *Profile → Account & backup → Restore…*, after a confirmation that says what it replaces |

If both your phone and your backup hold cards, **nothing happens automatically**. Silently
replacing cards you can see would destroy edits you never agreed to lose, so that collision is
always yours to resolve with the two manual buttons.

The same rule holds going up. Automatic backup stops, rather than upload, when the stored backup
was written by another phone (or before this phone ever synced) **and** has cards this phone
doesn't. *Profile → Account & backup* then says how many cards and offers both directions:
*Restore…* brings them here, *Back up now* (after a confirmation) replaces the backup. Cards you
delete on the phone that made the backup are not a conflict; the backup just follows.

## Deleting a backup

Nothing here is deleted as a side effect of anything else. Two actions look like they might
delete a backup and deliberately do not:

- **Signing out** leaves your data on the phone and your backup on the server. Changing phones
  is not a request to throw your data away.
- **Turning backup off** stops further uploads. The copy already stored is kept, so you can
  still restore it later or onto a new phone — it pauses backup rather than discarding it.

**Deleting your account is what erases it**, along with everything else: *Profile → Account & backup →
Delete account*, or the [account deletion page](https://jacobcelestine.com/swipewise/delete_account.html)
if you no longer have the app.

## Where it goes

A Cloudflare Worker backed by a D1 database, keyed on your Google account id. Every request
carries two proofs: a Firebase ID token (which account) and a Firebase App Check token (a
genuine copy of the app). Neither substitutes for the other.

The service lives in a private repository — not to hide what it stores, which is this
document, but to keep user-data infrastructure separate from the public, unauthenticated
catalog API, so that a mistake in one cannot reach the other.
