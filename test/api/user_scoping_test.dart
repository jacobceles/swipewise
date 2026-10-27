import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/bank_fdx_mapper.dart';
import 'package:swipewise/api/bank_write_repository.dart';
import 'package:swipewise/api/card_link_service.dart';
import 'package:swipewise/api/card_repository.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// Re-use satellite card/member identifiers across users so a missing owner
/// predicate cannot accidentally pass. Cards themselves have global ids.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late CatalogRepository catalog;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: DatabaseHelper.configureForTesting,
      ),
    );
    await DatabaseHelper.bootstrapSchema(db);
    DatabaseHelper.setTestDatabaseFactory(() async => db);
    catalog = CatalogRepository(DatabaseHelper());
    await db.insert('point_systems', {
      'point_system_id': 'usd',
      'display_name': 'USD',
      'baseline_cent_value': 1,
    });
    for (final (user, country, rate) in [('u1', 'CA', 1), ('u2', 'US', 2)]) {
      final cardId = user == 'u1' ? 'shared' : 'other';
      await db.insert('users', {'id': user, 'identifier': user});
      await db.insert('card_products', {
        'card_product_id': user,
        'issuer': 'Chase',
        'display_name': 'Product $user',
        'catalog_version': 't',
        'country': country,
      });
      await db.insert('cards', {
        'id': cardId,
        'user_id': user,
        'source': 'manual',
        'name': 'Card $user',
        'institution_id': 'inst',
        'last_four': '1234',
      });
      await catalog.upsertLink(
        userId: user,
        cardId: cardId,
        cardProductId: user,
        source: 'user_confirmed',
      );
      await db.insert('reward_rules', {
        'rule_id': '$user-base',
        'card_product_id': user,
        'kind': 'baseline',
        'rate': rate,
        'point_system_id': 'usd',
      });
      await db.insert('reward_rules', {
        'rule_id': '$user-rot',
        'card_product_id': user,
        'kind': 'rotating',
        'rate': rate + 4,
        'point_system_id': 'usd',
        'category': 'dining',
        'rotation_year': 2026,
        'rotation_quarter': 1,
      });
      await catalog.setActivation(
        userId: user,
        cardId: 'shared',
        year: 2026,
        quarter: user == 'u1' ? 1 : 2,
        activated: true,
      );
      await db.insert('card_overrides', {
        'user_id': user,
        'card_id': cardId,
        'custom_name': user,
        'product_identification': user,
      });
      await db.insert('bank_connections', {
        'user_id': user,
        'user_institution_id': 'member',
        'institution_id': 'inst',
        'created_at': '2026-01-01T00:00:00Z',
      });
      await db.insert('financial_accounts', {
        'id': user,
        'user_id': user,
        'linked_card_id': cardId,
      });
      await db.insert('transactions', {
        'id': 'shared',
        'user_id': user,
        'card_id': cardId,
        'card': 'Bank',
        'amount': rate,
        'currency': user == 'u1' ? 'CAD' : 'USD',
      });
    }
    // Satellites are keyed by (owner, card), and intentionally have no FK to
    // cards: orphaned links/overrides are legal and must remain owner-scoped.
    await catalog.upsertLink(
      userId: 'u2',
      cardId: 'shared',
      cardProductId: 'u2',
      source: 'user_confirmed',
    );
    await db.insert('card_overrides', {
      'user_id': 'u2',
      'card_id': 'shared',
      'custom_name': 'Other owner',
    });
  });
  tearDown(() async {
    DatabaseHelper.setTestDatabaseFactory(null);
    await db.close();
  });

  test(
    'linked cards and activations are owner-scoped even for the same card id',
    () async {
      final linked = await catalog.linkedCards('u1');
      expect(linked.map((c) => (c.cardProductId, c.cardName)), [
        ('u1', 'Card u1'),
      ]);
    },
  );

  test('activations are owner-scoped for a shared satellite card id', () async {
    expect(await catalog.activations('u1'), {
      'shared': {(2026, 1)},
    });
  });

  test('reward and rotating reads use only the caller link', () async {
    expect(
      (await catalog.rewardsForCard('u1', 'shared')).map((r) => r.ruleId),
      ['u1-base'],
    );
  });

  test('rotating schedule reads only the caller link', () async {
    final schedule = await catalog.rotatingScheduleForCard(
      'u1',
      'shared',
      now: DateTime(2026, 2, 1),
    );
    expect(schedule!.current!.rows.map((r) => r.ruleId), ['u1-rot']);
    expect(schedule.rate, 5);
  });

  test(
    'home country ignores another user bank currency and linked products',
    () async {
      expect(await DataRepository().homeCountry('u1'), 'CA');
      await db.delete('transactions', where: 'user_id = ?', whereArgs: ['u1']);
      expect(await DataRepository().homeCountry('u1'), 'CA');
    },
  );

  test(
    'manual deletion leaves the other owner card and satellites intact',
    () async {
      final before = <String, List<Map<String, Object?>>>{};
      for (final table in [
        'cards',
        'card_links',
        'card_overrides',
        'rotating_activations',
      ]) {
        before[table] = await db.query(
          table,
          where: 'user_id = ?',
          whereArgs: ['u2'],
        );
      }
      expect(
        await CardRepository(DatabaseHelper()).deleteManualCard('u1', 'shared'),
        1,
      );
      for (final table in before.keys) {
        expect(
          await db.query(table, where: 'user_id = ?', whereArgs: ['u2']),
          before[table],
          reason: table,
        );
        expect(
          await db.query(table, where: 'user_id = ?', whereArgs: ['u1']),
          isEmpty,
          reason: table,
        );
      }
    },
  );

  test(
    'seedLinks neither reads nor canonicalizes another owner card',
    () async {
      await db.delete('card_links');
      final before = await db.query(
        'cards',
        where: 'user_id = ?',
        whereArgs: ['u2'],
      );
      final result = await CardLinkService().seedLinks('u1');
      expect(result.explicit, 1);
      expect(
        (await db.query(
          'card_links',
        )).map((r) => (r['user_id'], r['card_product_id'])),
        [('u1', 'u1')],
      );
      expect(
        await db.query('cards', where: 'user_id = ?', whereArgs: ['u2']),
        before,
      );
    },
  );

  for (final rebuild in [true, false]) {
    test(
      '${rebuild ? 'rebuildInstitution' : 'dropMissingInstitutions'} leaves the bystander bank rows intact',
      () async {
        for (final user in ['u1', 'u2']) {
          final bankId = 'bank:inst:1234:$user';
          final card = (await db.query(
            'cards',
            where: 'user_id = ?',
            whereArgs: [user],
          )).single;
          await db.insert('cards', {...card, 'id': bankId, 'source': 'bank'});
          await db.update(
            'transactions',
            {'card_id': bankId},
            where: 'user_id = ?',
            whereArgs: [user],
          );
          await db.update(
            'financial_accounts',
            {'linked_card_id': bankId},
            where: 'user_id = ?',
            whereArgs: [user],
          );
          await db.delete('cards', where: 'id = ?', whereArgs: [card['id']]);
        }
        final before = <String, List<Map<String, Object?>>>{};
        for (final table in [
          'cards',
          'transactions',
          'financial_accounts',
          'bank_connections',
          'card_links',
          'card_overrides',
        ]) {
          before[table] = await db.query(
            table,
            where: 'user_id = ?',
            whereArgs: ['u2'],
          );
        }
        final bank = BankWriteRepository(DatabaseHelper());
        if (rebuild) {
          await bank.rebuildInstitution(
            userId: 'u1',
            institutionId: 'inst',
            institutionName: 'Bank',
            institutionLogo: null,
            accounts: [
              BankAccount(
                accountId: 'a1',
                raw: const {},
                accountType: 'Credit_Card',
                nickname: 'New card',
                accountNumberDisplay: '9999',
              ),
            ],
            txsByAccountId: const {},
          );
          final ownCards = await db.query(
            'cards',
            where: 'user_id = ?',
            whereArgs: ['u1'],
          );
          expect(ownCards, hasLength(1));
          expect(ownCards.single['last_four'], '9999');
        } else {
          await bank.dropMissingInstitutions(
            userId: 'u1',
            keepInstitutionIds: {},
            keepMemberIds: {},
            now: DateTime.utc(2026, 2, 1),
          );
          expect(
            await db.query(
              'bank_connections',
              where: 'user_id = ?',
              whereArgs: ['u1'],
            ),
            isEmpty,
          );
          expect(
            await db.query('cards', where: 'user_id = ?', whereArgs: ['u1']),
            isEmpty,
          );
          expect(
            await db.query(
              'transactions',
              where: 'user_id = ?',
              whereArgs: ['u1'],
            ),
            isEmpty,
          );
        }
        for (final table in before.keys) {
          expect(
            await db.query(table, where: 'user_id = ?', whereArgs: ['u2']),
            before[table],
            reason: table,
          );
        }
      },
    );
  }
}
