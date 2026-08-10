import 'package:sqflite/sqflite.dart';

import '../util/logger.dart';
import 'catalog_repository.dart';
import 'database_helper.dart';
import 'reward_engine.dart';

/// Binds each synced `cards` row to a catalog `card_product_id`, writing
/// `card_links`. This is the catalog-era replacement for the *binding* role
/// `RewardSeedService._bestMatch` played — but it produces a stable,
/// inspectable link row instead of re-deriving the match on every read.
///
/// Resolution per card, highest precedence first:
///   1. **explicit** — the card's `card_overrides.product_identification`,
///      when it's a slug present in the *current* catalog (`preconfirmed`).
///   2. **heuristic** — fuzzy name match `cards.name` → `card_products
///      .display_name` (Jaccard, bank-restricted then full), `confidence` set.
///   3. **unmatched** — no row written; the Identify Card sheet (B5) is the
///      affordance.
///
/// A `user_confirmed` link (written by the identify sheet) is never
/// downgraded by a re-seed.
class CardLinkService {
  CardLinkService({CatalogRepository? catalog, DatabaseHelper? dbHelper})
    : _catalog = catalog ?? CatalogRepository(DatabaseHelper()),
      _dbHelper = dbHelper ?? DatabaseHelper();

  final CatalogRepository _catalog;
  final DatabaseHelper _dbHelper;

  /// Re-derives links for all of the user's cards. Idempotent; safe to run
  /// after every sync.
  Future<CardLinkSeedResult> seedLinks(String userId) async {
    final db = await _dbHelper.database;
    final userCards = await db.rawQuery(
      '''
      SELECT cards.id, cards.name, cards.provider,
             card_overrides.product_identification AS pid,
             card_links.source AS link_source,
             card_links.card_product_id AS linked_pid
      FROM cards
      LEFT JOIN card_overrides
        ON card_overrides.card_id = cards.id
       AND card_overrides.user_id = cards.user_id
      LEFT JOIN card_links
        ON card_links.card_id = cards.id
       AND card_links.user_id = cards.user_id
      WHERE cards.user_id = ?
      ''',
      [userId],
    );

    final products = await _catalog.productsForIssuer(null);
    if (products.isEmpty) {
      // Catalog not hydrated yet — nothing to bind against.
      return const CardLinkSeedResult();
    }
    final byId = {for (final p in products) p.id: p};
    final tokenized = [
      for (final p in products)
        (product: p, tokens: _normalizeTokens(p.displayName)),
    ];

    var explicit = 0, heuristic = 0, unmatched = 0;
    for (final row in userCards) {
      final cardId = row['id'] as String;
      final name = (row['name'] as String?) ?? '';
      if (name.isEmpty) {
        unmatched++;
        continue;
      }
      final provider = row['provider'] as String?;
      final pid = row['pid'] as String?;

      // Never re-bind a user's explicit Identify-Card pick — but still
      // refresh its display art from the linked product. `image_url` is a
      // snapshot taken at confirm time; a card confirmed before the catalog
      // carried art for its product is left stale-empty, even though the
      // catalog has the image now. Re-canonicalize without touching the link.
      if (row['link_source'] == 'user_confirmed') {
        final linkedPid = row['linked_pid'] as String?;
        if (linkedPid != null) {
          await _upgradeCardDisplay(db, userId, cardId, byId[linkedPid]);
        }
        continue;
      }

      if (pid != null && pid.isNotEmpty && byId.containsKey(pid)) {
        await _catalog.upsertLink(
          userId: userId,
          cardId: cardId,
          cardProductId: pid,
          source: 'preconfirmed',
        );
        await _upgradeCardDisplay(db, userId, cardId, byId[pid]);
        explicit++;
        continue;
      }

      final match = _bestMatch(name, provider, tokenized);
      if (match == null) {
        unmatched++;
        continue;
      }
      await _catalog.upsertLink(
        userId: userId,
        cardId: cardId,
        cardProductId: match.product.id,
        source: 'heuristic',
        confidence: match.score,
      );
      await _upgradeCardDisplay(db, userId, cardId, match.product);
      heuristic++;
    }

    Log.i(
      'card-link',
      'seeded links: explicit=$explicit heuristic=$heuristic '
          'unmatched=$unmatched of ${userCards.length}',
    );
    return CardLinkSeedResult(
      explicit: explicit,
      heuristic: heuristic,
      unmatched: unmatched,
    );
  }

