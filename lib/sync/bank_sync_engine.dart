import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pool/pool.dart';

import '../api/brand_resolver.dart';
import '../api/data_repository.dart';
import '../api/settings_repository.dart';
import '../api/sophtron_auth_service.dart';
import '../api/bank_client.dart';
import '../api/bank_fdx_mapper.dart';
import '../api/bank_write_repository.dart';
import '../api/types.dart';
import '../util/logger.dart';
import 'sync_progress_event.dart';

/// Sophtron's built-in test bank. Anyone who exercised the debug script
/// against `sophtron bank` will have this leftover; hide it so it doesn't
/// appear as a fake bank in the app.
const _kSandboxInstitutionId = '8d0d9991-5e35-4b82-afa4-e93695e5ca7d';

/// Concurrent fan-out cap. Sophtron forwards to issuers; issuer rate
/// limits (Citi/Discover are strict) hit hard if we burst. Four is
/// conservative — bumpable per environment if monitoring shows
/// headroom.
const int _kMemberPoolWidth = 4;
const int _kAccountPoolWidth = 4;

/// Pulls everything Sophtron exposes for the user's linked banks.
///
/// Per-member staging (audit B1): each `_syncMember` runs its own
/// network IO, accumulates results in memory, then commits to SQLite in
/// one atomic transaction via `DataRepository.rebuildInstitution`.
/// A failure in one bank rolls back only that bank — other banks keep
/// their prior data, and the user never sees the empty-account flash
/// that the global pre-fanout wipe used to cause.
///
/// Bounded fan-out (B2): both the per-member loop and the per-account
/// inner loop run through a `Pool` capped at four concurrent jobs.
///
/// Null-cached institution lookups (B6): the v1 institution-by-id
/// endpoint result is cached even when the API returns null, so a
/// transient 404 isn't re-issued for every subsequent member with the
/// same institutionId.
class BankSyncEngine {
  BankSyncEngine(this._repo);

  final DataRepository _repo;

  /// Cap on the post-createMember `getMembersV2` retry-until-stable loop.
  /// 30s comfortably covers Sophtron's typical Customer-index propagation
  /// (observed seconds, not minutes) without leaving the user staring at
  /// a spinner forever on a genuinely broken response.
  static const Duration _membersListSettleTimeout = Duration(seconds: 30);

  /// Polling interval inside the settle loop. Matches the v2 client's
  /// rate-limit budget while staying responsive enough to catch the index
  /// the moment it updates.
  static const Duration _membersListSettleInterval = Duration(seconds: 2);

  /// Refresh-on-sync (re-scrape) tunables. The throttle skips a re-scrape when
  /// the member was refreshed within this window (background/app-open only;
  /// user-initiated syncs force it). The job is polled up to [_refreshMaxWait]
  /// — long enough for a fast scrape to land in the same sync, but many live
  /// scrapes outlast it; those are picked up by the pending-job outcome check
  /// on the next sync (see [_refreshMemberIfDue]). Members poll concurrently
  /// in the fan-out pool, so the wait is not multiplied per bank.
  static const Duration _refreshThrottle = Duration(minutes: 15);
  static const Duration _refreshPollInterval = Duration(milliseconds: 1500);
  static const Duration _refreshMaxWait = Duration(seconds: 30);

  /// How long a stored pending-refresh JobID stays trusted as "still
  /// running". Past this, the job is treated as wedged or lost at Sophtron
  /// (a normal scrape completes in minutes) and a new refresh is triggered
  /// instead of polling it forever — without the cap, a job the API never
  /// finalizes would block every future re-scrape for that member.
  static const Duration _pendingRefreshJobMaxAge = Duration(minutes: 30);

  /// How old a never-successfully-synced connection must be before its
  /// account-less Sophtron Member is treated as an abandoned link and retired
  /// (deleted at Sophtron + locally). Comfortably past Sophtron's
  /// createMember→accounts propagation window (observed minutes; the same 2h
  /// margin the orphan-cleanup pass uses), so a slow-but-legitimate first sync
  /// is never mistaken for a link the user bailed on mid-MFA.
  static const Duration _abandonedMemberMinAge = Duration(hours: 2);

  /// Rolling reconcile window for connections that have already had one
  /// successful sync. The per-card rebuild deletes local rows at/newer than
  /// the oldest row a scrape returns and re-inserts the returned set, so a
  /// narrower scrape window == a narrower "delete-what's-missing" window: any
  /// transaction the bank stops returning inside it (e.g. a disputed charge
  /// that was reversed) gets pruned locally; rows older than it stay frozen as
  /// a permanent archive. 90d covers the realistic dispute-resolution horizon
  /// (FCBA: 60d from the statement to file + up to ~2 billing cycles to
  /// resolve) without re-pulling years of already-archived history each sync.
  /// The FIRST sync of a connection ignores this and pulls full history
  /// ([lastSyncedAt] is null until the first success lands at
  /// [setConnectionLastSyncedAt]).
  static const int _reconcileWindowDays = 90;

  /// Shared `api_circuit_breakers` key for the Sophtron aggregator. Same row is
  /// read by foreground and background syncs, so a trip in either path pauses
  /// both. Threshold/cooldown mirror the Google Places guard.
  static const String _sophtronService = 'sophtron';
  static const int _breakerThreshold = 3;
  static const Duration _breakerCooldown = Duration(minutes: 5);

  /// True while the aggregator breaker is open and the run must fast-fail.
  ///
  /// Extracted so the gate is testable without a DB: a wrong `true` here
  /// silently stops every sync for the cooldown, so the boundary conditions
  /// (never opened, already expired, exactly at expiry) are pinned in tests.
  static bool breakerIsOpen({
    required int? openedUntil,
    required DateTime now,
  }) => openedUntil != null && openedUntil > now.millisecondsSinceEpoch;

