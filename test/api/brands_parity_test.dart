import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/brand_resolver.dart';
import 'package:swipewise/api/reward_category_mapper.dart';

/// Cross-impl brands-parity guard (B1-D9): the app's [BrandResolver] and the
/// backend-engine-produced brand data agree on brand slugs.
///
/// Two artifacts, both produced by the backend engine, that must stay in sync:
///   - `assets/vocab/brands.json` — the brand registry (brandId -> aliases).
///     The app loads this via `applyBrandsJson` into the in-code registry that
///     backs [BrandResolver.fromDefaultRegistry]; it IS the set of slugs the
///     resolver can emit.
///   - `swipewise-api/catalog/free.json` — the catalog. Its `reward_rules.brand`
///     and `reward_rule_exclusions.brand` fields reference brand slugs the app
///     joins against the registry (for display names, categories, brand bonuses).
///
/// Direction that matters: catalog brand refs ⊆ resolver slugs.
/// The resolver is *built from* brands.json, so "every resolver slug exists in
/// brands.json" is true by construction (a weak invariant, still guarded below).
/// The failable drift is the reverse: the catalog referencing a `brand` slug the
/// registry never defines — the resolver would never emit it and
/// `brandDisplayNameFor` returns null, so the brand bonus silently dies. That is
/// the contract the second test asserts.
void main() {
  group('brands parity: BrandResolver ↔ brands.json', () {
    late Set<String> registrySlugs; // brandIds in brands.json
    late Set<String> resolverSlugs; // brandIds the resolver can emit
    late BrandResolver resolver;

    setUpAll(() {
      final raw = File('assets/vocab/brands.json').readAsStringSync();
      registrySlugs = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => e['brandId'])
          .whereType<String>()
          .toSet();

      // Load the registry the way the app does at boot, then build the resolver
      // exactly as production does (BrandResolver.fromDefaultRegistry).
      expect(
        applyBrandsJson(raw),
        isTrue,
        reason: 'brands.json failed to load',
      );
      resolver = BrandResolver.fromDefaultRegistry();
      resolverSlugs = resolver.all.map((b) => b.brandId).toSet();
    });

    tearDownAll(resetBrandRegistry);

    test(
      'every slug the resolver can emit exists as a brand in brands.json',
      () {
        // Coverage invariant (true by construction today: the resolver is built
        // from brands.json). Guards a future refactor that adds resolver slugs
        // from another source without a matching registry entry.
        final orphans = resolverSlugs.difference(registrySlugs);
        expect(
          orphans,
          isEmpty,
          reason: 'resolver can emit slugs absent from brands.json: $orphans',
        );
      },
    );

    test('every brand slug the catalog references is resolvable by the app', () {
      // The real cross-impl contract. Collect every `brand` slug the published
      // catalog references and assert the resolver knows each one.
      final catalog =
          jsonDecode(File('swipewise-api/catalog/free.json').readAsStringSync())
              as Map<String, dynamic>;

      final referenced = <String>{};
      for (final r in (catalog['reward_rules'] as List).cast<Map>()) {
        final b = r['brand'];
        if (b is String && b.isNotEmpty) referenced.add(b);
      }
      for (final e in (catalog['reward_rule_exclusions'] as List).cast<Map>()) {
        final b = e['brand'];
        if (b is String && b.isNotEmpty) referenced.add(b);
      }

      expect(
        referenced,
        isNotEmpty,
        reason: 'no catalog brand refs found — check parsing',
      );

      final unresolvable = referenced.difference(resolverSlugs);
      expect(
        unresolvable,
        isEmpty,
        reason:
            'catalog references brand slugs the app registry cannot resolve '
            '(brand bonus dies, display name null): $unresolvable',
      );
    });
  });
}
