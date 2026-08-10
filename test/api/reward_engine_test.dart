import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/reward_engine.dart';
import 'package:swipewise/models/reward_category.dart';

/// Pure-engine tests (B3). Zero DB — every input is an in-memory fixture.
void main() {
  // Q1 2026.
  final when = DateTime(2026, 2, 15);

  CatalogSnapshot snap(
    List<RewardRule> rules, {
    Map<String, double> pointSystems = const {'usd': 1.0},
    Map<String, Set<String>> exclusions = const {},
    Map<String, double> ftf = const {},
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
          foreignTxFeePct: ftf[r.productId] ?? 0.0,
        ),
      );
      (byProduct[r.productId] ??= []).add(r);
    }
    return CatalogSnapshot(
      products: products,
      rulesByProduct: byProduct,
      exclusionsByRule: exclusions,
      pointSystems: {
        for (final e in pointSystems.entries)
          e.key: PointSystem(
            id: e.key,
            displayName: e.key,
            baselineCentValue: e.value,
          ),
      },
    );
  }

  RewardRule rule(
    String ruleId,
    RewardRuleKind kind, {
    String product = 'p',
    RewardCategory? category,
    String? brand,
    required double rate,
    String ps = 'usd',
    int? rotYear,
    int? rotQuarter,
    bool requiresActivation = false,
    double? cap,
    String? capGroup,
    DateTime? validFrom,
    DateTime? validTo,
    List<RewardCategory> excludedCategories = const [],
  }) => RewardRule(
    ruleId: ruleId,
    productId: product,
    kind: kind,
    category: category,
    brand: brand,
    rate: rate,
    pointSystemId: ps,
    rotationYear: rotYear,
    rotationQuarter: rotQuarter,
    requiresActivation: requiresActivation,
    capSpendAmountUsd: cap,
    capGroup: capGroup,
    validFrom: validFrom,
    validTo: validTo,
    excludedCategories: excludedCategories,
  );

  AppliedRate run(
    CatalogSnapshot s, {
    RewardCategory category = RewardCategory.dining,
    String? brand,
    double amount = 1.0,
    bool isForeign = false,
    ActivationState activations = ActivationState.none,
    SpendLedger spend = SpendLedger.empty,
  }) => resolve(
    snapshot: s,
    product: 'p',
    category: category,
    brand: brand,
    when: when,
    amount: amount,
    isForeign: isForeign,
    activations: activations,
    spend: spend,
  );

  group('multi-category brand (Costco gas 5% vs warehouse 2%)', () {
    // The Costco card carries two brand=costco rules: 5% on gas at Costco, 2% on other
    // Costco purchases. The engine must resolve each by the purchase category, not just
    // hand back the brand's highest rate at every Costco swipe.
    final gas5 = rule(
      'gas5',
      RewardRuleKind.brand,
      category: RewardCategory.gas,
      brand: 'costco',
      rate: 5,
    );
    final wholesale2 = rule(
      'wh2',
      RewardRuleKind.brand,
      category: RewardCategory.wholesale,
      brand: 'costco',
      rate: 2,
    );
    final base = rule('base', RewardRuleKind.baseline, rate: 1);

    test('Costco gas → the 5% gas brand rule', () {
      final r = run(
        snap([gas5, wholesale2, base]),
        category: RewardCategory.gas,
        brand: 'costco',
      );
      expect(r.ruleId, 'gas5');
      expect(r.rate, 5);
    });

    test('Costco warehouse → 2%, NOT the gas-only 5%', () {
      final r = run(
        snap([gas5, wholesale2, base]),
        category: RewardCategory.wholesale,
        brand: 'costco',
      );
      expect(r.ruleId, 'wh2');
      expect(r.rate, 2);
    });

    test(
      'a brand earn not pinned to this category still surfaces (never dropped to baseline)',
      () {
        // Only the gas rule exists; a different-category query at the brand falls back to the
        // brand earn rather than collapsing to baseline — the deliberate no-regression choice
        // for the single-category brands the app may query with a slightly different category.
        final r = run(
          snap([gas5, base]),
          category: RewardCategory.wholesale,
          brand: 'costco',
        );
        expect(r.kind, RewardRuleKind.brand);
        expect(r.rate, 5);
      },
    );
  });

  group('resolution order', () {
    final base = rule('base', RewardRuleKind.baseline, rate: 1);
    final cat = rule(
      'cat',
      RewardRuleKind.category,
      category: RewardCategory.dining,
      rate: 3,
    );
    final brand = rule(
      'brand',
      RewardRuleKind.brand,
      category: RewardCategory.dining,
      brand: 'chipotle',
      rate: 4,
    );
    final rot = rule(
      'rot',
      RewardRuleKind.rotating,
      category: RewardCategory.dining,
      rate: 5,
      rotYear: 2026,
      rotQuarter: 1,
    );
    final promo = rule(
      'promo',
      RewardRuleKind.promo,
      category: RewardCategory.dining,
      rate: 6,
    );

    test('promo beats rotating beats brand beats category beats baseline', () {
      expect(
        run(snap([base, cat, brand, rot, promo]), brand: 'chipotle').ruleId,
        'promo',
      );
      expect(
        run(snap([base, cat, brand, rot]), brand: 'chipotle').ruleId,
        'rot',
      );
      expect(run(snap([base, cat, brand]), brand: 'chipotle').ruleId, 'brand');
      expect(run(snap([base, cat]), brand: 'chipotle').ruleId, 'cat');
      expect(run(snap([base]), brand: 'chipotle').ruleId, 'base');
    });

    test('baseline is the floor when nothing matches', () {
      final r = run(snap([base, cat]), category: RewardCategory.gas);
      expect(r.kind, RewardRuleKind.baseline);
      expect(r.rate, 1);
    });

    test('returns none when no rule and no baseline', () {
      expect(run(snap([cat]), category: RewardCategory.gas).hasRule, isFalse);
    });
  });

  test('0-rate promo (intro APR) is skipped, not a winner', () {
    final s = snap([
      rule('base', RewardRuleKind.baseline, rate: 1),
      rule(
        'cat',
        RewardRuleKind.category,
        category: RewardCategory.dining,
        rate: 3,
      ),
      rule('apr', RewardRuleKind.promo, rate: 0, ps: 'usd'),
    ]);
    final r = run(s);
    expect(r.kind, RewardRuleKind.category);
    expect(r.rate, 3);
  });

  test('partner_portal rules never win on a normal swipe', () {
    final s = snap([
      rule('base', RewardRuleKind.baseline, rate: 1),
      rule(
        'portal',
        RewardRuleKind.partnerPortal,
        category: RewardCategory.travel,
        rate: 5,
      ),
    ]);
    final r = run(s, category: RewardCategory.travel);
    expect(r.kind, RewardRuleKind.baseline);
  });

  group('exclusions', () {
    final s = snap(
      [
        rule('base', RewardRuleKind.baseline, rate: 1),
        rule(
          'g#1',
          RewardRuleKind.category,
          category: RewardCategory.grocery,
          rate: 6,
        ),
      ],
      exclusions: {
        'g#1': {'walmart'},
      },
    );

    test('excluded brand cascades to baseline', () {
      final r = run(s, category: RewardCategory.grocery, brand: 'walmart');
      expect(r.ruleId, 'base');
    });

    test('non-excluded brand keeps the bonus', () {
      final r = run(s, category: RewardCategory.grocery, brand: 'target');
      expect(r.ruleId, 'g#1');
      expect(r.rate, 6);
    });
  });

  group('caps', () {
    final s = snap([
      rule('base', RewardRuleKind.baseline, rate: 1),
      rule(
        'cap',
        RewardRuleKind.category,
        category: RewardCategory.dining,
        rate: 5,
        cap: 100,
        capGroup: 'g',
      ),
    ]);

    test('amount=\$1 with headroom collapses to the plain rate', () {
      final r = run(s);
      expect(r.effectiveCentsPerDollar, 5);
      expect(r.rate, 5);
    });

    test('spend over the cap blends bonus + baseline overflow', () {
      // \$200 spend, \$100 cap: 100×5¢ + 100×1¢ = 600¢ over \$200 = 3¢/\$.
      final r = run(s, amount: 200);
      expect(r.effectiveCentsPerDollar, closeTo(3.0, 1e-9));
      expect(r.reason, contains('cap'));
    });

    test('exhausted cap cascades to baseline', () {
      final r = run(s, amount: 1, spend: const SpendLedger({'g': 100}));
      expect(r.ruleId, 'base');
    });
  });

  group('mixed currency comparison', () {
    test('1.5x UR (1.25¢) beats 2x Bonvoy (0.70¢) on effective', () {
      final ur = run(
        snap(
          [
            rule(
              'ur',
              RewardRuleKind.category,
              category: RewardCategory.dining,
              rate: 1.5,
              ps: 'ur',
            ),
          ],
          pointSystems: {'ur': 1.25},
        ),
      );
      final bonvoy = run(
        snap(
          [
            rule(
              'bv',
              RewardRuleKind.category,
              category: RewardCategory.dining,
              rate: 2,
              ps: 'bonvoy',
            ),
          ],
          pointSystems: {'bonvoy': 0.70},
        ),
      );
      expect(ur.effectiveCentsPerDollar, closeTo(1.875, 1e-9));
      expect(bonvoy.effectiveCentsPerDollar, closeTo(1.40, 1e-9));
      expect(
        ur.effectiveCentsPerDollar,
        greaterThan(bonvoy.effectiveCentsPerDollar),
      );
    });
  });

  group('rotating (assumed activated — no activation UI)', () {
    final s = snap([
      rule('base', RewardRuleKind.baseline, rate: 1),
      rule(
        'rot',
        RewardRuleKind.rotating,
        category: RewardCategory.dining,
        rate: 5,
        rotYear: 2026,
        rotQuarter: 1,
        requiresActivation: true,
      ),
    ]);

    test('in-window rotating earns the bonus with no activation record', () {
      // No activation toggle exists, so the ranker assumes the current quarter is
      // activated — an activation-required rotating rule still applies.
      final r = run(s);
      expect(r.ruleId, 'rot');
      expect(r.rate, 5);
    });

    test('explicit activation state is ignored (same bonus)', () {
      final r = run(s, activations: const ActivationState({(2026, 1)}));
      expect(r.ruleId, 'rot');
      expect(r.rate, 5);
    });

    test('null rotation_quarter matches any quarter of the year', () {
      final anyQ = snap([
        rule('base', RewardRuleKind.baseline, rate: 1),
        rule(
          'rot',
          RewardRuleKind.rotating,
          category: RewardCategory.dining,
          rate: 4,
          rotYear: 2026,
        ),
      ]);
      expect(run(anyQ).ruleId, 'rot');
    });

    test('rotating rule for a different year does not match', () {
      final old = snap([
        rule('base', RewardRuleKind.baseline, rate: 1),
        rule(
          'rot',
          RewardRuleKind.rotating,
          category: RewardCategory.dining,
          rate: 5,
          rotYear: 2025,
          rotQuarter: 1,
        ),
      ]);
      expect(run(old).ruleId, 'base');
    });
  });

  test('foreign transaction fee subtracts from the effective rate', () {
    final s = snap(
      [
        rule('base', RewardRuleKind.baseline, rate: 1),
        rule(
          'cat',
          RewardRuleKind.category,
          category: RewardCategory.dining,
          rate: 3,
        ),
      ],
      ftf: {'p': 3.0},
    );
    expect(run(s, isForeign: true).effectiveCentsPerDollar, closeTo(0.0, 1e-9));
    expect(run(s, isForeign: false).effectiveCentsPerDollar, 3);
  });

  test('date-bounded rule outside its window does not apply', () {
    final s = snap([
      rule('base', RewardRuleKind.baseline, rate: 1),
      rule(
        'promo',
        RewardRuleKind.promo,
        category: RewardCategory.dining,
        rate: 6,
        validFrom: DateTime(2027, 1, 1),
      ),
    ]);
    expect(run(s).ruleId, 'base');
  });

  group('travel is the superset of its sub-categories', () {
    AppliedRate at(CatalogSnapshot s, RewardCategory c) =>
        resolve(snapshot: s, product: 'p', category: c, when: when);

    test('a general travel rule applies at a hotel (sub-category) lookup', () {
      final s = snap([
        rule(
          't',
          RewardRuleKind.category,
          category: RewardCategory.travel,
          rate: 3,
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      final r = at(s, RewardCategory.hotels);
      expect(r.ruleId, 't'); // the travel rule, not the baseline
      expect(r.rate, 3);
    });

    test('a hotel-specific rule beats the general travel rule at a hotel', () {
      final s = snap([
        rule(
          't',
          RewardRuleKind.category,
          category: RewardCategory.travel,
          rate: 3,
        ),
        rule(
          'h',
          RewardRuleKind.category,
          category: RewardCategory.hotels,
          rate: 5,
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      expect(at(s, RewardCategory.hotels).ruleId, 'h'); // richest-rate wins
    });

    test('travel does not leak into a non-travel category', () {
      final s = snap([
        rule(
          't',
          RewardRuleKind.category,
          category: RewardCategory.travel,
          rate: 3,
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      expect(at(s, RewardCategory.dining).ruleId, 'b'); // baseline only
    });

    test('a sub-category rule does not leak into a sibling sub-category', () {
      final s = snap([
        rule(
          'h',
          RewardRuleKind.category,
          category: RewardCategory.hotels,
          rate: 5,
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      // transit is a sibling of hotels, not its parent — only travel + transit
      // rules apply at a transit lookup.
      expect(at(s, RewardCategory.transit).ruleId, 'b');
    });

    test('a travel rule excluding transit does NOT cover a transit purchase', () {
      // Citi Costco: "travel" 3% earns only the 1% base on train/commuter transit.
      final s = snap([
        rule(
          't',
          RewardRuleKind.category,
          category: RewardCategory.travel,
          rate: 3,
          excludedCategories: const [RewardCategory.transit],
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      final r = at(s, RewardCategory.transit);
      expect(r.ruleId, 'b'); // baseline, not the 3% travel rule
      expect(r.rate, 1);
    });

    test(
      'the transit exclusion does not affect other sub-categories or travel itself',
      () {
        final s = snap([
          rule(
            't',
            RewardRuleKind.category,
            category: RewardCategory.travel,
            rate: 3,
            excludedCategories: const [RewardCategory.transit],
          ),
          rule('b', RewardRuleKind.baseline, rate: 1),
        ]);
        expect(at(s, RewardCategory.travel).ruleId, 't'); // still 3% on travel
        expect(
          at(s, RewardCategory.hotels).ruleId,
          't',
        ); // still 3% on hotels (not excluded)
      },
    );
  });

  group('entertainment is the superset of movie theaters', () {
    AppliedRate at(CatalogSnapshot s, RewardCategory c) =>
        resolve(snapshot: s, product: 'p', category: c, when: when);

    test('a general entertainment rule applies at a movie-theater lookup', () {
      // Capital One Savor / US Bank Cash+ earn their entertainment bonus at movies.
      final s = snap([
        rule(
          'e',
          RewardRuleKind.category,
          category: RewardCategory.entertainment,
          rate: 3,
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      final r = at(s, RewardCategory.movieTheaters);
      expect(r.ruleId, 'e'); // the entertainment rule, not the baseline
      expect(r.rate, 3);
    });

    test('Freedom Flex live-entertainment 5% excludes movie theaters', () {
      // Chase's rotating "Select Live Entertainment" earns 5% at concerts/stadiums,
      // but its terms EXCLUDE movie theaters — so a movie ticket earns only baseline.
      final s = snap([
        rule(
          'e',
          RewardRuleKind.category,
          category: RewardCategory.entertainment,
          rate: 5,
          excludedCategories: const [RewardCategory.movieTheaters],
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      final r = at(s, RewardCategory.movieTheaters);
      expect(r.ruleId, 'b'); // baseline, not the 5% entertainment rule
      expect(r.rate, 1);
      // ...but the 5% still applies at live entertainment itself.
      expect(at(s, RewardCategory.entertainment).ruleId, 'e');
      expect(at(s, RewardCategory.entertainment).rate, 5);
    });

    test('entertainment does not leak into a non-entertainment category', () {
      final s = snap([
        rule(
          'e',
          RewardRuleKind.category,
          category: RewardCategory.entertainment,
          rate: 3,
        ),
        rule('b', RewardRuleKind.baseline, rate: 1),
      ]);
      expect(at(s, RewardCategory.dining).ruleId, 'b'); // baseline only
    });
  });
}