  /// Canonicalizes a card's display name + art from its linked catalog
  /// product (what `RewardSeedService` used to do on match). `custom_name`
  /// still overrides this in the UI, so a user rename is never lost.
  Future<void> _upgradeCardDisplay(
    Database db,
    String userId,
    String cardId,
    CardProduct? product,
  ) async {
    if (product == null) return;
    final update = <String, Object?>{};
    if (product.displayName.isNotEmpty) update['name'] = product.displayName;
    final img = product.imageUrl;
    if (img != null && img.isNotEmpty) update['image_url'] = img;
    if (update.isEmpty) return;
    await db.update(
      'cards',
      update,
      where: 'id = ? AND user_id = ?',
      whereArgs: [cardId, userId],
    );
  }

  /// Records an explicit user binding (Identify Card flow, B5) and
  /// canonicalizes the card's name/art from the product. Highest precedence;
  /// a re-seed will not overwrite it.
  Future<void> confirmLink({
    required String userId,
    required String cardId,
    required String cardProductId,
  }) async {
    await _catalog.upsertLink(
      userId: userId,
      cardId: cardId,
      cardProductId: cardProductId,
      source: 'user_confirmed',
    );
    final products = await _catalog.productsForIssuer(null);
    CardProduct? product;
    for (final p in products) {
      if (p.id == cardProductId) {
        product = p;
        break;
      }
    }
    await _upgradeCardDisplay(
      await _dbHelper.database,
      userId,
      cardId,
      product,
    );
  }

  /// Best catalog `card_product_id` for a card name (+ optional issuer/provider
  /// hint), or null below the match threshold. Bridges the Identify Card
  /// picker — which still operates in seed-product space — to a catalog slug
  /// so the explicit pick can be recorded as a `card_links` binding.
  Future<String?> matchProductSlug(String cardName, String? provider) async {
    final products = await _catalog.productsForIssuer(null);
    if (products.isEmpty) return null;
    final tokenized = [
      for (final p in products)
        (product: p, tokens: _normalizeTokens(p.displayName)),
    ];
    return _bestMatch(cardName, provider, tokenized)?.product.id;
  }

  // ─────────────── Fuzzy name matching ───────────────
  //
  // Mirrors RewardSeedService's Jaccard matcher, retargeted at
  // `card_products.display_name`. Kept self-contained so the seed service
  // (deleted at the engine cutover) carries no new dependency.

  static const _stopwords = <String>{
    'card',
    'credit',
    'the',
    'a',
    'an',
    'rewards',
    'signature',
  };

  static List<String> _normalizeTokens(String name) {
    final cleaned = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    if (cleaned.isEmpty) return const [];
    return [
      for (final t in cleaned.split(' '))
        if (t.length >= 2 && !_stopwords.contains(t)) t,
    ];
  }

  static ({CardProduct product, double score})? _bestMatch(
    String userCardName,
    String? userProvider,
    List<({CardProduct product, List<String> tokens})> tokenized,
  ) {
    final userSet = _normalizeTokens(userCardName).toSet();
    if (userSet.isEmpty) return null;

    ({CardProduct product, double score})? pickWithin(
      Iterable<({CardProduct product, List<String> tokens})> pool,
      double threshold,
    ) {
      CardProduct? best;
      var bestScore = 0.0;
      for (final s in pool) {
        if (s.tokens.isEmpty) continue;
        final seedSet = s.tokens.toSet();
        final inter = seedSet.intersection(userSet).length;
        if (inter == 0) continue;
        final jaccard = inter / seedSet.union(userSet).length;
        if (jaccard > bestScore) {
          bestScore = jaccard;
          best = s.product;
        }
      }
      if (best == null || bestScore < threshold) return null;
      return (product: best, score: bestScore);
    }

    // Bank-restricted pass first (issuer ↔ provider loose match, 0.30), then
    // the full catalog at the strict 0.50 floor to avoid cross-issuer
    // false positives.
    final providerKey = userProvider == null ? '' : _issuerKey(userProvider);
    if (providerKey.isNotEmpty) {
      final sameIssuer = tokenized.where((s) {
        final issuerKey = _issuerKey(s.product.issuer);
        return issuerKey.isNotEmpty &&
            (issuerKey.contains(providerKey) ||
                providerKey.contains(issuerKey));
      });
      final within = pickWithin(sameIssuer, 0.3);
      if (within != null) return within;
    }
    return pickWithin(tokenized, 0.5);
  }

  /// Collapses an issuer/provider label to an alphanumeric key so spacing and
  /// punctuation can't block a match: the synced provider "US Bank" (or
  /// "U.S. Bank") must reach the catalog's slug-derived issuer "Usbank".
  /// Single-token issuers (Chase/Citi/Discover) are unaffected.
  static String _issuerKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

class CardLinkSeedResult {
  const CardLinkSeedResult({
    this.explicit = 0,
    this.heuristic = 0,
    this.unmatched = 0,
  });
  final int explicit;
  final int heuristic;
  final int unmatched;

  int get linked => explicit + heuristic;
}
