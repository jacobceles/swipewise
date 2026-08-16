import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/insights.dart';
import '../models/reward_category.dart';
import 'database_helper.dart';
import 'reward_category_mapper.dart';
import 'reward_engine.dart';
import 'settings_repository.dart';
import 'types.dart';

/// One synced card bound to a catalog product — the input the engine ranks.
class LinkedCard {
  const LinkedCard({
    required this.cardId,
    required this.cardProductId,
    required this.cardName,
    this.lastFour,
    this.imageUrl,
  });

  final String cardId;
  final String cardProductId;
  final String cardName;
  final String? lastFour;
  final String? imageUrl;
}

/// An issuer as the wallet flow presents it: how many products we know of,
/// and one product image to represent them.
class CatalogIssuer {
  const CatalogIssuer({
    required this.id,
    required this.displayName,
    required this.productCount,
    this.imageUrl,
  });

  /// The raw `card_products.issuer` value — the join key, not a label.
  final String id;

  /// What to show the user. See [issuerDisplayName].
  final String displayName;
  final int productCount;

  /// Art from one of the issuer's products, purely to make the row scannable.
  final String? imageUrl;
}

/// The catalog stores issuers as squashed slugs (`Bankofamerica`, `Usbank`,
/// `Sofi`) because the bank-linked flow matches them by stripping every
/// non-alphanumeric character — `_normalized('Bank of America')` and
/// `_normalized('Bankofamerica')` land on the same string, which is what
/// makes that fuzzy join work.
///
/// Those slugs are join keys, not labels, so the free wallet flow — which
/// shows issuers to the user directly rather than deriving them from a bank
/// they picked — needs real names. Keyed on the squashed form so a future
/// catalog that starts emitting `Bank of America` keeps resolving.
///
/// Unknown issuers fall through to the catalog's own string. That is
/// deliberately a bit ugly: a new issuer should be visible enough that
/// someone adds it here, but never so broken that the card can't be added.
const Map<String, String> _kIssuerDisplayNames = {
  'amex': 'American Express',
  'bankofamerica': 'Bank of America',
  'barclays': 'Barclays',
  'bilt': 'Bilt',
  'capitalone': 'Capital One',
  'chase': 'Chase',
  'citi': 'Citi',
  'discover': 'Discover',
  'goldmansachs': 'Goldman Sachs',
  'navyfederal': 'Navy Federal',
  'penfed': 'PenFed',
  'robinhood': 'Robinhood',
  'sofi': 'SoFi',
  'usaa': 'USAA',
  'usbank': 'U.S. Bank',
  'wellsfargo': 'Wells Fargo',
};

/// Presentable name for a `card_products.issuer` value.
String issuerDisplayName(String issuer) {
  final key = issuer.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return _kIssuerDisplayNames[key] ?? issuer;
}

/// All DB access for the catalog Track-B tables: the five global catalog
/// tables (`point_systems`/`card_products`/`reward_rules`/
/// `reward_rule_exclusions`/`product_perks`), the user-side `card_links`, and
/// `rotating_activations`.
///
/// Deliberately the ONLY place that touches these tables, so `reward_engine`
/// stays a pure function over [CatalogSnapshot] and the rest of the app talks
/// to bindings through one surface.
class CatalogRepository {
  CatalogRepository(this._dbHelper);
  final DatabaseHelper _dbHelper;

  // ─────────────── Catalog hydration (global) ───────────────

