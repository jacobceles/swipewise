import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// The free wallet flow has no bank to derive an issuer from, so it asks the
/// catalog directly. Two things make that non-obvious: `card_products.issuer`
/// holds squashed slugs (`Bankofamerica`) that must never reach the user, and
/// retired products must not inflate an issuer's count or resurrect an issuer
/// nobody can hold a card from.
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

  Future<void> seed(
    String id,
    String issuer, {
    String? imageUrl,
    String? retiredAt,
  }) => db.insert('card_products', {
    'card_product_id': id,
    'issuer': issuer,
    'display_name': id,
    'catalog_version': '2026.01.01',
    'image_url': imageUrl,
    'retired_at': retiredAt,
  });

  test('groups the catalog by issuer and counts each', () async {
    await seed('chase.a', 'Chase');
    await seed('chase.b', 'Chase');
    await seed('citi.a', 'Citi');

    final issuers = await catalog.issuers();

    expect(issuers.map((i) => i.id), ['Chase', 'Citi']);
    expect(issuers.map((i) => i.productCount), [2, 1]);
  });

  test('resolves catalog slugs to names a user would recognise', () async {
    await seed('boa.a', 'Bankofamerica');
    await seed('amex.a', 'Amex');
    await seed('usb.a', 'Usbank');

    final issuers = await catalog.issuers();

    expect(
      issuers.map((i) => i.displayName),
      ['American Express', 'Bank of America', 'U.S. Bank'],
      reason: 'ordered by the displayed name, not the underlying slug',
    );
  });

  test('an unmapped issuer still shows up, under its raw name', () async {
    await seed('new.a', 'Someneobank');

    final issuers = await catalog.issuers();

    expect(issuers.single.displayName, 'Someneobank');
  });

  test('retired products neither count nor keep an issuer alive', () async {
    await seed('chase.live', 'Chase');
    await seed('chase.dead', 'Chase', retiredAt: '2020-01-01');
    await seed('bn.dead', 'Barnesandnoble', retiredAt: '2020-01-01');

    final issuers = await catalog.issuers();

    expect(issuers.map((i) => i.id), ['Chase']);
    expect(issuers.single.productCount, 1);
  });

  test('picks up card art when any product has it', () async {
    await seed('chase.a', 'Chase');
    await seed('chase.b', 'Chase', imageUrl: 'https://example.com/b.png');

    final issuers = await catalog.issuers();

    expect(issuers.single.imageUrl, 'https://example.com/b.png');
  });

  test('an issuer with no art at all is still listed', () async {
    await seed('chase.a', 'Chase');

    final issuers = await catalog.issuers();

    expect(issuers.single.imageUrl, isNull);
    expect(issuers.single.productCount, 1);
  });

  test('issuerDisplayName tolerates spacing and casing drift', () {
    // If the catalog ever starts emitting real names, the map must keep
    // resolving rather than silently falling through to the raw value.
    expect(issuerDisplayName('Bank of America'), 'Bank of America');
    expect(issuerDisplayName('U.S. Bank'), 'U.S. Bank');
    expect(issuerDisplayName('CAPITALONE'), 'Capital One');
  });
}