  Future<BankSyncResult> run({
    required String userId,

    /// Per-install Sophtron Customer uniqueId (the hashed-email value
    /// derived at onboarding via [SophtronConfig.deriveCustomerUniqueId]).
    /// Determines *which* Sophtron Customer this sync targets — each
    /// install resolves to its own, so two people sharing the APK don't
    /// share each other's bank data.
    required String bankCustomerId,

    /// True once this user has completed at least one full sync. When
    /// false, the engine treats the orphan-Member cleanup pass as unsafe
    /// (the local DB is empty by design — fresh install or post-reinstall
    /// recovery — so every Sophtron Member would look orphaned and get
    /// `deleteMember`'d). Becomes true after the first SyncCompleted
    /// event lands (the provider sets it on the users row).
    required bool firstSyncCompleted,
    // Sophtron forwards the date window to the underlying bank, which caps
    // it on its own (Chase/Citi ~24 mo, Discover/US Bank ~12 mo). Pick a
    // value well past any issuer's actual retention so we always get back
    // whatever the bank is willing to give - no client-side truncation.
    int transactionDays = 365 * 10,
    bool includeDebitAccounts = false,
    // When true (user-initiated sync), always trigger a fresh re-scrape per
    // member before reading; when false (background/app-open), throttle to
    // avoid hammering issuer rate limits.
    bool forceRefresh = false,
    void Function(SyncProgressEvent)? onProgress,

    /// MemberID just produced by `createMember`. When set, the engine
    /// waits (with backoff up to [_membersListSettleTimeout]) for this
    /// id to actually show up in `getMembersV2` before proceeding —
    /// closes the eventual-consistency window where a sync that fires
    /// immediately after `createMember` returns a partial Members list
    /// and therefore syncs fewer banks than the user expects.
    String? waitForMemberId,
  }) async {
    final client = BankClient();
    onProgress?.call(const SyncStarted());

    // Snapshot existing connections — used as fallback when v1
    // `getInstitutionByID` fails for a member during this run.
    final existingConns = await _repo.queryBankConnections(userId);
    final existingByMid = {
      for (final c in existingConns) c.userInstitutionId: c,
    };

    // Post-mutation eventual-consistency detection. Sophtron's
    // Customer→Members index is eventually consistent for a handful
    // of seconds after `createMember`: `getMembersV2` can return a
    // partial list (often only the freshly-modified Member). We're
    // "inside the window" when either:
    //   (a) the caller explicitly handed us a `waitForMemberId`
    //       (they just createMember'd), or
    //   (b) any local connection is younger than the drop-pass grace
    //       period — usually because (a) happened seconds ago, but
    //       also covers callers that didn't pass the hint.
    // Two behaviors are gated on this single concept:
    //   1. Settle loop on `getMembersV2` — re-fetches until the
    //      expected MemberID surfaces. Requires the explicit id, so
    //      gated on `waitForMemberId` specifically.
    //   2. Drop-pass skip — refuses to trust a possibly-partial
    //      Members list as authoritative for deletes. Gated on the
    //      broader window so implicit detection still protects us.
    final graceCutoff = DateTime.now().toUtc().subtract(
      BankWriteRepository.dropMissingGracePeriod,
    );
    final hasFreshConnection = existingConns.any((c) {
      final createdAt = c.createdAt;
      if (createdAt == null) return false;
      final ts = DateTime.tryParse(createdAt);
      return ts != null && ts.isAfter(graceCutoff);
    });
    final inPostMutationWindow = waitForMemberId != null || hasFreshConnection;

    // Step 1: resolve (or create) the v2 Customer.
    //
    // Circuit breaker (aggregator-availability guard). This is the first
    // Sophtron call of every sync and is account-level, so a repeated failure
    // here means the aggregator itself is unreachable or broken — not that one
    // bank needs re-auth (that's the per-connection `conn.isBroken` guard
    // further down, a different concept). Fast-failing while it's open stops
    // every foreground pull and 8-hourly background tick from hammering a dead
    // API. The breaker resets on the first success, so recovery is immediate.
    final breaker = await _repo.getCircuitBreaker(_sophtronService);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (breakerIsOpen(openedUntil: breaker.openedUntil, now: DateTime.now())) {
      final wait = Duration(milliseconds: breaker.openedUntil! - nowMs);
      Log.w(
        'bank-sync',
        'circuit breaker open for ${wait.inMinutes}m — skipping run',
      );
      const result = BankSyncResult(
        cardCount: 0,
        txCount: 0,
        errors: ['Bank service temporarily unavailable — retrying shortly.'],
      );
      onProgress?.call(const SyncCompleted(result));
      return result;
    }

    final String customerId;
    try {
      customerId = await client.resolveCustomerId(bankCustomerId);
      Log.i('bank-sync', 'customer resolved: $customerId');
      await _repo.resetCircuitBreaker(_sophtronService);
      onProgress?.call(const CustomerResolved());
    } catch (e, st) {
      Log.e('bank-sync', 'customer resolution failed', e, st);
      final next = await _repo.recordCircuitBreakerFailure(
        _sophtronService,
        threshold: _breakerThreshold,
        cooldown: _breakerCooldown,
      );
      if (next.openedUntil != null) {
        Log.w(
          'bank-sync',
          'circuit breaker tripped after ${next.failureCount}',
        );
      }
      rethrow;
    }

    // Step 2: list Members under the Customer.
    //
    // Inside `inPostMutationWindow` (see top of `run`), `getMembersV2`
    // can return a partial list — typically just the just-modified
    // Member. Two protections fire here, both belonging to the same
    // concept:
    //   - When we have an explicit `waitForMemberId` we settle the
    //     list by re-fetching until that id appears (this block).
    //   - The drop pass downstream is skipped on the same window so a
    //     partial list can't wipe local rows.
    // The settle loop bails out on [_membersListSettleTimeout] and
    // proceeds with whatever response came back — better a partial
    // sync than an infinite wait.
    List<dynamic> members;
    try {
      members = await client.getMembersV2(customerId);
      if (waitForMemberId != null &&
          !_membersContain(members, waitForMemberId)) {
        final deadline = DateTime.now().add(_membersListSettleTimeout);
        var attempts = 1;
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(_membersListSettleInterval);
          attempts++;
          try {
            members = await client.getMembersV2(customerId);
          } catch (e) {
            Log.w(
              'bank-sync',
              'getMembers retry $attempts failed (will retry): $e',
            );
            continue;
          }
          if (_membersContain(members, waitForMemberId)) {
            Log.i(
              'bank-sync',
              'members list settled after $attempts attempt(s) '
                  '(waitFor=$waitForMemberId, count=${members.length})',
            );
            break;
          }
        }
        if (!_membersContain(members, waitForMemberId)) {
          Log.w(
            'bank-sync',
            'members list never included $waitForMemberId within '
                '${_membersListSettleTimeout.inSeconds}s — proceeding with '
                'whatever is in the response',
          );
        }
      }
      Log.payload('bank-sync', 'members raw', () => members.toString());
    } catch (e, st) {
      Log.e('bank-sync', 'getMembers failed', e, st);
      rethrow;
    }

