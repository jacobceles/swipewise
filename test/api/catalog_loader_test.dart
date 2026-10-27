import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_crashlytics_platform_interface/test.dart';

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
/// Tests read the bundled offline floor directly from disk via
/// [_DiskCatalogService], without an HTTP request.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final crashlytics = _CrashlyticsHost();
  setUpAll(() async {
    TestFirebaseCoreHostApi.setUp(_CoreHost());
    TestFirebaseCrashlyticsHostApi.setUp(crashlytics);
    await Firebase.initializeApp();
    addTearDown(() {
      TestFirebaseCrashlyticsHostApi.setUp(null);
      TestFirebaseCoreHostApi.setUp(null);
    });
  });

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
    crashlytics.errors.clear();
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
    await loader().hydrateIfNeeded('u1');
    final catalog = CatalogRepository(DatabaseHelper());
    final before = await catalog.catalogCounts();
    final data =
        jsonDecode(await File(CatalogLoader.defaultAssetPath).readAsString())
            as Map<String, dynamic>;
    data['schemaVersion'] = 2;
    data['dataVersion'] = (data['dataVersion'] as num).toInt() + 1;
    data['card_products'] = [];
    final result = await CatalogLoader(
      remote: _InlineCatalogService(jsonEncode(data)),
    ).hydrateIfNeeded('u1');
    expect(result, CatalogLoadResult.needsAppUpdate);
    expect(await catalog.catalogCounts(), before);
  });

  for (final raw in ['', '{broken']) {
    test(
      'invalid cached catalog ${jsonEncode(raw)} reports error without replacing data',
      () async {
        await seedUser('u1');
        await loader().hydrateIfNeeded('u1');
        final before = await CatalogRepository(
          DatabaseHelper(),
        ).catalogCounts();
        final result = await CatalogLoader(
          remote: _InlineCatalogService(raw),
        ).hydrateIfNeeded('u1');
        expect(result, CatalogLoadResult.error);
        expect(
          await CatalogRepository(DatabaseHelper()).catalogCounts(),
          before,
        );
        await pumpEventQueue();
        expect(crashlytics.errors, hasLength(1));
        expect(crashlytics.errors.single.reason, 'catalog_load_failed');
      },
    );
  }

  test('a cache miss falls back to the bundled offline floor', () async {
    await seedUser('u1');
    expect(
      await CatalogLoader(
        remote: _MissingCatalogService(),
      ).hydrateIfNeeded('u1'),
      CatalogLoadResult.loaded,
    );
    final counts = await CatalogRepository(DatabaseHelper()).catalogCounts();
    expect(counts['card_products'], greaterThan(0));
  });

  group('unchanged catalog at launch', () {
    test(
      'a cache without a stored version is read once, then skipped',
      () async {
        await seedUser('u1');
        final remote = _DiskCatalogService();
        final l = CatalogLoader(remote: remote);
        expect(await l.hydrateIfNeeded('u1'), CatalogLoadResult.loaded);
        expect(remote.reads, 1);
        expect(remote.version, greaterThan(0));

        expect(await l.hydrateIfNeeded('u1'), CatalogLoadResult.upToDate);
        expect(remote.reads, 1, reason: 'the loaded cache must not be re-read');
      },
    );

    test(
      'a forced re-hydrate (loaded version reset to 0) reads it again',
      () async {
        await seedUser('u1');
        final remote = _DiskCatalogService();
        final l = CatalogLoader(remote: remote);
        await l.hydrateIfNeeded('u1');
        await SettingsRepository(
          DataRepository(),
        ).setLoadedCatalogDataVersion('u1', 0);

        expect(await l.hydrateIfNeeded('u1'), CatalogLoadResult.loaded);
        expect(remote.reads, 2);
      },
    );

    test('a cache newer than what is loaded is read and loaded', () async {
      await seedUser('u1');
      final remote = _DiskCatalogService();
      final l = CatalogLoader(remote: remote);
      await l.hydrateIfNeeded('u1');
      final settings = SettingsRepository(DataRepository());
      await settings.setLoadedCatalogDataVersion('u1', remote.version! - 1);

      expect(await l.hydrateIfNeeded('u1'), CatalogLoadResult.loaded);
      expect(remote.reads, 2);
      expect(await settings.getLoadedCatalogDataVersion('u1'), remote.version);
    });
  });

  test("a point system's unit is imported (older catalogs: null)", () async {
    await seedUser('u1');
    final data =
        jsonDecode(await File(CatalogLoader.defaultAssetPath).readAsString())
            as Map<String, dynamic>;
    final systems = data['point_systems'] as List;
    (systems.first as Map)['unit'] = 'miles';
    await CatalogLoader(
      remote: _InlineCatalogService(jsonEncode(data)),
    ).hydrateIfNeeded('u1');
    final snap = await CatalogRepository(DatabaseHelper()).loadSnapshot();
    final first = (systems.first as Map)['point_system_id'] as String;
    expect(snap.pointSystems[first]?.unit, 'miles');
    final second = (systems[1] as Map)['point_system_id'] as String;
    expect(snap.pointSystems[second]?.unit, isNull);
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

/// Reads the bundled catalog directly from disk to bypass rootBundle.
class _DiskCatalogService extends RemoteAssetService {
  int reads = 0;
  int? version;

  @override
  Future<int?> cachedDataVersion(String key) async => version;

  @override
  Future<void> saveCachedDataVersion(String key, int v) async => version = v;

  @override
  Future<String?> readCached(String key) async {
    if (key != 'catalog') return null;
    reads++;
    try {
      return await File(CatalogLoader.defaultAssetPath).readAsString();
    } catch (_) {
      return null;
    }
  }
}

class _InlineCatalogService extends RemoteAssetService {
  _InlineCatalogService(this.raw);
  final String raw;

  @override
  Future<String?> readCached(String key) async => key == 'catalog' ? raw : null;
}

class _MissingCatalogService extends RemoteAssetService {
  @override
  Future<String?> readCached(String key) async => null;
}

class _CoreHost extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    final apps = await super.initializeCore();
    apps.single.pluginConstants['plugins.flutter.io/firebase_crashlytics'] = {
      'isCrashlyticsCollectionEnabled': false,
    };
    return apps;
  }
}

class _CrashlyticsHost implements TestFirebaseCrashlyticsHostApi {
  final errors = <RecordErrorRequest>[];
  @override
  Future<void> recordError(RecordErrorRequest request) async =>
      errors.add(request);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
