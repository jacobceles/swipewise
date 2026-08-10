import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/engine_ranker.dart';
import 'package:swipewise/models/reward_category.dart';

/// Pins the assume-activated contract: the app has no activation toggle, so the
/// ranker credits an activation-required rotating bonus regardless of activation
/// state. The `rotating_activations` plumbing still persists (retained for a future
/// opt-in toggle) but no longer gates ranking.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late CatalogRepository catalog;
  final when = DateTime(2026, 2, 15); // Q1 2026

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
    await db.insert('cards', {
      'id': 'c1',
      'user_id': 'u1',
      'source': 'manual',
      'name': 'Flex',
    });

    await catalog.replaceCatalog(
      pointSystems: const [
        {
          'point_system_id': 'usd',
          'display_name': 'USD',
          'baseline_cent_value': 1.0,
          'valuation_source': 't',
          'valuation_updated_at': null,
        },
      ],
      cardProducts: const [
        {
          'card_product_id': 'flex',
          'issuer': 'Chase',
          'display_name': 'Flex',
          'network': null,
          'annual_fee_usd': null,
          'foreign_tx_fee_pct': 0.0,
          'image_url': null,
          'catalog_version': 't',
          'retired_at': null,
        },
      ],
      rewardRules: const [
        {
          'rule_id': 'flex#base',
          'card_product_id': 'flex',
          'kind': 'baseline',
          'category': null,
          'brand': null,
          'rate': 1.0,
          'point_system_id': 'usd',
          'valid_from': null,
          'valid_to': null,
          'rotation_year': null,
          'rotation_quarter': null,
          'requires_activation': 0,
          'cap_spend_amount_usd': null,
          'cap_period': null,
          'cap_group': null,
          'notes': null,
        },
        {
          'rule_id': 'flex#rot',
          'card_product_id': 'flex',
          'kind': 'rotating',
          'category': 'dining',
          'brand': null,
          'rate': 5.0,
          'point_system_id': 'usd',
          'valid_from': null,
          'valid_to': null,
          'rotation_year': 2026,
          'rotation_quarter': 1,
          'requires_activation': 1,
          'cap_spend_amount_usd': null,
          'cap_period': null,
          'cap_group': null,
          'notes': null,
        },
      ],
      exclusions: const [],
    );
    await catalog.upsertLink(
      userId: 'u1',
      cardId: 'c1',
      cardProductId: 'flex',
      source: 'user_confirmed',
    );
  });

  tearDown(() async {
    final db = await DatabaseHelper().database;
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<EngineRanker> ranker() async => EngineRanker(
    snapshot: await catalog.loadSnapshot(),
    linkedCards: await catalog.linkedCards('u1'),
    when: when,
    activationsByCard: await catalog.activations('u1'),
  );

  test(
    'rotating card ranks at its bonus rate with no activation (assumed activated)',
    () async {
      final r = (await ranker()).rewardRanking(RewardCategory.dining);
      expect(r.general.single.rate, 5.0);
    },
  );

  test(
    'activation state does not change the ranking (gate is dormant)',
    () async {
      // Explicitly deactivating must NOT demote the bonus — the ranker ignores activation.
      await catalog.setActivation(
        userId: 'u1',
        cardId: 'c1',
        year: 2026,
        quarter: 1,
        activated: false,
      );
      final r = (await ranker()).rewardRanking(RewardCategory.dining);
      expect(r.general.single.rate, 5.0);
    },
  );

  test(
    'setActivation still persists (plumbing retained for a future toggle)',
    () async {
      await catalog.setActivation(
        userId: 'u1',
        cardId: 'c1',
        year: 2026,
        quarter: 1,
        activated: true,
      );
      final acts = await catalog.activations('u1');
      expect(acts['c1'], contains((2026, 1)));
    },
  );
}
