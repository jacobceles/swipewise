import '../api/data_repository.dart';
import '../api/database_helper.dart';
import '../api/remote_asset_service.dart';
import '../api/reward_category_mapper.dart';
import '../api/settings_repository.dart';
import '../api/sophtron_auth_service.dart';
import '../util/logger.dart';
import 'bank_sync_engine.dart';

/// The body of the WorkManager background tick, split out of
/// `background_sync.dart` so the free build never reaches it.
///
/// The dispatcher that calls this is `@pragma('vm:entry-point')`, which makes
/// it a permanent tree-shake root — everything reachable from it stays in the
/// binary no matter how it is guarded internally. Keeping the body here, and
/// reaching it only through the `backgroundSyncTask` hook, keeps
/// `background_sync.dart` free of engine and aggregator imports.
///
/// ⚠️ That is a structural improvement, not a complete excision — see the note
/// on `backgroundSyncTask`. Free builds never assign the hook and never
/// register with WorkManager, so this never runs there.
///
/// Notes from audit B5, unchanged by the move:
///
/// - The 0–10 min Dart-side `Future.delayed` jitter was moved to
///   `setInitialDelay` on the periodic registration (see
///   `AutoSyncNotifier._applyToWorkManager`). Sleeping inside the
///   dispatcher held the worker process alive and risked the
///   foreground-service requirement on Android 12+; the system-managed
///   `setInitialDelay` doesn't.
/// - The auto-sync setting is checked *before* opening the DB so a
///   disabled feature doesn't spin up sqflite at all.
/// - A cross-isolate sync mutex (`DataRepository.acquireSyncLock`) gates
///   the engine call so a foreground pull-to-refresh and the background
///   tick can't double-write to the same SQLite database.
Future<bool> runBankBackgroundSync() async {
  if (!SophtronConfig.isConfigured) {
    Log.w('bg-sync', 'Sophtron creds not baked in; skipping');
    return true;
  }
  try {
    // The classifier registries are per-isolate in-memory state; this
    // dispatcher runs in its own isolate. Without loading them, the sync
    // engine classifies every transaction as `other` and misses all brand
    // matches — and those wrong categories get PERSISTED. (Same root cause
    // as the background-geofence "United Explorer at a restaurant" bug.)
    final remoteAssets = RemoteAssetService();
    await initBrandRegistry(remote: remoteAssets);
    await initCategoryRegistry(remote: remoteAssets);

    final dbHelper = DatabaseHelper();
    final repo = DataRepository();
    final settings = SettingsRepository(repo);
    final engine = BankSyncEngine(repo);
    final db = await dbHelper.database;
    final users = await db.query('users');

    for (final user in users) {
      final userId = user['id'] as String;
      final uniqueId = user['bank_customer_id'] as String?;
      if (uniqueId == null || uniqueId.isEmpty) {
        // Pre-shareability user row that doesn't have a Customer
        // uniqueId yet. Skip — foreground onboarding stamps the
        // column the next time the user opens the app.
        Log.w(
          'bg-sync',
          'skipping user $userId: no Sophtron Customer uniqueId on row',
        );
        continue;
      }
      final autoSync = await settings.getAutoSync(userId);
      if (!autoSync) continue;

      final lockToken = await repo.acquireSyncLock(
        userId,
        holder: 'background',
      );
      if (lockToken == null) {
        Log.i(
          'bg-sync',
          'skipping user $userId: another sync is already in progress',
        );
        continue;
      }

      final firstSyncCompleted = await repo.isFirstSyncCompleted(userId);
      final runId = await repo.startSyncRun(
        userId: userId,
        trigger: 'background',
      );
      try {
        final result = await engine.run(
          userId: userId,
          bankCustomerId: uniqueId,
          firstSyncCompleted: firstSyncCompleted,
          // Background tick: throttle re-scrapes (skip if a member was
          // refreshed recently) to respect issuer rate limits.
          forceRefresh: false,
          // Keep the lock's heartbeat fresh as the engine makes
          // progress so a foreground pull-to-refresh recognises this
          // run as alive and coalesces instead of stealing it. Stops
          // beating the moment the lock is stolen (token mismatch).
          onProgress: (_) {
            // ignore: unawaited_futures
            repo.heartbeatSyncLock(userId, acquiredAtToken: lockToken);
          },
        );
        if (!firstSyncCompleted) {
          await repo.markFirstSyncCompleted(
            userId: userId,
            at: DateTime.now().toUtc(),
          );
        }
        await repo.finishSyncRun(
          runId: runId,
          memberCount: 0,
          cardCount: result.cardCount,
          txCount: result.txCount,
          errorCount: result.errors.length,
          outcome: result.errors.isEmpty ? 'ok' : 'partial',
        );
      } catch (e, stack) {
        Log.e('bg-sync', 'failed for user $userId', e, stack);
        await repo.finishSyncRun(
          runId: runId,
          memberCount: 0,
          cardCount: 0,
          txCount: 0,
          errorCount: 1,
          outcome: 'failed',
        );
      } finally {
        await repo.releaseSyncLock(userId, acquiredAtToken: lockToken);
      }
    }
    return true;
  } catch (e, stack) {
    Log.e('bg-sync', 'dispatcher failed', e, stack);
    // false → WorkManager backs off and retries. We only return false
    // for setup-level failures (DB open, etc.) — per-user sync errors
    // are caught above and don't trigger a retry of the whole batch.
    return false;
  }
}
