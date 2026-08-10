import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/reward_category.dart';
import '../util/logger.dart';
import 'remote_asset_service.dart';

/// Classifies a free-form `label` (bank transaction description,
/// Google Places display name, etc.) into a [RewardCategory] bucket and an
/// optional canonical `brand_id` slug.
///
/// Brand and category tables here are the **single source of truth** for
/// brand canonicalization. The `brand_id` returned is what gets written
/// into `transactions.brand_id`, then matched against the catalog's
/// `reward_rules.brand` at ranking time.
///
/// Both registries are data, not code: [initBrandRegistry] loads brands and
/// [initCategoryRegistry] loads categories from the local R2 cache, then the
/// bundled `assets/vocab/{brands,categories}.json`. The category matcher
/// keywords live in `assets/vocab/categories.json` — the single source shared
/// with the backend engine (its build classifier reads the same file).
///
/// Matching is word-boundary, not bidirectional substring — so "walmart"
/// never matches "Mart Coffee" and "uber" never matches "Hubert's".
/// Exception: the brand's matchers can be multi-token phrases, in which
/// case we match as a contiguous substring of normalized tokens. That
/// covers "uber eats" beating "uber" without re-creating substring noise.
({RewardCategory category, String? brandId}) classifyLabel(String label) {
  final tokens = _normalize(label);
  if (tokens.isEmpty) {
    return (category: RewardCategory.other, brandId: null);
  }

  // Brand pass: longest matcher wins. We iterate in declared order but the
  // matchers themselves are sorted by descending length so "uber eats"
  // beats "uber" without depending on table order.
  for (final entry in _brandTable) {
    for (final m in entry.tokenMatchers) {
      if (_containsAllTokensContiguously(tokens, m)) {
        return (category: entry.category, brandId: entry.brandId);
      }
    }
  }

  // Category pass: longest matcher wins globally. The flat matcher list is
  // pre-sorted by descending token length, so "online grocery" beats plain
  // "grocery" regardless of which category declared it first.
  for (final m in _categoryMatchers) {
    if (_containsAllTokensContiguously(tokens, m.tokens)) {
      return (category: m.category, brandId: null);
    }
  }

  return (category: RewardCategory.other, brandId: null);
}

/// Back-compat for callers that only want the category bucket.
RewardCategory classifyLooseLabel(String label) =>
    classifyLabel(label).category;

/// Path to the bundled brand registry — the offline floor (the full canonical
/// `assets/vocab/brands.json`, shipped with the app).
const String _bundledBrandsAsset = 'assets/vocab/brands.json';

/// Loads the brand registry into the in-memory classifier. Call once at app
/// boot, before the first sync. Three-tier, fallback-safe:
///   1. the local R2 cache from the previous launch (fast, offline-safe),
///   2. the bundled `assets/vocab/brands.json` (the offline floor).
/// A missing/empty/malformed source is logged and the next tier is tried. If
/// both fail the table stays empty (only a corrupt bundled asset reaches that,
/// and it ships with the binary). The JSON shape is what R2/CDN serves —
/// "brand knowledge as data, not code".
Future<void> initBrandRegistry({RemoteAssetService? remote}) async {
  // 1. Try the local R2 cache from the previous launch (fast, offline-safe).
  if (remote != null) {
    final cached = await remote.readCached('brands');
    if (cached != null && applyBrandsJson(cached)) {
      Log.i('brands', 'loaded ${_brandTable.length} brands from local cache');
      // Fire-and-forget background refresh: updates cache for the next launch.
      // ignore: unawaited_futures
      _refreshBrandsInBackground(remote);
      return;
    }
    // No local cache yet — fetch now and fall through to the bundled asset.
    // ignore: unawaited_futures
    _refreshBrandsInBackground(remote);
  }

  // 2. Bundled asset — the offline floor (full registry shipped with the app).
  try {
    final bundled = await rootBundle.loadString(_bundledBrandsAsset);
    if (applyBrandsJson(bundled)) {
      Log.i(
        'brands',
        'loaded ${_brandTable.length} brands from the bundled asset',
      );
      return;
    }
  } catch (e) {
    Log.w('brands', 'bundled brands asset unavailable', e);
  }

  // Both unavailable — table stays empty. Only a missing/corrupt bundled asset
  // reaches here (it ships with the binary), so this is near-unreachable.
  Log.w(
    'brands',
    'no brand registry loaded (R2 cache + bundled asset both failed)',
  );
}

