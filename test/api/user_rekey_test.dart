import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/backup_provider.dart';
import 'package:swipewise/providers/bank_sync_provider.dart';
import 'package:swipewise/sync/wallet_backup_client.dart';

/// Pins [DatabaseHelper.reassignUserId] — the free → Pro upgrade path.
///
/// A free user's identity is a device-local UUID. When they sign in, every row
/// they own has to follow them onto the Firebase UID in one transaction. Miss a
/// table and that slice of their wallet is orphaned under an id nothing reads
/// again; the user sees data silently disappear and no error is raised
/// anywhere. So the interesting assertion is not "it moved the cards" but
/// "it moved *everything*, and this test knows what everything is".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    final original = FirebaseAuthPlatform.instance;
    FirebaseAuthPlatform.instance = _SignOutAuth();
    addTearDown(() => FirebaseAuthPlatform.instance = original);
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (_) async => true,
        );
    DatabaseHelper.setTestDatabaseFactory(
      () => databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      ),
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    final db = await DatabaseHelper().database;
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  test(
    'kUserScopedTables is exactly the set of tables keyed on user_id',
    () async {
      final db = await DatabaseHelper().database;
      final tables = await db.query(
        'sqlite_master',
        columns: ['name'],
        where: "type = 'table' AND name NOT LIKE 'sqlite_%'",
      );

      final actual = <String>{};
      for (final row in tables) {
        final name = row['name'] as String;
        final columns = await db.rawQuery('PRAGMA table_info($name)');
        if (columns.any((c) => c['name'] == 'user_id')) actual.add(name);
      }

      expect(
        actual,
        kUserScopedTables.toSet(),
        reason:
            'A user-scoped table was added or removed without updating '
            'kUserScopedTables. reassignUserId rewrites only what is in that '
            'list, so a table missing from it is silently orphaned the first '
            'time a free user upgrades to Pro.',
      );
    },
  );

  test(
    're-key moves every user-scoped table and leaves nothing behind',
    () async {
      final db = await DatabaseHelper().database;
      await db.insert('users', {
        'id': 'local:aaaa',
        'identifier': 'You',
        'first_sync_completed_at': '2026-01-01T00:00:00Z',
        'auth_time': 1700000000,
      });
      for (final table in kUserScopedTables) {
        await db.insert(table, await _minimalRow(db, table, 'local:aaaa'));
      }
      await db.insert('users', {'id': 'u2', 'identifier': 'Bystander'});
      final bystander = <String, List<Map<String, Object?>>>{};
      for (final table in kUserScopedTables) {
        final row = await _minimalRow(db, table, 'u2');
        if (row['id'] is String) row['id'] = '${row['id']}-u2';
        if (table == 'sync_runs') row['run_id'] = '${row['run_id']}-u2';
        await db.insert(table, row);
        bystander[table] = await db.query(
          table,
          where: 'user_id = ?',
          whereArgs: ['u2'],
        );
      }

      await DatabaseHelper().reassignUserId(from: 'local:aaaa', to: 'uid-bbbb');
      for (final table in kUserScopedTables) {
        expect(
          await db.query(table, where: 'user_id = ?', whereArgs: ['u2']),
          bystander[table],
          reason: table,
        );
      }

      for (final table in kUserScopedTables) {
        expect(
          await _countFor(db, table, 'uid-bbbb'),
          1,
          reason: '$table did not follow the user onto the new id',
        );
        expect(
          await _countFor(db, table, 'local:aaaa'),
          0,
          reason: '$table still holds rows orphaned under the old id',
        );
      }

      final users = await db.query(
        'users',
        where: 'id != ?',
        whereArgs: ['u2'],
      );
      expect(users, hasLength(1), reason: 'the old identity must be retired');
      expect(users.single['id'], 'uid-bbbb');
      expect(
        users.single['first_sync_completed_at'],
        '2026-01-01T00:00:00Z',
        reason: 'the destination row inherits the source row, it is not a stub',
      );
    },
  );

  test('re-key is a no-op when the source identity does not exist', () async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'uid-bbbb', 'identifier': 'Pro'});

    await DatabaseHelper().reassignUserId(from: 'local:nope', to: 'uid-bbbb');

    expect(await db.query('users'), hasLength(1));
  });

  test('re-key from an id onto itself changes nothing', () async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'local:aaaa', 'identifier': 'You'});
    await db.insert('cards', await _minimalRow(db, 'cards', 'local:aaaa'));

    await DatabaseHelper().reassignUserId(from: 'local:aaaa', to: 'local:aaaa');

    expect(await _countFor(db, 'cards', 'local:aaaa'), 1);
    expect(await db.query('users'), hasLength(1));
  });

  test('an existing destination is refused before re-keying', () async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'local:aaaa', 'identifier': 'You'});
    await db.insert('users', {'id': 'uid-bbbb', 'identifier': 'Pro'});

    // Same primary key (user_id, key) on both sides — a merge, not a re-key.
    await db.insert('settings', {
      'user_id': 'local:aaaa',
      'key': 'default_screen',
      'value': '1',
    });

    await db.insert('settings', {
      'user_id': 'uid-bbbb',
      'key': 'default_screen',
      'value': '0',
    });

    await expectLater(
      DatabaseHelper().reassignUserId(from: 'local:aaaa', to: 'uid-bbbb'),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      await _countFor(db, 'settings', 'local:aaaa'),
      1,
      reason: 'the transaction must roll back rather than half-migrate',
    );
  });

  test(
    'a failure after cards move rolls back every table and identity',
    () async {
      final db = await DatabaseHelper().database;
      await db.insert('users', {'id': 'local:aaaa', 'identifier': 'You'});
      for (final table in kUserScopedTables) {
        await db.insert(table, await _minimalRow(db, table, 'local:aaaa'));
      }
      await db.execute('''
CREATE TRIGGER fail_settings_move BEFORE UPDATE OF user_id ON settings
WHEN NEW.user_id = 'uid-bbbb'
BEGIN
  SELECT RAISE(ABORT, 'injected re-key failure');
END
''');
      await expectLater(
        DatabaseHelper().reassignUserId(from: 'local:aaaa', to: 'uid-bbbb'),
        throwsA(
          isA<DatabaseException>().having(
            (e) => e.toString(),
            'message',
            contains('injected re-key failure'),
          ),
        ),
      );
      expect((await db.query('users')).map((r) => r['id']), ['local:aaaa']);
      for (final table in kUserScopedTables) {
        expect(await _countFor(db, table, 'local:aaaa'), 1, reason: table);
        expect(await _countFor(db, table, 'uid-bbbb'), 0, reason: table);
      }
    },
  );

  // Not testing our code — pinning the SQLite behaviour that dictates it.
  // `AuthNotifier.signInWithGoogle` deliberately does update-then-insert on
  // `users` instead of `ConflictAlgorithm.replace`; this is why. If SQLite ever
  // stopped cascading through a REPLACE, that comment would be misleading.
  test('REPLACE on users cascades and destroys the wallet', () async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'uid-bbbb', 'identifier': 'Pro'});
    await db.insert('cards', await _minimalRow(db, 'cards', 'uid-bbbb'));

    await db.insert('users', {
      'id': 'uid-bbbb',
      'identifier': 'Pro (again)',
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    expect(
      await _countFor(db, 'cards', 'uid-bbbb'),
      0,
      reason:
          'REPLACE is DELETE + INSERT, and every user-scoped table cascades '
          'on delete — which is why sign-in must never use it',
    );
  });

  test(
    'sign-out wipes the wallet and creates an empty guest for the next account',
    () async {
      final db = await DatabaseHelper().database;
      await db.insert('users', {
        'id': 'uid-bbbb',
        'identifier': 'Jacob',
        'email': 'someone@example.com',
        'bank_customer_id': 'derived-customer-id',
        'auth_time': 1700000000,
      });
      for (final table in kUserScopedTables) {
        await db.insert(table, await _minimalRow(db, table, 'uid-bbbb'));
      }
      const globalWalletTables = [
        'muted_merchants',
        'store_picks',
        'user_bonus_selections',
        'active_geofences',
        'boundary_geofence',
        'merchant_notification_cooldown',
        'category_notification_cooldown',
      ];
      for (final table in globalWalletTables) {
        await db.insert(table, await _minimalRow(db, table, null));
      }
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.appsoflife/geofence'),
            (call) async {
              nativeCalls.add(call.method);
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.appsoflife/geofence'),
              null,
            ),
      );
      await db.insert('settings', {
        'user_id': 'uid-bbbb',
        'key': 'onboarding_seen',
        'value': 'true',
      });
      const privateKeys = [
        'pro_cached',
        'backup_enabled',
        'backup_fingerprint',
        'last_backup_at',
        'backup_held_cards',
      ];
      for (final key in privateKeys) {
        await db.insert('settings', {
          'user_id': 'uid-bbbb',
          'key': key,
          'value': 'true',
        });
      }

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final auth = container.read(authProvider.notifier);
      await auth.checkStatus();
      await pumpEventQueue();
      await auth.logout();
      expect(nativeCalls, contains('clearAccountState'));
      for (final table in globalWalletTables) {
        expect(await db.query(table), isEmpty, reason: table);
      }
      final localId = container.read(authProvider).userId!;
      expect(localId, startsWith(kLocalUserIdPrefix));
      // An old foreground/background sync cannot write against a retired owner.
      await expectLater(
        db.insert('cards', {
          'id': 'late-sync',
          'user_id': 'uid-bbbb',
          'name': 'Old account',
          'source': 'manual',
        }),
        throwsA(
          isA<DatabaseException>().having(
            (e) => e.toString(),
            'error',
            contains('FOREIGN KEY'),
          ),
        ),
      );

      for (final table in kUserScopedTables) {
        expect(
          await _countFor(db, table, localId),
          0,
          reason: '$table must not follow sign-out into the guest wallet',
        );
        expect(await _countFor(db, table, 'uid-bbbb'), 0, reason: table);
      }
      final settings = await db.query(
        'settings',
        where: 'user_id = ?',
        whereArgs: [localId],
      );
      expect(
        settings.map((r) => r['key']),
        isNot(anyElement(isIn(privateKeys))),
      );

      final onboarding = await db.query(
        'settings',
        where: 'user_id = ? AND key = ?',
        whereArgs: [localId, 'onboarding_seen'],
      );
      expect(onboarding, isEmpty);

      final user = (await db.query('users')).single;
      expect(user['id'], localId);
      expect(
        user['email'],
        isNull,
        reason: 'sign-out must clear the Google identity',
      );
      expect(
        user['bank_customer_id'],
        isNull,
        reason: 'the derived Customer id is meaningless without the email',
      );
      // B signing in must not inherit ANY of A's wallet.
      await DatabaseHelper().reassignUserId(from: localId, to: 'uid-other');
      for (final table in kUserScopedTables) {
        expect(await _countFor(db, table, 'uid-other'), 0, reason: table);
      }
      expect(
        await db.query(
          'settings',
          where: 'user_id = ? AND key IN (?, ?, ?, ?, ?)',
          whereArgs: ['uid-other', ...privateKeys],
        ),
        isEmpty,
      );
    },
  );

  test(
    'logout waits for a pending restore and discards its old response',
    () async {
      final db = await DatabaseHelper().database;
      await db.insert('users', {'id': 'uid-bbbb', 'identifier': 'Account'});
      final client = _PendingBackup();
      final container = ProviderContainer(
        overrides: [walletBackupClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      final auth = container.read(authProvider.notifier);
      await auth.checkStatus();
      await pumpEventQueue();
      final controller = container.read(walletBackupControllerProvider);
      final restoring = controller.restoreNow();
      await client.started.future;
      var finished = false;
      final logout = auth.logout().then((_) => finished = true);
      await pumpEventQueue();
      expect(finished, isFalse);
      expect(container.read(authProvider).userId, isNull);
      client.response.complete(const BackupResult(BackupStatus.empty));
      expect(await restoring, RestoreOutcome.unavailable);
      await logout;
      expect(
        container.read(authProvider).userId,
        startsWith(kLocalUserIdPrefix),
      );
      expect(await db.query('cards'), isEmpty);
    },
  );

  test('logout drains active bank sync before retiring its owner', () async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'uid-bbbb', 'identifier': 'Account'});
    final sync = _PendingSync();
    final container = ProviderContainer(
      overrides: [bankSyncProvider.overrideWith(() => sync)],
    );
    addTearDown(container.dispose);
    final auth = container.read(authProvider.notifier);
    await auth.checkStatus();
    await pumpEventQueue();
    final logout = auth.logout();
    await sync.started.future;
    expect(container.read(authProvider).userId, isNull);
    expect((await db.query('users')).single['id'], 'uid-bbbb');
    // A write from the existing run finishes before the cascade, never after
    // a same-Firebase-UID re-login can make that owner valid again.
    await db.insert('cards', {
      'id': 'last-sync',
      'user_id': 'uid-bbbb',
      'name': 'Old',
      'source': 'manual',
    });
    sync.finished.complete();
    await logout;
    expect(await db.query('cards'), isEmpty);
    expect(container.read(authProvider).userId, startsWith(kLocalUserIdPrefix));
  });
}

