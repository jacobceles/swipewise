import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/reward_category_mapper.dart';
import 'package:swipewise/models/reward_category.dart';

/// Data-integrity guard for the bundled brand registry
/// ([assets/vocab/brands.json]). This is the app-side version of the catalog's
/// slug-vocabulary check: it ensures hand/Gemini edits to the brand data
/// can't ship a malformed file, a duplicate slug, or a category that isn't
/// a real [RewardCategory] (which would silently classify as `other`).
void main() {
  group('assets/vocab/brands.json integrity', () {
    late List<dynamic> entries;

    setUpAll(() {
      final raw = File('assets/vocab/brands.json').readAsStringSync();
      entries = jsonDecode(raw) as List<dynamic>;
    });

    test('is a non-empty list of objects', () {
      expect(entries, isNotEmpty);
      expect(entries.every((e) => e is Map), isTrue);
    });

    test('every entry has brandId, displayName, and non-empty aliases', () {
      for (final e in entries) {
        final m = e as Map;
        final id = m['brandId'];
        expect(id, isA<String>(), reason: 'brandId missing in $m');
        expect((id as String).isNotEmpty, isTrue);
        expect(m['displayName'], isA<String>(), reason: 'displayName for $id');
        expect(m['aliases'], isA<List>(), reason: 'aliases for $id');
        expect(
          (m['aliases'] as List).isNotEmpty,
          isTrue,
          reason: 'empty aliases for $id',
        );
      }
    });

    test('no duplicate brandIds', () {
      final ids = entries.map((e) => (e as Map)['brandId'] as String).toList();
      expect(
        ids.toSet().length,
        ids.length,
        reason: 'duplicate brandId in brands.json',
      );
    });

    // 2026-10-20: ten stores (ALDI, Lidl, Peet's…) had two slugs each, so the
    // Brands tab listed them twice.
    test('no two entries share a displayName', () {
      final seen = <String, String>{};
      for (final e in entries) {
        final m = e as Map;
        final name = (m['displayName'] as String).toLowerCase();
        final id = m['brandId'] as String;
        expect(
          seen[name],
          isNull,
          reason: '"${m['displayName']}" is both ${seen[name]} and $id',
        );
        seen[name] = id;
      }
    });

    test('every category resolves to a real RewardCategory', () {
      for (final e in entries) {
        final m = e as Map;
        final cat = m['category'] as String?;
        expect(cat, isNotNull, reason: 'category missing for ${m['brandId']}');
        // fromName falls back to `other` for unknown names; require the name
        // to round-trip so a typo can't silently become `other`.
        expect(
          RewardCategory.fromName(cat!).name,
          cat,
          reason: 'invalid category "$cat" for ${m['brandId']}',
        );
      }
    });

    // A typo ("Visa", "mc") would match no card, so the store would refuse
    // every card in the wallet instead of the ones it really refuses.
    test('acceptedNetworks uses known countries and network tokens', () {
      const countries = {'US', 'CA'};
      const networks = {'visa', 'mastercard', 'amex', 'discover'};
      for (final e in entries) {
        final m = e as Map;
        final acc = m['acceptedNetworks'];
        if (acc == null) continue;
        expect(acc, isA<Map>(), reason: 'acceptedNetworks for ${m['brandId']}');
        for (final entry in (acc as Map).entries) {
          expect(countries, contains(entry.key), reason: '${m['brandId']}');
          final list = entry.value as List;
          expect(list, isNotEmpty, reason: '${m['brandId']} ${entry.key}');
          for (final n in list) {
            expect(networks, contains(n), reason: '${m['brandId']}: "$n"');
          }
        }
      }
    });

    test('the shipped asset loads cleanly via applyBrandsJson', () {
      final raw = File('assets/vocab/brands.json').readAsStringSync();
      expect(applyBrandsJson(raw), isTrue);
      resetBrandRegistry();
    });
  });
}