Future<void> _refreshBrandsInBackground(RemoteAssetService remote) async {
  try {
    final fresh = await remote.fetchIfUpdated(
      'brands',
      RemoteAssetService.brandsUrl(),
    );
    if (fresh != null) {
      applyBrandsJson(fresh);
      Log.i('brands', 'refreshed ${_brandTable.length} brands from R2');
    }
  } catch (e) {
    Log.w('brands', 'background R2 refresh failed', e);
  }
}

/// Parses a brands JSON document (a list of
/// `{brandId, displayName, category, aliases}` objects) and swaps it into
/// the live registry. Returns false (and keeps the current table) on any
/// parse error or when no valid entries are found. Exposed for tests so
/// the data-driven path can be exercised without bundling an asset.
@visibleForTesting
bool applyBrandsJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return false;
    final loaded = <_BrandEntry>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final brandId = e['brandId'] as String?;
      final displayName = e['displayName'] as String?;
      final aliases = (e['aliases'] as List?)?.whereType<String>().toList();
      if (brandId == null ||
          displayName == null ||
          aliases == null ||
          aliases.isEmpty) {
        continue;
      }
      loaded.add(
        _BrandEntry(
          brandId: brandId,
          displayName: displayName,
          category: RewardCategory.fromName(
            e['category'] as String? ?? 'other',
          ),
          matchers: aliases,
        ),
      );
    }
    if (loaded.isEmpty) return false;
    _brandTable = loaded;
    _allBrandsById = _buildBrandsById(loaded);
    return true;
  } catch (_) {
    return false;
  }
}

/// Clears the in-memory registry (back to empty). For test teardown so one
/// test's loaded brands don't leak into the next.
@visibleForTesting
void resetBrandRegistry() {
  _brandTable = <_BrandEntry>[];
  _allBrandsById = <String, BrandRegistryEntry>{};
}

/// Display name for a brand_id slug. Used when seeding the `brands` table
/// and when projecting brand bonus rows back to UI copy. `null` for
/// unknown slugs.
String? brandDisplayNameFor(String brandId) =>
    _allBrandsById[brandId]?.displayName;

/// Default category for a brand_id slug (the category most reward rules
/// for that brand list). `RewardCategory.other` when unknown.
RewardCategory brandDefaultCategory(String brandId) =>
    _allBrandsById[brandId]?.category ?? RewardCategory.other;

/// Returns every brand we ship a canonical id for. The brand resolver
/// builds its runtime index from this list; each entry's `aliases` is a
/// list of normalized matcher phrases so the resolver can match merchant
/// names without re-implementing the matching logic.
Iterable<BrandRegistryEntry> registeredBrands() =>
    _allBrandsById.values.toList(growable: false);

class BrandRegistryEntry {
  const BrandRegistryEntry({
    required this.brandId,
    required this.displayName,
    required this.category,
    required this.aliases,
  });
  final String brandId;
  final String displayName;
  final RewardCategory category;
  final List<String> aliases;
}

class _BrandEntry {
  _BrandEntry({
    required this.brandId,
    required this.displayName,
    required this.category,
    required this.matchers,
  }) : tokenMatchers = [for (final m in matchers) _normalize(m)]
         ..sort((a, b) => b.length.compareTo(a.length));
  final String brandId;
  final String displayName;
  final RewardCategory category;
  final List<String> matchers;
  final List<List<String>> tokenMatchers;
}

/// A single normalized category matcher phrase + the category it resolves to.
/// The classifier holds a flat list of these sorted by descending token
/// length so the longest phrase wins globally (see [classifyLabel]).
class _CategoryMatcher {
  _CategoryMatcher(this.tokens, this.category);
  final List<String> tokens;
  final RewardCategory category;
}

// ────── Brand registry ──────
//
// The registry is data, not code: [initBrandRegistry] loads it from the R2
// cache or the bundled assets/vocab/brands.json. To add a brand, append an
// entry there — pick the brand_id slug carefully, it's a stable identifier
// downstream code joins against. The table is empty until boot loads it.

