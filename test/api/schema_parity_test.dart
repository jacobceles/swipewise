import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Cross-impl schema-parity guard (B2-4, app half): APP-reads ⊆ BUNDLE.
///
/// Asserts that every catalog column the *app* actually projects out of the
/// published bundle exists on the bundle's records. The app parses the bundle
/// in [CatalogLoader] (`lib/api/catalog_loader.dart`), projecting each of the
/// five catalog tables down to a fixed column list before INSERT. Those
/// (private) column constants — `_pointSystemCols`, `_cardProductCols`,
/// `_rewardRuleCols`, `_exclusionCols`, `_productPerkCols` — ARE the app's read
/// contract, so they are mirrored verbatim below. If CatalogLoader's projection
/// columns change, update [_appColumns] to match (they can't be imported: they
/// are private to the class).
///
/// This is the app-side complement to `swipewise-api/test/schema.test.ts`,
/// which validates the bundle's INTERNAL shape + referential integrity. This
/// test deliberately does NOT duplicate that; it checks the app→bundle column
/// parity only: if the backend engine renames/drops a column the app reads, the
/// projection silently yields NULLs (or an empty table) in production — this
/// fails first, in the app repo that owns the read contract.
///
/// The published `free.json` is the same object the app ships in-APK as its
/// offline fallback, so parity against it is parity against what the app runs.
void main() {
  // The app's read contract: table JSON key -> columns CatalogLoader projects.
  // Mirrors the `_*Cols` constants in lib/api/catalog_loader.dart.
  const appColumns = <String, List<String>>{
    'point_systems': [
      'point_system_id',
      'display_name',
      'baseline_cent_value',
      'valuation_source',
      'valuation_updated_at',
    ],
    'card_products': [
      'card_product_id',
      'issuer',
      'display_name',
      'network',
      'annual_fee_usd',
      'foreign_tx_fee_pct',
      'image_url',
      'catalog_version',
      'retired_at',
    ],
    'reward_rules': [
      'rule_id',
      'card_product_id',
      'kind',
      'category',
      'brand',
      'rate',
      'point_system_id',
      'valid_from',
      'valid_to',
      'rotation_year',
      'rotation_quarter',
      'requires_activation',
      'cap_spend_amount_usd',
      'cap_period',
      'cap_group',
      'notes',
      'earn_constraint',
      'excluded_categories',
    ],
    'reward_rule_exclusions': ['rule_id', 'brand'],
    'product_perks': [
      'card_product_id',
      'perk_id',
      'kind',
      'title',
      'description',
      'frequency',
      'value_estimate',
      'calendar_max_year_amount',
      'how_to_earn',
      'image_uri',
      'redemption_url',
    ],
  };

  group('catalog schema parity: app reads ⊆ published bundle', () {
    late Map<String, dynamic> bundle;

    setUpAll(() {
      // The committed free bundle — the file the app also ships as its in-APK
      // offline fallback (see CatalogLoader._bundledCatalogAsset).
      final raw = File('assets/catalog/free.json').readAsStringSync();
      bundle = jsonDecode(raw) as Map<String, dynamic>;
    });

    test('bundle carries the top-level fields the app reads', () {
      // CatalogLoader reads data['schemaVersion'] and data['dataVersion'] to gate
      // the app-update prompt and the "already loaded" no-op, plus the five arrays.
      expect(
        bundle['schemaVersion'],
        isA<num>(),
        reason: 'schemaVersion missing',
      );
      expect(bundle['dataVersion'], isA<num>(), reason: 'dataVersion missing');
      for (final table in appColumns.keys) {
        expect(
          bundle[table],
          isA<List>(),
          reason: 'table "$table" missing/not a list',
        );
        expect(
          (bundle[table] as List),
          isNotEmpty,
          reason: 'table "$table" is empty',
        );
      }
    });

    test('every app-read column is present on every record of its table', () {
      // The backend engine emits dense rows (explicit nulls, never omitted keys),
      // so the read contract is per-record column presence — the same convention
      // schema.test.ts uses (`'annual_fee_usd' in c` for every card). A dropped
      // or renamed column shows up here as a missing key.
      final violations = <String>[];
      appColumns.forEach((table, columns) {
        final rows = (bundle[table] as List).cast<Map<String, dynamic>>();
        for (final column in columns) {
          final missing = rows.where((r) => !r.containsKey(column)).length;
          if (missing > 0) {
            violations.add(
              '$table.$column missing on $missing/${rows.length} rows',
            );
          }
        }
      });
      expect(
        violations,
        isEmpty,
        reason:
            'bundle is missing app-read columns:\n  ${violations.join('\n  ')}',
      );
    });
  });
}
