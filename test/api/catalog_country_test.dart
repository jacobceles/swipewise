import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/settings_repository.dart';

/// Country filtering for the Add-Cards picker.
///
/// The load-bearing case is not "Canadian cards are hidden from Americans" —
/// it is what happens to a catalog published *before* Canada existed. Those
/// bundles carry no `country` at all, so every row is NULL, and a naive
/// `country = 'US'` filter empties the picker for every existing user until
/// they happen to receive a new catalog. `COALESCE(country, 'US')` is what
/// makes NULL mean "American", which it always was.
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

  group('country filtering', () {
    test('a pre-Canada catalog row (country NULL) reads as US', () async {
      await seed('chase.sapphire', 'Chase');

      expect(
        (await catalog.productsForIssuer(null, country: 'US')).map((p) => p.id),
        ['chase.sapphire'],
      );
      expect(await catalog.productsForIssuer(null, country: 'CA'), isEmpty);
    });

    test('Canadian cards are offered only to Canada', () async {
      await seed('rbc.avion', 'Rbc', country: 'CA');
      await seed('chase.sapphire', 'Chase', country: 'US');

      expect(
        (await catalog.productsForIssuer(null, country: 'CA')).map((p) => p.id),
        ['rbc.avion'],
      );
      expect(
        (await catalog.productsForIssuer(null, country: 'US')).map((p) => p.id),
        ['chase.sapphire'],
      );
    });

    test('the ALL sentinel filters nothing', () async {
      await seed('rbc.avion', 'Rbc', country: 'CA');
      await seed('chase.sapphire', 'Chase', country: 'US');
      await seed('legacy.card', 'Legacy');

      final all = await catalog.productsForIssuer(
        null,
        country: catalogCountryAll,
      );
      expect(all.map((p) => p.id).toSet(), {
        'rbc.avion',
        'chase.sapphire',
        'legacy.card',
      });
    });

    test('no country asked for is the same as ALL', () async {
      await seed('rbc.avion', 'Rbc', country: 'CA');
      await seed('chase.sapphire', 'Chase', country: 'US');

      expect(await catalog.productsForIssuer(null), hasLength(2));
    });

    test('country and issuer filters compose', () async {
      // Amex sells in both countries; stepping into the issuer must not leak
      // the other country's line-up.
      await seed('amex.gold', 'Amex', country: 'US');
      await seed('amex.cobalt', 'Amex', country: 'CA');

      expect(
        (await catalog.productsForIssuer('Amex', country: 'CA')).map((p) => p.id),
        ['amex.cobalt'],
      );
    });

    test('the issuer picker hides an issuer with no cards here', () async {
      await seed('rbc.avion', 'Rbc', country: 'CA');
      await seed('chase.sapphire', 'Chase', country: 'US');

      expect(
        (await catalog.issuers(country: 'US')).map((i) => i.id),
        ['Chase'],
      );
      expect((await catalog.issuers(country: 'CA')).map((i) => i.id), ['Rbc']);
      expect((await catalog.issuers()).map((i) => i.id), hasLength(2));
    });

    test('issuer counts reflect the filter, not the whole catalog', () async {
      await seed('amex.gold', 'Amex', country: 'US');
      await seed('amex.platinum', 'Amex', country: 'US');
      await seed('amex.cobalt', 'Amex', country: 'CA');

      final ca = (await catalog.issuers(country: 'CA')).single;
      expect(ca.productCount, 1);
      final us = (await catalog.issuers(country: 'US')).single;
      expect(us.productCount, 2);
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
      expect(
        (await catalog.productsForIssuer(null, country: 'US')).map((p) => p.id),
        ['chase.sapphire'],
      );
    });

    test('is idempotent — re-running does not throw on existing columns', () async {
      await DatabaseHelper.runUpgrade(db, 13, 14);
      await DatabaseHelper.runUpgrade(db, 13, 14);
    });
  });
}
