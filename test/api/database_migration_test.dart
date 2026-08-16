import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';

/// Pins the v1→v2 migration (B1): a tester on the pre-catalog schema must
/// gain the six RewardEngine tables, in valid FK order, with `foreign_keys`
/// enforced — without touching their existing data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('onUpgrade(1→2) creates the catalog tables on a v1 DB', () async {
    // A minimal "v1" schema: just the `users` table the new FKs reference.
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await db.execute(
      'CREATE TABLE users (id TEXT PRIMARY KEY, identifier TEXT NOT NULL)',
    );
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});

    // Run to current version (3). v3 clears the users table so it can be
    // repopulated by Google Sign-In on next launch.
    await DatabaseHelper.runUpgrade(db, 1, 3);
    // Re-insert user to exercise the FK path (mirrors a post-login state).
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});

    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name'] as String).toSet();
    expect(
      tables,
      containsAll(<String>[
        'point_systems',
        'card_products',
        'reward_rules',
        'reward_rule_exclusions',
        'card_links',
        'rotating_activations',
      ]),
    );

    // FK to users(id) is live: a link for the existing user inserts cleanly.
    await db.insert('card_links', {
      'user_id': 'u1',
      'card_id': 'c1',
      'card_product_id': 'chase.freedom-flex',
      'source': 'heuristic',
    });
    final n = await db.rawQuery('SELECT COUNT(*) AS n FROM card_links');
    expect(n.first['n'], 1);

    await db.close();
  });

  test(
    'onUpgrade(3→4) adds reward_rules.earn_constraint; fresh install has it',
    () async {
      // A DB physically created at v2/v3 (old _createCatalogTables, no column) — the only
      // state lacking earn_constraint. v4 must ALTER it in.
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      await db.execute(
        'CREATE TABLE reward_rules (rule_id TEXT PRIMARY KEY, notes TEXT)', // pre-column shape
      );
      var cols = (await db.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('earn_constraint'), isFalse);

      await DatabaseHelper.runUpgrade(db, 3, 4);
      cols = (await db.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('earn_constraint'), isTrue);
      await db.close();

      // Fresh install lands the column directly via _onCreate.
      final fresh = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      );
      final freshCols = (await fresh.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      expect(freshCols.contains('earn_constraint'), isTrue);
      await fresh.close();
    },
  );

  test(
    'onUpgrade(4→5) adds reward_rules.excluded_categories; fresh install has it',
    () async {
      // A DB at v4 (has earn_constraint, lacks excluded_categories). v5 must ALTER it in.
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      await db.execute(
        'CREATE TABLE reward_rules (rule_id TEXT PRIMARY KEY, notes TEXT, earn_constraint TEXT)',
      );
      var cols = (await db.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('excluded_categories'), isFalse);

      await DatabaseHelper.runUpgrade(db, 4, 5);
      cols = (await db.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('excluded_categories'), isTrue);
      await db.close();

      // Fresh install lands the column directly via _onCreate.
      final fresh = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      );
      final freshCols = (await fresh.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      expect(freshCols.contains('excluded_categories'), isTrue);
      await fresh.close();
    },
  );

  test(
    'onUpgrade(1→5) is guarded: the v2-created columns are not double-added',
    () async {
      // v1→v5 creates reward_rules WITH earn_constraint AND excluded_categories in the v2
      // block (via the current _createCatalogTables), so the later ALTERs must skip — not crash.
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      await db.execute(
        'CREATE TABLE users (id TEXT PRIMARY KEY, identifier TEXT NOT NULL)',
      );
      await DatabaseHelper.runUpgrade(
        db,
        1,
        5,
      ); // must not throw on the guarded ALTERs
      final cols = (await db.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('earn_constraint'), isTrue);
      expect(cols.contains('excluded_categories'), isTrue);
      await db.close();
    },
  );

  test('_onCreate also lands the catalog tables for fresh installs', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
      ),
    );
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name'] as String).toSet();
    expect(tables, containsAll(<String>['reward_rules', 'card_links']));
    await db.close();
  });

  // Data survival: the migration chain must not silently destroy data it isn't
  // meant to. v3 *intentionally* clears users (forced Google Sign-In re-login),
  // which cascade-deletes user-scoped rows; this pins that contract AND that the
  // long-lived `institutions_cache` (no user FK, documented "never wiped")
  // survives, so orphan transactions keep their bank label after a re-login.
  test(
    'upgrade preserves institutions_cache but clears user-scoped rows (intentional)',
    () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      await db.execute(
        'CREATE TABLE users (id TEXT PRIMARY KEY, identifier TEXT NOT NULL)',
      );
      // user-scoped table with the real cascade FK
      await db.execute('''
      CREATE TABLE cards (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        source TEXT NOT NULL,
        name TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');
      // long-lived cache with NO user FK — must survive every migration
      await db.execute('''
      CREATE TABLE institutions_cache (
        institution_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        logo TEXT
      )
    ''');
      await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});
      await db.insert('cards', {
        'id': 'bank:inst1:1234:slug',
        'user_id': 'u1',
        'source': 'bank',
        'name': 'Test Card',
      });
      await db.insert('institutions_cache', {
        'institution_id': 'inst1',
        'name': 'Test Bank',
        'logo': null,
      });

      await DatabaseHelper.runUpgrade(db, 1, 3);

      final cache = await db.query('institutions_cache');
      expect(
        cache,
        hasLength(1),
        reason: 'institutions_cache must never be wiped by a migration',
      );
      expect(cache.first['name'], 'Test Bank');

      expect(
        await db.query('users'),
        isEmpty,
        reason: 'v3 intentionally clears users (forces re-login)',
      );
      expect(
        await db.query('cards'),
        isEmpty,
        reason: 'user-scoped rows cascade-delete when v3 clears users',
      );

      await db.close();
    },
  );

  test(
    'onUpgrade(8→9) adds merchant_tile_cache.business_status; fresh install has it',
    () async {
      // Pre-v9 cache shape (no business_status) — v9 must ALTER the column in so a
      // cached tile can carry the "Temporarily closed" status (N15).
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      await db.execute('''
      CREATE TABLE merchant_tile_cache (
        cell_id TEXT NOT NULL,
        merchant_id TEXT NOT NULL,
        name TEXT NOT NULL,
        category TEXT,
        foursquare_category_id TEXT,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        fetched_at INTEGER NOT NULL,
        last_accessed_at INTEGER NOT NULL,
        PRIMARY KEY (cell_id, merchant_id)
      )
    ''');
      var cols = (await db.rawQuery(
        'PRAGMA table_info(merchant_tile_cache)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('business_status'), isFalse);

      await DatabaseHelper.runUpgrade(db, 8, 9);
      cols = (await db.rawQuery(
        'PRAGMA table_info(merchant_tile_cache)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('business_status'), isTrue);
      await db.close();

      // Fresh install lands the column directly via _onCreate.
      final fresh = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      );
      final freshCols = (await fresh.rawQuery(
        'PRAGMA table_info(merchant_tile_cache)',
      )).map((r) => r['name'] as String).toSet();
      expect(freshCols.contains('business_status'), isTrue);
      await fresh.close();
    },
  );

  test('onUpgrade(8→9) is guarded when merchant_tile_cache is absent', () async {
    // A migration test with only a subset of tables must not crash on the ALTER —
    // the cache is disposable, so a missing table just skips.
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await DatabaseHelper.runUpgrade(db, 8, 9); // must not throw
    await db.close();
  });

  test(
    'onUpgrade(10→11) adds cards.originated_manual; fresh install has it',
    () async {
      // Pre-v11 `cards` shape (no originated_manual). v11 must ALTER it in.
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      await db.execute('''
      CREATE TABLE cards (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        source TEXT NOT NULL,
        name TEXT NOT NULL
      )
    ''');
      var cols = (await db.rawQuery(
        'PRAGMA table_info(cards)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('originated_manual'), isFalse);

      await DatabaseHelper.runUpgrade(db, 10, 11);
      cols = (await db.rawQuery(
        'PRAGMA table_info(cards)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols.contains('originated_manual'), isTrue);
      await db.close();

      // Fresh install lands the column directly via _onCreate.
      final fresh = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      );
      final freshCols = (await fresh.rawQuery(
        'PRAGMA table_info(cards)',
      )).map((r) => r['name'] as String).toSet();
      expect(freshCols.contains('originated_manual'), isTrue);
      await fresh.close();
    },
  );

  test('onUpgrade(10→11) is guarded when cards is absent', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await DatabaseHelper.runUpgrade(db, 10, 11); // must not throw
    await db.close();
  });

  test('onUpgrade(14→15) creates dwell_outcomes; fresh install has it', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await DatabaseHelper.runUpgrade(db, 14, 15);
    final cols = (await db.rawQuery(
      'PRAGMA table_info(dwell_outcomes)',
    )).map((r) => r['name'] as String).toSet();
    expect(cols, equals(_dwellOutcomeColumns));
    await db.close();

    final fresh = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
      ),
    );
    final freshCols = (await fresh.rawQuery(
      'PRAGMA table_info(dwell_outcomes)',
    )).map((r) => r['name'] as String).toSet();
    expect(freshCols, equals(_dwellOutcomeColumns));
    await fresh.close();
  });

  // The native writer carries its own copy of this CREATE (it can fire before
  // Dart has ever opened the DB), so the two can drift into an INSERT that
  // silently fails inside DwellOutcomeStore's catch-all. Pin them together.
  test('DwellOutcomeStore.CREATE_SQL matches the Dart schema', () async {
    final kotlin = File(
      'android/app/src/main/kotlin/com/appsoflife/swipewise/DwellOutcomeStore.kt',
    ).readAsStringSync();
    final create = RegExp(
      r'CREATE TABLE IF NOT EXISTS dwell_outcomes \(([^)]*)\)',
    ).firstMatch(kotlin);
    expect(create, isNotNull, reason: 'CREATE_SQL not found in the Kotlin store');
    final nativeCols = create!
        .group(1)!
        .split(',')
        .map((l) => l.trim().split(RegExp(r'\s+')).first)
        .where((c) => c.isNotEmpty)
        .toSet();
    expect(nativeCols, equals(_dwellOutcomeColumns));
  });
}

const _dwellOutcomeColumns = <String>{
  'id',
  'at',
  'geofence_id',
  'merchant_name',
  'outcome',
  'distance_m',
  'accuracy_m',
  'allowed_m',
};
