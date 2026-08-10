import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/brand_resolver.dart';
import 'package:swipewise/api/reward_category_mapper.dart';
import 'package:swipewise/models/reward_category.dart';

/// The shipped category vocabulary — the classifier's category pass is data
/// now (assets/vocab/categories.json), so the logic tests load the real file
/// (its integrity is guarded separately in categories_json_test).
final _categoriesAsset = File(
  'assets/vocab/categories.json',
).readAsStringSync();

void main() {
  // Controlled fixture — the classifier-logic tests assert against a small,
  // known set, decoupled from the full 711-brand registry (validated separately
  // in brands_json_test). Production loads its registry at boot; here we load
  // this fixture before each test.
  const fixture = r'''
[
  {"brandId":"whole-foods-market","displayName":"Whole Foods Market","category":"grocery","aliases":["whole foods"]},
  {"brandId":"sams-club","displayName":"Sam's Club","category":"wholesale","aliases":["sam's club","sams club"]},
  {"brandId":"costco-gas","displayName":"Costco Gasoline","category":"gas","aliases":["costco gas","costco gasoline","costco gas stations","costco fuel"]},
  {"brandId":"costco","displayName":"Costco","category":"wholesale","aliases":["costco"]},
  {"brandId":"uber-eats","displayName":"Uber Eats","category":"dining","aliases":["uber eats"]},
  {"brandId":"doordash","displayName":"DoorDash","category":"dining","aliases":["doordash"]},
  {"brandId":"instacart","displayName":"Instacart","category":"onlineGrocery","aliases":["instacart"]},
  {"brandId":"amazon-fresh","displayName":"Amazon Fresh","category":"onlineGrocery","aliases":["amazon fresh"]},
  {"brandId":"uber","displayName":"Uber","category":"transit","aliases":["uber"]},
  {"brandId":"lyft","displayName":"Lyft","category":"transit","aliases":["lyft"]},
  {"brandId":"amazon","displayName":"Amazon","category":"onlineShopping","aliases":["amazon"]},
  {"brandId":"walmart","displayName":"Walmart","category":"departmentStores","aliases":["walmart"]},
  {"brandId":"target","displayName":"Target","category":"departmentStores","aliases":["target"]},
  {"brandId":"apple-pay","displayName":"Apple Pay","category":"onlineShopping","aliases":["apple pay","apple card"]}
]
''';
  setUp(() {
    applyBrandsJson(fixture);
    applyCategoriesJson(_categoriesAsset);
  });

  group('classifyLabel - brand pass', () {
    final brandCases = <(String, RewardCategory, String)>[
      ('Whole Foods Market', RewardCategory.grocery, 'whole-foods-market'),
      ('whole foods', RewardCategory.grocery, 'whole-foods-market'),
      ('Costco', RewardCategory.wholesale, 'costco'),
      ("Sam's Club", RewardCategory.wholesale, 'sams-club'),
      ('Sams Club', RewardCategory.wholesale, 'sams-club'),
      ('Uber Eats', RewardCategory.dining, 'uber-eats'),
      ('DoorDash', RewardCategory.dining, 'doordash'),
      ('Uber', RewardCategory.transit, 'uber'),
      ('Lyft', RewardCategory.transit, 'lyft'),
      ('Instacart', RewardCategory.onlineGrocery, 'instacart'),
      ('Amazon Fresh', RewardCategory.onlineGrocery, 'amazon-fresh'),
      ('Amazon', RewardCategory.onlineShopping, 'amazon'),
      ('Walmart', RewardCategory.departmentStores, 'walmart'),
      ('Target', RewardCategory.departmentStores, 'target'),
      ('Apple Pay', RewardCategory.onlineShopping, 'apple-pay'),
    ];

    for (final (label, expectedCategory, expectedBrandId) in brandCases) {
      test('"$label" → ${expectedCategory.name} / $expectedBrandId', () {
        final r = classifyLabel(label);
        expect(r.category, expectedCategory);
        expect(r.brandId, expectedBrandId);
      });
    }

    test('Uber Eats does not get swallowed by Uber rule', () {
      // Token-based matcher prefers the longer "uber eats" alias over
      // "uber", regardless of declaration order in the brand table.
      final r = classifyLabel('uber eats');
      expect(r.category, RewardCategory.dining);
      expect(r.brandId, 'uber-eats');
    });

    test('Amazon Fresh does not get swallowed by Amazon rule', () {
      final r = classifyLabel('Amazon Fresh');
      expect(r.category, RewardCategory.onlineGrocery);
      expect(r.brandId, 'amazon-fresh');
    });

    test('Walmart does not match "Mart" inside another word', () {
      // Regression for the bidirectional-substring bug: "Mart Coffee"
      // would have matched the "walmart" brand under the old matcher
      // via `merchant.contains(brand) || brand.contains(merchant)`.
      final r = classifyLabel('Mart Coffee');
      expect(r.category, RewardCategory.coffee);
      expect(r.brandId, isNull);
    });

    test('Uber does not match "Hubert" via substring', () {
      final r = classifyLabel("Hubert's Lemonade");
      expect(r.brandId, isNull);
    });

    test(
      'Costco Gas resolves to the gas-specific brand, not the warehouse',
      () {
        // costco-gas is listed before costco so first-match-wins gives the
        // specific brand for a gas label, while plain "Costco" stays warehouse.
        final gas = classifyLabel('Costco Gas Stations');
        expect(gas.brandId, 'costco-gas');
        expect(gas.category, RewardCategory.gas);

        final store = classifyLabel('Costco');
        expect(store.brandId, 'costco');
        expect(store.category, RewardCategory.wholesale);
      },
    );
  });

  group('classifyLabel - category pass', () {
    final categoryCases = <(String, RewardCategory)>[
      ('Dining', RewardCategory.dining),
      ('Restaurants', RewardCategory.dining),
      ('Coffee Shops', RewardCategory.coffee),
      ('Grocery Stores', RewardCategory.grocery),
      ('Supermarkets', RewardCategory.grocery),
      ('Gas Stations', RewardCategory.gas),
      ('EV Charging', RewardCategory.evCharging),
      ('Hotels', RewardCategory.hotels),
      ('Lodging', RewardCategory.hotels),
      ('Airlines', RewardCategory.airlines),
      ('Flights', RewardCategory.airlines),
      ('Rental Cars', RewardCategory.carRentals),
      ('Travel', RewardCategory.travel),
      ('Drug Stores', RewardCategory.drugStores),
      ('Pharmacy', RewardCategory.drugStores),
      ('Streaming Services', RewardCategory.streaming),
      ('Entertainment', RewardCategory.entertainment),
      ('Online Shopping', RewardCategory.onlineShopping),
      ('Transit', RewardCategory.transit),
      ('Department Stores', RewardCategory.departmentStores),
      ('Phone and Internet', RewardCategory.phoneAndInternet),
      ('Wireless', RewardCategory.phoneAndInternet),
      ('Wholesale Clubs', RewardCategory.wholesale),
      ('Office Supply Stores', RewardCategory.officeSupply),
      ('Home Improvement', RewardCategory.homeImprovement),
      ('Gym Memberships', RewardCategory.fitness),
      ('Fitness Club', RewardCategory.fitness),
      ('Utilities', RewardCategory.utilities),
    ];

    for (final (label, expected) in categoryCases) {
      test('"$label" → ${expected.name} (no brand)', () {
        final r = classifyLabel(label);
        expect(r.category, expected);
        expect(r.brandId, isNull);
      });
    }
  });

  group('classifyLabel - unified vocabulary (shared categories.json)', () {
    // The category matchers now come from assets/vocab/categories.json — the
    // single source shared with the backend engine. The app gained the richer
    // issuer-copy phrases that previously lived only in the Python fork.
    final supersetCases = <(String, RewardCategory)>[
      ('takeout', RewardCategory.dining),
      ('food delivery', RewardCategory.dining),
      ('cruise', RewardCategory.travel),
      ('rideshare', RewardCategory.transit),
      ('transportation', RewardCategory.transit),
      ('vacation rentals', RewardCategory.hotels),
      ('British Airways', RewardCategory.airlines),
      ('online merchants', RewardCategory.onlineShopping),
    ];
    for (final (label, expected) in supersetCases) {
      test('"$label" → ${expected.name}', () {
        expect(classifyLabel(label).category, expected);
      });
    }

    test('longest matcher wins globally: "online grocery" → onlineGrocery', () {
      // 'online grocery' (2 tokens) must beat plain 'grocery' (1 token)
      // regardless of category declaration order.
      expect(
        classifyLabel('online grocery purchases').category,
        RewardCategory.onlineGrocery,
      );
      expect(
        classifyLooseLabel('online grocery'),
        RewardCategory.onlineGrocery,
      );
    });

    test('"online shopping" → onlineShopping (not bare grocery/shopping)', () {
      expect(
        classifyLooseLabel('online shopping'),
        RewardCategory.onlineShopping,
      );
    });

    test('empty category registry → everything falls to other', () {
      resetCategoryRegistry();
      expect(classifyLooseLabel('Restaurants'), RewardCategory.other);
      // Brand pass is unaffected by the category registry being empty.
      expect(classifyLabel('Costco').brandId, 'costco');
    });
  });

  group('classifyLabel - fallback', () {
    test('unknown label → other', () {
      final r = classifyLabel('Mystery Reward Label');
      expect(r.category, RewardCategory.other);
      expect(r.brandId, isNull);
    });

    test('empty string → other', () {
      final r = classifyLabel('');
      expect(r.category, RewardCategory.other);
      expect(r.brandId, isNull);
    });

    test('diacritics normalize: "café" → coffee', () {
      final r = classifyLabel('Local Café');
      expect(r.category, RewardCategory.coffee);
    });
  });

  group('RewardCategory.fromName', () {
    test('valid name round-trips', () {
      expect(RewardCategory.fromName('grocery'), RewardCategory.grocery);
      expect(
        RewardCategory.fromName('phoneAndInternet'),
        RewardCategory.phoneAndInternet,
      );
    });

    test('invalid name falls back to other', () {
      expect(RewardCategory.fromName('not_a_category'), RewardCategory.other);
      expect(RewardCategory.fromName(''), RewardCategory.other);
    });
  });

  group('classifyLooseLabel', () {
    test('returns just the category for free-form strings', () {
      expect(classifyLooseLabel('Restaurants'), RewardCategory.dining);
      expect(classifyLooseLabel('Whole Foods Market'), RewardCategory.grocery);
      expect(classifyLooseLabel('mystery'), RewardCategory.other);
    });
  });

  group('BrandResolver — store-badge / sheet / notification parity', () {
    // The nearby store badge, the ranking sheet, and the geofence
    // notification all resolve a merchant name to a brand_id via this
    // resolver, so they must agree. Costco Gasoline must resolve apart
    // from the Costco warehouse.
    late BrandResolver resolver;
    setUp(() => resolver = BrandResolver.fromDefaultRegistry());
    test('Costco → costco (warehouse)', () {
      expect(resolver.resolve('Costco'), 'costco');
    });
    test('Costco Gasoline → costco-gas', () {
      expect(resolver.resolve('Costco Gasoline'), 'costco-gas');
    });
    test('Costco Gas Stations → costco-gas', () {
      expect(resolver.resolve('Costco Gas Stations'), 'costco-gas');
    });
  });

  group('brand registry (Channel B) loading', () {
    // Each test that mutates the registry restores defaults afterwards so
    // it can't leak into the other groups (which rely on the compiled-in
    // defaults — i.e. they never boot the registry, proving the fallback).
    tearDown(resetBrandRegistry);

    test('applyBrandsJson adds a new brand the classifier then resolves', () {
      // Unknown to the default table → other / no brand.
      expect(classifyLabel('Blue Bottle').category, RewardCategory.other);
      expect(classifyLabel('Blue Bottle').brandId, isNull);

      final ok = applyBrandsJson('''
        [
          { "brandId": "blue-bottle", "displayName": "Blue Bottle Coffee",
            "category": "coffee", "aliases": ["blue bottle"] }
        ]
      ''');
      expect(ok, isTrue);

      final r = classifyLabel('SQ Blue Bottle');
      expect(r.category, RewardCategory.coffee);
      expect(r.brandId, 'blue-bottle');
      expect(brandDisplayNameFor('blue-bottle'), 'Blue Bottle Coffee');
    });

    test('malformed JSON keeps the defaults (returns false)', () {
      expect(applyBrandsJson('{ not valid json'), isFalse);
      // Default registry still intact.
      expect(classifyLabel('Costco').brandId, 'costco');
    });

    test('empty list keeps the defaults (returns false)', () {
      expect(applyBrandsJson('[]'), isFalse);
      expect(classifyLabel('Costco').brandId, 'costco');
    });

    test('entries missing required fields are skipped', () {
      // One valid, one missing brandId, one missing aliases.
      final ok = applyBrandsJson('''
        [
          { "brandId": "blue-bottle", "displayName": "Blue Bottle",
            "category": "coffee", "aliases": ["blue bottle"] },
          { "displayName": "No Id", "category": "coffee", "aliases": ["x"] },
          { "brandId": "no-aliases", "displayName": "No Aliases",
            "category": "coffee" }
        ]
      ''');
      expect(ok, isTrue);
      expect(classifyLabel('Blue Bottle').brandId, 'blue-bottle');
      // The swap replaced the table, so a default brand is now gone.
      expect(classifyLabel('Costco').brandId, isNull);
    });

    test('unknown category name falls back to other on the loaded brand', () {
      final ok = applyBrandsJson('''
        [
          { "brandId": "x-mart", "displayName": "X Mart",
            "category": "not_a_real_category", "aliases": ["x mart"] }
        ]
      ''');
      expect(ok, isTrue);
      expect(brandDefaultCategory('x-mart'), RewardCategory.other);
    });
  });
}
