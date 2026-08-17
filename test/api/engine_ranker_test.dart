import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/engine_ranker.dart';
import 'package:swipewise/api/reward_category_mapper.dart';
import 'package:swipewise/api/reward_engine.dart';
import 'package:swipewise/models/reward_category.dart';

/// Pure tests for the ranking loops that turn the engine into the UI's
/// best-card / catch-all / ranking outputs — the coverage the old
/// SQL-ranker integration test used to provide, now DB-free.
void main() {
  final when = DateTime(2026, 2, 15);

  RewardRule rule(
    String product,
    String id,
    RewardRuleKind kind, {
    RewardCategory? category,
    String? brand,
    required double rate,
    String ps = 'usd',
  }) => RewardRule(
    ruleId: id,
    productId: product,
    kind: kind,
    category: category,
    brand: brand,
    rate: rate,
    pointSystemId: ps,
  );

  CatalogSnapshot snap(
    List<RewardRule> rules, {
    Map<String, double> ps = const {'usd': 1.0},
  }) {
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
        for (final e in ps.entries)
          e.key: PointSystem(
            id: e.key,
            displayName: e.key,
            baselineCentValue: e.value,
          ),
      },
    );
  }

  LinkedCard link(String cardId, String product, String name) =>
      LinkedCard(cardId: cardId, cardProductId: product, cardName: name);

  EngineRanker ranker(
    CatalogSnapshot s,
    List<LinkedCard> links, {
    List<String> pref = const [],
  }) => EngineRanker(
    snapshot: s,
    linkedCards: links,
    when: when,
    cardPreferenceOrder: pref,
  );

  final catalog = snap([
    rule(
      'a',
      'a#cat',
      RewardRuleKind.category,
      category: RewardCategory.dining,
      rate: 3,
    ),
    rule('a', 'a#base', RewardRuleKind.baseline, rate: 1),
    rule(
      'b',
      'b#cat',
      RewardRuleKind.category,
      category: RewardCategory.dining,
      rate: 2,
    ),
    rule('b', 'b#base', RewardRuleKind.baseline, rate: 1.5),
    rule(
      'b',
      'b#brand',
      RewardRuleKind.brand,
      category: RewardCategory.dining,
      brand: 'chipotle',
      rate: 5,
    ),
  ]);
  final links = [link('c1', 'a', 'Card A'), link('c2', 'b', 'Card B')];

  test('best card per category picks the highest effective rate', () {
    final lookup = ranker(catalog, links).bestCardByCategory();
    expect(lookup.byCategory[RewardCategory.dining]?.id, 'c1'); // 3% > 2%
    expect(lookup.byCategory[RewardCategory.dining]?.rate, 3);
  });

  test('best catch-all card is the highest baseline', () {
    final pick = ranker(catalog, links).bestCatchAllCard();
    expect(pick?.id, 'c2'); // 1.5% > 1%
    expect(pick?.rate, 1.5);
  });

  group('bestCardByCategoryAll — the browsable Categories grid', () {
    test('covers every category, not just the ones a card names', () {
      final all = ranker(catalog, links).bestCardByCategoryAll();
      expect(
        all.map((p) => p.category).toSet(),
        RewardCategory.values.toSet(),
        reason:
            'a category with no bonus must still appear, showing the best '
            'everyday rate — hiding it reads as "SwipeWise does not know '
            'this category exists"',
      );
    });

    test('flags a bonus as a bonus and a fallback as baseline', () {
      final byCat = {
        for (final p in ranker(catalog, links).bestCardByCategoryAll())
          p.category: p,
      };
      // dining has a real 3% category rule on Card A.
      expect(byCat[RewardCategory.dining]!.isBonus, isTrue);
      expect(byCat[RewardCategory.dining]!.rate, 3);
      // Nothing names transit, so it falls back to the best baseline (1.5%).
      expect(byCat[RewardCategory.transit]!.isBonus, isFalse);
      expect(byCat[RewardCategory.transit]!.rate, 1.5);
      expect(byCat[RewardCategory.transit]!.cardId, 'c2');
    });

    test('a wallet that earns nothing reports 0%, not a missing tile', () {
      // A no-baseline card — secured / balance-transfer / store, which is 118
      // of the catalog's 410 products. 0% is the real rate these pay, so the
      // category still gets a tile; there is just no card to crown.
      final storeOnly = snap([
        rule(
          's',
          's#brand',
          RewardRuleKind.brand,
          category: RewardCategory.apparel,
          brand: 'gap',
          rate: 5,
        ),
      ]);
      final r = ranker(storeOnly, [link('c9', 's', 'Store Card')]);
      final byCat = {for (final p in r.bestCardByCategoryAll()) p.category: p};

      expect(byCat.keys.toSet(), RewardCategory.values.toSet());
      final grocery = byCat[RewardCategory.grocery]!;
      expect(grocery.rate, 0);
      expect(grocery.isBonus, isFalse);
      expect(
        grocery.cardName,
        isNull,
        reason: 'every card ties at nothing, so naming a winner would mislead',
      );

      // And the sheet behind that tile lists the cards at 0 rather than being
      // empty — an empty sheet reads as a bug, not as an answer.
      final sheet = r.rewardRanking(RewardCategory.grocery);
      expect(sheet.general, hasLength(1));
      expect(sheet.general.single.rate, 0);
    });

    test('a category some card DOES earn is unaffected by the 0% fallback', () {
      final r = ranker(catalog, links);
      final sheet = r.rewardRanking(RewardCategory.dining);
      expect(
        sheet.general.map((g) => g.rate),
        [3, 2],
        reason:
            'the fallback is guarded on nothing matching — a card that simply '
            'loses at dining must not appear as a 0% row',
      );
    });
  });

  test('byBrand surfaces the brand-bonus card', () {
    final lookup = ranker(catalog, links).bestCardByCategory();
    expect(lookup.byBrand['chipotle']?.id, 'c2');
    expect(lookup.byBrand['chipotle']?.rate, 5);
  });

  test('brand-bonus counts per category (regression: dynamic rule list)', () {
    // Guards the `?? const <RewardRule>[]` typing: an untyped `const []`
    // fallback makes the loop var `dynamic`, so `category.name` dispatches
    // dynamically and the `EnumName` extension getter is invisible —
    // throwing `NoSuchMethodError: ... has no instance getter 'name'`.
    final counts = ranker(catalog, links).brandBonusCountsByCategory();
    expect(counts[RewardCategory.dining], 1);
  });

  test('reward ranking returns cards sorted best-first', () {
    final r = ranker(catalog, links).rewardRanking(RewardCategory.dining);
    expect(r.general.first.cardId, 'c1');
    expect(r.general.first.isBest, isTrue);
    expect(r.general.map((e) => e.cardId), ['c1', 'c2']);
  });

  test('a tie breaks on preference order', () {
    final tied = snap([
      rule(
        'a',
        'a#cat',
        RewardRuleKind.category,
        category: RewardCategory.dining,
        rate: 3,
      ),
      rule('a', 'a#base', RewardRuleKind.baseline, rate: 1),
      rule(
        'b',
        'b#cat',
        RewardRuleKind.category,
        category: RewardCategory.dining,
        rate: 3,
      ),
      rule('b', 'b#base', RewardRuleKind.baseline, rate: 1),
    ]);
    // c2 preferred over c1 → wins the tie despite equal rate.
    final lookup = ranker(tied, links, pref: ['c2', 'c1']).bestCardByCategory();
    expect(lookup.byCategory[RewardCategory.dining]?.id, 'c2');
  });

  test('mixed-currency cards rank on cents-per-dollar, not raw rate', () {
    final mixed = snap(
      [
        rule(
          'a',
          'a#cat',
          RewardRuleKind.category,
          category: RewardCategory.dining,
          rate: 2,
          ps: 'ur',
        ),
        rule('a', 'a#base', RewardRuleKind.baseline, rate: 1),
        rule(
          'b',
          'b#cat',
          RewardRuleKind.category,
          category: RewardCategory.dining,
          rate: 3,
          ps: 'usd',
        ),
        rule('b', 'b#base', RewardRuleKind.baseline, rate: 1),
      ],
      ps: {'usd': 1.0, 'ur': 2.0},
    );
    // a: 2×2.0 = 4¢/$ beats b: 3×1.0 = 3¢/$.
    final lookup = ranker(mixed, links).bestCardByCategory();
    expect(lookup.byCategory[RewardCategory.dining]?.id, 'c1');
  });

  // `bestCardByBrand` iterates the in-memory brand registry, so these load a
  // tiny fixture: `chipotle` (dining → a card bonuses it) and `acme`
  // (officeSupply → no card bonuses it, falls to baseline).
  group('bestCardByBrand', () {
    setUp(() {
      applyBrandsJson('''
      [
        {"brandId":"chipotle","displayName":"Chipotle","category":"dining","aliases":["chipotle"]},
        {"brandId":"acme","displayName":"Acme","category":"officeSupply","aliases":["acme"]}
      ]
      ''');
    });
    tearDown(resetBrandRegistry);

    test('a brand-bonus brand surfaces as a win with the bonus card', () {
      final picks = ranker(catalog, links).bestCardByBrand();
      final chipotle = picks.firstWhere((p) => p.brandId == 'chipotle');
      expect(chipotle.cardId, 'c2'); // c2 (product b) has the 5x chipotle rule
      expect(chipotle.rate, 5);
      expect(chipotle.isBonus, isTrue);
    });

    test('a no-bonus brand falls to the catch-all card in the tail', () {
      final picks = ranker(catalog, links).bestCardByBrand();
      final acme = picks.firstWhere((p) => p.brandId == 'acme');
      expect(acme.cardId, 'c2'); // highest baseline (1.5%)
      expect(acme.rate, 1.5);
      expect(acme.isBonus, isFalse);
    });

    test('wins sort ahead of the baseline tail', () {
      final picks = ranker(catalog, links).bestCardByBrand();
      final iChipotle = picks.indexWhere((p) => p.brandId == 'chipotle');
      final iAcme = picks.indexWhere((p) => p.brandId == 'acme');
      expect(iChipotle, lessThan(iAcme));
    });

    test('a wallet with no baseline drops a brand with no applicable rule', () {
      final noBaseline = snap([
        rule(
          'a',
          'a#brand',
          RewardRuleKind.brand,
          category: RewardCategory.dining,
          brand: 'chipotle',
          rate: 5,
        ),
      ]);
      final picks = ranker(noBaseline, [
        link('c1', 'a', 'Card A'),
      ]).bestCardByBrand();
      final ids = picks.map((p) => p.brandId);
      expect(ids, contains('chipotle')); // brand rule still applies
      expect(ids, isNot(contains('acme'))); // no rule, no baseline → dropped
    });
  });

  group('foreign-travel mode (N7)', () {
    // Two cards, identical 2% baseline; card B carries a 3% foreign-tx fee.
    final s = CatalogSnapshot(
      products: {
        'A': const CardProduct(
          id: 'A',
          issuer: 'x',
          displayName: 'A',
          catalogVersion: 't',
          // Explicit: omitting this now means *unknown*, not 0%.
          foreignTxFeePct: 0.0,
        ),
        'B': const CardProduct(
          id: 'B',
          issuer: 'x',
          displayName: 'B',
          catalogVersion: 't',
          foreignTxFeePct: 3.0,
        ),
      },
      rulesByProduct: {
        'A': [rule('A', 'a', RewardRuleKind.baseline, rate: 2.0)],
        'B': [rule('B', 'b', RewardRuleKind.baseline, rate: 2.0)],
      },
      exclusionsByRule: const {},
      pointSystems: const {
        'usd': PointSystem(
          id: 'usd',
          displayName: 'usd',
          baselineCentValue: 1.0,
        ),
      },
    );
    final links = [link('cA', 'A', 'Card A'), link('cB', 'B', 'Card B')];

    test('at home the fee is ignored — the preference breaks the tie', () {
      final ranking = EngineRanker(
        snapshot: s,
        linkedCards: links,
        when: when,
        cardPreferenceOrder: const ['cB'],
      ).rewardRanking(RewardCategory.dining).general;
      expect(ranking.first.cardId, 'cB'); // equal rate → preferred card wins
    });

    test(
      'abroad the 3% FX fee sinks card B below A, overriding the preference',
      () {
        final ranking = EngineRanker(
          snapshot: s,
          linkedCards: links,
          when: when,
          cardPreferenceOrder: const ['cB'],
          isForeign: true,
        ).rewardRanking(RewardCategory.dining).general;
        expect(ranking.first.cardId, 'cA'); // no-FX-fee card wins abroad
      },
    );
  });

  group('foreign-travel mode — unknown fee is not a free pass', () {
    // Identical 2% baselines. K is *known* to charge nothing; U's fee was never
    // captured. Nothing is docked from either, so they tie on effective rate —
    // and the preference deliberately favours the unknown card, so only the
    // tie-break can separate them.
    final s = CatalogSnapshot(
      products: {
        'K': const CardProduct(
          id: 'K',
          issuer: 'x',
          displayName: 'K',
          catalogVersion: 't',
          foreignTxFeePct: 0.0,
        ),
        'U': const CardProduct(
          id: 'U',
          issuer: 'x',
          displayName: 'U',
          catalogVersion: 't',
        ),
      },
      rulesByProduct: {
        'K': [rule('K', 'k', RewardRuleKind.baseline, rate: 2.0)],
        'U': [rule('U', 'u', RewardRuleKind.baseline, rate: 2.0)],
      },
      exclusionsByRule: const {},
      pointSystems: const {
        'usd': PointSystem(
          id: 'usd',
          displayName: 'usd',
          baselineCentValue: 1.0,
        ),
      },
    );
    final links = [link('cK', 'K', 'Card K'), link('cU', 'U', 'Card U')];

    test('abroad, a known 0% beats an unknown fee', () {
      final ranking = EngineRanker(
        snapshot: s,
        linkedCards: links,
        when: when,
        cardPreferenceOrder: const ['cU'],
        isForeign: true,
      ).rewardRanking(RewardCategory.dining).general;
      expect(ranking.first.cardId, 'cK');
    });

    test('at home the distinction is ignored — preference wins', () {
      final ranking = EngineRanker(
        snapshot: s,
        linkedCards: links,
        when: when,
        cardPreferenceOrder: const ['cU'],
      ).rewardRanking(RewardCategory.dining).general;
      expect(ranking.first.cardId, 'cU');
    });

    test('an unknown fee is never invented as a cost', () {
      // U must keep its full 2%: docking a guessed fee would be the mirror
      // -image lie of claiming it charges nothing.
      final ranking = EngineRanker(
        snapshot: s,
        linkedCards: links,
        when: when,
        isForeign: true,
      ).rewardRanking(RewardCategory.dining).general;
      final u = ranking.firstWhere((r) => r.cardId == 'cU');
      final k = ranking.firstWhere((r) => r.cardId == 'cK');
      expect(u.rate, k.rate);
    });
  });
}