/// Live brand registry — empty until [initBrandRegistry] / [applyBrandsJson]
/// fills it (R2 cache → bundled asset). Boot loads it before the first
/// classification, so production never sees the empty table.
List<_BrandEntry> _brandTable = <_BrandEntry>[];

Map<String, BrandRegistryEntry> _buildBrandsById(List<_BrandEntry> table) => {
  for (final b in table)
    b.brandId: BrandRegistryEntry(
      brandId: b.brandId,
      displayName: b.displayName,
      category: b.category,
      aliases: b.matchers,
    ),
};

Map<String, BrandRegistryEntry> _allBrandsById = <String, BrandRegistryEntry>{};

// ────── Category registry ──────
//
// The category matcher keywords are data, not code: [initCategoryRegistry]
// loads them from the R2 cache or the bundled assets/vocab/categories.json —
// the single source shared with the backend engine. Matcher phrases include both
// singular and plural forms when relevant (token-equality matching means
// "airlines" wouldn't match the "airline" token); we don't stem, since that
// introduces false positives. The table is empty until boot loads it.

/// Path to the bundled category vocabulary — the offline floor (the full
/// canonical `assets/vocab/categories.json`, shipped with the app).
const String _bundledCategoriesAsset = 'assets/vocab/categories.json';

/// Highest categories.json `vocabVersion` this build fully understands. A
/// shipped file declaring a higher version carries categories whose ids this
/// binary's [RewardCategory] enum doesn't know — they classify to `other`
/// (breadcrumbed by [RewardCategory.fromName]) until the app is updated. Bump
/// in lockstep when new category ids are added to the enum. Mirrors
/// [CatalogLoader.supportedSchemaVersion].
const int supportedVocabVersion = 1;

/// Gates on the categories.json document marker (the leading, id-less object
/// carrying `vocabVersion` / `minApp`). Logs a breadcrumb only when the shipped
/// file is NEWER than this build understands — some of its categories may map
/// to `other` until the app updates. No-op when the file is at/below the
/// supported version, or when the marker is absent (older vocab files).
void _checkVocabVersion(Map marker) {
  final version = (marker['vocabVersion'] as num?)?.toInt();
  if (version == null) return;
  if (version > supportedVocabVersion) {
    Log.w(
      'categories',
      'categories.json vocabVersion=$version exceeds supported '
          '$supportedVocabVersion (minApp=${marker['minApp']}) — update SwipeWise '
          'to map its newest categories; unknown ids fall back to Other',
    );
  }
}

/// Live category matcher list — empty until [initCategoryRegistry] /
/// [applyCategoriesJson] fills it. Sorted by descending token length so the
/// longest matching phrase wins globally in [classifyLabel].
List<_CategoryMatcher> _categoryMatchers = <_CategoryMatcher>[];

/// Live `Google Places primaryType -> RewardCategory` index, built from each
/// category's `googlePlaceTypes` in `categories.json` (curated from Google's
/// place-types table). This is the AUTHORITATIVE place-type → category map for
/// the nearby/geofence flow — a direct one-hop lookup, so it never depends on
/// the label round-trip the way [classifyLooseLabel] does. Empty until loaded.
Map<String, RewardCategory> _placeTypeToCategory = <String, RewardCategory>{};

/// Maps a Google Places `primaryType` (e.g. `warehouse_store`) directly to its
/// [RewardCategory] via the curated `googlePlaceTypes`. Returns null when the
/// type isn't curated, so callers fall back to label/name heuristics.
RewardCategory? categoryForPlaceType(String? primaryType) {
  if (primaryType == null || primaryType.isEmpty) return null;
  return _placeTypeToCategory[primaryType];
}

/// Loads the category registry into the in-memory classifier. Call once at
/// app boot, before the first classification. Mirrors [initBrandRegistry]:
///   1. the local R2 cache from the previous launch (fast, offline-safe),
///   2. the bundled `assets/vocab/categories.json` (the offline floor).
Future<void> initCategoryRegistry({RemoteAssetService? remote}) async {
  if (remote != null) {
    final cached = await remote.readCached('categories');
    if (cached != null && applyCategoriesJson(cached)) {
      Log.i(
        'categories',
        'loaded ${_categoryMatchers.length} matchers from local cache',
      );
      // ignore: unawaited_futures
      _refreshCategoriesInBackground(remote);
      return;
    }
    // ignore: unawaited_futures
    _refreshCategoriesInBackground(remote);
  }

  try {
    final bundled = await rootBundle.loadString(_bundledCategoriesAsset);
    if (applyCategoriesJson(bundled)) {
      Log.i(
        'categories',
        'loaded ${_categoryMatchers.length} matchers from the bundled asset',
      );
      return;
    }
  } catch (e) {
    Log.w('categories', 'bundled categories asset unavailable', e);
  }

  Log.w(
    'categories',
    'no category registry loaded (R2 cache + bundled asset both failed)',
  );
}