    // Best-effort orphan cleanup. Any Sophtron Member with no matching
    // local `bank_connections` row AND a recent `LastModified` is
    // almost certainly an abandoned link — the user either killed the
    // app mid-MFA, or hit "Cancel link" on the warning dialog after
    // `createMember` had already succeeded. Delete it at Sophtron so it
    // doesn't sit there forever consuming a connection slot.
    //
    // The 2-hour `LastModified` window protects against accidentally
    // wiping an older successfully-linked Member; recently-modified
    // Members are the only ones eligible to be considered orphans.
    //
    // **Additionally** skipped entirely until [firstSyncCompleted] —
    // until then the local DB is empty by design (fresh install /
    // post-reinstall recovery), so every Sophtron Member would look
    // like an orphan and we'd `deleteMember` the whole wallet. The
    // gate flips true after the provider lands a successful
    // SyncCompleted; orphan cleanup resumes on the next sync. The
    // 2-hour window stays as belt-and-suspenders for the abandoned-
    // MFA case once cleanup is re-enabled.
    final cleanupCutoff = DateTime.now().subtract(const Duration(hours: 2));
    final cleanedUpMids = <String>{};
    if (!firstSyncCompleted) {
      Log.i(
        'bank-sync',
        'skipping orphan cleanup — first sync not yet completed for this '
            'user; treating every Sophtron Member as legitimate '
            '(reinstall-recovery path)',
      );
    } else {
      for (final m in members) {
        if (m is! Map) continue;
        final mid = (m['MemberID'] ?? m['ID'] ?? m['id'])?.toString();
        if (mid == null || mid.isEmpty) continue;
        if (existingByMid.containsKey(mid)) continue;
        final lastModifiedRaw = m['LastModified']?.toString();
        final lastModified = lastModifiedRaw == null
            ? null
            : DateTime.tryParse(lastModifiedRaw);
        if (lastModified == null || lastModified.isBefore(cleanupCutoff)) {
          continue;
        }
        try {
          await client.deleteMember(customerId: customerId, memberId: mid);
          Log.i(
            'bank-sync',
            'cleaned up orphan Sophtron Member $mid '
                '(modified ${lastModified.toIso8601String()})',
          );
          cleanedUpMids.add(mid);
        } catch (e) {
          Log.w('bank-sync', 'orphan cleanup failed for $mid: $e');
        }
      }
    }

    // Hydrate each Member with institution metadata. Null-cached so a
    // transient v1 outage doesn't re-issue requests for the same id
    // for every duplicate Member.
    final instCache = <String, _InstLookup>{};
    final resolved = <_ResolvedMember>[];
    for (final m in members) {
      if (m is! Map) continue;
      final mid = (m['MemberID'] ?? m['ID'] ?? m['id'])?.toString();
      final iid = m['InstitutionID']?.toString();
      if (mid == null ||
          mid.isEmpty ||
          iid == null ||
          iid == _kSandboxInstitutionId) {
        continue;
      }
      // Skip Members we just deleted at Sophtron in the orphan pass above.
      if (cleanedUpMids.contains(mid)) continue;
      _InstLookup lookup;
      if (instCache.containsKey(iid)) {
        lookup = instCache[iid]!;
      } else {
        try {
          final raw = await client.getInstitutionByID(iid);
          lookup = _InstLookup(value: raw);
        } on SophtronException catch (e) {
          // Don't tear down the whole sync; record null so we don't
          // re-issue, but the per-member fallback chain still tries
          // the stored connection row.
          Log.w(
            'bank-sync',
            'institution lookup failed for $iid: ${e.summary}',
          );
          lookup = const _InstLookup(value: null);
        }
        instCache[iid] = lookup;
      }
      final inst = lookup.value;
      final prior = existingByMid[mid];
      final name =
          (inst?['InstitutionName']?.toString()) ?? prior?.institutionName;
      final logo = (inst?['Logo']?.toString().trim()) ?? prior?.institutionLogo;
      if (name == null || name.isEmpty) {
        Log.w(
          'bank-sync',
          'skipping member $mid: no institution name from v1 or stored.',
        );
        continue;
      }
      await _repo.upsertInstitutionCache(
        institutionId: iid,
        name: name,
        logo: logo,
      );
      resolved.add(
        _ResolvedMember(
          mid: mid,
          iid: iid,
          name: name,
          logo: logo,
          lastModified: m['LastModified']?.toString() ?? '',
        ),
      );
    }

    // Name-dedup: collapse multi-InstitutionID issuers (Chase + Chase
    // Bank + Chase Credit Cards) to the most-recently-modified Member.
    final byName = <String, int>{};
    for (var i = 0; i < resolved.length; i++) {
      final r = resolved[i];
      final key = _normalizeBankKey(r.name);
      final existing = byName[key];
      if (existing == null) {
        byName[key] = i;
      } else if (r.lastModified.compareTo(resolved[existing].lastModified) >
          0) {
        byName[key] = i;
      }
    }
    Log.i('bank-sync', 'name-dedup: ${resolved.length} → ${byName.length}');

