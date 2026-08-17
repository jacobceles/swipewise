import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';

/// Pins `_onConfigure`, which nothing else exercises: every other suite goes
/// through `setTestDatabaseFactory`, which opens its own connection and never
/// runs the production pragmas.
///
/// LIMIT, stated so nobody trusts this further than it goes: this asserts the
/// pragmas *take effect*, not that they use the right sqflite call. The crash
/// that prompted it — `execute` on a row-returning PRAGMA — is Android-only,
/// because `execute` there is `SQLiteDatabase.execSQL`, which refuses queries.
/// ffi's sqlite3 runs both happily, so it cannot reproduce that failure. Only
/// a device can.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await DatabaseHelper.configureForTesting(db);
  });

  tearDown(() async => db.close());

  test('foreign keys are enforced', () async {
    // Every ON DELETE CASCADE in the schema is decorative without this, and
    // sqflite defaults it OFF.
    final rows = await db.rawQuery('PRAGMA foreign_keys');
    expect(rows.first.values.first, 1);
  });

  test('a busy timeout is set', () async {
    // 0 means "fail the instant the other isolate holds the lock", which is
    // the SQLITE_BUSY crash out of `_initDatabase`.
    final rows = await db.rawQuery('PRAGMA busy_timeout');
    expect(rows.first.values.first, 5000);
  });

  test('journal mode is WAL', () async {
    // In-memory DBs cannot do WAL, so this asserts against a file-backed one —
    // otherwise it would pass on 'memory' and prove nothing.
    final file = await databaseFactoryFfi.openDatabase(
      '${Directory.systemTemp.createTempSync('swipewise_cfg').path}/t.db',
    );
    addTearDown(file.close);
    await DatabaseHelper.configureForTesting(file);
    final rows = await file.rawQuery('PRAGMA journal_mode');
    expect(rows.first.values.first, 'wal');
  });
}
