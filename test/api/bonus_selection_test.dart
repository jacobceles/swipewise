import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/catalog_loader.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/engine_ranker.dart';
import 'package:swipewise/api/remote_asset_service.dart';
import 'package:swipewise/api/reward_engine.dart';
import 'package:swipewise/models/reward_category.dart';

/// Pins selectable bonus categories (N17).
///
/// Some cards pay their headline rate only on categories the cardholder
/// *selected* (Bank of America Customized Cash: "choose 1 of 9"), or that the
/// issuer picks from spend the app can't see (Amex Business Gold: "your top 2
/// each cycle"). The ranker used to credit every one of those rules
/// unconditionally, which recommended a 6% card for EV charging to someone who
/// had chosen home improvement and would have earned 1%.
///
/// Two halves here: the ranker must credit a member rule only when it can
/// prove the rule is live, and the *user's* choices must survive the catalog
/// wipe that runs on every sync.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // ─────────────── the ranker (pure, no DB) ───────────────

  group('ranking only credits a selectable bonus it can prove is live', () {
    final when = DateTime(2026, 8, 22);

    const boaGroup = 'boa.cash#sel-u1-month';
    const amexGroup = 'amex.biz-gold#sel-a2-month';
    const cashPlus5 = 'usbank.cash-plus#sel-u1-quarter';
    const cashPlus2 = 'usbank.cash-plus#sel-u2-quarter';

    RewardRule rule(
      String product,
      String id, {
      required RewardCategory category,
      required double rate,
      String? selectionGroup,
    }) => RewardRule(
      ruleId: id,
      productId: product,
      kind: RewardRuleKind.category,
      category: category,
      rate: rate,
      pointSystemId: 'usd',
      selectionGroup: selectionGroup,
    );

    RewardRule baseline(String product, double rate) => RewardRule(
      ruleId: '$product#base',
      productId: product,
      kind: RewardRuleKind.baseline,
      rate: rate,
      pointSystemId: 'usd',
    );

    BonusSelectionGroup group(
      String id,
      String product,
      BonusSelectionMode mode, {
      int choose = 1,
    }) => BonusSelectionGroup(
      groupId: id,
      productId: product,
      choose: choose,
      mode: mode,
      period: 'month',
    );

    CatalogSnapshot snap(
      List<RewardRule> rules,
      List<BonusSelectionGroup> groups,
    ) {
      final products = <String, CardProduct>{};
      final byProduct = <String, List<RewardRule>>{};
      for (final r in rules) {
        products.putIfAbsent(
          r.productId,
          () => CardProduct(
            id: r.productId,
            issuer: 'x',
            displayName: r.productId,
            catalogVersion: 't',
          ),
        );
        (byProduct[r.productId] ??= []).add(r);
      }
      return CatalogSnapshot(
        products: products,
        rulesByProduct: byProduct,
        exclusionsByRule: const {},
        pointSystems: {
          'usd': const PointSystem(
            id: 'usd',
            displayName: 'usd',
            baselineCentValue: 1.0,
          ),
        },
        selectionGroups: {for (final g in groups) g.groupId: g},
      );
    }

    // A wallet of three cards: one "choose 1 of 2" card, one "top 2 of 2"
    // card, and a plain 2% card with no selectable anything.
    final catalog = snap(
      [
        rule(
          'boa.cash',
          'boa#ev',
          category: RewardCategory.evCharging,
          rate: 6,
          selectionGroup: boaGroup,
        ),
        rule(
          'boa.cash',
          'boa#home',
          category: RewardCategory.homeImprovement,
          rate: 6,
          selectionGroup: boaGroup,
        ),
        baseline('boa.cash', 1),
        rule(
          'amex.biz-gold',
          'amex#dining',
          category: RewardCategory.dining,
          rate: 4,
          selectionGroup: amexGroup,
        ),
        baseline('amex.biz-gold', 1),
        rule('flat', 'flat#dining', category: RewardCategory.dining, rate: 2),
        baseline('flat', 1.5),
      ],
      [
        group(boaGroup, 'boa.cash', BonusSelectionMode.userChoice),
        group(
          amexGroup,
          'amex.biz-gold',
          BonusSelectionMode.automatic,
          choose: 2,
        ),
      ],
    );

    final links = [
      const LinkedCard(
        cardId: 'c-boa',
        cardProductId: 'boa.cash',
        cardName: 'Customized Cash',
      ),
      const LinkedCard(
        cardId: 'c-amex',
        cardProductId: 'amex.biz-gold',
        cardName: 'Business Gold',
      ),
      const LinkedCard(
        cardId: 'c-flat',
        cardProductId: 'flat',
        cardName: 'Flat Card',
      ),
    ];

    EngineRanker ranker(
      CatalogSnapshot s,
      List<LinkedCard> l, {
      Map<String, Set<RewardCategory>> chosen = const {},
    }) => EngineRanker(
      snapshot: s,
      linkedCards: l,
      when: when,
      selectedBonusCategories: chosen,
    );

    test('an unanswered user_choice bonus is not credited anywhere', () {
      final r = ranker(catalog, links);
      // No tile at all: nothing in the wallet earns a bonus on EV charging,
      // so the category isn't even a candidate.
      expect(
        r.bestCardByCategory().byCategory,
        isNot(contains(RewardCategory.evCharging)),
      );
      // The browsable grid still answers, but with the truth: the best
      // everyday rate, flagged as not-a-bonus.
      final grid = r.bestCardByCategoryAll().firstWhere(
        (p) => p.category == RewardCategory.evCharging,
      );
      expect(grid.cardId, 'c-flat');
      expect(grid.rate, 1.5);
      expect(grid.isBonus, isFalse);
    });

    test('choosing the OTHER category still does not credit this one', () {
      final r = ranker(
        catalog,
        links,
        chosen: {
          boaGroup: {RewardCategory.homeImprovement},
        },
      );
      final grid = r.bestCardByCategoryAll();
      // The bug, precisely: 6% on EV charging for a cardholder who picked home
      // improvement and would really earn 1%.
      final ev = grid.firstWhere(
        (p) => p.category == RewardCategory.evCharging,
      );
      expect(ev.cardId, 'c-flat');
      expect(ev.rate, 1.5);
      // ...while the category they DID pick wins on the same card.
      final home = grid.firstWhere(
        (p) => p.category == RewardCategory.homeImprovement,
      );
      expect(home.cardId, 'c-boa');
      expect(home.rate, 6);
      expect(home.isBonus, isTrue);
    });

    test('a chosen user_choice bonus is credited like any other rule', () {
      final r = ranker(
        catalog,
        links,
        chosen: {
          boaGroup: {RewardCategory.evCharging},
        },
      );
      final best = r.bestCardByCategory().byCategory[RewardCategory.evCharging];
      expect(best?.id, 'c-boa');
      expect(best?.rate, 6);
    });

    test('an automatic bonus is never credited, however it is answered', () {
      // The issuer picks from spend the app can't see, so even a stored answer
      // proves nothing. Dining falls to the plain 2% card, not Amex's 4x.
      for (final chosen in <Map<String, Set<RewardCategory>>>[
        const {},
        {
          amexGroup: {RewardCategory.dining},
        },
      ]) {
        final best = ranker(
          catalog,
          links,
          chosen: chosen,
        ).bestCardByCategory().byCategory[RewardCategory.dining];
        expect(best?.id, 'c-flat');
        expect(best?.rate, 2);
      }
    });

    test('a group missing from the catalog is treated as unprovable', () {
      // A rule pointing at a group the catalog doesn't carry can't be shown to
      // be live, so it must not win — the same call as `automatic`.
      final orphaned = snap([
        rule(
          'boa.cash',
          'boa#ev',
          category: RewardCategory.evCharging,
          rate: 6,
          selectionGroup: 'boa.cash#gone',
        ),
        baseline('boa.cash', 1),
      ], const []);
      final best = ranker(orphaned, [
        links.first,
      ]).bestCardByCategory().byCategory[RewardCategory.evCharging];
      expect(best, isNull);
    });

    test('two groups on one card resolve independently', () {
      // U.S. Bank Cash+: choose 1 of 2 at 5%, and choose 2 of 2 at 2%.
      final cashPlus = snap(
        [
          rule(
            'usbank.cash-plus',
            'cp#gas5',
            category: RewardCategory.gas,
            rate: 5,
            selectionGroup: cashPlus5,
          ),
          rule(
            'usbank.cash-plus',
            'cp#grocery5',
            category: RewardCategory.grocery,
            rate: 5,
            selectionGroup: cashPlus5,
          ),
          rule(
            'usbank.cash-plus',
            'cp#dining2',
            category: RewardCategory.dining,
            rate: 2,
            selectionGroup: cashPlus2,
          ),
          rule(
            'usbank.cash-plus',
            'cp#transit2',
            category: RewardCategory.transit,
            rate: 2,
            selectionGroup: cashPlus2,
          ),
          baseline('usbank.cash-plus', 1),
        ],
        [
          group(cashPlus5, 'usbank.cash-plus', BonusSelectionMode.userChoice),
          group(
            cashPlus2,
            'usbank.cash-plus',
            BonusSelectionMode.userChoice,
            choose: 2,
          ),
        ],
      );
      final card = [
        const LinkedCard(
          cardId: 'c-cp',
          cardProductId: 'usbank.cash-plus',
          cardName: 'Cash+',
        ),
      ];
      final byCategory = ranker(
        cashPlus,
        card,
        chosen: {
          cashPlus5: {RewardCategory.grocery},
          cashPlus2: {RewardCategory.dining, RewardCategory.transit},
        },
      ).bestCardByCategory().byCategory;

      // Answering the 5% group does not unlock the 2% group's other member...
      expect(byCategory[RewardCategory.grocery]?.rate, 5);
      expect(byCategory, isNot(contains(RewardCategory.gas)));
      // ...and both picks in the choose-2 group are live at once.
      expect(byCategory[RewardCategory.dining]?.rate, 2);
      expect(byCategory[RewardCategory.transit]?.rate, 2);
    });

    test('the reward-ranking sheet drops the card to what it really pays', () {
      final rows = ranker(
        catalog,
        links,
        chosen: {
          boaGroup: {RewardCategory.homeImprovement},
        },
      ).rewardRanking(RewardCategory.evCharging).general;
      final boa = rows.firstWhere((r) => r.cardId == 'c-boa');
      expect(boa.rate, 1, reason: 'baseline, not the unselected 6%');
      expect(rows.first.cardId, 'c-flat');
    });

    test('the input snapshot is left intact — only ranking narrows', () {
      final r = ranker(catalog, links);
      r.bestCardByCategory();
      expect(r.snapshot.rulesByProduct['boa.cash'], hasLength(3));
    });
  });

  // ─────────────── ingest + persistence (DB) ───────────────

  group('catalog ingest and the user\'s own picks', () {
    setUp(() {
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

    CatalogRepository repo() => CatalogRepository(DatabaseHelper());

    test('bonus_selections and selection_group land in the DB', () async {
      await seedUser('u1');
      expect(
        await CatalogLoader(
          remote: _InlineCatalog(_catalog()),
        ).hydrateIfNeeded('u1'),
        CatalogLoadResult.loaded,
      );

      final groups = await repo().selectionGroupsForProduct('usbank.cash-plus');
      expect(groups, hasLength(2));
      // The JSON key is `id`; the column is `group_id`.
      expect(groups.map((g) => g.groupId), contains(_group5));
      final five = groups.firstWhere((g) => g.groupId == _group5);
      expect(five.choose, 1);
      expect(five.mode, BonusSelectionMode.userChoice);
      expect(five.period, 'quarter');
      expect(
        groups.firstWhere((g) => g.groupId == _groupAuto).mode,
        BonusSelectionMode.automatic,
      );

      final snapshot = await repo().loadSnapshot();
      expect(snapshot.selectionGroups, hasLength(2));
      final rules = snapshot.rulesByProduct['usbank.cash-plus']!;
      expect(
        rules.firstWhere((r) => r.ruleId == 'cp#gas').selectionGroup,
        _group5,
      );
      expect(
        rules.firstWhere((r) => r.ruleId == 'cp#base').selectionGroup,
        isNull,
      );
    });

    test('a catalog with no bonus_selections imports cleanly', () async {
      // Every bundle published before N17 — including the offline floor inside
      // the APK — has neither key.
      await seedUser('u1');
      final legacy = _catalog()
        ..remove('bonus_selections')
        ..['reward_rules'] = [
          for (final r in _rules()) {...r}..remove('selection_group'),
        ];
      expect(
        await CatalogLoader(
          remote: _InlineCatalog(legacy),
        ).hydrateIfNeeded('u1'),
        CatalogLoadResult.loaded,
      );
      expect(
        await repo().selectionGroupsForProduct('usbank.cash-plus'),
        isEmpty,
      );
    });

    test('a full catalog replace keeps the user\'s selections', () async {
      await seedUser('u1');
      await CatalogLoader(
        remote: _InlineCatalog(_catalog()),
      ).hydrateIfNeeded('u1');
      await repo().setBonusSelection(
        groupId: _group5,
        cardProductId: 'usbank.cash-plus',
        categories: const [RewardCategory.grocery],
      );

      // A publish moves dataVersion, so the next boot wipes and re-imports
      // every catalog table. The one thing it must not cost the user is the
      // choice they made.
      final republished = _catalog()..['dataVersion'] = 2;
      expect(
        await CatalogLoader(
          remote: _InlineCatalog(republished),
        ).hydrateIfNeeded('u1'),
        CatalogLoadResult.loaded,
      );

      expect(await repo().bonusSelections(), {
        _group5: {RewardCategory.grocery},
      });
      // ...while the catalog half was genuinely replaced, not appended to.
      final db = await DatabaseHelper().database;
      expect(await db.query('bonus_selection_groups'), hasLength(2));
    });

    test('a selection write is scoped to its own group', () async {
      await seedUser('u1');
      await CatalogLoader(
        remote: _InlineCatalog(_catalog()),
      ).hydrateIfNeeded('u1');
      final r = repo();
      await r.setBonusSelection(
        groupId: _group5,
        cardProductId: 'usbank.cash-plus',
        categories: const [RewardCategory.gas],
      );
      await r.setBonusSelection(
        groupId: _groupAuto,
        cardProductId: 'usbank.cash-plus',
        categories: const [RewardCategory.dining],
      );

      // Re-answering one group replaces only that group's rows.
      await r.setBonusSelection(
        groupId: _group5,
        cardProductId: 'usbank.cash-plus',
        categories: const [RewardCategory.grocery],
      );
      expect(await r.bonusSelections(), {
        _group5: {RewardCategory.grocery},
        _groupAuto: {RewardCategory.dining},
      });

      // An empty pick clears that group and leaves the other alone.
      await r.setBonusSelection(
        groupId: _group5,
        cardProductId: 'usbank.cash-plus',
        categories: const [],
      );
      expect(await r.bonusSelections(), {
        _groupAuto: {RewardCategory.dining},
      });
    });

    test('the card\'s own rewards list still shows the rule', () async {
      // Ranking hides an unselected bonus; the card detail must not. The card
      // really does pay 5% on gas once gas is the pick, and dropping the row
      // would be its own kind of wrong.
      await seedUser('u1');
      await CatalogLoader(
        remote: _InlineCatalog(_catalog()),
      ).hydrateIfNeeded('u1');
      final db = await DatabaseHelper().database;
      await db.insert('cards', {
        'id': 'c1',
        'user_id': 'u1',
        'source': 'manual',
        'name': 'Cash+',
      });
      final r = repo();
      await r.upsertLink(
        userId: 'u1',
        cardId: 'c1',
        cardProductId: 'usbank.cash-plus',
        source: 'user_confirmed',
      );
      final rewards = await r.rewardsForCard('u1', 'c1');
      expect(
        rewards.map((w) => w.ruleId),
        containsAll(<String>['cp#gas', 'cp#grocery', 'cp#dining']),
      );
    });

    test('rotating quarters split into the live one and the next', () async {
      // The catalog carries a rotating card's past and announced-ahead quarters
      // too (Freedom Flex shipped Q3 2026, Q4 2026 and Q1 2027 together), and
      // listing them all showed "Grocery (rotating)" twice.
      Map<String, Object?> rotating(
        String id,
        String category,
        int year,
        int q,
      ) => {
        'rule_id': id,
        'card_product_id': 'usbank.cash-plus',
        'kind': 'rotating',
        'category': category,
        'rate': 5.0,
        'point_system_id': 'usd',
        'rotation_year': year,
        'rotation_quarter': q,
      };
      await seedUser('u1');
      await CatalogLoader(
        remote: _InlineCatalog(
          _catalog(
            extraRules: [
              rotating('rot#q3-gas', 'gas', 2026, 3),
              rotating('rot#q4-grocery', 'grocery', 2026, 4),
              rotating('rot#q1-grocery', 'grocery', 2027, 1),
            ],
          ),
        ),
      ).hydrateIfNeeded('u1');
      final db = await DatabaseHelper().database;
      await db.insert('cards', {
        'id': 'c1',
        'user_id': 'u1',
        'source': 'manual',
        'name': 'Cash+',
      });
      final r = repo();
      await r.upsertLink(
        userId: 'u1',
        cardId: 'c1',
        cardProductId: 'usbank.cash-plus',
        source: 'user_confirmed',
      );

      Future<List<List<String>?>> quarters(DateTime now) async {
        final s = await r.rotatingScheduleForCard('u1', 'c1', now: now);
        return [
          s?.current?.rows.map((w) => w.ruleId).toList(),
          s?.next?.rows.map((w) => w.ruleId).toList(),
        ];
      }

      expect(await quarters(DateTime(2026, 10, 14)), [
        ['rot#q4-grocery'],
        ['rot#q1-grocery'],
      ]);
      // Nothing announced past Q1 2027 yet.
      expect(await quarters(DateTime(2027, 1, 15)), [
        ['rot#q1-grocery'],
        null,
      ]);
      final q4 = (await r.rotatingScheduleForCard(
        'u1',
        'c1',
        now: DateTime(2026, 10, 14),
      ))!.current!;
      expect((q4.start, q4.end), (DateTime(2026, 10), DateTime(2026, 12, 31)));
      // The flat list keeps only the fixed rules.
      final all = await r.rewardsForCard('u1', 'c1');
      expect(all.map((w) => w.ruleId), isNot(contains(startsWith('rot#'))));
      expect(all.map((w) => w.ruleId), contains('cp#base'));
    });
  });
}

const _group5 = 'usbank.cash-plus#sel-u1-quarter';
const _groupAuto = 'usbank.cash-plus#sel-a2-month';

List<Map<String, Object?>> _rules() => [
  {
    'rule_id': 'cp#gas',
    'card_product_id': 'usbank.cash-plus',
    'kind': 'category',
    'category': 'gas',
    'rate': 5.0,
    'point_system_id': 'usd',
    'selection_group': _group5,
  },
  {
    'rule_id': 'cp#grocery',
    'card_product_id': 'usbank.cash-plus',
    'kind': 'category',
    'category': 'grocery',
    'rate': 5.0,
    'point_system_id': 'usd',
    'selection_group': _group5,
  },
  {
    'rule_id': 'cp#dining',
    'card_product_id': 'usbank.cash-plus',
    'kind': 'category',
    'category': 'dining',
    'rate': 4.0,
    'point_system_id': 'usd',
    'selection_group': _groupAuto,
  },
  {
    'rule_id': 'cp#base',
    'card_product_id': 'usbank.cash-plus',
    'kind': 'baseline',
    'category': null,
    'rate': 1.0,
    'point_system_id': 'usd',
    'selection_group': null,
  },
];

/// A minimal published catalog carrying both a `user_choice` and an
/// `automatic` group on the same product.
Map<String, Object?> _catalog({
  List<Map<String, Object?>> extraRules = const [],
}) => {
  'schemaVersion': 1,
  'dataVersion': 1,
  'point_systems': [
    {
      'point_system_id': 'usd',
      'display_name': 'Cash back',
      'baseline_cent_value': 1.0,
    },
  ],
  'card_products': [
    {
      'card_product_id': 'usbank.cash-plus',
      'issuer': 'Usbank',
      'display_name': 'U.S. Bank Cash+',
      'catalog_version': '2026.08.22',
      'foreign_tx_fee_pct': 0.0,
    },
  ],
  'reward_rules': [..._rules(), ...extraRules],
  'reward_rule_exclusions': <Map<String, Object?>>[],
  'product_perks': <Map<String, Object?>>[],
  'bonus_selections': [
    {
      'id': _group5,
      'card_product_id': 'usbank.cash-plus',
      'choose': 1,
      'mode': 'user_choice',
      'period': 'quarter',
    },
    {
      'id': _groupAuto,
      'card_product_id': 'usbank.cash-plus',
      'choose': 2,
      'mode': 'automatic',
      'period': 'month',
    },
  ],
};

/// Serves an in-test catalog through the loader's cache path, so hydration is
/// exercised end to end without touching R2 or the bundled asset.
class _InlineCatalog extends RemoteAssetService {
  _InlineCatalog(this.data);
  final Map<String, Object?> data;

  @override
  Future<String?> readCached(String key) async =>
      key == 'catalog' ? jsonEncode(data) : null;
}