    // Auto-dedupe duplicate links: re-linking the same institution leaves
    // multiple Members with the SAME InstitutionID (and identical accounts).
    // Keep the most-recently-modified per InstitutionID and deleteMember the
    // rest at Sophtron so duplicates don't multiply sync work + history
    // refreshes. Gated on firstSyncCompleted only (skip during reinstall
    // recovery, when the local DB is empty by design). Safe even if the
    // Members list is partial: we only delete same-InstitutionID duplicates of
    // a member we actually see, keeping the most-recent — a unique bank is
    // never deleted, and the just-linked member (most-recent) is the keeper.
    if (firstSyncCompleted) {
      final byInstitution = <String, List<_ResolvedMember>>{};
      for (final r in resolved) {
        (byInstitution[r.iid] ??= <_ResolvedMember>[]).add(r);
      }
      for (final group in byInstitution.values) {
        if (group.length < 2) continue;
        group.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        for (final dup in group.skip(1)) {
          try {
            await client.deleteMember(
              customerId: customerId,
              memberId: dup.mid,
            );
            Log.i(
              'bank-sync',
              'deduped duplicate member ${dup.mid} (institution ${dup.iid})',
            );
          } catch (e) {
            Log.w('bank-sync', 'dedupe deleteMember failed for ${dup.mid}: $e');
          }
        }
      }
    }

    // Persist connection rows up front. Each per-institution rebuild
    // writes the rest. Done before fan-out so the Cards screen has the
    // bank-section scaffolding to render even while we're still pulling
    // accounts/txs.
    final keepInstitutionIds = <String>{};
    for (final idx in byName.values) {
      final r = resolved[idx];
      keepInstitutionIds.add(r.iid);
      final cleanName = r.name.replaceAll(RegExp(r'\s+'), ' ').trim();
      await _repo.upsertConnection(
        userId: userId,
        userInstitutionId: r.mid,
        memberId: r.mid,
        institutionId: r.iid,
        institutionName: cleanName,
        institutionLogo: r.logo,
      );
    }

    // Drop connection rows (and their data) for institutions no longer
    // in the v2 response. Replaces the prior global `replaceBankData`
    // wipe — bounded to actually-removed banks, no collateral damage to
    // freshly-synced ones.
    //
    // Skipped entirely inside the post-mutation eventual-consistency
    // window (see `inPostMutationWindow` at the top of `run`): trusting
    // a possibly-partial Members list as authoritative for deletes
    // would wipe perfectly-good local rows for banks the v2 index just
    // hasn't re-listed yet. The next sync, once the window closes,
    // runs a normal drop pass.
    if (inPostMutationWindow) {
      Log.i(
        'bank-sync',
        'skipping drop pass — inside post-mutation window '
            '(Sophtron Members list may be partial)',
      );
    } else {
      final keepMemberIds = byName.values
          .map((idx) => resolved[idx].mid)
          .toSet();
      await _repo.dropMissingInstitutions(
        userId: userId,
        keepInstitutionIds: keepInstitutionIds,
        keepMemberIds: keepMemberIds,
      );
    }

    final connections = await _repo.queryBankConnections(userId);
    Log.i(
      'bank-sync',
      'syncing ${connections.length} link(s) (pool=$_kMemberPoolWidth)',
    );

    // Progress denominator = the member connections we actually fan out over,
    // NOT the name-deduped count. Inside the post-mutation window the drop pass
    // is skipped, so `connections` can still include a duplicate link that the
    // deduped count collapsed — emitting the deduped count here is what made
    // the banner read an impossible "6 of 5 banks". This always matches the
    // number of MemberCompleted events the loop below can emit.
    onProgress?.call(MembersListed(connections.length));

    // Brand resolver: load once for the whole sync. Backed by the
    // in-code registry, so this is a pure in-memory construction.
    final brandResolver = _repo.loadBrandResolver();

