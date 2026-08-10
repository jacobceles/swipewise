import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/transaction_repository.dart';

/// N11: `queryRecurringPayments` must carry the card a recurring charge is
/// billed to (the most-recent occurrence's `card_id`) so the router can compare
/// it against the user's best card for that category.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUp(() {
    DatabaseHelper.setTestDatabaseFactory(() async {
      return databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
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

  Future<void> insertTx(
    String id, {
    required String merchant,
    required String cardId,
    required String postedAt,
    double amount = 15.99,
  }) async {
    final db = await DatabaseHelper().database;
    await db.insert('transactions', {
      'id': id,
      'user_id': 'u1',
      'merchant': merchant,
      'card_id': cardId,
      'type': 'DEBIT',
      'amount': amount,
      'currency': 'USD',
      'posted_at': postedAt,
    });
  }

  Future<void> seedUser() async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});
  }

  test(
    'chargedCardId is the most-recent occurrence card (survives a mid-stream switch)',
    () async {
      await seedUser();
      // Netflix moved from cardA to cardB partway through — the router should see
      // the card it's billed to *now*.
      await insertTx(
        't1',
        merchant: 'Netflix',
        cardId: 'cardA',
        postedAt: '2026-04-01T00:00:00Z',
      );
      await insertTx(
        't2',
        merchant: 'Netflix',
        cardId: 'cardA',
        postedAt: '2026-05-01T00:00:00Z',
      );
      await insertTx(
        't3',
        merchant: 'Netflix',
        cardId: 'cardB',
        postedAt: '2026-06-01T00:00:00Z',
      );
      await insertTx(
        't4',
        merchant: 'Netflix',
        cardId: 'cardB',
        postedAt: '2026-07-01T00:00:00Z',
      );

      final summary = await TransactionRepository(
        DatabaseHelper(),
      ).queryRecurringPayments('u1');
      final netflix = summary.items.firstWhere((p) => p.merchant == 'Netflix');
      expect(netflix.chargedCardId, 'cardB');
    },
  );

  test('a single-card recurring charge reports that card', () async {
    await seedUser();
    await insertTx(
      's1',
      merchant: 'Spotify',
      cardId: 'cardX',
      amount: 9.99,
      postedAt: '2026-05-01T00:00:00Z',
    );
    await insertTx(
      's2',
      merchant: 'Spotify',
      cardId: 'cardX',
      amount: 9.99,
      postedAt: '2026-06-01T00:00:00Z',
    );
    await insertTx(
      's3',
      merchant: 'Spotify',
      cardId: 'cardX',
      amount: 9.99,
      postedAt: '2026-07-01T00:00:00Z',
    );

    final summary = await TransactionRepository(
      DatabaseHelper(),
    ).queryRecurringPayments('u1');
    final spotify = summary.items.firstWhere((p) => p.merchant == 'Spotify');
    expect(spotify.chargedCardId, 'cardX');
  });
}
