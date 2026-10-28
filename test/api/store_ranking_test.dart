import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/engine_ranker.dart';
import 'package:swipewise/api/reward_category_mapper.dart';
import 'package:swipewise/api/reward_engine.dart';
import 'package:swipewise/models/reward_category.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/data_providers.dart';

/// The store sheet (a ranking opened for one store / brand) and the card
/// networks a store takes. Both were wrong on the emulator 2026-10-20: at Whole
/// Foods the sheet called Prime Visa's 5% "Best" above Amex Gold's 4x (≈ 8¢),
/// and at Costco it recommended a Mastercard that a US Costco refuses.
void main() {
  final when = DateTime(2026, 2, 15);

  setUp(() {
    applyBrandsJson(
      jsonEncode([
        {
          'brandId': 'whole-foods-market',
          'displayName': 'Whole Foods Market',
          'category': 'grocery',
          'aliases': ['whole foods'],
        },
        {
          'brandId': 'safeway',
          'displayName': 'Safeway',
          'category': 'grocery',
          'aliases': ['safeway'],
        },
        {
          'brandId': 'walmart',
          'displayName': 'Walmart',
          'category': 'departmentStores',
          'aliases': ['walmart'],
        },
        {
          'brandId': 'target',
          'displayName': 'Target',
          'category': 'departmentStores',
          'aliases': ['target'],
        },
        {
          'brandId': 'home-depot',
          'displayName': 'The Home Depot',
          'category': 'homeImprovement',
          'aliases': ['home depot'],
        },
        {
          'brandId': 'costco',
          'displayName': 'Costco',
          'category': 'wholesale',
          'aliases': ['costco'],
          'acceptedNetworks': {
            'US': ['visa'],
            'CA': ['mastercard'],
          },
        },
      ]),
    );
  });
  tearDown(resetBrandRegistry);

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

  /// [networks]: product → (network, country).
  CatalogSnapshot snap(
    List<RewardRule> rules,
    Map<String, (String?, String?)> networks,
  ) {
    final byProduct = <String, List<RewardRule>>{};
    for (final r in rules) {
      (byProduct[r.productId] ??= []).add(r);
    }
    return CatalogSnapshot(
      products: {
        for (final p in byProduct.keys)
          p: CardProduct(
            id: p,
            issuer: 'x',
            displayName: p,
            catalogVersion: 't',
            network: networks[p]?.$1,
            country: networks[p]?.$2,
          ),
      },
      rulesByProduct: byProduct,
      exclusionsByRule: const {},
      pointSystems: {
        'usd': PointSystem(id: 'usd', displayName: 'usd', baselineCentValue: 1),
        'mr': PointSystem(id: 'mr', displayName: 'MR', baselineCentValue: 2),
      },
    );
  }

  EngineRanker ranker(CatalogSnapshot s, List<String> products) => EngineRanker(
    snapshot: s,
    linkedCards: [
      for (final p in products)
        LinkedCard(cardId: 'c-$p', cardProductId: p, cardName: p),
    ],
    when: when,
  );

  group('store sheet: one list, each card once, ranked by value here', () {
    final s = snap(
      [
        rule(
          'gold',
          'g#d',
          RewardRuleKind.category,
          category: RewardCategory.grocery,
          rate: 4,
          ps: 'mr',
        ),
        rule('gold', 'g#b', RewardRuleKind.baseline, rate: 1, ps: 'mr'),
        rule(
          'prime',
          'p#wf',
          RewardRuleKind.brand,
          category: RewardCategory.grocery,
          brand: 'whole-foods-market',
          rate: 5,
        ),
        rule(
          'prime',
          'p#sw',
          RewardRuleKind.brand,
          category: RewardCategory.grocery,
          brand: 'safeway',
          rate: 3,
        ),
        rule('prime', 'p#b', RewardRuleKind.baseline, rate: 1),
      ],
      {'gold': ('American Express', 'US'), 'prime': ('Visa', 'US')},
    );

    test('a store bonus competes on value instead of sitting on top', () {
      final r = ranker(s, ['gold', 'prime']).rewardRanking(
        RewardCategory.grocery,
        brandFilter: 'whole-foods-market',
      );
      expect(r.general.map((e) => e.cardName), ['gold', 'prime']);
      expect(r.general.first.isBest, isTrue); // 4x MR ≈ 8¢ beats 5%
      expect(r.general[1].rate, 5); // Prime at its Whole Foods rate, once
      expect(r.general[1].bonusBrand, 'Whole Foods Market');
      expect(r.general.first.bonusBrand, isNull);
      expect(r.brandBonuses, isEmpty); // no Safeway row at Whole Foods
    });

    test('the category sheet still lists every store bonus', () {
      final r = ranker(s, [
        'gold',
        'prime',
      ]).rewardRanking(RewardCategory.grocery);
      expect(r.brandBonuses.map((b) => b.brand), [
        'Whole Foods Market',
        'Safeway',
      ]);
      expect(r.general.every((e) => e.bonusBrand == null), isTrue);
    });
  });

  group('a store that only takes some networks', () {
    final s = snap(
      [
        rule('dc', 'dc#b', RewardRuleKind.baseline, rate: 2),
        rule(
          'costcovisa',
          'cv#c',
          RewardRuleKind.brand,
          category: RewardCategory.wholesale,
          brand: 'costco',
          rate: 2,
        ),
        rule('costcovisa', 'cv#b', RewardRuleKind.baseline, rate: 1),
        rule('gold', 'g#b', RewardRuleKind.baseline, rate: 1, ps: 'mr'),
        rule('mystery', 'm#b', RewardRuleKind.baseline, rate: 1.5),
        rule('cibc', 'ci#b', RewardRuleKind.baseline, rate: 1),
        rule('tdvisa', 'td#b', RewardRuleKind.baseline, rate: 2),
      ],
      {
        'tdvisa': ('Visa', 'CA'),
        'dc': ('Mastercard', 'US'),
        'costcovisa': ('Visa', 'US'),
        'gold': ('American Express', 'US'),
        'mystery': (null, 'US'),
        'cibc': ('Mastercard', 'CA'),
      },
    );

    test('refused cards rank last, are never best, and say why', () {
      final r = ranker(s, [
        'dc',
        'costcovisa',
        'gold',
        'mystery',
      ]).rewardRanking(RewardCategory.wholesale, brandFilter: 'costco');
      final names = r.general.map((e) => e.cardName).toList();
      // The Visa and the unknown-network card first; Mastercard and Amex last.
      expect(names, ['costcovisa', 'mystery', 'gold', 'dc']);
      expect(r.general.first.isBest, isTrue);
      final dc = r.general.firstWhere((e) => e.cardName == 'dc');
      expect(dc.notAcceptedReason, 'Costco takes Visa only');
      expect(dc.isBest, isFalse);
      final mystery = r.general.firstWhere((e) => e.cardName == 'mystery');
      expect(mystery.notAcceptedReason, isNull); // unknown is never ruled out
    });

    test('the Stores list and notifications pick an accepted card', () {
      final lookup = ranker(s, ['dc', 'gold', 'mystery']).bestCardByCategory();
      // Double Cash pays the most (2%) but is a Mastercard.
      expect(lookup.byBrand['costco']?.name, 'mystery');
      // An everyday rate, so the Stores list must not call it a Costco bonus.
      expect(lookup.byBrand['costco']?.brand, isNull);
      final withCostcoCard = ranker(s, [
        'dc',
        'costcovisa',
      ]).bestCardByCategory();
      expect(withCostcoCard.byBrand['costco']?.brand, 'costco');
    });

    test('the Brands tab picks an accepted card', () {
      final picks = ranker(s, ['dc', 'gold', 'mystery']).bestCardByBrand();
      expect(
        picks.firstWhere((p) => p.brandId == 'costco').cardName,
        'mystery',
      );
    });

    test("a Canadian wallet gets Costco Canada's rule (Mastercard)", () {
      final r = ranker(s, [
        'cibc',
        'tdvisa',
      ]).rewardRanking(RewardCategory.wholesale, brandFilter: 'costco');
      expect(r.general.first.cardName, 'cibc');
      expect(r.general.first.isBest, isTrue);
      expect(r.general.last.cardName, 'tdvisa'); // 2% Visa, still refused
      expect(r.general.last.notAcceptedReason, 'Costco takes Mastercard only');
    });

    test(
      'an even US/CA wallet breaks the tie using homeCountry (R5)',
      () {
        final caRanker = EngineRanker(
          snapshot: s,
          linkedCards: [
            const LinkedCard(
              cardId: 'c-cibc',
              cardProductId: 'cibc',
              cardName: 'cibc',
            ),
            const LinkedCard(
              cardId: 'c-costcovisa',
              cardProductId: 'costcovisa',
              cardName: 'costcovisa',
            ),
          ],
          when: when,
          homeCountry: 'CA',
        );
        final caResult = caRanker.rewardRanking(
          RewardCategory.wholesale,
          brandFilter: 'costco',
        );
        expect(caResult.general.first.cardName, 'cibc');
        expect(caResult.general.first.isBest, isTrue);
        expect(
          caResult.general.last.notAcceptedReason,
          'Costco takes Mastercard only',
        );

        final usRanker = EngineRanker(
          snapshot: s,
          linkedCards: [
            const LinkedCard(
              cardId: 'c-cibc',
              cardProductId: 'cibc',
              cardName: 'cibc',
            ),
            const LinkedCard(
              cardId: 'c-costcovisa',
              cardProductId: 'costcovisa',
              cardName: 'costcovisa',
            ),
          ],
          when: when,
          homeCountry: 'US',
        );
        final usResult = usRanker.rewardRanking(
          RewardCategory.wholesale,
          brandFilter: 'costco',
        );
        expect(usResult.general.first.cardName, 'costcovisa');
        expect(usResult.general.first.isBest, isTrue);
        expect(
          usResult.general.last.notAcceptedReason,
          'Costco takes Visa only',
        );
      },
    );
  });

  group('rewardRankingProvider applies storeCategory (R1)', () {
    test(
      'Walmart, Target, and Home Depot use their brand storeCategory over a grocery/other caller category',
      () async {
        final s = snap(
          [
            rule(
              'bcp',
              'bcp#g',
              RewardRuleKind.category,
              category: RewardCategory.grocery,
              rate: 6,
            ),
            rule('bcp', 'bcp#b', RewardRuleKind.baseline, rate: 1),
            rule('dc', 'dc#b', RewardRuleKind.baseline, rate: 2),
            rule(
              'hd',
              'hd#hi',
              RewardRuleKind.category,
              category: RewardCategory.homeImprovement,
              rate: 4,
            ),
            rule('hd', 'hd#b', RewardRuleKind.baseline, rate: 1),
          ],
          {
            'bcp': ('American Express', 'US'),
            'dc': ('Mastercard', 'US'),
            'hd': ('Visa', 'US'),
          },
        );
        final r = ranker(s, ['bcp', 'dc', 'hd']);
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWithValue(
              Session.from(AuthState(isLoggedIn: true, userId: 'u1')),
            ),
            engineRankerProvider.overrideWith((ref) async => r),
          ],
        );
        addTearDown(container.dispose);

        // Even when the caller passes grocery (e.g. Google typed Walmart/Target
        // as a supermarket), rewardRankingProvider applies storeCategory ->
        // departmentStores, so Double Cash 2% beats Blue Cash Preferred's 1%
        // baseline (rather than falsely awarding 6% grocery).
        final walmartRanking = await container.read(
          rewardRankingProvider((
            category: RewardCategory.grocery,
            merchantName: 'Walmart Supercenter',
            brandId: null,
          )).future,
        );
        expect(walmartRanking.general.first.cardName, 'dc');
        expect(walmartRanking.general.first.rate, 2);

        final targetRanking = await container.read(
          rewardRankingProvider((
            category: RewardCategory.grocery,
            merchantName: 'Target',
            brandId: null,
          )).future,
        );
        expect(targetRanking.general.first.cardName, 'dc');
        expect(targetRanking.general.first.rate, 2);

        // Home Depot with a loose 'other' caller category resolves to
        // homeImprovement via storeCategory, matching the 4% homeImprovement card.
        final hdRanking = await container.read(
          rewardRankingProvider((
            category: RewardCategory.other,
            merchantName: 'The Home Depot',
            brandId: null,
          )).future,
        );
        expect(hdRanking.general.first.cardName, 'hd');
        expect(hdRanking.general.first.rate, 4);
      },
    );
  });

  group('storeCategory: a known store keeps its own category', () {
    // Google types many Walmart Supercenters as supermarkets; issuers don't
    // count Walmart as a grocery store, so a 6% grocery card must not win there.
    test('a supermarket-typed Walmart ranks as a department store', () {
      expect(
        storeCategory(RewardCategory.grocery, 'walmart'),
        RewardCategory.departmentStores,
      );
      expect(
        storeCategory(RewardCategory.grocery, 'costco'),
        RewardCategory.wholesale,
      );
    });

    test('a fuel place stays fuel even under a store brand', () {
      expect(storeCategory(RewardCategory.gas, 'walmart'), RewardCategory.gas);
      expect(
        storeCategory(RewardCategory.evCharging, 'walmart'),
        RewardCategory.evCharging,
      );
    });

    test('no brand, or an unregistered one, keeps the place type', () {
      expect(
        storeCategory(RewardCategory.grocery, null),
        RewardCategory.grocery,
      );
      expect(
        storeCategory(RewardCategory.grocery, 'not-registered'),
        RewardCategory.grocery,
      );
    });
  });

  test('normalizeCardNetwork reads the catalog spellings', () {
    expect(normalizeCardNetwork('Visa Signature'), 'visa');
    expect(
      normalizeCardNetwork('Mastercard (World Elite Mastercard)'),
      'mastercard',
    );
    expect(normalizeCardNetwork('American Express'), 'amex');
    expect(normalizeCardNetwork('Discover'), 'discover');
    expect(normalizeCardNetwork('Visa or Mastercard'), isNull);
    expect(normalizeCardNetwork(null), isNull);
  });
}
