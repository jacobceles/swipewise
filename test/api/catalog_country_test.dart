import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// Issuer countries for the Add-a-Card country filter.
///
/// The load-bearing case is what happens to a catalog published *before*
/// Canada existed. Those bundles carry no `country` at all, so every row is
/// NULL, and an issuer with no countries would vanish under every filter but
/// All. `COALESCE(country, 'US')` is what makes NULL mean "American", which it
/// always was.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late CatalogRepository catalog;
  late Database db;

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
    catalog = CatalogRepository(DatabaseHelper());
    db = await DatabaseHelper().database;
  });

  tearDown(() async {
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<void> seed(String id, String issuer, {String? country}) =>
      db.insert('card_products', {
        'card_product_id': id,
        'issuer': issuer,
        'display_name': id,
        'catalog_version': 'v1',
        'foreign_tx_fee_pct': 0.0,
        'country': ?country,
      });

  group('issuer countries', () {
    Future<Map<String, Set<String>>> countries() async => {
      for (final i in await catalog.issuers()) i.id: i.countries,
    };

    test('a pre-Canada catalog row (country NULL) reads as US', () async {
      await seed('chase.sapphire', 'Chase');

      expect(await countries(), {
        'Chase': {'US'},
      });
    });

    test('an issuer selling in both countries carries both', () async {
      // Amex is the one issuer in both: the picker tags it "US + CANADA" and
      // its card list offers its own country switch.
      await seed('amex.gold', 'Amex', country: 'US');
      await seed('amex.cobalt', 'Amex', country: 'CA');
      await seed('rbc.avion', 'Rbc', country: 'CA');

      expect(await countries(), {
        'Amex': {'US', 'CA'},
        'Rbc': {'CA'},
      });
    });

    test('issuers() lists every country, unfiltered', () async {
      await seed('rbc.avion', 'Rbc', country: 'CA');
      await seed('chase.sapphire', 'Chase', country: 'US');
      await seed('legacy.card', 'Legacy');

      expect((await catalog.issuers()).map((i) => i.id), hasLength(3));
      expect(await catalog.productsForIssuer(null), hasLength(3));
    });
  });

  group('v14 migration', () {
    test('adds the columns to a database that predates Canada', () async {
      await db.execute('DROP TABLE card_products');
      await db.execute('DROP TABLE point_systems');
      // The pre-v14 shape, verbatim.
      await db.execute('''
        CREATE TABLE card_products (
          card_product_id TEXT PRIMARY KEY,
          issuer TEXT NOT NULL,
          display_name TEXT NOT NULL,
          network TEXT,
          annual_fee_usd REAL,
          foreign_tx_fee_pct REAL NOT NULL DEFAULT 0.0,
          image_url TEXT,
          catalog_version TEXT NOT NULL,
          retired_at TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE point_systems (
          point_system_id TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          baseline_cent_value REAL NOT NULL,
          valuation_source TEXT,
          valuation_updated_at TEXT
        )
      ''');
      await db.insert('card_products', {
        'card_product_id': 'chase.sapphire',
        'issuer': 'Chase',
        'display_name': 'Sapphire',
        'catalog_version': 'v1',
        'foreign_tx_fee_pct': 0.0,
      });

      await DatabaseHelper.runUpgrade(db, 13, 14);

      final cols = (await db.rawQuery(
        'PRAGMA table_info(card_products)',
      )).map((r) => r['name'] as String).toSet();
      expect(cols, containsAll(<String>['country', 'currency']));

      final psCols = (await db.rawQuery(
        'PRAGMA table_info(point_systems)',
      )).map((r) => r['name'] as String).toSet();
      expect(psCols, contains('currency'));

      // The existing card survives and still reads as American.
      expect((await catalog.issuers()).single.countries, {'US'});
    });

    test('is idempotent — re-running does not throw on existing columns', () async {
      await DatabaseHelper.runUpgrade(db, 13, 14);
      await DatabaseHelper.runUpgrade(db, 13, 14);
    });
  });
}
