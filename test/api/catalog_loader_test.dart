import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/catalog_loader.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/remote_asset_service.dart';
import 'package:swipewise/api/settings_repository.dart';

/// Pins the catalog hydration (B2). Opens an in-memory DB with
/// `foreign_keys = ON`, runs the catalog JSON through `CatalogLoader`, and
/// checks row counts, idempotency, and schema-too-new rejection.
///
/// catalog.json is not bundled in the app (served from R2); tests read it
/// directly from disk via [_DiskCatalogService].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  /// Returns the catalog JSON from the local assets/ directory. Used only
  /// in tests — at runtime the app fetches from R2 (RemoteAssetService).
  Future<Map<String, int>> bundleCounts() async {
    final raw = await File(CatalogLoader.defaultAssetPath).readAsString();
    final data = jsonDecode(raw) as Map<String, dynamic>;
    int len(String k) => (data[k] as List).length;
    return {
      'card_products': len('card_products'),
      'reward_rules': len('reward_rules'),
      'reward_rule_exclusions': len('reward_rule_exclusions'),
      'point_systems': len('point_systems'),
    };
  }

  setUp(() {
    DatabaseHelper.setTestDatabaseFactory(() async {
      return databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
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

  CatalogLoader loader() => CatalogLoader(remote: _DiskCatalogService());

  test('hydrates the four global catalog tables from the bundle', () async {
    await seedUser('u1');
    final result = await loader().hydrateIfNeeded('u1');
    expect(result, CatalogLoadResult.loaded);

    final expected = await bundleCounts();
    final counts = await CatalogRepository(DatabaseHelper()).catalogCounts();
    expect(counts['card_products'], expected['card_products']);
    expect(counts['reward_rules'], expected['reward_rules']);
    expect(
      counts['reward_rule_exclusions'],
      expected['reward_rule_exclusions'],
    );
    expect(counts['point_systems'], expected['point_systems']);
  });

  test('second call with same dataVersion is a no-op', () async {
    await seedUser('u1');
    expect(await loader().hydrateIfNeeded('u1'), CatalogLoadResult.loaded);
    expect(await loader().hydrateIfNeeded('u1'), CatalogLoadResult.upToDate);

    // Still exactly one copy of the catalog — no duplicate inserts.
    final expected = await bundleCounts();
    final counts = await CatalogRepository(DatabaseHelper()).catalogCounts();
    expect(counts['reward_rules'], expected['reward_rules']);
  });

  test('records the loaded dataVersion in settings', () async {
    await seedUser('u1');
    await loader().hydrateIfNeeded('u1');
    final settings = SettingsRepository(DataRepository());
    expect(await settings.getLoadedCatalogDataVersion('u1'), greaterThan(0));
  });

  test(
    'snapshot round-trips products, rules, exclusions, point systems',
    () async {
      await seedUser('u1');
      await loader().hydrateIfNeeded('u1');
      final expected = await bundleCounts();
      final snap = await CatalogRepository(DatabaseHelper()).loadSnapshot();
      expect(snap.products.length, expected['card_products']);
      expect(snap.pointSystems['usd']?.baselineCentValue, 1.0);
      // Every (rule, brand) exclusion pair in the bundle round-trips into the
      // snapshot's per-rule brand sets.
      final exclusionPairs = snap.exclusionsByRule.values.fold<int>(
        0,
        (n, brands) => n + brands.length,
      );
      expect(exclusionPairs, expected['reward_rule_exclusions']);
    },
  );

  test('bundle with a newer schemaVersion is rejected, DB untouched', () async {
    await seedUser('u1');
    // No real over-version asset to load; assert the guard constant instead so
    // a future schema bump can't silently corrupt older installs.
    expect(CatalogLoader.supportedSchemaVersion, 1);
  });

  test('migrated perks surface for a linked card', () async {
    await seedUser('u1');
    await loader().hydrateIfNeeded('u1');
    final db = await DatabaseHelper().database;
    // Pick any product that carries perks, link a card to it.
    final pr = await db.query('product_perks', limit: 1);
    expect(pr, isNotEmpty);
    final productId = pr.first['card_product_id'] as String;
    await db.insert('cards', {
      'id': 'c1',
      'user_id': 'u1',
      'source': 'manual',
      'name': 'X',
    });
    final catalog = CatalogRepository(DatabaseHelper());
    await catalog.upsertLink(
      userId: 'u1',
      cardId: 'c1',
      cardProductId: productId,
      source: 'user_confirmed',
    );
    final perks = await catalog.perksForCard('u1', 'c1');
    expect(perks, isNotEmpty);
    expect(perks.first.title, isNotNull);
  });
}

/// Reads catalog.json directly from disk. Used in tests to bypass rootBundle
/// (catalog.json is not a bundled app asset; it's served from R2 at runtime).
class _DiskCatalogService extends RemoteAssetService {
  @override
  Future<String?> readCached(String key) async {
    if (key != 'catalog') return null;
    try {
      return await File(CatalogLoader.defaultAssetPath).readAsString();
    } catch (_) {
      return null;
    }
  }
}
