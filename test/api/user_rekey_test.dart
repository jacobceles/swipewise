import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';

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

  setUp(() async {
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

      await DatabaseHelper().reassignUserId(from: 'local:aaaa', to: 'uid-bbbb');

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

      final users = await db.query('users');
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

  test('a colliding destination rolls the whole re-key back', () async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'local:aaaa', 'identifier': 'You'});
    await db.insert('users', {'id': 'uid-bbbb', 'identifier': 'Pro'});

    // Same primary key (user_id, key) on both sides — a merge, not a re-key.
    await db.insert('settings', {
      'user_id': 'local:aaaa',
      'key': 'auto_sync',
      'value': '1',
    });
    await db.insert('settings', {
      'user_id': 'uid-bbbb',
      'key': 'auto_sync',
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
  String userId,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  final row = <String, Object?>{'user_id': userId};
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
