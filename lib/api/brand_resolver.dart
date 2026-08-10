import 'reward_category_mapper.dart';

/// Token-aware merchant-name → `brand_id` resolver. Replaces the
/// bidirectional-substring matching that used to live in the old SQL reward
/// ranker and `geofence_manager._findBrandHit` (which falsely matched
/// "Walmart" against "Mart Coffee" via the reverse-direction
/// `merchant.contains(brand)` branch).
///
/// Built from the in-code [registeredBrands] registry — the same Dart
/// list that backs `classifyLabel`. No SQLite involvement: the
/// registry is the single source of truth, never empty, and producing a
/// derived view at runtime is cheap. Previously this loaded from a
/// `brands` SQLite table that mirrored the registry; the mirror added
/// FK-ordering hazards (transactions referencing brand_ids the table
/// hadn't been seeded with yet) for no real benefit and is gone.
///
/// The same resolver is used by the sync engine (writing
/// `transactions.brand_id`), the nearby pipeline (matching merchants to brand
/// bonuses), and the reward ranker (`brand_id` filter for the ranking sheet).
class BrandResolver {
  BrandResolver._(this._byFirstToken, this._all);

  /// Returns a resolver built from the in-code brand registry. Cheap
  /// enough to rebuild per sync; safe to cache for the life of the
  /// process if a caller prefers (the registry is compile-time static).
  factory BrandResolver.fromRegistry(Iterable<BrandRegistryEntry> entries) {
    final byFirstToken = <String, List<_Alias>>{};
    final all = <_BrandRow>[];
    for (final e in entries) {
      all.add(_BrandRow(brandId: e.brandId, displayName: e.displayName));
      final phrases = e.aliases.isEmpty ? [e.displayName] : e.aliases;
      for (final phrase in phrases) {
        final tokens = _tokenize(phrase);
        if (tokens.isEmpty) continue;
        byFirstToken
            .putIfAbsent(tokens.first, () => [])
            .add(_Alias(brandId: e.brandId, tokens: tokens));
      }
    }
    // Longer aliases first so "uber eats" matches before "uber" when the
    // merchant name supports both.
    for (final list in byFirstToken.values) {
      list.sort((a, b) => b.tokens.length.compareTo(a.tokens.length));
    }
    return BrandResolver._(byFirstToken, all);
  }

  /// Default shared resolver built from the live in-code registry.
  /// Callers that don't have a custom registry (e.g., tests using a
  /// trimmed-down brand list) should reach for this directly instead
  /// of plumbing one through DataRepository.
  static BrandResolver fromDefaultRegistry() =>
      BrandResolver.fromRegistry(registeredBrands());

  final Map<String, List<_Alias>> _byFirstToken;
  final List<_BrandRow> _all;

  /// Returns the matched `brand_id` for a merchant / description string,
  /// or `null` when no alias matches. Matching is whole-token contiguous.
  String? resolve(String merchantName) {
    final tokens = _tokenize(merchantName);
    if (tokens.isEmpty) return null;
    String? longestMatch;
    int longestLen = 0;
    for (var i = 0; i < tokens.length; i++) {
      final candidates = _byFirstToken[tokens[i]];
      if (candidates == null) continue;
      for (final cand in candidates) {
        if (cand.tokens.length > tokens.length - i) continue;
        if (cand.tokens.length < longestLen) continue;
        var ok = true;
        for (var j = 0; j < cand.tokens.length; j++) {
          if (tokens[i + j] != cand.tokens[j]) {
            ok = false;
            break;
          }
        }
        if (ok && cand.tokens.length > longestLen) {
          longestMatch = cand.brandId;
          longestLen = cand.tokens.length;
        }
      }
    }
    return longestMatch;
  }

  /// Snapshot of every brand_id known to the resolver. Used by the ranker
  /// to enumerate brand bonuses without re-querying the DB.
  Iterable<({String brandId, String displayName})> get all =>
      _all.map((b) => (brandId: b.brandId, displayName: b.displayName));
}

class _Alias {
  const _Alias({required this.brandId, required this.tokens});
  final String brandId;
  final List<String> tokens;
}

class _BrandRow {
  const _BrandRow({required this.brandId, required this.displayName});
  final String brandId;
  final String displayName;
}

List<String> _tokenize(String s) {
  final stripped = _strip(s.toLowerCase());
  final cleaned = stripped.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  if (cleaned.isEmpty) return const [];
  return cleaned.split(' ');
}

/// Minimal diacritic-stripping. Mirrors `reward_category_mapper`'s table.
String _strip(String s) {
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
