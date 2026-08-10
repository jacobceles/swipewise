import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/bank_fdx_mapper.dart';
import 'package:swipewise/api/bank_write_repository.dart';
import 'package:swipewise/api/card_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// Pins the data-loss-critical behaviour of the sync write path
/// ([BankWriteRepository.rebuildInstitution] and [dropMissingInstitutions]) —
/// the code that can silently wipe or corrupt a user's wallet. All against an
/// in-memory DB; no network, no Sophtron.
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

  Future<void> seedUser(String userId) async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': userId, 'identifier': '$userId@test'});
  }

  BankAccount acct(String id, {String last4 = '1234', String name = 'Card'}) =>
      BankAccount(
        accountId: id,
        raw: const <String, dynamic>{},
        accountType: 'Credit_Card',
        accountNumberDisplay: last4,
        nickname: name,
      );

  BankTransaction tx(String desc, double amount, DateTime posted) =>
      BankTransaction(
        raw: const <String, dynamic>{},
        description: desc,
        amount: amount,
        type: 'DEBIT',
        postedAt: posted,
        date: posted,
      );

  Future<({int cardCount, int txCount})> rebuild(
    BankWriteRepository repo, {
    required String institutionId,
    required List<BankAccount> accounts,
    required Map<String, List<BankTransaction>> txs,
  }) => repo.rebuildInstitution(
    userId: 'u1',
    institutionId: institutionId,
    institutionName: 'Bank',
    institutionLogo: null,
    accounts: accounts,
    txsByAccountId: txs,
  );

  test(
    'rebuildInstitution is idempotent — re-syncing the same data never duplicates rows',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());
      final accounts = [acct('a1')];
      final txs = {
        'a1': [tx('Coffee', 4.50, DateTime.utc(2026, 1, 10))],
      };

      await rebuild(repo, institutionId: 'inst1', accounts: accounts, txs: txs);
      await rebuild(repo, institutionId: 'inst1', accounts: accounts, txs: txs);

      final db = await DatabaseHelper().database;
      expect(
        await db.query('cards'),
        hasLength(1),
        reason: 'stable card id + replace => no duplicate card',
      );
      expect(
        await db.query('transactions'),
        hasLength(1),
        reason: 'stable transaction id => no duplicate transaction',
      );
    },
  );

  test(
    'rebuildInstitution preserves transactions older than the returned scrape window',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());

      // First sync brings an old + a recent transaction.
      await rebuild(
        repo,
        institutionId: 'inst1',
        accounts: [acct('a1')],
        txs: {
          'a1': [
            tx('Old', 10, DateTime.utc(2025, 1, 1)),
            tx('Recent', 20, DateTime.utc(2026, 1, 1)),
          ],
        },
      );
      // Second sync only returns the recent window (issuer served a short window).
      await rebuild(
        repo,
        institutionId: 'inst1',
        accounts: [acct('a1')],
        txs: {
          'a1': [tx('Recent', 20, DateTime.utc(2026, 1, 1))],
        },
      );

      final db = await DatabaseHelper().database;
      final names = (await db.query('transactions')).map((t) => t['name']);
      expect(
        names,
        containsAll(['Old', 'Recent']),
        reason:
            'the archived older transaction must survive a shorter scrape window',
      );
    },
  );

  test(
    'rebuildInstitution isolates institutions — rebuilding one leaves another untouched',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());

      await rebuild(
        repo,
        institutionId: 'instA',
        accounts: [acct('a1')],
        txs: {
          'a1': [tx('A-tx', 5, DateTime.utc(2026, 1, 1))],
        },
      );
      await rebuild(
        repo,
        institutionId: 'instB',
        accounts: [acct('b1')],
        txs: {
          'b1': [tx('B-tx', 6, DateTime.utc(2026, 1, 2))],
        },
      );
      // Re-sync A — B's rows must remain.
      await rebuild(
        repo,
        institutionId: 'instA',
        accounts: [acct('a1')],
        txs: {
          'a1': [tx('A-tx', 5, DateTime.utc(2026, 1, 1))],
        },
      );

      final db = await DatabaseHelper().database;
      expect(
        await db.query('cards', where: "institution_id = 'instB'"),
        hasLength(1),
        reason: 'rebuilding A must not wipe B cards',
      );
      expect(
        await db.query('transactions', where: "card_id LIKE 'bank:instB:%'"),
        hasLength(1),
        reason: 'rebuilding A must not wipe B transactions',
      );
    },
  );

  test(
    'rebuildInstitution preserves card_overrides — user edits re-attach across a sync',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());
      await rebuild(
        repo,
        institutionId: 'inst1',
        accounts: [acct('a1')],
        txs: {'a1': const []},
      );

      final db = await DatabaseHelper().database;
      final cardId = (await db.query('cards', limit: 1)).first['id'] as String;
      // User sets a manual credit limit + rename on the synced card.
      await db.insert('card_overrides', {
        'card_id': cardId,
        'user_id': 'u1',
        'manual_credit_limit': 5000.0,
        'custom_name': 'My Card',
      });

      // Next sync rebuilds the same card (same stable id).
      await rebuild(
        repo,
        institutionId: 'inst1',
        accounts: [acct('a1')],
        txs: {'a1': const []},
      );

      final ov = await db.query(
        'card_overrides',
        where: 'card_id = ?',
        whereArgs: [cardId],
      );
      expect(
        ov,
        hasLength(1),
        reason: 'sync wipe must not drop user overrides',
      );
      expect(ov.first['custom_name'], 'My Card');
      expect(ov.first['manual_credit_limit'], 5000.0);
    },
  );

  test(
    'dropMissingInstitutions spares a freshly-linked connection inside the grace window',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());
      final now = DateTime.utc(2026, 1, 1, 12);
      final db = await DatabaseHelper().database;
      await db.insert('bank_connections', {
        'user_institution_id': 'mem1',
        'user_id': 'u1',
        'institution_id': 'inst1',
        'created_at': now
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      });

      // Sync says keep nothing, but the row is too young to drop.
      await repo.dropMissingInstitutions(
        userId: 'u1',
        keepInstitutionIds: const {},
        keepMemberIds: const {},
        now: now,
      );

      expect(
        await db.query('bank_connections'),
        hasLength(1),
        reason:
            'a just-linked bank must not be wiped before its MemberID propagates',
      );
    },
  );

  test(
    'dropMissingInstitutions drops an aged-out connection absent server-side',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());
      final now = DateTime.utc(2026, 1, 1, 12);
      final db = await DatabaseHelper().database;
      await db.insert('bank_connections', {
        'user_institution_id': 'mem1',
        'user_id': 'u1',
        'institution_id': 'inst1',
        'created_at': now.subtract(const Duration(hours: 1)).toIso8601String(),
      });

      await repo.dropMissingInstitutions(
        userId: 'u1',
        keepInstitutionIds: const {},
        keepMemberIds: const {},
        now: now,
      );

      expect(
        await db.query('bank_connections'),
        isEmpty,
        reason:
            'an aged-out connection no longer present server-side is dropped',
      );
    },
  );

  test('mergeManualCardsWithBank collapses a matching manual card into the '
      'newly-synced bank card, carrying overrides + catalog link and '
      'flagging originated_manual', () async {
    await seedUser('u1');
    final repo = BankWriteRepository(DatabaseHelper());
    final db = await DatabaseHelper().database;

    // User manually added this card before ever linking Chase.
    await db.insert('cards', {
      'id': 'manual:chase.sapphire-preferred',
      'user_id': 'u1',
      'source': 'manual',
      'provider': 'Chase',
      'name': 'Chase Sapphire Preferred',
      'last_four': '1234',
    });
    await db.insert('card_overrides', {
      'card_id': 'manual:chase.sapphire-preferred',
      'user_id': 'u1',
      'manual_credit_limit': 10000.0,
      'due_day': 15,
    });
    await db.insert('card_links', {
      'user_id': 'u1',
      'card_id': 'manual:chase.sapphire-preferred',
      'card_product_id': 'chase.sapphire-preferred',
      'source': 'manual',
    });

    // The same physical card now syncs in via Sophtron.
    await repo.rebuildInstitution(
      userId: 'u1',
      institutionId: 'inst1',
      institutionName: 'Chase',
      institutionLogo: null,
      accounts: [acct('a1', last4: '1234', name: 'Sapphire')],
      txsByAccountId: const {},
    );
    final merged = await repo.mergeManualCardsWithBank(
      userId: 'u1',
      institutionName: 'Chase',
    );
    expect(merged, 1);

    final cards = await db.query('cards', where: "user_id = 'u1'");
    expect(cards, hasLength(1), reason: 'the manual row is collapsed away');
    final bankCard = cards.single;
    expect(bankCard['source'], 'bank');
    expect(
      bankCard['originated_manual'],
      1,
      reason: 'breadcrumb for dropMissingInstitutions to demote later',
    );
    final bankCardId = bankCard['id'] as String;

    final overrides = await db.query(
      'card_overrides',
      where: 'card_id = ?',
      whereArgs: [bankCardId],
    );
    expect(overrides.single['manual_credit_limit'], 10000.0);
    expect(overrides.single['due_day'], 15);

    final links = await db.query(
      'card_links',
      where: 'card_id = ?',
      whereArgs: [bankCardId],
    );
    expect(
      links.single['card_product_id'],
      'chase.sapphire-preferred',
      reason:
          'catalog binding must survive the merge, not dangle on the '
          'deleted manual card_id',
    );
  });

  test('dropMissingInstitutions demotes an originated_manual card to '
      'source=manual (keeping its overrides + transactions) instead of '
      'deleting it, but still wipes a card that was never manual', () async {
    await seedUser('u1');
    final repo = BankWriteRepository(DatabaseHelper());
    final db = await DatabaseHelper().database;
    final now = DateTime.utc(2026, 1, 1, 12);

    await db.insert('bank_connections', {
      'user_institution_id': 'mem1',
      'user_id': 'u1',
      'institution_id': 'inst1',
      'created_at': now.subtract(const Duration(hours: 1)).toIso8601String(),
    });

    const manualOriginId = 'bank:inst1:1234:sapphire';
    await db.insert('cards', {
      'id': manualOriginId,
      'user_id': 'u1',
      'source': 'bank',
      'provider': 'Chase',
      'name': 'Sapphire Preferred',
      'last_four': '1234',
      'institution_id': 'inst1',
      'originated_manual': 1,
    });
    await db.insert('card_overrides', {
      'card_id': manualOriginId,
      'user_id': 'u1',
      'manual_credit_limit': 10000.0,
    });
    await db.insert('transactions', {
      'id': 'tx1',
      'user_id': 'u1',
      'card_id': manualOriginId,
      'amount': 5.0,
      'type': 'DEBIT',
    });

    const pureBankId = 'bank:inst1:5678:checking';
    await db.insert('cards', {
      'id': pureBankId,
      'user_id': 'u1',
      'source': 'bank',
      'provider': 'Chase',
      'name': 'Checking',
      'last_four': '5678',
      'institution_id': 'inst1',
    });
    await db.insert('transactions', {
      'id': 'tx2',
      'user_id': 'u1',
      'card_id': pureBankId,
      'amount': 2.0,
      'type': 'DEBIT',
    });

    await repo.dropMissingInstitutions(
      userId: 'u1',
      keepInstitutionIds: const {},
      keepMemberIds: const {},
      now: now,
    );

    final demoted = await db.query(
      'cards',
      where: 'id = ?',
      whereArgs: [manualOriginId],
    );
    expect(
      demoted,
      hasLength(1),
      reason: 'originated_manual card must survive, demoted not deleted',
    );
    expect(demoted.single['source'], 'manual');
    expect(
      demoted.single['institution_id'],
      CardRepository.manualInstitutionId('Chase'),
      reason:
          'demoted card groups into "Chase (Manual)" alongside any other '
          'manual Chase card, not the flat legacy Manual bucket',
    );

    final demotedTx = await db.query(
      'transactions',
      where: 'card_id = ?',
      whereArgs: [manualOriginId],
    );
    expect(
      demotedTx,
      hasLength(1),
      reason: 'demoted card keeps its transaction history',
    );

    final demotedOverrides = await db.query(
      'card_overrides',
      where: 'card_id = ?',
      whereArgs: [manualOriginId],
    );
    expect(demotedOverrides.single['manual_credit_limit'], 10000.0);

    final pureBankCard = await db.query(
      'cards',
      where: 'id = ?',
      whereArgs: [pureBankId],
    );
    expect(
      pureBankCard,
      isEmpty,
      reason: 'a card that was never manual is deleted as before',
    );
    final pureBankTx = await db.query(
      'transactions',
      where: 'card_id = ?',
      whereArgs: [pureBankId],
    );
    expect(
      pureBankTx,
      isEmpty,
      reason: 'transactions for a genuinely-gone bank card are wiped as before',
    );
  });

  test(
    'upsertConnection preserves created_at / last_synced_at / last_sync_status across re-syncs',
    () async {
      await seedUser('u1');
      final repo = BankWriteRepository(DatabaseHelper());
      final db = await DatabaseHelper().database;

      // First link: stamps created_at, then a sync records a result on the row.
      await repo.upsertConnection(
        userId: 'u1',
        userInstitutionId: 'mem1',
        memberId: 'mem1',
        institutionId: 'inst1',
        institutionName: 'Old Name',
        institutionLogo: null,
      );
      await repo.setConnectionLastSyncedAt('mem1', DateTime.utc(2026, 1, 1));
      await repo.setConnectionSyncStatus(
        'mem1',
        status: 'failed',
        error: 'boom',
      );

      final before = (await db.query(
        'bank_connections',
        where: 'user_institution_id = ?',
        whereArgs: ['mem1'],
      )).single;
      final createdAt = before['created_at'];
      expect(createdAt, isNotNull);

      // A later sync upserts the same member with refreshed institution metadata.
      await repo.upsertConnection(
        userId: 'u1',
        userInstitutionId: 'mem1',
        memberId: 'mem1',
        institutionId: 'inst1',
        institutionName: 'New Name',
        institutionLogo: 'logo.png',
      );

      final after = (await db.query(
        'bank_connections',
        where: 'user_institution_id = ?',
        whereArgs: ['mem1'],
      )).single;
      expect(
        after['institution_name'],
        'New Name',
        reason: 'metadata refreshes',
      );
      expect(after['institution_logo'], 'logo.png');
      expect(
        after['created_at'],
        createdAt,
        reason:
            'created_at must NOT reset — the abandoned-link 2h gate reads it',
      );
      expect(
        after['last_synced_at'],
        DateTime.utc(2026, 1, 1).toIso8601String(),
        reason: 'last_synced_at must survive — never-synced detection reads it',
      );
      expect(
        after['last_sync_status'],
        'failed',
        reason: 'last_sync_status must survive — the circuit breaker reads it',
      );
    },
  );
}