Future<void> _refreshCategoriesInBackground(RemoteAssetService remote) async {
  try {
    final fresh = await remote.fetchIfUpdated(
      'categories',
      RemoteAssetService.categoriesUrl(),
    );
    if (fresh != null) {
      applyCategoriesJson(fresh);
      Log.i(
        'categories',
        'refreshed ${_categoryMatchers.length} matchers from R2',
      );
    }
  } catch (e) {
    Log.w('categories', 'background R2 refresh failed', e);
  }
}

/// Parses a categories JSON document (a list of
/// `{id, displayName, iconKey, matcherKeywords, googlePlaceTypes}` objects)
/// and swaps its matcher keywords into the live registry. Returns false (and
/// keeps the current table) on any parse error or when no valid matchers are
/// found. Exposed for tests so the data-driven path can be exercised without
/// bundling an asset.
@visibleForTesting
bool applyCategoriesJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return false;
    final loaded = <_CategoryMatcher>[];
    final placeTypes = <String, RewardCategory>{};
    for (final e in decoded) {
      if (e is! Map) continue;
      final id = e['id'] as String?;
      if (id == null) {
        // The document marker (no `id`) carries the vocab version — gate on it.
        _checkVocabVersion(e);
        continue;
      }
      final category = RewardCategory.fromName(id);
      final keywords = (e['matcherKeywords'] as List?)?.whereType<String>();
      for (final phrase in keywords ?? const <String>[]) {
        final tokens = _normalize(phrase);
        if (tokens.isNotEmpty) loaded.add(_CategoryMatcher(tokens, category));
      }
      final types = (e['googlePlaceTypes'] as List?)?.whereType<String>();
      for (final t in types ?? const <String>[]) {
        final key = t.trim();
        if (key.isNotEmpty) placeTypes[key] = category;
      }
    }
    if (loaded.isEmpty) return false;
    loaded.sort((a, b) => b.tokens.length.compareTo(a.tokens.length));
    _categoryMatchers = loaded;
    _placeTypeToCategory = placeTypes;
    return true;
  } catch (_) {
    return false;
  }
}

/// Clears the in-memory category registry (back to empty). For test teardown
/// so one test's loaded matchers don't leak into the next.
@visibleForTesting
void resetCategoryRegistry() {
  _categoryMatchers = <_CategoryMatcher>[];
  _placeTypeToCategory = <String, RewardCategory>{};
}

// ────── Tokenization ──────

/// Lowercases, replaces non-alphanumeric runs with spaces, splits, and
/// drops empty tokens. Diacritics are normalized via `_stripDiacritics`
/// so "café" matches "cafe".
List<String> _normalize(String s) {
  final stripped = _stripDiacritics(s.toLowerCase());
  final cleaned = stripped.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  if (cleaned.isEmpty) return const [];
  return cleaned.split(' ');
}

/// Returns true when [needle] appears as a contiguous run of tokens inside
/// [haystack]. Single-token matchers degrade to "haystack contains the
/// token as a whole word", which is what we want (no substring matches
/// like "uber" inside "hubert").
bool _containsAllTokensContiguously(
  List<String> haystack,
  List<String> needle,
) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Maps the small set of Latin-1 supplemental + extended-A characters we
/// see in US merchant names. Sufficient for "café", "Häagen-Dazs", etc.
/// without dragging in a full ICU dependency.
String _stripDiacritics(String s) {
  const map = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'ā': 'a',
    'ç': 'c',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ē': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ī': 'i',
    'ñ': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ø': 'o',
    'ō': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ū': 'u',
    'ý': 'y',
    'ÿ': 'y',
  };
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    buf.write(map[ch] ?? ch);
  }
  return buf.toString();
}