class _PendingSync extends BankSyncNotifier {
  final started = Completer<void>();
  final finished = Completer<void>();
  @override
  AsyncValue<BankSyncState> build() => const AsyncData(BankSyncState());
  @override
  Future<void> clearForLogout() {
    started.complete();
    return finished.future;
  }
}

class _PendingBackup extends WalletBackupClient {
  final started = Completer<void>();
  final response = Completer<BackupResult>();
  @override
  Future<BackupResult> pull() {
    started.complete();
    return response.future;
  }
}

class _SignOutAuth extends FirebaseAuthPlatform {
  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseAuthPlatform setInitialValues({
    dynamic currentUser,
    String? languageCode,
  }) => this;

  @override
  Future<void> signOut() async {}
}

Future<int> _countFor(Database db, String table, String userId) async {
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS n FROM $table WHERE user_id = ?',
    [userId],
  );
  return rows.single['n'] as int;
}

/// Builds the smallest legal row for [table] by reading the live schema, so
/// this test keeps working when a column is added rather than failing for a
/// reason that has nothing to do with re-keying.
Future<Map<String, Object?>> _minimalRow(
  Database db,
  String table,
  String? userId,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  final row = <String, Object?>{'user_id': ?userId};
  for (final column in columns) {
    final name = column['name'] as String;
    if (name == 'user_id') continue;
    final required =
        (column['notnull'] as int) == 1 || (column['pk'] as int) > 0;
    if (!required || column['dflt_value'] != null) continue;
    row[name] = switch ((column['type'] as String).toUpperCase()) {
      'INTEGER' => 1,
      'REAL' => 1.0,
      _ => 'seed-$table-$name',
    };
  }
  return row;
}
