import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

/// Owns the small ops tables that aren't really "data" but coordinate
/// sync runs and per-service circuit breakers across foreground +
/// background isolates:
///
/// - `sync_state` — per-user advisory lock so foreground and WorkManager
///   can't race the engine.
/// - `sync_runs` — per-run timing + outcome rows powering diagnostics.
/// - `api_circuit_breakers` — cross-isolate breaker state for external
///   APIs (Google Places, Sophtron, etc.).
///
/// Stateless; safe to instantiate per-use, but `DataRepository` keeps a
/// long-lived instance so callers don't allocate per call.
class SyncStateRepository {
  SyncStateRepository(this._dbHelper);
  final DatabaseHelper _dbHelper;

  // ───────────── sync mutex ─────────────

  /// Liveness window for a held lock. The holder bumps `heartbeat_at` as
  /// it makes progress; once the last heartbeat is older than this, the
  /// lock is considered dead and [acquireSyncLock] will steal it. Sized
  /// generously above the per-bank fetch cadence so a healthy multi-bank
  /// sync never trips it, but short enough that a crashed run is
  /// recoverable on the next pull-to-refresh.
  static const Duration syncLockLiveness = Duration(seconds: 60);

  /// Hard backstop on total hold time. Even if a wedged run keeps
  /// heartbeating in a tight retry loop, the lock becomes stealable once
  /// it has been held this long.
  static const Duration syncLockTtl = Duration(minutes: 15);

  /// A held lock's coordinates. [isStale] is the steal predicate shared
  /// by the acquire path and the foreground coalesce/recover decision.
  bool _isStale(int acquiredAtMs, int heartbeatAtMs, int nowMs) =>
      nowMs - heartbeatAtMs >= syncLockLiveness.inMilliseconds ||
      nowMs - acquiredAtMs >= syncLockTtl.inMilliseconds;

