import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/card_link_service.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// Pins card_links seeding (B2.5): explicit precedence, heuristic name match,
/// no-downgrade of a user_confirmed link, and unmatched → no row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late CatalogRepository catalog;

  setUp(() async {
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
    catalog = CatalogRepository(DatabaseHelper());
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});

    // A two-product synthetic catalog with controlled display names.
    Map<String, Object?> product(String id, String issuer, String name) => {
      'card_product_id': id,
      'issuer': issuer,
      'display_name': name,
      'network': null,
      'annual_fee_usd': null,
      'foreign_tx_fee_pct': 0.0,
      'image_url': null,
      'catalog_version': 't',
      'retired_at': null,
    };
    await catalog.replaceCatalog(
      pointSystems: const [],
      cardProducts: [
        product('chase.freedom-flex', 'Chase', 'Chase Freedom Flex'),
        product('amex.gold', 'Amex', 'American Express Gold Card'),
        product(
          'usbank.altitude-go',
          'Usbank',
          'US Bank Altitude Go Visa Signature Card',
        ),
      ],
      rewardRules: const [],
      exclusions: const [],
    );
  });

  tearDown(() async {
    final db = await DatabaseHelper().database;
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<void> seedCard(String id, String name, {String? provider}) async {
    final db = await DatabaseHelper().database;
    await db.insert('cards', {
      'id': id,
      'user_id': 'u1',
      'source': 'manual',
      'name': name,
      'provider': provider,
    });
  }

  // Reads card_links.source directly. Replaces the removed
  // CatalogRepository.linkSource (the lookup was inlined into the seeding
  // query in card_link_service); seeding still writes the same source values.
  Future<String?> linkSource(String cardId) async {
    final db = await DatabaseHelper().database;
    final rows = await db.query(
      'card_links',
      columns: ['source'],
      where: 'user_id = ? AND card_id = ?',
      whereArgs: ['u1', cardId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['source'] as String?;
  }

  test('heuristic name match links a recognizable card', () async {
    await seedCard('c1', 'Chase Freedom Flex', provider: 'Chase');
    final res = await CardLinkService().seedLinks('u1');
    expect(res.heuristic, 1);

    final links = await catalog.linkedCards('u1');
    expect(links.single.cardProductId, 'chase.freedom-flex');
    expect(await linkSource('c1'), 'heuristic');
  });

  test('explicit product_identification beats heuristic', () async {
    await seedCard('c1', 'Chase Freedom Flex', provider: 'Chase');
    final db = await DatabaseHelper().database;
    await db.insert('card_overrides', {
      'card_id': 'c1',
      'user_id': 'u1',
      'product_identification': 'amex.gold', // a valid (if odd) slug
    });
    final res = await CardLinkService().seedLinks('u1');
    expect(res.explicit, 1);
    final links = await catalog.linkedCards('u1');
    expect(links.single.cardProductId, 'amex.gold');
    expect(await linkSource('c1'), 'preconfirmed');
  });

  test(
    'stale product_identification (unknown slug) falls back to heuristic',
    () async {
      await seedCard('c1', 'Chase Freedom Flex', provider: 'Chase');
      final db = await DatabaseHelper().database;
      await db.insert('card_overrides', {
        'card_id': 'c1',
        'user_id': 'u1',
        'product_identification': '509', // old numeric seed id, not a slug
      });
      await CardLinkService().seedLinks('u1');
      expect(await linkSource('c1'), 'heuristic');
    },
  );

  test('a user_confirmed link is never downgraded by re-seeding', () async {
    await seedCard('c1', 'Chase Freedom Flex', provider: 'Chase');
    await CardLinkService().confirmLink(
      userId: 'u1',
      cardId: 'c1',
      cardProductId: 'amex.gold',
    );
    await CardLinkService().seedLinks('u1');
    expect(await linkSource('c1'), 'user_confirmed');
    final links = await catalog.linkedCards('u1');
    expect(links.single.cardProductId, 'amex.gold');
  });

  test(
    'issuer match bridges "US Bank" provider to "Usbank" catalog issuer',
    () async {
      // The slug-derived catalog issuer drops the space; the synced provider
      // keeps it. Matching must still restrict to the right issuer.
      await seedCard(
        'c1',
        'US Bank Altitude Go Visa Signature Card',
        provider: 'US Bank',
      );
      final res = await CardLinkService().seedLinks('u1');
      expect(res.heuristic, 1);
      final links = await catalog.linkedCards('u1');
      expect(links.single.cardProductId, 'usbank.altitude-go');
    },
  );

  test('an unrecognizable card gets no link row', () async {
    await seedCard('c1', 'Mystery Metal Card', provider: 'Unknown');
    final res = await CardLinkService().seedLinks('u1');
    expect(res.unmatched, 1);
    expect(await catalog.linkedCards('u1'), isEmpty);
  });
}