    // Bounded fan-out. `Pool.forEach` returns a stream; we materialize
    // the outcomes list with `.toList()`.
    final memberPool = Pool(_kMemberPoolWidth);
    try {
      final outcomes = await memberPool
          .forEach<BankConnectionRow, _MemberOutcome>(
            connections,
            (conn) => _syncMember(
              client: client,
              customerId: customerId,
              userId: userId,
              conn: conn,
              transactionDays: transactionDays,
              includeDebitAccounts: includeDebitAccounts,
              forceRefresh: forceRefresh,
              onProgress: onProgress,
              brandResolver: brandResolver,
            ),
          )
          .toList();

      var totalCards = 0;
      var totalTxs = 0;
      final errors = <String>[];
      for (final outcome in outcomes) {
        totalCards += outcome.cardCount;
        totalTxs += outcome.txCount;
        errors.addAll(outcome.errors);
      }

      Log.i(
        'bank-sync',
        'done: cards=$totalCards txs=$totalTxs errors=${errors.length}',
      );
      final result = BankSyncResult(
        cardCount: totalCards,
        txCount: totalTxs,
        errors: errors,
      );
      onProgress?.call(SyncCompleted(result));
      return result;
    } finally {
      await memberPool.close();
      client.close();
    }
  }

  /// True when the raw v2 Members list contains an entry whose MemberID
  /// (or fallback `ID` field, which v2 sometimes uses interchangeably)
  /// matches [memberId]. Used by the post-createMember settle loop.
  static bool _membersContain(List<dynamic> members, String memberId) {
    for (final m in members) {
      if (m is! Map) continue;
      final mid = (m['MemberID'] ?? m['ID'] ?? m['id'])?.toString();
      if (mid == memberId) return true;
    }
    return false;
  }

  /// Whether a Member should be retired as an abandoned link.
  ///
  /// True only when ALL of these hold:
  ///   - Sophtron returned zero accounts of *any* type ([rawAccountsEmpty]) —
  ///     raw, not credit-filtered, so a real debit-only bank (which returns
  ///     accounts, just no credit ones) is never mistaken for abandoned;
  ///   - the connection has never had a successful sync ([neverSyncedBefore]);
  ///   - it was created longer ago than [_abandonedMemberMinAge], i.e. past
  ///     the createMember→accounts propagation window where a legitimate fresh
  ///     link would already have produced its first sync.
  /// A missing or unparseable [createdAtRaw] returns false — we never retire
  /// on ambiguous data.
  @visibleForTesting
  static bool shouldRetireAbandoned({
    required bool rawAccountsEmpty,
    required bool neverSyncedBefore,
    required String? createdAtRaw,
    DateTime? now,
  }) {
    if (!rawAccountsEmpty || !neverSyncedBefore) return false;
    if (createdAtRaw == null) return false;
    final created = DateTime.tryParse(createdAtRaw);
    if (created == null) return false;
    final reference = (now ?? DateTime.now()).toUtc();
    return reference.difference(created.toUtc()) > _abandonedMemberMinAge;
  }

  Future<_MemberOutcome> _syncMember({
    required BankClient client,
    required String customerId,
    required String userId,
    required BankConnectionRow conn,
    required int transactionDays,
    required bool includeDebitAccounts,
    required bool forceRefresh,
    required BrandResolver brandResolver,
    void Function(SyncProgressEvent)? onProgress,
  }) async {
    final memberId = conn.userInstitutionId;
    final institutionId = conn.institutionId!;
    final instName = conn.institutionName ?? memberId;
    final instLogo = conn.institutionLogo;
    final errors = <String>[];

    // Circuit breaker (re-auth lockout guard). A connection already flagged
    // `failed` needs the user to reconnect; re-running the per-member sync
    // would fire another `refreshMember` scrape — i.e. another login at the
    // issuer. Repeated logins against a bank awaiting re-auth are exactly what
    // trips an issuer "too many attempts" lockout. Skip it entirely: the cards
    // from the last good sync stay in place (we never wipe them), the
    // Cards-screen Reconnect prompt stays up, and we make zero network calls.
    // The user clears it by reconnecting, which creates a fresh Member with its
    // own status.
    if (conn.isBroken) {
      Log.i(
        'bank-sync',
        'skipping $memberId ($instName): needs reconnect — not re-scraping',
      );
      onProgress?.call(
        MemberCompleted(
          memberId: memberId,
          bankName: instName,
          success: false,
          error: conn.lastSyncError ?? 'Reconnect required',
        ),
      );
      return const _MemberOutcome(cardCount: 0, txCount: 0, errors: <String>[]);
    }

    // `last_synced_at IS NULL` means we've never seen this Member return
    // a successful sync. For Sophtron-side errors during this window —
    // chiefly the 404 / "Member not found" responses observed for a few
    // minutes after `createMember` succeeds — we treat the failure as
    // transient instead of flipping `last_sync_status='failed'`. The
    // `Cards`-screen "Connection lost · Reconnect" banner would mislead
    // here: the link is fine, the customer/members view just hasn't
    // caught up.
    final neverSyncedBefore = conn.lastSyncedAt == null;

    onProgress?.call(MemberStarted(memberId: memberId, bankName: instName));

    try {
      // Re-scrape the bank first so the v3 reads return current data instead
      // of replaying the last job's snapshot (the root cause of stale/short
      // history). Best-effort: never blocks the read on MFA/timeout/error.
      final refreshOutcome = await _refreshMemberIfDue(
        client: client,
        customerId: customerId,
        memberId: memberId,
        userId: userId,
        forceRefresh: forceRefresh,
        instName: instName,
      );

      // The pre-read scrape surfaced a re-auth / MFA need (or the bank rejected
      // the login outright). This signal was previously swallowed: the cached
      // v3 read below still returns a stale snapshot and would mark the bank
      // `ok`, hiding the problem while every later sync silently re-attempted
      // the login until the issuer locked the account. Flag it `failed` so the
      // Reconnect prompt shows, and bail before the read so we stop hammering.
      // Skipped for never-synced members: a refresh right after linking can
      // re-challenge during Sophtron's propagation window, and we don't want to
      // slap a Reconnect banner on a bank the user just added.
      if (refreshOutcome == _RefreshOutcome.reauthRequired &&
          !neverSyncedBefore) {
        Log.w('bank-sync', 're-auth required for $memberId ($instName)');
        await _repo.setConnectionSyncStatus(
          memberId,
          status: 'failed',
          error: 'Reconnect required — your bank needs you to verify again',
        );
        onProgress?.call(
          MemberCompleted(
            memberId: memberId,
            bankName: instName,
            success: false,
            error: 'Reconnect required',
          ),
        );
        return const _MemberOutcome(
          cardCount: 0,
          txCount: 0,
          errors: <String>[],
        );
      }
      final rawAccounts = await client.getMemberAccountsV3(
        customerId: customerId,
        memberId: memberId,
      );

      // Abandoned-link retirement: a Member that returns no accounts at all,
      // has never successfully synced, and is past the createMember
      // propagation window is a link the user started but never authenticated
      // (entered creds, bailed at MFA). Sophtron keeps the half-created Member
      // forever; left alone it re-appears as a phantom "syncing" bank every
      // sync and never yields a card. Retire it so it stops coming back.
      if (shouldRetireAbandoned(
        rawAccountsEmpty: rawAccounts.isEmpty,
        neverSyncedBefore: neverSyncedBefore,
        createdAtRaw: conn.createdAt,
      )) {
        return _retireAbandonedMember(
          client: client,
          customerId: customerId,
          userId: userId,
          memberId: memberId,
          instName: instName,
          reason: 'no accounts returned past propagation window',
        );
      }

      // Zero accounts of ANY type on a never-synced member that's still inside
      // the 2h propagation window (the retire check above only fires past it).
      // Leave it unsynced — skip rebuildInstitution and don't stamp
      // last_synced_at — so it stays eligible for retirement once it ages out
      // instead of being marked "synced with 0 cards" and spared forever. This
      // mirrors the never-synced 404 path below; a bank that's merely still
      // propagating returns real accounts on a later sync and completes then.
      if (rawAccounts.isEmpty && neverSyncedBefore) {
        Log.i(
          'bank-sync',
          'member $memberId returned no accounts yet — leaving unsynced '
              '($instName)',
        );
        return _MemberOutcome(cardCount: 0, txCount: 0, errors: errors);
      }

      // Zero accounts on a member that HAS synced before is treated as a
      // transient/degraded response (a flaky Sophtron round-trip returning
      // 200 + an empty list, rather than a clean timeout exception), never
      // as "the user closed every account." `rebuildInstitution` below
      // would otherwise wipe this institution's existing cards and insert
      // nothing in their place — silently emptying a previously-healthy
      // bank with `last_sync_status` still `'ok'`, no broken-banner signal
      // for the user to notice. Skip the rebuild and leave everything
      // (cards, `last_synced_at`, `last_sync_status`) untouched, exactly
      // like the `SophtronTransientException` handling below.
      if (rawAccounts.isEmpty && !neverSyncedBefore) {
        Log.w(
          'bank-sync',
          'member $memberId ($instName) returned zero accounts on an '
              'already-synced connection — treating as transient, not '
              'wiping existing cards',
        );
        return _MemberOutcome(
          cardCount: 0,
          txCount: 0,
          errors: ['empty-accounts[$memberId]: treated as transient'],
        );
      }

      // FDX accounts carry balances inline (no detail call). The mapper is the
      // only code that knows FDX field names; everything below is neutral.
      final accounts = rawAccounts
          .map(BankFdxMapper.account)
          .whereType<BankAccount>()
          .where((a) => includeDebitAccounts || a.accountType == 'Credit_Card')
          .toList();

      onProgress?.call(
        MemberAccountsLoaded(
          memberId: memberId,
          bankName: instName,
          accountCount: accounts.length,
        ),
      );

      // Per-account transactions — bounded fan-out inside this member
      // too, so a Chase login with 8 cards doesn't fire 8 concurrent
      // requests against one issuer.
      final end = DateTime.now().toUtc();
      // First sync of a connection backfills full history; later syncs pull
      // only the rolling reconcile window ([_reconcileWindowDays]) so a
      // disputed/removed charge inside it gets pruned locally, without
      // re-pulling years of already-archived rows on every refresh.
      final effectiveDays = neverSyncedBefore
          ? transactionDays
          : _reconcileWindowDays;
      final start = end.subtract(Duration(days: effectiveDays));
      final accountPool = Pool(_kAccountPoolWidth);
      Map<String, List<BankTransaction>> txsByAccountId;
      try {
        final entries = await accountPool
            .forEach<BankAccount, MapEntry<String, List<BankTransaction>>>(
              accounts,
              (acct) async {
                final accountId = acct.accountId;
                try {
                  final raw = await client.getTransactionsV3(
                    customerId: customerId,
                    accountId: accountId,
                    startDate: start,
                    endDate: end,
                  );
                  final txs = raw
                      .map(BankFdxMapper.transaction)
                      .whereType<BankTransaction>()
                      .toList();
                  return MapEntry(accountId, txs);
                } on SophtronTransientException catch (e) {
                  Log.w(
                    'bank-sync',
                    'tx fetch transient for $accountId: ${e.summary}',
                  );
                  errors.add('tx[$accountId]: transient ${e.cause}');
                  return MapEntry(accountId, <BankTransaction>[]);
                } on SophtronException catch (e, st) {
                  Log.e('bank-sync', 'tx fetch for $accountId failed', e, st);
                  errors.add('tx[$accountId]: ${e.summary}');
                  return MapEntry(accountId, <BankTransaction>[]);
                }
              },
            )
            .toList();
        txsByAccountId = {
          for (final e in entries)
            if (e.key.isNotEmpty) e.key: e.value,
        };
      } finally {
        await accountPool.close();
      }

      // Single atomic write: wipe this institution's prior rows + insert
      // everything we just fetched. Failure here rolls back this bank
      // only; other banks keep their prior state.
      final counts = await _repo.rebuildInstitution(
        userId: userId,
        institutionId: institutionId,
        institutionName: instName,
        institutionLogo: instLogo,
        accounts: accounts,
        txsByAccountId: txsByAccountId,
        brandResolver: brandResolver,
      );

      // Collapse "same physical card under both bank and Manual" — runs
      // after the rebuild so manual cards merge into the freshly-inserted
      // synced rows.
      final merged = await _repo.mergeManualCardsWithBank(
        userId: userId,
        institutionName: instName,
      );
      if (merged > 0) {
        Log.i('bank-sync', 'merged $merged manual card(s) into $instName');
      }

      onProgress?.call(
        MemberTransactionsLoaded(
          memberId: memberId,
          bankName: instName,
          txCount: counts.txCount,
        ),
      );

      await _repo.setConnectionLastSyncedAt(memberId, DateTime.now().toUtc());
      await _repo.setConnectionSyncStatus(memberId, status: 'ok');
      onProgress?.call(
        MemberCompleted(memberId: memberId, bankName: instName, success: true),
      );
      return _MemberOutcome(
        cardCount: counts.cardCount,
        txCount: counts.txCount,
        errors: errors,
      );
    } on SophtronTransientException catch (e) {
      // Transient (5xx / 408 / 429 / network / timeout): leave the prior
      // `last_sync_status` untouched so the Cards screen doesn't render
      // a red ✗ for a recoverable issue. No `MemberCompleted` event
      // either — the first-sync progress UI stays neutral.
      Log.w(
        'bank-sync',
        'transient failure for $memberId (status preserved): ${e.summary}',
      );
      return _MemberOutcome(
        cardCount: 0,
        txCount: 0,
        errors: ['transient[$memberId]: ${e.cause}'],
      );
    } on SophtronAuthException catch (e) {
      // 401/403: link needs re-auth. Marked failed so the Cards screen
      // shows the prominent Reconnect treatment.
      Log.w('bank-sync', 'auth failure for $memberId: ${e.summary}');
      errors.add('auth[$memberId]: ${e.summary}');
      await _repo.setConnectionSyncStatus(
        memberId,
        status: 'failed',
        error: e.summary,
      );
      onProgress?.call(
        MemberCompleted(
          memberId: memberId,
          bankName: instName,
          success: false,
          error: e.summary,
        ),
      );
      return _MemberOutcome(cardCount: 0, txCount: 0, errors: errors);
    } on SophtronException catch (e, st) {
      // Sophtron's customer/members view is eventually consistent after
      // `createMember`. For up to a few minutes, `getMemberAccounts`
      // against the new MemberID can return 404 even though the link
      // itself is healthy. Marking `'failed'` here would surface the
      // "Connection lost · Reconnect" banner for a perfectly fine bank
      // the user just added. Treat NotFound on a never-synced connection
      // as transient — the next sync after Sophtron catches up succeeds.
      if (neverSyncedBefore && e is SophtronNotFoundException) {
        // A 404 means zero accounts of any type. Past the propagation window
        // that's an abandoned link, not a slow first sync — retire it rather
        // than re-probing a dead Member every sync forever.
        if (shouldRetireAbandoned(
          rawAccountsEmpty: true,
          neverSyncedBefore: neverSyncedBefore,
          createdAtRaw: conn.createdAt,
        )) {
          return _retireAbandonedMember(
            client: client,
            customerId: customerId,
            userId: userId,
            memberId: memberId,
            instName: instName,
            reason: '404 past propagation window',
          );
        }
        Log.w(
          'bank-sync',
          'first-sync 404 for $memberId (likely Sophtron propagation '
              'window; status not marked failed): ${e.summary}',
        );
        return _MemberOutcome(
          cardCount: 0,
          txCount: 0,
          errors: ['first-sync-404[$memberId]: ${e.summary}'],
        );
      }
      Log.e('bank-sync', 'member $memberId failed', e, st);
      errors.add('member[$memberId]: ${e.summary}');
      await _repo.setConnectionSyncStatus(
        memberId,
        status: 'failed',
        error: e.summary,
      );
      onProgress?.call(
        MemberCompleted(
          memberId: memberId,
          bankName: instName,
          success: false,
          error: e.summary,
        ),
      );
      return _MemberOutcome(cardCount: 0, txCount: 0, errors: errors);
    } catch (e, st) {
      // Non-Sophtron error (likely a local DB write failure). Treat as
      // a hard fail for this bank only.
      Log.e('bank-sync', 'member $memberId failed', e, st);
      errors.add('member[$memberId]: $e');
      await _repo.setConnectionSyncStatus(
        memberId,
        status: 'failed',
        error: e.toString(),
      );
      onProgress?.call(
        MemberCompleted(
          memberId: memberId,
          bankName: instName,
          success: false,
          error: e.toString(),
        ),
      );
      return _MemberOutcome(cardCount: 0, txCount: 0, errors: errors);
    }
  }

  /// Deletes an abandoned Member at Sophtron and wipes its local rows.
  /// Best-effort on the remote delete (logged, never throws) so a Sophtron
  /// hiccup can't leave the local phantom in place — the local wipe is what
  /// stops it re-appearing as a "syncing" bank, and once the remote delete
  /// lands the next sync's Members list no longer includes it.
  Future<_MemberOutcome> _retireAbandonedMember({
    required BankClient client,
    required String customerId,
    required String userId,
    required String memberId,
    required String instName,
    required String reason,
  }) async {
    Log.i(
      'bank-sync',
      'retiring abandoned member $memberId ($instName): $reason',
    );
    try {
      await client.deleteMember(customerId: customerId, memberId: memberId);
    } catch (e) {
      Log.w('bank-sync', 'deleteMember failed for abandoned $memberId: $e');
    }
    await _repo.deleteMemberData(userId: userId, userInstitutionId: memberId);
    return const _MemberOutcome(cardCount: 0, txCount: 0, errors: <String>[]);
  }

  /// Best-effort re-scrape before reading a member. Triggers a standard
  /// `aggregate` refresh job and polls it to completion, so the subsequent v3
  /// reads return current data rather than replaying the last job's snapshot.
  /// NEVER throws — on timeout or any error we log and fall back to reading the
  /// last snapshot. Throttled (skipped if refreshed within [_refreshThrottle])
  /// unless [forceRefresh] (user-initiated sync).
  ///
  /// A job that outlives the poll window keeps its JobID persisted; the next
  /// sync checks that job's final outcome FIRST — a completed-but-failed or
  /// MFA-blocked job found there is the "bank connection is dead" signal that
  /// used to be invisible (every sync re-read the stale snapshot and reported
  /// ok), and a still-running one is resumed rather than stacking a second
  /// login against the issuer.
  ///
  /// Returns [_RefreshOutcome.reauthRequired] when the scrape (current or
  /// pending from a prior sync) surfaced an MFA challenge or the bank rejected
  /// the login (a completed-but-failed job), so the caller can flag the member
  /// for reconnect and stop re-scraping it; [_RefreshOutcome.proceeded] in
  /// every other case (success, throttled, transient trigger/poll error,
  /// timeout).
  Future<_RefreshOutcome> _refreshMemberIfDue({
    required BankClient client,
    required String customerId,
    required String memberId,
    required String userId,
    required bool forceRefresh,
    required String instName,
  }) async {
    final settings = SettingsRepository(_repo);

    // Outcome check for a refresh job a prior sync triggered but stopped
    // watching.
    String? jobId;
    final pendingJobId = await settings.getMemberRefreshJobId(userId, memberId);
    if (pendingJobId != null) {
      Map<String, dynamic>? job;
      try {
        job = await client.getJobInfo(pendingJobId);
      } catch (e) {
        Log.w(
          'bank-sync',
          'pending refresh job $pendingJobId unreadable for $memberId: $e',
        );
      }
      if (job != null && refreshJobNeedsReauth(job)) {
        await settings.clearMemberRefreshJobId(userId, memberId);
        Log.w(
          'bank-sync',
          'prior refresh job for $memberId ($instName) failed — '
              'flagging re-auth: ${job['ErrorMessage']}',
        );
        return _RefreshOutcome.reauthRequired;
      }
      if (job != null && job['SuccessFlag'] == true) {
        // Finished fine after we stopped watching — the v3 reads will return
        // its data. Fall through to the normal throttle/trigger logic (the
        // trigger timestamp was stamped when this job started, so a recent
        // one throttles as usual).
        await settings.clearMemberRefreshJobId(userId, memberId);
      } else if (job != null && job.isNotEmpty) {
        // Still running server-side. Trusted only up to
        // [_pendingRefreshJobMaxAge] (measured from the stored trigger
        // timestamp): within it, resume polling this job below instead of
        // stacking a second login against the issuer; past it, treat the job
        // as wedged/lost and fall through to trigger a fresh one.
        final triggeredAt = await settings.getMemberRefreshedAt(
          userId,
          memberId,
        );
        final age = triggeredAt == null
            ? null
            : DateTime.now().toUtc().difference(triggeredAt.toUtc());
        if (age != null && age < _pendingRefreshJobMaxAge) {
          jobId = pendingJobId;
        } else {
          await settings.clearMemberRefreshJobId(userId, memberId);
          Log.w(
            'bank-sync',
            'pending refresh job for $memberId aged out — re-triggering',
          );
        }
      } else {
        // Unreadable or empty payload — nothing more to learn from it.
        await settings.clearMemberRefreshJobId(userId, memberId);
      }
    }

    if (jobId == null) {
      if (!forceRefresh) {
        final last = await settings.getMemberRefreshedAt(userId, memberId);
        if (last != null &&
            DateTime.now().toUtc().difference(last.toUtc()) <
                _refreshThrottle) {
          Log.i('bank-sync', 'refresh throttled for $memberId ($instName)');
          return _RefreshOutcome.proceeded;
        }
      }
      try {
        final res = await client.refreshMember(
          customerId: customerId,
          memberId: memberId,
          jobType: 'aggregate',
        );
        jobId = (res['JobID'] ?? res['jobID'])?.toString();
      } catch (e) {
        Log.w('bank-sync', 'refresh trigger failed for $memberId: $e');
        return _RefreshOutcome.proceeded;
      }
      if (jobId == null) return _RefreshOutcome.proceeded;
      // Mark the *attempt* (not just success): a slow or MFA-gated job must
      // not be re-triggered every sync, or syncs stay perpetually slow. The
      // throttle counts attempts; the job still finishes server-side and the
      // next (post-throttle) sync reads its result. The JobID is persisted so
      // that next sync checks the OUTCOME, not just the snapshot.
      await settings.setMemberRefreshedAt(
        userId,
        memberId,
        DateTime.now().toUtc(),
      );
      await settings.setMemberRefreshJobId(userId, memberId, jobId);
    }

    final deadline = DateTime.now().add(_refreshMaxWait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_refreshPollInterval);
      Map<String, dynamic> job;
      try {
        job = await client.getJobInfo(jobId);
      } catch (_) {
        continue;
      }
      if (job['SuccessFlag'] == true) {
        await settings.clearMemberRefreshJobId(userId, memberId);
        return _RefreshOutcome.proceeded;
      }
      if (refreshJobNeedsReauth(job)) {
        await settings.clearMemberRefreshJobId(userId, memberId);
        Log.w(
          'bank-sync',
          'refresh for $memberId needs re-auth ($instName): '
              '${job['ErrorMessage']}',
        );
        return _RefreshOutcome.reauthRequired;
      }
    }
    // Timed out with the job still running. The JobID stays persisted so the
    // NEXT sync checks its final outcome before triggering another scrape.
    Log.w('bank-sync', 'refresh for $memberId timed out; reading snapshot');
    return _RefreshOutcome.proceeded;
  }

  /// True when a refresh job's payload says the scrape can't complete without
  /// the user. Two shapes:
  ///   - an MFA challenge is pending (can't be answered headlessly during
  ///     sync) — this IS the re-auth signal;
  ///   - the job completed unsuccessfully = the bank rejected the scrape (bad
  ///     or locked credentials, additional verification).
  /// Either way the caller flags the member for reconnect and stops
  /// re-attempting the login (issuer lockout guard).
  @visibleForTesting
  static bool refreshJobNeedsReauth(Map<String, dynamic> job) {
    if (job['SecurityQuestion'] != null ||
        job['TokenMethod'] != null ||
        job['TokenSentFlag'] == true ||
        job['TokenRead'] != null ||
        job['CaptchaImage'] != null) {
      return true;
    }
    return job['SuccessFlag'] == false && job['LastStatus'] == 'Completed';
  }
}

