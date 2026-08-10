import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'entitlement_provider.dart';
import 'auth_provider.dart';
import 'data_providers.dart';
import '../api/bank_client.dart';
import '../api/card_link_service.dart';
import '../api/catalog_loader.dart';
import '../api/data_repository.dart';
import '../api/settings_repository.dart';
import '../api/sophtron_auth_service.dart';
import '../sync/bank_sync_engine.dart';
import '../sync/sync_progress_event.dart';
import '../util/link_progress_notifier.dart';
import '../util/logger.dart';

/// Combined state exposed to the UI: latest result + the most recent
/// progress event. Screens (first-sync loading, sticky sync banner,
/// broken-bank chip, etc.) watch this for both end-of-run summaries and
/// per-step updates.
class BankSyncState {
  const BankSyncState({
    this.result,
    this.lastProgress,
    this.bankStatuses = const {},
    this.memberCount,
  });

  /// Latest completed sync result, or null if no sync has finished yet.
  final BankSyncResult? result;

  /// Most recent progress event emitted by the running sync (or the last
  /// one from a finished sync). null when no sync has started.
  final SyncProgressEvent? lastProgress;

  /// Live per-member status map, keyed by MemberID. Each value is the
  /// last `MemberCompleted` event for that member. The first-sync UI
  /// reads this for step-by-step "Loaded N accounts" rendering.
  final Map<String, MemberCompleted> bankStatuses;

  /// Number of banks the engine reported it's about to sync, derived
  /// from the `MembersListed` progress event. Null until that event
  /// arrives (very early in the run). Drives the
  /// "Syncing X of Y banks…" copy on the sticky progress banner —
  /// without it, the denominator would be unknown until the first
  /// `MemberCompleted` event lands.
  final int? memberCount;

  /// True when the engine has emitted `MembersListed` but `SyncCompleted`
  /// hasn't fired yet — i.e. we're in the per-member fan-out window
  /// and progress is meaningful. The sticky banner uses this to decide
  /// whether to render at all.
  bool get isPerMemberSyncing {
    final lp = lastProgress;
    if (lp == null) return false;
    if (lp is SyncCompleted) return false;
    return memberCount != null;
  }

  BankSyncState copyWith({
    BankSyncResult? result,
    SyncProgressEvent? lastProgress,
    Map<String, MemberCompleted>? bankStatuses,
    int? memberCount,
  }) => BankSyncState(
    result: result ?? this.result,
    lastProgress: lastProgress ?? this.lastProgress,
    bankStatuses: bankStatuses ?? this.bankStatuses,
    memberCount: memberCount ?? this.memberCount,
  );
}

class BankSyncNotifier extends Notifier<AsyncValue<BankSyncState>> {
  late final DataRepository _repo;
  // Catalog layer: hydrate the bundled catalog and (re)bind synced cards to
  // catalog products so each card gets its rewards/perks/recommendations.
  final _catalogLoader = CatalogLoader();
  final _cardLinks = CardLinkService();
  late final SettingsRepository _settings;
  late final BankSyncEngine _engine;

  @override
  AsyncValue<BankSyncState> build() {
    _repo = ref.read(dataRepositoryProvider);
    _settings = SettingsRepository(_repo);
    _engine = BankSyncEngine(_repo);
    return const AsyncValue.data(BankSyncState());
  }

