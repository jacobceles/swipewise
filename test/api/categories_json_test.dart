import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/reward_category_mapper.dart';
import 'package:swipewise/models/reward_category.dart';
import 'package:swipewise/nearby/google_place_type_map.dart';
import 'package:swipewise/nearby/place_roots.dart';

/// Data-integrity guard for the bundled category vocabulary
/// ([assets/vocab/categories.json]) — the single source shared with the backend engine.
/// Ensures the file stays in lockstep with the [RewardCategory] enum, that
/// every earning category carries matchers, and that its `googlePlaceTypes`
/// don't drift from the nearby place-type map.
void main() {
  // Category objects only — the leading document marker (id-less, carrying
  // vocabVersion) is filtered out so the per-entry guards below see categories.
  late List<dynamic> entries;
  late Map<String, dynamic> marker;

  setUpAll(() {
    final raw = File('assets/vocab/categories.json').readAsStringSync();
    final all = jsonDecode(raw) as List<dynamic>;
    marker =
        all.firstWhere(
              (e) => e is Map && e['id'] == null,
              orElse: () => <String, dynamic>{},
            )
            as Map<String, dynamic>;
    entries = all.where((e) => e is Map && e['id'] != null).toList();
    // The drift guard resolves place-type labels through the classifier, so
    // load the real matchers into the registry first.
    applyCategoriesJson(raw);
  });

  tearDownAll(resetCategoryRegistry);

  test('is a non-empty list of objects', () {
    expect(entries, isNotEmpty);
    expect(entries.every((e) => e is Map), isTrue);
  });

  test('carries a vocab document marker (vocabVersion + minApp)', () {
    // Version-gating prerequisite (A2-F10): the id-less leading object carries
    // the vocab version the app gates on (see supportedVocabVersion). It has no
    // `id`, so category consumers skip it — that's what keeps a vocab bump
    // backward-compatible with already-shipped app builds.
    expect(
      marker['vocabVersion'],
      isA<int>(),
      reason: 'missing vocabVersion marker',
    );
    expect(marker['vocabVersion'], greaterThanOrEqualTo(1));
    expect(marker['minApp'], isA<String>(), reason: 'missing minApp marker');
    expect(marker.containsKey('id'), isFalse);
  });

  test('ids are exactly the RewardCategory enum names (no drift)', () {
    final ids = entries.map((e) => (e as Map)['id'] as String).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate id');
    expect(
      ids.toSet(),
      RewardCategory.values.map((v) => v.name).toSet(),
      reason: 'categories.json ids must match the RewardCategory enum',
    );
  });

  test('displayName matches the enum label for each id', () {
    for (final e in entries) {
      final m = e as Map;
      final id = m['id'] as String;
      expect(
        m['displayName'],
        RewardCategory.fromName(id).label,
        reason: 'displayName drift for $id',
      );
    }
  });

  test('every earning category has matchers; only appOnly may be empty', () {
    for (final e in entries) {
      final m = e as Map;
      final id = m['id'] as String;
      final keywords = m['matcherKeywords'] as List?;
      expect(keywords, isNotNull, reason: 'matcherKeywords missing for $id');
      if (m['appOnly'] == true) {
        expect(keywords, isEmpty, reason: '$id is appOnly, must not earn');
      } else {
        expect(
          keywords,
          isNotEmpty,
          reason: 'earning category $id has no matchers',
        );
      }
    }
  });

  test('only `other` is appOnly (the app-only catch-all)', () {
    final appOnly = [
      for (final e in entries)
        if ((e as Map)['appOnly'] == true) e['id'],
    ];
    expect(appOnly, ['other']);
  });

  test('googlePlaceTypes form a deterministic place-type → category index', () {
    // `googlePlaceTypes` is the AUTHORITATIVE place-type → category source for
    // the nearby flow (see categoryForPlaceType). Each type must map to exactly
    // one category and round-trip through the runtime lookup.
    final seen = <String, String>{};
    for (final e in entries) {
      final m = e as Map;
      final id = m['id'] as String;
      for (final pt in (m['googlePlaceTypes'] as List).cast<String>()) {
        expect(
          seen[pt],
          anyOf(isNull, equals(id)),
          reason: 'place type "$pt" is declared under both ${seen[pt]} and $id',
        );
        seen[pt] = id;
        expect(
          categoryForPlaceType(pt),
          RewardCategory.fromName(id),
          reason: 'categoryForPlaceType("$pt") must resolve to $id',
        );
      }
    }
  });

  test('hardcoded label map never contradicts categories.json', () {
    // kGooglePlaceTypeToLabel is now only the display-label + fallback source.
    // Where a place type is in BOTH, the label must classify to the SAME
    // category (so the displayed chip agrees with the recommended card). A
    // hardcoded label that classifies to `other` is just an unmapped fallback,
    // not a contradiction — the authoritative index still covers it.
    final byPlaceType = <String, String>{
      for (final e in entries)
        for (final pt
            in ((e as Map)['googlePlaceTypes'] as List).cast<String>())
          pt: e['id'] as String,
    };
    kGooglePlaceTypeToLabel.forEach((pt, label) {
      final declared = byPlaceType[pt];
      if (declared == null) return; // hardcoded-only type → fallback path, fine
      final viaLabel = classifyLooseLabel(label);
      if (viaLabel == RewardCategory.other) return; // unmapped, not a conflict
      expect(
        viaLabel.name,
        declared,
        reason:
            'place type "$pt": hardcoded label "$label" classifies to '
            '${viaLabel.name}, but categories.json declares it $declared',
      );
    });
  });

  test('every categorised place type is searchable and has a display label', () {
    // The three place-type lists are maintained separately: kPlaceRoots (what
    // the nearby search fetches), kGooglePlaceTypeToLabel (the display label),
    // and categories.json googlePlaceTypes (the reward category). This locks
    // them so categories.json never maps a type the search won't fetch (a dead
    // mapping, e.g. the `coffee_stand` drift) or that has no display label.
    final searched = {for (final r in kPlaceRoots) ...r.includedTypes};
    for (final e in entries) {
      final m = e as Map;
      final id = m['id'] as String;
      for (final pt in (m['googlePlaceTypes'] as List).cast<String>()) {
        expect(
          searched,
          contains(pt),
          reason:
              '"$pt" ($id) is reward-mapped but in no kPlaceRoots search '
              'list — it would never be fetched',
        );
        expect(
          kGooglePlaceTypeToLabel,
          contains(pt),
          reason: '"$pt" ($id) has no display label in kGooglePlaceTypeToLabel',
        );
      }
    }
  });

  test('every enabled-root place type resolves to a category or has a display '
      'label (forward invariant, B5-C5-1)', () {
    // FORWARD guard complementing the reverse check above. The reverse test
    // ensures every reward-mapped type is searchable; this ensures every type
    // the search actually fetches (an enabled root) is USABLE downstream —
    // either it maps to a reward category (categories.json googlePlaceTypes) or
    // it carries a display-only label in kGooglePlaceTypeToLabel. A type on
    // neither would fence a venue that surfaces as an uncategorised,
    // raw-type-labelled notification with no reward benefit (the exact failure
    // the opt-in Events root documents). Disabled roots are opt-in, excluded.
    final enabledTypes = <String>{
      for (final r in kPlaceRoots)
        if (r.defaultEnabled) ...r.includedTypes,
    };
    final unresolved = [
      for (final pt in enabledTypes)
        if (categoryForPlaceType(pt) == null &&
            !kGooglePlaceTypeToLabel.containsKey(pt))
          pt,
    ];
    expect(
      unresolved,
      isEmpty,
      reason:
          'enabled-root place types neither reward-mapped nor '
          'display-labelled: $unresolved — add each to a categories.json '
          'googlePlaceTypes list or give it a kGooglePlaceTypeToLabel entry',
    );
  });

  test('apparel / electronics / sportingGoods / pets place types reward-map '
      '(B5-C5-1)', () {
    // These four retail-root types were searched (fenced) but had empty
    // googlePlaceTypes, so their venues never reward-matched. Regression lock.
    expect(categoryForPlaceType('clothing_store'), RewardCategory.apparel);
    expect(
      categoryForPlaceType('electronics_store'),
      RewardCategory.electronics,
    );
    expect(
      categoryForPlaceType('sporting_goods_store'),
      RewardCategory.sportingGoods,
    );
    expect(categoryForPlaceType('pet_store'), RewardCategory.pets);
  });

  test('warehouse / home-improvement / department / fitness map correctly', () {
    // Regression for the coverage fix: a warehouse club (Costco) is wholesale,
    // NOT grocery — issuers routinely exclude warehouse clubs from grocery.
    expect(categoryForPlaceType('warehouse_store'), RewardCategory.wholesale);
    expect(categoryForPlaceType('wholesaler'), RewardCategory.wholesale);
    expect(
      categoryForPlaceType('home_improvement_store'),
      RewardCategory.homeImprovement,
    );
    expect(
      categoryForPlaceType('hardware_store'),
      RewardCategory.homeImprovement,
    );
    expect(
      categoryForPlaceType('department_store'),
      RewardCategory.departmentStores,
    );
    expect(categoryForPlaceType('gym'), RewardCategory.fitness);
    expect(categoryForPlaceType('grocery_store'), RewardCategory.grocery);
    // An uncurated type returns null so the caller falls back to heuristics.
    expect(categoryForPlaceType('school'), isNull);
  });

  test('the shipped asset loads cleanly via applyCategoriesJson', () {
    final raw = File('assets/vocab/categories.json').readAsStringSync();
    expect(applyCategoriesJson(raw), isTrue);
  });

  test('shopping_mall reward-maps to departmentStores, broadening its '
      'coverage beyond a single place type (B5-C5-5)', () {
    // shopping_mall was searched (kPlaceRoots retail root) and display-labelled
    // ("Shopping") but had no reward category, so mall venues fenced without
    // ever reward-matching. departmentStores is the best-fit existing category
    // for general/mixed retail; department_store alone was too narrow.
    expect(
      categoryForPlaceType('shopping_mall'),
      RewardCategory.departmentStores,
    );
    final departmentStores =
        entries.firstWhere((e) => (e as Map)['id'] == 'departmentStores')
            as Map;
    expect(
      (departmentStores['googlePlaceTypes'] as List).cast<String>(),
      containsAll(['department_store', 'shopping_mall']),
    );
  });

  test('parking_lot / toll place types are not searched, so they stay '
      'unmapped rather than mis-asserting a reward category (B5-C5-5)', () {
    // Neither parking_lot nor any toll-ish type appears in any kPlaceRoots
    // includedTypes list, so they never fence a venue today — there is
    // nothing to reward-map. Locks that assumption so a future place_roots.dart
    // change surfaces here instead of silently going unmapped.
    final searched = {for (final r in kPlaceRoots) ...r.includedTypes};
    expect(searched.contains('parking_lot'), isFalse);
    expect(searched.where((t) => t.contains('toll')), isEmpty);
  });

  test(
    'the Events root stays opt-in until its types map to a category (B5-C5-2)',
    () {
      // event_venue / convention_center / wedding_venue / banquet_hall resolve to
      // no reward category (and carry no display label), so a default-on Events
      // root fences users at venues the model can't categorise or label — pure
      // notification noise. Guard against silently re-enabling it without first
      // wiring coverage. Auto-relaxes once any of its types maps in categories.json.
      final event = kPlaceRoots.firstWhere((r) => r.id == 'event');
      final anyMapped = event.includedTypes.any(
        (t) => categoryForPlaceType(t) != null,
      );
      expect(
        event.defaultEnabled && !anyMapped,
        isFalse,
        reason:
            'Events root is default-enabled but none of its place types '
            'resolve to a reward category — map them (categories.json '
            'googlePlaceTypes) or keep the root opt-in.',
      );
    },
  );
}
