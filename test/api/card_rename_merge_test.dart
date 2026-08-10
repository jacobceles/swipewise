import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/bank_fdx_mapper.dart';
import 'package:swipewise/api/bank_write_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// Pins the account-rename merge in the sync write path.
///
/// `stableCardId` embeds `accountSlug`, which is derived from the Sophtron
/// AccountName. So when an issuer relabels an account the id changes and the
/// rebuild writes a SECOND card: observed live when Discover renamed
/// "Discover it Card" to "Discover Card" — 179 transactions stayed under
/// `…:2501:discoveritcard` while the new row took `…:2501:discovercard`, and the
/// orphan-recovery read resurrected the old one as a duplicate wallet card.
///
/// The merge re-keys onto the existing card, but only on an UNAMBIGUOUS match:
/// two real cards can share a last four at one issuer, and merging those would
/// destroy data — strictly worse than the duplicate it fixes.
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

  Future<void> seedUser(String id) async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': id, 'identifier': '\$id@test'});
  }

  BankAccount acct(String id, {String? last4, String? name}) => BankAccount(
    accountId: id,
    raw: const <String, dynamic>{},
    accountType: 'Credit_Card',
    accountNumberDisplay: last4,
    nickname: name,
  );

  BankTransaction tx(String desc, DateTime posted) => BankTransaction(
    raw: const <String, dynamic>{},
    description: desc,
    amount: 10.0,
    postedAt: posted,
    date: posted,
    type: 'DEBIT',
  );

  Future<void> sync(
    BankWriteRepository repo, {
    required List<BankAccount> accounts,
    required Map<String, List<BankTransaction>> txs,
  }) => repo.rebuildInstitution(
    userId: 'u1',
    institutionId: 'inst1',
    institutionName: 'Discover',
    institutionLogo: null,
    accounts: accounts,
    txsByAccountId: txs,
  );

  test('an issuer renaming an account does NOT create a second card', () async {
    await seedUser('u1');
    final repo = BankWriteRepository(DatabaseHelper());
    final db = await DatabaseHelper().database;
    final when = DateTime(2026, 6, 1);

    await sync(
      repo,
      accounts: [acct('a1', last4: '2501', name: 'Discover it Card')],
      txs: {
        'a1': [tx('coffee', when)],
      },
    );
    final firstId = (await db.query('cards')).single['id'] as String;
    expect(firstId, contains('discoveritcard'));

    // Same physical account, issuer relabelled it.
    await sync(
      repo,
      accounts: [acct('a1', last4: '2501', name: 'Discover Card')],
      txs: {
        'a1': [tx('coffee', when)],
      },
    );

    final cards = await db.query('cards');
    expect(
      cards.length,
      1,
      reason: 'a rename must not mint a second wallet card',
    );
    expect(cards.single['id'], firstId, reason: 'the original id must survive');
  });

  test('the renamed card keeps its transaction history', () async {
    await seedUser('u1');
    final repo = BankWriteRepository(DatabaseHelper());
    final db = await DatabaseHelper().database;

    await sync(
      repo,
      accounts: [acct('a1', last4: '2501', name: 'Discover it Card')],
      txs: {
        'a1': [tx('old-purchase', DateTime(2026, 1, 5))],
      },
    );
    await sync(
      repo,
      accounts: [acct('a1', last4: '2501', name: 'Discover Card')],
      txs: {
        'a1': [tx('new-purchase', DateTime(2026, 6, 1))],
      },
    );

    final cardId = (await db.query('cards')).single['id'] as String;
    final orphaned = await db.query(
      'transactions',
      where: 'user_id = ? AND card_id != ?',
      whereArgs: ['u1', cardId],
    );
    expect(
      orphaned,
      isEmpty,
      reason:
          'history stranded under the old id is exactly what rebuilds the phantom card',
    );
  });

  test('two real cards sharing a last four are NOT merged', () async {
    await seedUser('u1');
    final repo = BankWriteRepository(DatabaseHelper());
    final db = await DatabaseHelper().database;

    await sync(
      repo,
      accounts: [
        acct('a1', last4: '2501', name: 'Card One'),
        acct('a2', last4: '2501', name: 'Card Two'),
      ],
      txs: const {},
    );
    expect((await db.query('cards')).length, 2);

    // A third arrival with the same last four must stay separate: the match is
    // ambiguous, so refusing to merge is the safe answer.
    await sync(
      repo,
      accounts: [
        acct('a1', last4: '2501', name: 'Card One'),
        acct('a2', last4: '2501', name: 'Card Two'),
        acct('a3', last4: '2501', name: 'Card Three'),
      ],
      txs: const {},
    );
    expect(
      (await db.query('cards')).length,
      3,
      reason:
          'merging distinct cards would destroy data — worse than a duplicate',
    );
  });

  test(
    'a genuinely new card with a different last four is still added',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());
      final db = await DatabaseHelper().database;

      await sync(
        repo,
        accounts: [acct('a1', last4: '2501', name: 'Discover it Card')],
        txs: const {},
      );
      await sync(
        repo,
        accounts: [
          acct('a1', last4: '2501', name: 'Discover it Card'),
          acct('a2', last4: '9999', name: 'Discover Miles'),
        ],
        txs: const {},
      );
      expect((await db.query('cards')).length, 2);
    },
  );
}