/// Outcome of the pre-read scrape ([BankSyncEngine._refreshMemberIfDue]).
enum _RefreshOutcome {
  /// Carry on and read — fresh data, throttled, or a transient hiccup we ignore.
  proceeded,

  /// The scrape hit an MFA challenge or the bank rejected the login. The member
  /// needs the user to reconnect and must not be re-scraped (lockout guard).
  reauthRequired,
}

class _ResolvedMember {
  const _ResolvedMember({
    required this.mid,
    required this.iid,
    required this.name,
    required this.logo,
    required this.lastModified,
  });
  final String mid;
  final String iid;
  final String name;
  final String? logo;
  final String lastModified;
}

/// Wraps a v1 institution lookup result so the cache stores explicit
/// nulls. The prior `instCache[iid] ??= await ...` form skipped caching
/// when the call returned null, re-issuing the request for every member
/// with the same institutionId.
class _InstLookup {
  const _InstLookup({required this.value});
  final Map<String, dynamic>? value;
}

class _MemberOutcome {
  const _MemberOutcome({
    required this.cardCount,
    required this.txCount,
    required this.errors,
  });
  final int cardCount;
  final int txCount;
  final List<String> errors;
}

class BankSyncResult {
  const BankSyncResult({
    required this.cardCount,
    required this.txCount,
    required this.errors,
  });
  final int cardCount;
  final int txCount;
  final List<String> errors;
}

/// Reduces an institution display name to a comparison key. Strips
/// runs of whitespace and common issuer suffixes that vary across the
/// same underlying issuer's `InstitutionID`s.
String _normalizeBankKey(String raw) {
  var s = raw.toLowerCase();
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(
    RegExp(
      r'\s+(bank|credit cards?|card services|na|n\.a\.|usa)$',
      caseSensitive: false,
    ),
    '',
  );
  return s.trim();
}