  /// Tries to take the per-user sync mutex. Returns the fencing token (the
  /// acquire timestamp, ms-epoch) when acquired — either the lock was free
  /// or the previous holder's heartbeat went stale (a crashed run) and we
  /// stole it. Returns null when a live holder is still beating inside
  /// [syncLockLiveness]. Pass the token to [heartbeatSyncLock] /
  /// [releaseSyncLock] so a stolen-out run can't touch the new holder's row.
  Future<int?> acquireSyncLock(
    String userId, {
    required String holder,
    DateTime? now,
  }) async {
    final db = await _dbHelper.database;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'sync_state',
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final acquiredAt = (existing.first['acquired_at'] as num).toInt();
        final heartbeatAt =
            (existing.first['heartbeat_at'] as num?)?.toInt() ?? acquiredAt;
        if (!_isStale(acquiredAt, heartbeatAt, nowMs)) return null;
      }
      // acquired_at doubles as the holder's fencing token: heartbeats and
      // release only touch the row while it still carries this value, so a
      // run whose lock was stolen out from under it can't resurrect or
      // delete the new holder's lock.
      await txn.insert('sync_state', {
        'user_id': userId,
        'acquired_at': nowMs,
        'heartbeat_at': nowMs,
        'holder': holder,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return nowMs;
    });
  }

  /// Bumps `heartbeat_at` to keep a held lock alive while a run is making
  /// progress. No-op if the lock has since been stolen (the row no longer
  /// carries this holder's [acquiredAtToken]).
  Future<void> heartbeatSyncLock(
    String userId, {
    required int acquiredAtToken,
    DateTime? now,
  }) async {
    final db = await _dbHelper.database;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await db.update(
      'sync_state',
      {'heartbeat_at': nowMs},
      where: 'user_id = ? AND acquired_at = ?',
      whereArgs: [userId, acquiredAtToken],
    );
  }

  /// Current lock holder for [userId], or null if the lock is free.
  /// `isStale` reflects whether a fresh [acquireSyncLock] would steal it
  /// (heartbeat lapsed or hard-cap exceeded) — i.e. the run looks dead.
  Future<({String holder, int acquiredAt, int heartbeatAt, bool isStale})?>
  readSyncLock(String userId, {DateTime? now}) async {
    final db = await _dbHelper.database;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await db.query(
      'sync_state',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final acquiredAt = (rows.first['acquired_at'] as num).toInt();
    final heartbeatAt =
        (rows.first['heartbeat_at'] as num?)?.toInt() ?? acquiredAt;
    return (
      holder: rows.first['holder'] as String,
      acquiredAt: acquiredAt,
      heartbeatAt: heartbeatAt,
      isStale: _isStale(acquiredAt, heartbeatAt, nowMs),
    );
  }

  /// Releases the lock. Scoped to [acquiredAtToken] when provided so a run
  /// whose lock was already stolen doesn't delete the new holder's row;
  /// pass null to force-clear regardless of holder.
  Future<void> releaseSyncLock(String userId, {int? acquiredAtToken}) async {
    final db = await _dbHelper.database;
    if (acquiredAtToken == null) {
      await db.delete('sync_state', where: 'user_id = ?', whereArgs: [userId]);
    } else {
      await db.delete(
        'sync_state',
        where: 'user_id = ? AND acquired_at = ?',
        whereArgs: [userId, acquiredAtToken],
      );
    }
  }

  // ───────────── sync_runs ─────────────

  /// Records the start of a sync run. Returns the `run_id` the caller
  /// passes to [finishSyncRun].
  Future<String> startSyncRun({
    required String userId,
    required String trigger, // 'foreground' | 'background' | 'reconnect'
  }) async {
    final db = await _dbHelper.database;
    final runId = sha1
        .convert(
          utf8.encode('$userId|$trigger|${DateTime.now().toIso8601String()}'),
        )
        .toString()
        .substring(0, 16);
    await db.insert('sync_runs', {
      'run_id': runId,
      'user_id': userId,
      'trigger': trigger,
      'started_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _pruneSyncRuns(db, userId);
    return runId;
  }

  Future<void> finishSyncRun({
    required String runId,
    required int memberCount,
    required int cardCount,
    required int txCount,
    required int errorCount,
    required String outcome, // 'ok' | 'failed' | 'partial'
    Map<String, dynamic>? membersJson,
  }) async {
    final db = await _dbHelper.database;
    await db.update(
      'sync_runs',
      {
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'member_count': memberCount,
        'card_count': cardCount,
        'tx_count': txCount,
        'error_count': errorCount,
        'outcome': outcome,
        'members_json': membersJson == null ? null : jsonEncode(membersJson),
      },
      where: 'run_id = ?',
      whereArgs: [runId],
    );
  }

  /// Bounds the per-user run history at 100 rows. Older runs are deleted
  /// on each fresh start.
  Future<void> _pruneSyncRuns(Database db, String userId) async {
    await db.rawDelete(
      '''
      DELETE FROM sync_runs
      WHERE user_id = ? AND run_id NOT IN (
        SELECT run_id FROM sync_runs
        WHERE user_id = ?
        ORDER BY started_at DESC
        LIMIT 100
      )
      ''',
      [userId, userId],
    );
  }

  // ───────────── circuit breaker ─────────────

  /// Returns the current breaker state for [service]. `openedUntil`
  /// non-null means the breaker is OPEN until that ms-epoch; callers
  /// should fast-fail instead of calling the upstream.
  Future<({int failureCount, int? openedUntil})> getCircuitBreaker(
    String service,
  ) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'api_circuit_breakers',
      where: 'service = ?',
      whereArgs: [service],
      limit: 1,
    );
    if (rows.isEmpty) return (failureCount: 0, openedUntil: null);
    return (
      failureCount: (rows.first['failure_count'] as num).toInt(),
      openedUntil: (rows.first['opened_until'] as num?)?.toInt(),
    );
  }

  /// Increments the failure counter and, when [threshold] is hit, opens
  /// the breaker for [cooldown]. Returns the new state.
  Future<({int failureCount, int? openedUntil})> recordCircuitBreakerFailure(
    String service, {
    required int threshold,
    required Duration cooldown,
    DateTime? now,
  }) async {
    final db = await _dbHelper.database;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'api_circuit_breakers',
        where: 'service = ?',
        whereArgs: [service],
        limit: 1,
      );
      final prevCount = existing.isEmpty
          ? 0
          : (existing.first['failure_count'] as num).toInt();
      final nextCount = prevCount + 1;
      int? openedUntil;
      if (nextCount >= threshold) {
        openedUntil = nowMs + cooldown.inMilliseconds;
      }
      await txn.insert('api_circuit_breakers', {
        'service': service,
        'failure_count': nextCount,
        'opened_until': openedUntil,
        'last_failure_at': nowMs,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return (failureCount: nextCount, openedUntil: openedUntil);
    });
  }

  /// Resets the breaker — call on a successful upstream response.
  Future<void> resetCircuitBreaker(String service) async {
    final db = await _dbHelper.database;
    await db.delete(
      'api_circuit_breakers',
      where: 'service = ?',
      whereArgs: [service],
    );
  }
}