  /// [waitForMemberId] is forwarded to [BankSyncEngine.run]: when
  /// set, the engine waits for that MemberID to surface in
  /// `getMembersV2` before proceeding. Callers should set this only
  /// when they're triggering a sync *because* of a `createMember` they
  /// just completed (add-bank / reconnect), so the first post-link sync
  /// doesn't miss its own freshly-added bank or older sibling Members
  /// that the v2 index hasn't re-listed yet.
  Future<void> runSync({String? waitForMemberId}) async {
    final auth = ref.read(authProvider);
    if (!auth.isLoggedIn || auth.userId == null) {
      Log.w('bank-sync', 'runSync called without auth; skipping');
      return;
    }
    final uniqueId = auth.bankCustomerId;
    if (uniqueId == null || uniqueId.isEmpty) {
      Log.w(
        'bank-sync',
        'runSync called without a per-user Customer uniqueId on AuthState; '
            'onboarding should have populated this',
      );
      return;
    }
    // Entitlement first, credentials second. Without Pro there is nothing to
    // sync; without credentials the request would fail at the aggregator. The
    // published build satisfies neither, which is what makes the bank-sync
    // code that ships alongside it inert.
    if (!ref.read(proEntitlementProvider) || !SophtronConfig.isConfigured) {
      Log.w('bank-sync', 'bank sync unavailable in this build; skipping');
      return;
    }
    // Coalesce double-taps. The first runSync flips `state.isLoading`
    // before its first await, so the second pull-to-refresh bails here
    // and waits for the first to finish.
    if (state.isLoading) {
      Log.i('bank-sync', 'runSync already in flight; ignoring re-entry');
      return;
    }
    final userId = auth.userId!;

    // Flip to loading BEFORE the first await so the Cards-screen first-sync
    // UI appears immediately on the frame after the AddBank screen pops.
    state = const AsyncValue.loading();

    // Cross-isolate mutex: blocks background WorkManager from racing this
    // call. Returns a fencing token, or null when a *live* sync already
    // owns the lock (acquire only fails on a still-heartbeating holder;
    // a crashed run's stale lock is stolen here transparently).
    int? lockToken = await _repo.acquireSyncLock(userId, holder: 'foreground');
    if (lockToken == null) {
      // A live sync is already running for this user. Don't fake success
      // and leave the list stale (the old bug) — follow that run to the
      // finish line so the pull-to-refresh spinner stays up honestly,
      // then pull its freshly-written data into the UI. If it stops
      // heartbeating we treat it as crashed and take over.
      Log.i('bank-sync', 'lock held by a live sync; coalescing');
      final outcome = await _followRunningSync(userId);
      if (outcome == _CoalesceOutcome.finished) {
        Log.i('bank-sync', 'in-flight sync finished; refreshing data');
        for (final p in syncInvalidatedProviders) {
          ref.invalidate(p);
        }
        // That run (another isolate) may have re-hydrated the catalog; we
        // can't tell from here, so refresh the snapshot so rankings aren't
        // stale. See the own-run path below for the full rationale.
        ref.invalidate(catalogSnapshotProvider);
        state = const AsyncValue.data(BankSyncState());
        return;
      }
      // The run stopped heartbeating — it crashed. Steal the now-stale
      // lock and run ourselves so the user's pull actually recovers.
      Log.w('bank-sync', 'in-flight sync went stale; stealing lock');
      lockToken = await _repo.acquireSyncLock(userId, holder: 'foreground');
      if (lockToken == null) {
        // Another foreground waiter stole it first; let their run own the
        // refresh and just surface its eventual data.
        for (final p in syncInvalidatedProviders) {
          ref.invalidate(p);
        }
        ref.invalidate(catalogSnapshotProvider);
        state = const AsyncValue.data(BankSyncState());
        return;
      }
    }

    final includeDebit = await _settings.getIncludeDebitAccounts(userId);
    final t0 = DateTime.now();
    final bankStatuses = <String, MemberCompleted>{};
    int? memberCount;
    final runId = await _repo.startSyncRun(
      userId: userId,
      trigger: 'foreground',
    );

    // Post-link sync: the Add Bank screen hands the link-progress
    // notification (and its backing Android foreground service) to us
    // here. Refresh it to a "syncing your cards" message so the
    // service stays foreground through this run — without that the
    // OS would put the Dart isolate to sleep mid-sync when the user
    // backgrounds the app, and the per-account fetches would all hit
    // `Failed host lookup`. Dismissed in `finally` regardless of
    // outcome so we always release the service hold.
    final ownsLinkNotification = waitForMemberId != null;
    if (ownsLinkNotification) {
      // ignore: unawaited_futures
      LinkProgressNotifier.show(
        title: 'Setting up your cards',
        body: 'Loading accounts and recent transactions…',
        alert: false,
      );
    }

    // Was this user's first-ever successful sync done? Drives whether
    // the engine's orphan-cleanup pass is allowed to run — see the
    // comment block on that pass for why the gate exists. Read here
    // (not inside the engine) so the engine stays free of DB concerns.
    final firstSyncCompleted = await _repo.isFirstSyncCompleted(userId);

    try {
      final result = await _engine.run(
        userId: userId,
        bankCustomerId: uniqueId,
        firstSyncCompleted: firstSyncCompleted,
        includeDebitAccounts: includeDebit,
        // Every caller of this notifier is a foreground user gesture
        // (pull-to-refresh, retry button, add-bank, debit toggle), so the
        // re-scrape throttle is bypassed per the engine's documented
        // user-initiated contract. The background WorkManager path calls the
        // engine directly with forceRefresh: false and keeps the throttle.
        forceRefresh: true,
        waitForMemberId: waitForMemberId,
        onProgress: (event) {
          // Keep the lock's heartbeat fresh so a concurrent pull or the
          // background tick recognises this run as alive and coalesces
          // rather than stealing the lock mid-sync.
          // ignore: unawaited_futures
          _repo.heartbeatSyncLock(userId, acquiredAtToken: lockToken!);
          if (event is MemberCompleted) {
            bankStatuses[event.memberId] = event;
          }
          if (event is MembersListed) {
            // Cache the denominator early so the sticky banner can show
            // "Syncing X of Y banks…" from the moment fan-out begins
            // rather than waiting for the first MemberCompleted.
            memberCount = event.count;
          }
          final prev = state.hasValue ? state.value : null;
          state = AsyncValue.data(
            BankSyncState(
              result: prev?.result,
              lastProgress: event,
              bankStatuses: Map.unmodifiable(bankStatuses),
              memberCount: memberCount,
            ),
          );
        },
      );

      // Catalog layer: hydrate the bundled catalog, then (re)bind synced cards
      // to catalog products + canonicalize their names/art. This is what gives
      // each card its rewards, perks, and recommendations. Failures here must
      // not fail the sync.
      var catalogChanged = false;
      try {
        final hydrate = await _catalogLoader.hydrateIfNeeded(userId);
        catalogChanged = hydrate == CatalogLoadResult.loaded;
        await _cardLinks.seedLinks(userId);
      } catch (e) {
        Log.w('bank-sync', 'catalog link seeding failed (non-fatal)', e);
      }

      await _settings.setLastSyncAt(userId, DateTime.now().toUtc());
      await _repo.finishSyncRun(
        runId: runId,
        memberCount: bankStatuses.length,
        cardCount: result.cardCount,
        txCount: result.txCount,
        errorCount: result.errors.length,
        outcome: result.errors.isEmpty ? 'ok' : 'partial',
      );

      // Flip `users.first_sync_completed_at` once. From the next sync
      // onward the engine's orphan-cleanup pass is allowed to run; on
      // this run it was skipped if `firstSyncCompleted == false` so
      // the local empty-DB doesn't get misread as "the user has no
      // banks." Stamp it even on partial outcomes — at least one
      // Member made it through, the user is past the recovery window.
      if (!firstSyncCompleted) {
        await _repo.markFirstSyncCompleted(
          userId: userId,
          at: DateTime.now().toUtc(),
        );
      }

      // Re-fire data providers - they read tables we just wrote.
      for (final p in syncInvalidatedProviders) {
        ref.invalidate(p);
      }
      // The catalog snapshot is opt-out of that list (it's the global catalog,
      // not user sync data), but this sync just re-hydrated it. When the bundle
      // actually changed, refresh the in-memory snapshot so the engine ranks
      // off the new catalog instead of the boot-time copy — otherwise catalog
      // fixes only reach rankings on a full app restart.
      if (catalogChanged) {
        ref.invalidate(catalogSnapshotProvider);
      }

      state = AsyncValue.data(
        BankSyncState(
          result: result,
          lastProgress: SyncCompleted(result),
          bankStatuses: Map.unmodifiable(bankStatuses),
          memberCount: memberCount,
        ),
      );
      final ms = DateTime.now().difference(t0).inMilliseconds;
      Log.i(
        'bank-sync',
        'completed in ${ms}ms: cards=${result.cardCount} '
            'txs=${result.txCount} errors=${result.errors.length}',
      );
    } catch (e, st) {
      Log.e('bank-sync', 'sync failed', e, st);
      // A protocol exception means Sophtron's response no longer matches what
      // BankClient parses — an aggregator-side API change, not the usual
      // network/auth failure. It needs its own Crashlytics reason so it isn't
      // buried in the `sync_failed` bucket: one is "a sync didn't work", the
      // other is "our integration is broken for everyone".
      final reason = e is SophtronProtocolException
          ? 'sophtron_protocol_drift'
          : 'sync_failed';
      // ignore: unawaited_futures
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: reason,
        fatal: false,
      );
      await _repo.finishSyncRun(
        runId: runId,
        memberCount: bankStatuses.length,
        cardCount: 0,
        txCount: 0,
        errorCount: 1,
        outcome: 'failed',
      );
      state = AsyncValue.error(e, st);
    } finally {
      // Token-scoped: if our lock was stolen mid-run (we stalled past the
      // liveness window and another sync took over), this is a no-op so we
      // don't yank the new holder's lock out from under it.
      await _repo.releaseSyncLock(userId, acquiredAtToken: lockToken);
      if (ownsLinkNotification) {
        // ignore: unawaited_futures
        LinkProgressNotifier.dismiss();
      }
    }
  }

  /// Watches a sync that another isolate (background tick) or a previous
  /// foreground call is already running, while our own pull-to-refresh
  /// spinner stays up. Resolves [_CoalesceOutcome.finished] when that run
  /// releases the lock (its writes are committed — caller refreshes the
  /// data providers), or [_CoalesceOutcome.stale] when its heartbeat
  /// lapses (it crashed — caller steals the lock and runs itself).
  Future<_CoalesceOutcome> _followRunningSync(String userId) async {
    const pollInterval = Duration(seconds: 2);
    // Backstop so a wedged-but-heartbeating run can't pin the spinner
    // forever. Comfortably above a normal multi-bank sync; a genuinely
    // dead run is caught far sooner by the liveness check below.
    const maxWait = Duration(minutes: 3);
    final deadline = DateTime.now().add(maxWait);
    while (DateTime.now().isBefore(deadline)) {
      final lock = await _repo.readSyncLock(userId);
      if (lock == null) return _CoalesceOutcome.finished;
      if (lock.isStale) return _CoalesceOutcome.stale;
      await Future<void>.delayed(pollInterval);
    }
    // Hit the backstop without a verdict — treat as finished and let the
    // caller refresh whatever's been written so far.
    return _CoalesceOutcome.finished;
  }
}

/// Result of [BankSyncNotifier._followRunningSync].
enum _CoalesceOutcome {
  /// The in-flight sync released the lock cleanly; its data is committed.
  finished,

  /// The in-flight sync stopped heartbeating; it looks crashed and the
  /// caller should steal the lock and run itself.
  stale,
}

final bankSyncProvider =
    NotifierProvider<BankSyncNotifier, AsyncValue<BankSyncState>>(
      BankSyncNotifier.new,
    );