  /// Replaces the five global catalog tables atomically. Rows must already
  /// be column-projected (only real column keys). Deletes run in reverse FK
  /// order, inserts in forward FK order, so `foreign_keys = ON` is happy.
  Future<void> replaceCatalog({
    required List<Map<String, Object?>> pointSystems,
    required List<Map<String, Object?>> cardProducts,
    required List<Map<String, Object?>> rewardRules,
    required List<Map<String, Object?>> exclusions,
    List<Map<String, Object?>> productPerks = const [],
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      await txn.delete('reward_rule_exclusions');
      await txn.delete('reward_rules');
      await txn.delete('product_perks');
      await txn.delete('card_products');
      await txn.delete('point_systems');

      final batch = txn.batch();
      for (final p in pointSystems) {
        batch.insert('point_systems', p);
      }
      for (final c in cardProducts) {
        batch.insert('card_products', c);
      }
      for (final r in rewardRules) {
        batch.insert('reward_rules', r);
      }
      for (final e in exclusions) {
        batch.insert('reward_rule_exclusions', e);
      }
      for (final p in productPerks) {
        batch.insert('product_perks', p);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Row counts per catalog table — used by the loader to log a hydration
  /// summary and by tests to assert the import landed.
  Future<Map<String, int>> catalogCounts() async {
    final db = await _dbHelper.database;
    final out = <String, int>{};
    for (final t in const [
      'point_systems',
      'card_products',
      'reward_rules',
      'reward_rule_exclusions',
    ]) {
      final res = await db.rawQuery('SELECT COUNT(*) AS n FROM $t');
      out[t] = Sqflite.firstIntValue(res) ?? 0;
    }
    return out;
  }

  // ─────────────── Snapshot (engine input) ───────────────

  /// Reads the four global tables once and builds the immutable
  /// [CatalogSnapshot] the engine resolves against.
  Future<CatalogSnapshot> loadSnapshot() async {
    final db = await _dbHelper.database;
    final productRows = await db.query('card_products');
    final ruleRows = await db.query('reward_rules');
    final exclusionRows = await db.query('reward_rule_exclusions');
    final psRows = await db.query('point_systems');

    final products = <String, CardProduct>{
      for (final r in productRows) r['card_product_id'] as String: _product(r),
    };

    final rulesByProduct = <String, List<RewardRule>>{};
    for (final r in ruleRows) {
      final rule = _rule(r);
      (rulesByProduct[rule.productId] ??= <RewardRule>[]).add(rule);
    }

    final exclusionsByRule = <String, Set<String>>{};
    for (final r in exclusionRows) {
      final ruleId = r['rule_id'] as String;
      (exclusionsByRule[ruleId] ??= <String>{}).add(r['brand'] as String);
    }

    final pointSystems = <String, PointSystem>{
      for (final r in psRows) r['point_system_id'] as String: _pointSystem(r),
    };

    return CatalogSnapshot(
      products: products,
      rulesByProduct: rulesByProduct,
      exclusionsByRule: exclusionsByRule,
      pointSystems: pointSystems,
    );
  }

  /// Catalog products for an issuer (case-insensitive), for the Identify
  /// Card picker. Null/empty issuer returns the whole catalog.
  Future<List<CardProduct>> productsForIssuer(
    String? issuer, {
    String? country,
  }) async {
    final db = await _dbHelper.database;
    final clauses = <String>[];
    final args = <Object?>[];
    if (issuer != null && issuer.trim().isNotEmpty) {
      clauses.add('LOWER(issuer) = ?');
      args.add(issuer.trim().toLowerCase());
    }
    final countryClause = _countryClause(country);
    if (countryClause != null) {
      clauses.add(countryClause);
      args.add(country);
    }
    final rows = await db.query(
      'card_products',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: clauses.isEmpty ? null : args,
      orderBy: 'display_name',
    );
    return rows.map(_product).toList(growable: false);
  }

  /// `null` when no filtering applies — no country asked for, or [catalogCountryAll].
  ///
  /// `COALESCE(country, 'US')` is what makes this safe against an older catalog:
  /// bundles published before Canada carry no `country` at all, and every card
  /// in them is American, so a NULL reads as US rather than dropping the whole
  /// catalog out of the picker.
  static String? _countryClause(String? country) =>
      (country == null || country == catalogCountryAll)
      ? null
      : "COALESCE(country, 'US') = ?";

  /// Every issuer in the catalog, for the wallet flow's issuer picker.
  ///
  /// Retired products are excluded — a card nobody can hold shouldn't pad an
  /// issuer's count, and an issuer whose whole line-up is retired shouldn't
  /// appear at all. The image is just the first product that has art
  /// (~95% of the catalog does), used to make the row scannable.
  Future<List<CatalogIssuer>> issuers({String? country}) async {
    final db = await _dbHelper.database;
    final countryClause = _countryClause(country);
    final rows = await db.rawQuery('''
      SELECT issuer,
             COUNT(*) AS product_count,
             MIN(image_url) AS image_url
      FROM card_products
      WHERE retired_at IS NULL
            ${countryClause == null ? '' : 'AND $countryClause'}
      GROUP BY issuer
      ORDER BY issuer COLLATE NOCASE
    ''', countryClause == null ? null : [country]);
    return [
      for (final r in rows)
        CatalogIssuer(
          id: r['issuer'] as String,
          displayName: issuerDisplayName(r['issuer'] as String),
          productCount: (r['product_count'] as num).toInt(),
          imageUrl: r['image_url'] as String?,
        ),
    ]..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  /// How many of the user's cards belong to each issuer, keyed by the raw
  /// `card_products.issuer` value so it joins straight onto [issuers].
  ///
  /// Drives the "already added" count on each row of the issuer picker.
  /// Someone building a wallet adds a few cards across several issuers in one
  /// sitting, and without this the list looks identical before and after —
  /// there is nothing on screen to say where they got to.
  Future<Map<String, int>> linkedCountsByIssuer(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT cp.issuer AS issuer, COUNT(*) AS n
      FROM card_links cl
      JOIN card_products cp ON cp.card_product_id = cl.card_product_id
      WHERE cl.user_id = ?
      GROUP BY cp.issuer
      ''',
      [userId],
    );
    return {
      for (final r in rows) r['issuer'] as String: (r['n'] as num).toInt(),
    };
  }

  /// Every known `card_product_id` — used to validate a card's stored
  /// `product_identification` against the *current* catalog before treating
  /// it as an explicit link.
  Future<Set<String>> allProductIds() async {
    final db = await _dbHelper.database;
    final rows = await db.query('card_products', columns: ['card_product_id']);
    return {for (final r in rows) r['card_product_id'] as String};
  }

  // ─────────────── card_links (user-side) ───────────────

  /// The user's cards bound to a catalog product, joined to the synced
  /// `cards` row for display fields. Cards with no link are absent.
  Future<List<LinkedCard>> linkedCards(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT cl.card_id, cl.card_product_id,
             c.name AS card_name, c.last_four, c.image_url
      FROM card_links cl
      JOIN cards c ON c.id = cl.card_id AND c.user_id = cl.user_id
      WHERE cl.user_id = ?
      ''',
      [userId],
    );
    return [
      for (final r in rows)
        LinkedCard(
          cardId: r['card_id'] as String,
          cardProductId: r['card_product_id'] as String,
          cardName: (r['card_name'] as String?) ?? '',
          lastFour: r['last_four'] as String?,
          imageUrl: r['image_url'] as String?,
        ),
    ];
  }

  Future<void> upsertLink({
    required String userId,
    required String cardId,
    required String cardProductId,
    required String source,
    double? confidence,
  }) async {
    final db = await _dbHelper.database;
    await db.insert('card_links', {
      'user_id': userId,
      'card_id': cardId,
      'card_product_id': cardProductId,
      'source': source,
      'confidence': confidence,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ─────────────── rotating_activations (user-side) ───────────────

  /// card_id → set of activated `(year, quarter)` pairs for the user.
  Future<Map<String, Set<(int, int)>>> activations(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'rotating_activations',
      where: 'user_id = ? AND activated_at IS NOT NULL',
      whereArgs: [userId],
    );
    final out = <String, Set<(int, int)>>{};
    for (final r in rows) {
      final cardId = r['card_id'] as String;
      final y = (r['rotation_year'] as num).toInt();
      final q = (r['rotation_quarter'] as num).toInt();
      (out[cardId] ??= <(int, int)>{}).add((y, q));
    }
    return out;
  }

  Future<void> setActivation({
    required String userId,
    required String cardId,
    required int year,
    required int quarter,
    required bool activated,
    DateTime? at,
  }) async {
    final db = await _dbHelper.database;
    await db.insert('rotating_activations', {
      'user_id': userId,
      'card_id': cardId,
      'rotation_year': year,
      'rotation_quarter': quarter,
      'activated_at': activated
          ? (at ?? DateTime.now()).toUtc().toIso8601String()
          : null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ─────────────── Card-detail reads (via card_links) ───────────────

  /// Perks for a card, resolved through its catalog link. Display-only —
  /// `product_perks` has no user redemption state, so every perk is surfaced
  /// as available.
  Future<List<CardPerk>> perksForCard(String userId, String cardId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT pp.perk_id AS id, ? AS card_id, pp.title, pp.kind, pp.description,
             pp.frequency, pp.value_estimate, pp.calendar_max_year_amount,
             pp.how_to_earn, pp.image_uri, pp.redemption_url
      FROM card_links cl
      JOIN product_perks pp ON pp.card_product_id = cl.card_product_id
      WHERE cl.user_id = ? AND cl.card_id = ?
      ORDER BY pp.title
      ''',
      [cardId, userId, cardId],
    );
    return rows.map(CardPerk.fromRow).toList(growable: false);
  }

  /// The card's earn rules, shaped like the old `wallet_rewards` rows so the
  /// card-detail Rewards tab renders unchanged. 0-rate intro-APR promos are
  /// omitted (not earn rules); baseline sorts last.
  Future<List<WalletRewardRow>> rewardsForCard(
    String userId,
    String cardId,
  ) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT rr.*
      FROM card_links cl
      JOIN reward_rules rr ON rr.card_product_id = cl.card_product_id
      WHERE cl.user_id = ? AND cl.card_id = ?
      ''',
      [userId, cardId],
    );
    final out = <WalletRewardRow>[];
    for (final r in rows) {
      final rule = _rule(r);
      if (rule.kind == RewardRuleKind.promo && rule.rate == 0) continue;
      if (rule.kind == RewardRuleKind.partnerPortal) continue;
      out.add(
        WalletRewardRow(
          ruleId: rule.ruleId,
          label: _ruleLabel(rule),
          categoryName: rule.category?.name ?? 'other',
          brandId: rule.brand,
          isBaseline: rule.kind == RewardRuleKind.baseline,
          amount: rule.rate,
          currency: _currencyLabel(rule.pointSystemId),
          iconId: null,
          earnConstraint: rule.earnConstraint,
        ),
      );
    }
    out.sort((a, b) {
      if (a.isBaseline != b.isBaseline) return a.isBaseline ? 1 : -1;
      return (b.amount ?? 0).compareTo(a.amount ?? 0);
    });
    return out;
  }

  /// card_id → display currency ('USD' / 'POINTS' / 'MILES'), from each card's
  /// linked product's baseline point system. Replaces the wallet_rewards-based
  /// currency map used by the transactions list.
  Future<Map<String, String>> cardCurrencyMap(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT cl.card_id, rr.point_system_id
      FROM card_links cl
      JOIN reward_rules rr ON rr.card_product_id = cl.card_product_id
                          AND rr.kind = 'baseline'
      WHERE cl.user_id = ?
      ''',
      [userId],
    );
    return {
      for (final r in rows)
        r['card_id'] as String: _currencyLabel(r['point_system_id'] as String),
    };
  }

  static String _currencyLabel(String pointSystemId) => pointSystemId == 'usd'
      ? 'USD'
      : (pointSystemId.contains('miles') ? 'MILES' : 'POINTS');

  static String _ruleLabel(RewardRule r) {
    switch (r.kind) {
      case RewardRuleKind.baseline:
        return 'All other purchases';
      case RewardRuleKind.rotating:
        final base = r.brand != null
            ? (brandDisplayNameFor(r.brand!) ?? r.brand!)
            : (r.category?.label ?? 'Rotating');
        return '$base (rotating)';
      case RewardRuleKind.brand:
        return brandDisplayNameFor(r.brand ?? '') ?? r.brand ?? 'Brand bonus';
      case RewardRuleKind.category:
        return r.category?.label ?? 'Category';
      case RewardRuleKind.promo:
      case RewardRuleKind.partnerPortal:
      case RewardRuleKind.unknown:
        return r.notes ?? r.category?.label ?? 'Rewards';
    }
  }

  // ─────────────── Row → model ───────────────

  static DateTime? _date(Object? v) =>
      v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;

  CardProduct _product(Map<String, Object?> r) => CardProduct(
    id: r['card_product_id'] as String,
    issuer: r['issuer'] as String,
    displayName: r['display_name'] as String,
    network: r['network'] as String?,
    annualFeeUsd: (r['annual_fee_usd'] as num?)?.toDouble(),
    // Negative is the "never captured" sentinel written by CatalogLoader: the
    // column is NOT NULL DEFAULT 0.0 and has two FK dependents, so making it
    // nullable would mean a table rebuild for a distinction a sentinel carries
    // just as well. No real fee is negative.
    foreignTxFeePct: switch ((r['foreign_tx_fee_pct'] as num?)?.toDouble()) {
      null => null,
      final v when v < 0 => null,
      final v => v,
    },
    imageUrl: r['image_url'] as String?,
    catalogVersion: r['catalog_version'] as String,
    retiredAt: r['retired_at'] as String?,
    country: r['country'] as String?,
    currency: r['currency'] as String?,
  );

  RewardRule _rule(Map<String, Object?> r) {
    final cat = r['category'] as String?;
    return RewardRule(
      ruleId: r['rule_id'] as String,
      productId: r['card_product_id'] as String,
      kind: RewardRuleKind.fromName(r['kind'] as String?),
      category: cat != null ? RewardCategory.fromName(cat) : null,
      brand: r['brand'] as String?,
      rate: (r['rate'] as num).toDouble(),
      pointSystemId: r['point_system_id'] as String,
      validFrom: _date(r['valid_from']),
      validTo: _date(r['valid_to']),
      rotationYear: (r['rotation_year'] as num?)?.toInt(),
      rotationQuarter: (r['rotation_quarter'] as num?)?.toInt(),
      requiresActivation: (r['requires_activation'] as num?)?.toInt() == 1,
      capSpendAmountUsd: (r['cap_spend_amount_usd'] as num?)?.toDouble(),
      capPeriod: r['cap_period'] as String?,
      capGroup: r['cap_group'] as String?,
      notes: r['notes'] as String?,
      earnConstraint: r['earn_constraint'] as String?,
      excludedCategories: _categoryList(r['excluded_categories']),
    );
  }

  /// Decode the stored `excluded_categories` JSON array (e.g. `'["transit"]'`) into
  /// `RewardCategory` values. Empty for null/blank/legacy rows (pre-migration data or
  /// the common case with no exclusions).
  static List<RewardCategory> _categoryList(Object? v) {
    if (v is! String || v.isEmpty) return const [];
    final decoded = jsonDecode(v);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is String) RewardCategory.fromName(e),
    ];
  }

  PointSystem _pointSystem(Map<String, Object?> r) => PointSystem(
    id: r['point_system_id'] as String,
    displayName: r['display_name'] as String,
    baselineCentValue: (r['baseline_cent_value'] as num).toDouble(),
  );
}
