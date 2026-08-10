import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';

/// Pins the v12 repair for the account-rename card split.
///
/// Reproduces the live case: Discover relabelled "Discover it Card" to
/// "Discover Card", so `cards.id` changed. The rebuild wrote the new card while
/// 179 transactions stayed under the old id with no `cards` row, and the
/// orphan-recovery read resurrected them as a duplicate wallet card.
///
/// The write-path fix prevents NEW splits but cannot heal this one — the stale
/// id no longer matches any incoming account — so the migration adopts the
/// orphans. Only when unambiguous: two real cards can share a last four at one
/// issuer, and merging those would destroy data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await DatabaseHelper.bootstrapSchema(db);
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});
  });

  tearDown(() async => db.close());

  Future<void> addCard(String id, String inst, String last4) =>
      db.insert('cards', {
        'id': id,
        'user_id': 'u1',
        'source': 'bank',
        'name': 'Card',
        'institution_id': inst,
        'last_four': last4,
      });

  Future<void> addTx(String id, String cardId) => db.insert('transactions', {
    'id': id,
    'user_id': 'u1',
    'card_id': cardId,
    'amount': 1.0,
    'posted_at': '2026-01-01',
  });

  const inst = 'fffdc27c';
  const survivor = 'bank:fffdc27c:2501:discovercard';
  const orphan = 'bank:fffdc27c:2501:discoveritcard';

  test('adopts transactions stranded under a renamed card id', () async {
    await addCard(survivor, inst, '2501');
    await addTx('t-new', survivor);
    await addTx('t-old-1', orphan);
    await addTx('t-old-2', orphan);

    await DatabaseHelper.runUpgrade(db, 11, 12);

    final stranded = await db.query(
      'transactions',
      where: 'card_id = ?',
      whereArgs: [orphan],
    );
    expect(
      stranded,
      isEmpty,
      reason: 'orphans are what rebuild the phantom card',
    );
    expect(
      (await db.query(
        'transactions',
        where: 'card_id = ?',
        whereArgs: [survivor],
      )).length,
      3,
    );
  });

  test('drops the stale card_link pointing at the dead id', () async {
    await addCard(survivor, inst, '2501');
    await addTx('t1', orphan);
    for (final id in [survivor, orphan]) {
      await db.insert('card_links', {
        'user_id': 'u1',
        'card_id': id,
        'card_product_id': 'discover.credit-cards-cash-back-it-card',
        'source': 'auto',
      });
    }

    await DatabaseHelper.runUpgrade(db, 11, 12);

    final links = await db.query(
      'card_links',
      where: 'card_id = ?',
      whereArgs: [orphan],
    );
    expect(links, isEmpty);
  });

  test(
    'AMBIGUOUS last four is left alone — two real cards must not merge',
    () async {
      await addCard('bank:$inst:2501:cardone', inst, '2501');
      await addCard('bank:$inst:2501:cardtwo', inst, '2501');
      await addTx('t1', 'bank:$inst:2501:ghost');

      await DatabaseHelper.runUpgrade(db, 11, 12);

      final still = await db.query(
        'transactions',
        where: 'card_id = ?',
        whereArgs: ['bank:$inst:2501:ghost'],
      );
      expect(
        still.length,
        1,
        reason: 'merging distinct cards is worse than the duplicate',
      );
    },
  );

  test('an orphan with no surviving card is left alone', () async {
    await addTx('t1', 'bank:$inst:9999:gone');
    await DatabaseHelper.runUpgrade(db, 11, 12);
    expect(
      (await db.query(
        'transactions',
        where: 'card_id = ?',
        whereArgs: ['bank:$inst:9999:gone'],
      )).length,
      1,
    );
  });

  test('healthy transactions are untouched', () async {
    await addCard(survivor, inst, '2501');
    await addTx('t1', survivor);
    await DatabaseHelper.runUpgrade(db, 11, 12);
    expect(
      (await db.query(
        'transactions',
        where: 'card_id = ?',
        whereArgs: [survivor],
      )).length,
      1,
    );
  });
}
