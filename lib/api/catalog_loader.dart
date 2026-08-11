import 'dart:convert';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../util/logger.dart';
import 'catalog_repository.dart';
import 'data_repository.dart';
import 'database_helper.dart';
import 'remote_asset_service.dart';
import 'settings_repository.dart';

/// Outcome of a [CatalogLoader.hydrateIfNeeded] call.
enum CatalogLoadResult {
  /// Catalog tables were (re)hydrated from the bundle.
  loaded,

  /// Bundle `dataVersion` already matches what's loaded — no-op.
  upToDate,

  /// Bundle `schemaVersion` is newer than this build understands. The DB was
  /// left untouched; the UI should prompt "update SwipeWise".
  needsAppUpdate,

  /// The asset failed to load/parse. DB untouched.
  error,
}

/// Hydrates the catalog into the five global catalog tables (point_systems,
/// card_products, reward_rules, reward_rule_exclusions, product_perks) from the
/// first available source: R2 (ETag-gated) → the local R2 cache → the bundled
/// asset (the offline floor shipped with the app). So even a first launch with no
/// network gets a working rewards engine instead of empty tables.
///
/// Idempotent and cheap to call on every boot: it re-hydrates only when the
/// bundle's `dataVersion` differs from what's recorded as loaded.
class CatalogLoader {
  CatalogLoader({
    CatalogRepository? catalog,
    SettingsRepository? settings,
    RemoteAssetService? remote,
  }) : _catalog = catalog ?? CatalogRepository(DatabaseHelper()),
       _settings = settings ?? SettingsRepository(DataRepository()),
       _remote = remote ?? RemoteAssetService();

  /// Path used by tests to locate the catalog JSON on disk.
  static const String defaultAssetPath = 'test/fixtures/catalog.json';

  /// The offline floor: a catalog snapshot shipped in the app bundle, loaded when
  /// R2 is unreachable and there's no local cache yet (e.g. a first launch with no
  /// network).
  ///
  /// Deliberately allowed to go stale. It is a floor, not a mirror: [hydrateIfNeeded]
  /// tries R2 on every boot, so this is only ever read by an install that has never
  /// once fetched successfully, and their first online launch replaces it. Its
  /// freshness is bounded by the last `make publish` before the release build —
  /// which is all the freshness it can have anyway, since the APK freezes it at
  /// build time. A pre-commit hook used to re-sync it on every card edit; that was
  /// removed because it churned 2.3 MB through git history without changing what
  /// any user ever saw.
  static const String _bundledCatalogAsset = 'assets/catalog/free.json';

  /// Highest catalog `schemaVersion` this build can read. A bundle declaring
  /// a higher schema means the app binary is behind the catalog structure.
  static const int supportedSchemaVersion = 1;

  final CatalogRepository _catalog;
  final SettingsRepository _settings;
  final RemoteAssetService? _remote;

  Future<CatalogLoadResult> hydrateIfNeeded(String userId) async {
    // Try R2 first (ETag-gated — free if catalog hasn't changed).
    final Map<String, dynamic>? remoteData = await _fetchRemote();
    final Map<String, dynamic> data;
    if (remoteData != null) {
      data = remoteData;
    } else {
      // Fall back to the local R2 cache (written on a previous launch), then the
      // bundled asset — the offline floor shipped with the app, so a first launch
      // with no network still gets a working rewards engine instead of empty tables.
      final raw =
          await _remote?.readCached('catalog') ?? await _loadBundledCatalog();
      if (raw == null) {
        Log.w(
          'catalog',
          'no catalog data — R2 unreachable, no local cache, no bundled asset',
        );
        // ignore: unawaited_futures
        FirebaseCrashlytics.instance.recordError(
          StateError(
            'catalog unavailable: R2 unreachable, no cache, no bundle',
          ),
          StackTrace.current,
          reason: 'catalog_load_failed',
          fatal: false,
        );
        return CatalogLoadResult.error;
      }
      try {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } catch (e, st) {
        Log.e('catalog', 'failed to parse catalog (cache/bundle)', e, st);
        // ignore: unawaited_futures
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'catalog_load_failed',
          fatal: false,
        );
        return CatalogLoadResult.error;
      }
    }

