import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/sync/bank_sync_engine.dart';

/// Pins the safety contract of the abandoned-link retirement gate
/// ([BankSyncEngine.shouldRetireAbandoned]) — the predicate that decides
/// whether a Member gets deleted at Sophtron AND wiped locally. A wrong `true`
/// destroys a real bank's link, so every condition (and the conservative
/// "ambiguous data => don't retire" fallbacks) is pinned here.
void main() {
  final now = DateTime.utc(2026, 1, 1, 12);
  final old = now.subtract(const Duration(hours: 3)).toIso8601String();
  final young = now.subtract(const Duration(minutes: 30)).toIso8601String();

  _breakerTests();

  test('retires an old, never-synced, account-less member', () {
    expect(
      BankSyncEngine.shouldRetireAbandoned(
        rawAccountsEmpty: true,
        neverSyncedBefore: true,
        createdAtRaw: old,
        now: now,
      ),
      isTrue,
    );
  });

  test('spares a young member still inside the propagation window', () {
    expect(
      BankSyncEngine.shouldRetireAbandoned(
        rawAccountsEmpty: true,
        neverSyncedBefore: true,
        createdAtRaw: young,
        now: now,
      ),
      isFalse,
      reason: 'a fresh link may legitimately have no accounts yet',
    );
  });

  test('spares a member that returned accounts (e.g. a debit-only bank)', () {
    expect(
      BankSyncEngine.shouldRetireAbandoned(
        rawAccountsEmpty: false,
        neverSyncedBefore: true,
        createdAtRaw: old,
        now: now,
      ),
      isFalse,
      reason: 'raw accounts present => authenticated link, never abandoned',
    );
  });

  test('spares a member that has synced successfully before', () {
    expect(
      BankSyncEngine.shouldRetireAbandoned(
        rawAccountsEmpty: true,
        neverSyncedBefore: false,
        createdAtRaw: old,
        now: now,
      ),
      isFalse,
      reason:
          'a previously-working bank that is briefly empty is not abandoned',
    );
  });

  test('never retires on missing or unparseable created_at', () {
    expect(
      BankSyncEngine.shouldRetireAbandoned(
        rawAccountsEmpty: true,
        neverSyncedBefore: true,
        createdAtRaw: null,
        now: now,
      ),
      isFalse,
    );
    expect(
      BankSyncEngine.shouldRetireAbandoned(
        rawAccountsEmpty: true,
        neverSyncedBefore: true,
        createdAtRaw: 'not-a-date',
        now: now,
      ),
      isFalse,
    );
  });

  // ── refreshJobNeedsReauth ──
  // Pins the predicate that turns a refresh job payload into the "flag this
  // bank for reconnect" signal — including for jobs checked one sync AFTER
  // they were triggered (the pending-JobID path). A wrong `true` shows a
  // false Reconnect banner and trips the circuit breaker; a wrong `false`
  // leaves a dead bank silently serving stale snapshots forever.

  test('re-auth on any pending MFA challenge field', () {
    for (final mfa in <Map<String, dynamic>>[
      {'SecurityQuestion': 'mother maiden name'},
      {'TokenMethod': 'sms'},
      {'TokenSentFlag': true},
      {'TokenRead': 'x'},
      {'CaptchaImage': 'base64...'},
    ]) {
      expect(
        BankSyncEngine.refreshJobNeedsReauth(mfa),
        isTrue,
        reason: 'MFA field $mfa cannot be answered headlessly',
      );
    }
  });

  test('re-auth on a completed-but-failed job (bank rejected the login)', () {
    expect(
      BankSyncEngine.refreshJobNeedsReauth({
        'SuccessFlag': false,
        'LastStatus': 'Completed',
        'ErrorMessage': 'Invalid credentials',
      }),
      isTrue,
    );
  });

  test('no re-auth on a successful job', () {
    expect(
      BankSyncEngine.refreshJobNeedsReauth({
        'SuccessFlag': true,
        'LastStatus': 'Completed',
      }),
      isFalse,
    );
  });

  test('no re-auth on a still-running job', () {
    expect(
      BankSyncEngine.refreshJobNeedsReauth({
        'SuccessFlag': null,
        'LastStatus': 'AccountsReady',
      }),
      isFalse,
      reason: 'in-flight jobs are polled, not flagged',
    );
    expect(
      BankSyncEngine.refreshJobNeedsReauth(const {}),
      isFalse,
      reason: 'empty payload (expired/404 job) must not fake a reconnect',
    );
  });

  test('no re-auth on failed-but-not-completed (transient scrape error)', () {
    expect(
      BankSyncEngine.refreshJobNeedsReauth({
        'SuccessFlag': false,
        'LastStatus': 'Error',
      }),
      isFalse,
      reason: 'only Completed+failed means the bank rejected the login',
    );
  });
}

/// Pins the aggregator circuit-breaker gate ([BankSyncEngine.breakerIsOpen]).
/// A wrong `true` silently stops every foreground pull AND the 8-hourly
/// background tick for the whole cooldown, so the boundaries are pinned here.
void _breakerTests() {
  final now = DateTime.utc(2026, 1, 1, 12);
  final nowMs = now.millisecondsSinceEpoch;

  test('closed when the breaker has never opened', () {
    expect(BankSyncEngine.breakerIsOpen(openedUntil: null, now: now), isFalse);
  });

  test('open while the cooldown is still in the future', () {
    expect(
      BankSyncEngine.breakerIsOpen(openedUntil: nowMs + 60000, now: now),
      isTrue,
    );
  });

  test('closed once the cooldown has elapsed', () {
    expect(
      BankSyncEngine.breakerIsOpen(openedUntil: nowMs - 1, now: now),
      isFalse,
    );
  });

  test('closed exactly at expiry — recovery must not be delayed a tick', () {
    expect(BankSyncEngine.breakerIsOpen(openedUntil: nowMs, now: now), isFalse);
  });
}
