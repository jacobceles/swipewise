import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/sync_state_repository.dart';

/// Pins the heartbeat-based sync mutex that lets a foreground pull-to-refresh
/// coalesce with (rather than fake-succeed over) a live sync, and steal the
/// lock only from a run that has actually stopped heartbeating.
///
/// All timing is injected via the `now:` params so the suite never sleeps.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUp(() {
    DatabaseHelper.setTestDatabaseFactory(() async {
      return databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      );
    });
  });

  tearDown(() async {
    final db = await DatabaseHelper().database;
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<void> seedUser(String userId) async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': userId, 'identifier': '$userId@test'});
  }

  final liveness = SyncStateRepository.syncLockLiveness;
  final ttl = SyncStateRepository.syncLockTtl;
  final t0 = DateTime.utc(2026, 1, 1, 12);

  test(
    'first acquire returns a token; a live second acquire returns null',
    () async {
      await seedUser('u1');
      final repo = DataRepository();

      final token = await repo.acquireSyncLock(
        'u1',
        holder: 'background',
        now: t0,
      );
      expect(token, isNotNull);

      final second = await repo.acquireSyncLock(
        'u1',
        holder: 'foreground',
        now: t0.add(const Duration(seconds: 5)),
      );
      expect(second, isNull, reason: 'a still-fresh holder must not be stolen');
    },
  );

  test('heartbeats keep a long-running sync from being stolen', () async {
    await seedUser('u1');
    final repo = DataRepository();

    final token =
        await repo.acquireSyncLock('u1', holder: 'background', now: t0) as int;

    // Beat just inside the liveness window, repeatedly, well past it in total.
    var t = t0;
    for (var i = 0; i < 5; i++) {
      t = t.add(liveness - const Duration(seconds: 5));
      await repo.heartbeatSyncLock('u1', acquiredAtToken: token, now: t);
      final steal = await repo.acquireSyncLock(
        'u1',
        holder: 'foreground',
        now: t,
      );
      expect(
        steal,
        isNull,
        reason:
            'a heartbeating run stays locked at +${t.difference(t0).inSeconds}s',
      );
    }
  });

  test(
    'a run that stops heartbeating is stolen after the liveness window',
    () async {
      await seedUser('u1');
      final repo = DataRepository();

      await repo.acquireSyncLock('u1', holder: 'background', now: t0);

      final justBefore = await repo.acquireSyncLock(
        'u1',
        holder: 'foreground',
        now: t0.add(liveness - const Duration(seconds: 1)),
      );
      expect(justBefore, isNull);

      final afterStale = await repo.acquireSyncLock(
        'u1',
        holder: 'foreground',
        now: t0.add(liveness + const Duration(seconds: 1)),
      );
      expect(afterStale, isNotNull, reason: 'a dead run must be stealable');
    },
  );

  test('hard TTL backstop steals even a still-heartbeating run', () async {
    await seedUser('u1');
    final repo = DataRepository();

    final token =
        await repo.acquireSyncLock('u1', holder: 'background', now: t0) as int;

    final wedged = t0.add(ttl + const Duration(seconds: 1));
    // Fresh heartbeat, but total hold has blown past the hard cap.
    await repo.heartbeatSyncLock('u1', acquiredAtToken: token, now: wedged);
    final steal = await repo.acquireSyncLock(
      'u1',
      holder: 'foreground',
      now: wedged,
    );
    expect(steal, isNotNull);
  });

  test('readSyncLock reports holder and staleness', () async {
    await seedUser('u1');
    final repo = DataRepository();

    expect(await repo.readSyncLock('u1', now: t0), isNull);

    await repo.acquireSyncLock('u1', holder: 'background', now: t0);

    final fresh = await repo.readSyncLock(
      'u1',
      now: t0.add(const Duration(seconds: 5)),
    );
    expect(fresh, isNotNull);
    expect(fresh!.holder, 'background');
    expect(fresh.isStale, isFalse);

    final stale = await repo.readSyncLock(
      'u1',
      now: t0.add(liveness + const Duration(seconds: 1)),
    );
    expect(stale!.isStale, isTrue);
  });

  test(
    'release is token-scoped: a stolen-out run cannot clear the new lock',
    () async {
      await seedUser('u1');
      final repo = DataRepository();

      final firstToken =
          await repo.acquireSyncLock('u1', holder: 'background', now: t0)
              as int;

      // First run stalls; foreground steals it after the liveness window.
      final secondToken =
          await repo.acquireSyncLock(
                'u1',
                holder: 'foreground',
                now: t0.add(liveness + const Duration(seconds: 1)),
              )
              as int;
      expect(secondToken, isNot(firstToken));

      // The zombie first run finally hits its finally{} and releases with its
      // own (now stale) token — this must NOT delete the new holder's lock.
      await repo.releaseSyncLock('u1', acquiredAtToken: firstToken);
      expect(
        await repo.readSyncLock(
          'u1',
          now: t0.add(liveness + const Duration(seconds: 2)),
        ),
        isNotNull,
        reason: 'new holder lock survives the zombie release',
      );

      // The real holder releases with the matching token and frees the lock.
      await repo.releaseSyncLock('u1', acquiredAtToken: secondToken);
      expect(
        await repo.readSyncLock(
          'u1',
          now: t0.add(liveness + const Duration(seconds: 3)),
        ),
        isNull,
      );
    },
  );
}