    final schemaVersion = (data['schemaVersion'] as num?)?.toInt() ?? 1;
    if (schemaVersion > supportedSchemaVersion) {
      Log.w(
        'catalog',
        'bundled schemaVersion=$schemaVersion exceeds supported '
            '$supportedSchemaVersion — app update required; leaving DB as-is',
      );
      return CatalogLoadResult.needsAppUpdate;
    }

    final dataVersion = (data['dataVersion'] as num?)?.toInt() ?? 0;
    final loaded = await _settings.getLoadedCatalogDataVersion(userId);
    if (loaded == dataVersion && dataVersion != 0) {
      return CatalogLoadResult.upToDate;
    }

    await _catalog.replaceCatalog(
      pointSystems: _project(data['point_systems'], _pointSystemCols),
      cardProducts: _project(data['card_products'], _cardProductCols),
      rewardRules: _jsonEncodeColumn(
        _project(data['reward_rules'], _rewardRuleCols),
        'excluded_categories',
      ),
      exclusions: _project(data['reward_rule_exclusions'], _exclusionCols),
      productPerks: _project(data['product_perks'], _productPerkCols),
    );
    await _settings.setLoadedCatalogDataVersion(userId, dataVersion);

    final counts = await _catalog.catalogCounts();
    Log.i('catalog', 'hydrated catalog dataVersion=$dataVersion $counts');
    return CatalogLoadResult.loaded;
  }

  /// Projects each JSON object down to exactly the table's columns, so a
  /// stray key in the build artifact can never reach `INSERT` (which would
  /// throw "no column named …").
  ///
  /// Null/missing values are *omitted* from the row map rather than emitted as
  /// explicit `NULL`. SQLite only applies a column `DEFAULT` when the column is
  /// absent from the INSERT — an explicit `NULL` into a `NOT NULL DEFAULT x`
  /// column (e.g. `card_products.foreign_tx_fee_pct`) fails the constraint and
  /// rolls back the whole import. Omitting lets the default apply; nullable
  /// columns still resolve to NULL.
  static List<Map<String, Object?>> _project(
    Object? rows,
    List<String> columns,
  ) {
    if (rows is! List) return const [];
    return [
      for (final r in rows)
        if (r is Map)
          {
            for (final c in columns)
              if (r[c] != null) c: r[c] as Object?,
          },
    ];
  }

  /// sqflite can't bind a List, so JSON-encode a list-valued column to a TEXT
  /// string before insert (decoded back in `CatalogRepository._rule`). No-op for
  /// rows where the column is absent or already a scalar.
  static List<Map<String, Object?>> _jsonEncodeColumn(
    List<Map<String, Object?>> rows,
    String column,
  ) {
    for (final r in rows) {
      if (r[column] is List) r[column] = jsonEncode(r[column]);
    }
    return rows;
  }

  static const _pointSystemCols = [
    'point_system_id',
    'display_name',
    'baseline_cent_value',
    'valuation_source',
    'valuation_updated_at',
  ];
  static const _cardProductCols = [
    'card_product_id',
    'issuer',
    'display_name',
    'network',
    'annual_fee_usd',
    'foreign_tx_fee_pct',
    'image_url',
    'catalog_version',
    'retired_at',
  ];
  static const _rewardRuleCols = [
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
  ];
  static const _exclusionCols = ['rule_id', 'brand'];

  /// Loads the bundled offline-floor catalog, or null if absent/unreadable (e.g.
  /// in a test harness that doesn't ship the asset).
  Future<String?> _loadBundledCatalog() async {
    try {
      return await rootBundle.loadString(_bundledCatalogAsset);
    } catch (e) {
      Log.w('catalog', 'bundled catalog asset unavailable', e);
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchRemote() async {
    if (_remote == null) return null;
    try {
      final raw = await _remote.fetchIfUpdated(
        'catalog',
        RemoteAssetService.catalogUrl(),
      );
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      Log.w('catalog', 'R2 fetch failed; falling back to bundle', e);
      return null;
    }
  }

  static const _productPerkCols = [
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
  ];
}
