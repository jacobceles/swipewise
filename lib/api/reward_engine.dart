/// The pure rate-resolution engine (catalog Track B). Given a card product,
/// a classified purchase (category + optional brand), and the moment, it
/// resolves the single best applicable reward rule and returns an
/// [AppliedRate]. No database, no I/O, no Flutter — every input is an
/// in-memory value, so the whole thing is unit-testable from fixtures.
///
/// It replaces `RewardRepository._runGeneralRanking` (~250 lines of SQL over
/// `wallet_rewards`). The SQL ranker can't express time bounds, caps, point
/// valuations, or FX; this can.
///
/// Resolution order (highest priority first), matching the design spec:
///   1. promo (date-bounded; `rate == 0` intro-APR offers are skipped)
///   2. rotating (matching quarter; assumed activated — see the tier comment)
///   3. brand (exact brand_id)
///   4. category (permanent)
///   5. baseline (the floor; always applies last)
///
/// `partner_portal` and unknown kinds are intentionally NOT in the order:
/// a portal rate ("5x via Chase Travel") isn't earned on an ordinary swipe,
/// so those rules never match here.
library;

import '../models/reward_category.dart';

/// Polymorphic discriminator for a [RewardRule], mirroring the catalog's
/// `reward_rules.kind` column.
enum RewardRuleKind {
  baseline,
  category,
  brand,
  rotating,
  promo,
  partnerPortal,
  unknown;

  static RewardRuleKind fromName(String? s) {
    switch (s) {
      case 'baseline':
        return RewardRuleKind.baseline;
      case 'category':
        return RewardRuleKind.category;
      case 'brand':
        return RewardRuleKind.brand;
      case 'rotating':
        return RewardRuleKind.rotating;
      case 'promo':
        return RewardRuleKind.promo;
      case 'partner_portal':
        return RewardRuleKind.partnerPortal;
      default:
        return RewardRuleKind.unknown;
    }
  }
}

/// A points/miles currency with its app-curated cents-per-point valuation.
/// `usd` is 1.0 — so a 5% cashback rule and a 5x-points rule become
/// comparable on a single `effectiveCentsPerDollar` axis.
class PointSystem {
  const PointSystem({
    required this.id,
    required this.displayName,
    required this.baselineCentValue,
  });

  final String id;
  final String displayName;
  final double baselineCentValue;

  /// Display currency bucket the UI renders ("USD" → "%", else "x points").
  String get currencyLabel {
    if (id == 'usd') return 'USD';
    if (id.contains('miles')) return 'MILES';
    return 'POINTS';
  }
}

/// One earn rule for a card product. A flattened catalog `reward_rules` row.
class RewardRule {
  const RewardRule({
    required this.ruleId,
    required this.productId,
    required this.kind,
    this.category,
    this.brand,
    required this.rate,
    required this.pointSystemId,
    this.validFrom,
    this.validTo,
    this.rotationYear,
    this.rotationQuarter,
    this.requiresActivation = false,
    this.capSpendAmountUsd,
    this.capPeriod,
    this.capGroup,
    this.notes,
    this.earnConstraint,
    this.excludedCategories = const [],
  });

  final String ruleId;
  final String productId;
  final RewardRuleKind kind;

  /// Parsed [RewardCategory] (null when the catalog `category` is null —
  /// baseline / brand-only / blanket promo). A non-null catalog string that
  /// isn't a known category resolves to [RewardCategory.other].
  final RewardCategory? category;
  final String? brand;
  final double rate;
  final String pointSystemId;
  final DateTime? validFrom;
  final DateTime? validTo;
  final int? rotationYear;
  final int? rotationQuarter;
  final bool requiresActivation;
  final double? capSpendAmountUsd;
  final String? capPeriod;
  final String? capGroup;
  final String? notes;

  /// Display caveat for a conditional earn that reaches only a subset of the
  /// card's eligible categories — a "top N spend categories" / choose-N mechanic
  /// (e.g. 2X on your top 3, not all six). Shown as inline subtext on the
  /// Rewards tab; null for an ordinary unconditional earn.
  final String? earnConstraint;

  /// Travel sub-categories this rule does NOT extend to, overriding the
  /// travel-superset match below. Issuer terms sometimes carve one out — Citi's
  /// Costco "travel" 3% earns only 1% on train/commuter transit — so a general
  /// `travel` rule listing `transit` here won't win a transit lookup. Curated in
  /// the catalog (`excluded_categories`); empty for the common case.
  final List<RewardCategory> excludedCategories;
}

/// A card product (the issuer's marketed card). Only the fields the engine
/// needs (FX fee) plus what the ranker surfaces.
class CardProduct {
  const CardProduct({
    required this.id,
    required this.issuer,
    required this.displayName,
    this.network,
    this.annualFeeUsd,
    this.foreignTxFeePct = 0.0,
    this.imageUrl,
    required this.catalogVersion,
    this.retiredAt,
    this.country,
    this.currency,
  });

  final String id;
  final String issuer;
  final String displayName;
  final String? network;
  final double? annualFeeUsd;
  final double foreignTxFeePct;
  final String? imageUrl;
  final String catalogVersion;
  final String? retiredAt;

  /// ISO country the product is sold in. NULL on catalogs published before
  /// Canada, where every card was American — read it as 'US'.
  final String? country;

  /// The card's own currency ('USD' | 'CAD'). NULL reads as 'USD'.
  ///
  /// Reward values are NOT converted between currencies: a CAD program is
  /// valued in CAD cents and compared numerically against USD cents. That is
  /// exact for a wallet held in one country, and the deliberate trade-off is a
  /// mixed US+CA wallet, where the cross-border comparison is off by the FX
  /// rate. Adding an FX rate would put a value that goes stale between
  /// catalog publishes in front of every ranking.
  final String? currency;
}

/// Immutable in-memory catalog the engine resolves against. Built once from
/// the four catalog tables by `CatalogRepository.loadSnapshot()` and cached
/// behind `catalogSnapshotProvider`; the engine itself never touches the DB.
class CatalogSnapshot {
  CatalogSnapshot({
    required this.products,
    required this.rulesByProduct,
    required this.exclusionsByRule,
    required this.pointSystems,
  });

  /// card_product_id → product.
  final Map<String, CardProduct> products;

  /// card_product_id → its rules.
  final Map<String, List<RewardRule>> rulesByProduct;

  /// rule_id → excluded brand_id slugs.
  final Map<String, Set<String>> exclusionsByRule;

  /// point_system_id → valuation.
  final Map<String, PointSystem> pointSystems;

  static final CatalogSnapshot empty = CatalogSnapshot(
    products: const {},
    rulesByProduct: const {},
    exclusionsByRule: const {},
    pointSystems: const {},
  );

  bool get isEmpty => products.isEmpty;

  double centValueOf(String pointSystemId) =>
      pointSystems[pointSystemId]?.baselineCentValue ?? 1.0;
}

/// Per-card rotating-bonus activation state, scoped to a single card the
/// ranker is currently resolving (the caller builds one from
/// `rotating_activations`). Holds the `(year, quarter)` pairs the user
/// enrolled in for that card.
class ActivationState {
  const ActivationState(this._activated);
  final Set<(int, int)> _activated;

  bool isActivated(int year, int quarter) =>
      _activated.contains((year, quarter));

  static const ActivationState none = ActivationState(<(int, int)>{});
}

/// Spend-so-far per cap group, for the current cap period. Empty means full
/// headroom (the recommendation path, where `amount == $1`, passes this).
class SpendLedger {
  const SpendLedger(this._spentByGroup);
  final Map<String, double> _spentByGroup;

  double spentInGroup(String capGroup) => _spentByGroup[capGroup] ?? 0.0;

  static const SpendLedger empty = SpendLedger(<String, double>{});
}

/// The engine's verdict for one (product, category, brand, when) query.
/// `effectiveCentsPerDollar` is the ONLY number ranking compares.
class AppliedRate {
  const AppliedRate({
    required this.rate,
    required this.pointSystemId,
    required this.effectiveCentsPerDollar,
    this.ruleId,
    this.reason,
    this.kind,
    this.capExhausted = false,
  });

  /// Raw multiplier as marketed (5.0 for 5% or 5x). What the UI shows.
  final double rate;
  final String pointSystemId;

  /// `rate × centValue` (− FX fee when foreign), blended across a cap.
  /// The cross-currency-comparable ranking key.
  final double effectiveCentsPerDollar;
  final String? ruleId;
  final String? reason;
  final RewardRuleKind? kind;
  final bool capExhausted;

  bool get hasRule => ruleId != null;

  /// "No applicable rule" — an unlinked card or a product with no baseline.
  static const AppliedRate none = AppliedRate(
    rate: 0,
    pointSystemId: 'usd',
    effectiveCentsPerDollar: 0,
    reason: 'no rule',
  );
}

int quarterOf(DateTime when) => ((when.month - 1) ~/ 3) + 1;

/// Resolves the best applicable rate for a purchase. Pure.
///
/// For the **recommendation** path (best card *before* a purchase) call with
/// `amount: 1.0` and an empty [SpendLedger]: caps collapse to the plain rate
/// when there's headroom, to baseline when there isn't.
AppliedRate resolve({
  required CatalogSnapshot snapshot,
  required String product,
  required RewardCategory category,
  String? brand,
  required DateTime when,
  ActivationState activations = ActivationState.none,
  SpendLedger spend = SpendLedger.empty,
  double amount = 1.0,
  bool isForeign = false,
}) {
  final rules = snapshot.rulesByProduct[product] ?? const <RewardRule>[];
  if (rules.isEmpty) return AppliedRate.none;

  final cardProduct = snapshot.products[product];
  final quarter = quarterOf(when);
  // FX fee in cents-per-dollar terms (foreign_tx_fee_pct is already a percent).
  final ftfCents = isForeign ? (cardProduct?.foreignTxFeePct ?? 0.0) : 0.0;

  bool dateValid(RewardRule r) =>
      (r.validFrom == null || !when.isBefore(r.validFrom!)) &&
      (r.validTo == null || !when.isAfter(r.validTo!));

  // The baseline rule — the floor, the overflow rate for capped rules, and
  // the final fallback.
  RewardRule? baseline;
  for (final r in rules) {
    if (r.kind == RewardRuleKind.baseline && dateValid(r)) {
      baseline = r;
      break;
    }
  }

  double centValueOf(String id) => snapshot.centValueOf(id);

  // A rule earns in this `category` if it names the category directly, OR it's
  // a general `travel` rule and `category` is a travel sub-category (hotels /
  // airlines / car rentals / transit). `travel` is the issuer-defined superset
  // of those, so e.g. a "3x travel" card competes at a hotel — the richest-rate
  // sort below then picks the better of the specific and the general bonus.
  // A rule may carve a sub-category out of that superset (`excludedCategories`)
  // when the issuer's terms exclude it — Citi Costco's travel bonus is 1%, not
  // 3%, on transit — so the general rate doesn't leak onto it.
  bool categoryMatches(RewardRule r) =>
      r.category == category ||
      (category.isTravelSubcategory &&
          r.category == RewardCategory.travel &&
          !r.excludedCategories.contains(category)) ||
      (category.isGasSubcategory &&
          r.category == RewardCategory.gas &&
          !r.excludedCategories.contains(category)) ||
      (category.isEntertainmentSubcategory &&
          r.category == RewardCategory.entertainment &&
          !r.excludedCategories.contains(category));

  // Build the prioritized candidate list (baseline excluded — it's the
  // floor). Within a tier, try the richest rate first.
  final candidates = <RewardRule>[];
  void collectTier(bool Function(RewardRule) pred) {
    final tier = [
      for (final r in rules)
        if (pred(r)) r,
    ];
    tier.sort(
      (a, b) => (b.rate * centValueOf(b.pointSystemId)).compareTo(
        a.rate * centValueOf(a.pointSystemId),
      ),
    );
    candidates.addAll(tier);
  }

  // 1. promo — date-bounded; 0-rate intro-APR offers are not earn rules.
  collectTier(
    (r) =>
        r.kind == RewardRuleKind.promo &&
        r.rate > 0 &&
        dateValid(r) &&
        _promoMatches(r, category, brand),
  );
  // 2. rotating — current rotation window. We ASSUME the user has activated the
  // current quarter's bonus: there is no activation toggle in the app, so gating on
  // `activations` would permanently suppress every activation-required rotating rule
  // (the whole Freedom Flex / Discover it 5% program). The `activations` plumbing is
  // retained for a future opt-in toggle, but is intentionally not consulted here.
  collectTier(
    (r) =>
        r.kind == RewardRuleKind.rotating &&
        dateValid(r) &&
        r.rotationYear == when.year &&
        (r.rotationQuarter == null || r.rotationQuarter == quarter) &&
        categoryMatches(r) &&
        (r.brand == null || r.brand == brand),
  );
  // 3. brand — exact brand_id. A brand can carry rules in several categories (the
  // Costco card earns 5% on *gas* at Costco but only 2% on other Costco purchases).
  // Prefer the rule whose category matches THIS purchase, then fall back to the brand's
  // highest rate — so a single-category brand, and any brand earn that isn't pinned to
  // this category, still surfaces instead of being dropped to baseline.
  if (brand != null) {
    final brandTier = [
      for (final r in rules)
        if (r.kind == RewardRuleKind.brand && dateValid(r) && r.brand == brand)
          r,
    ];
    bool catScoped(RewardRule r) => r.category == null || categoryMatches(r);
    brandTier.sort((a, b) {
      final am = catScoped(a), bm = catScoped(b);
      if (am != bm) return am ? -1 : 1; // category-matching first
      return (b.rate * centValueOf(b.pointSystemId)).compareTo(
        a.rate * centValueOf(a.pointSystemId),
      );
    });
    candidates.addAll(brandTier);
  }
  // 4. category — permanent.
  collectTier(
    (r) =>
        r.kind == RewardRuleKind.category && dateValid(r) && categoryMatches(r),
  );

  for (final r in candidates) {
    final applied = _tryApply(
      rule: r,
      baseline: baseline,
      snapshot: snapshot,
      brand: brand,
      amount: amount,
      spend: spend,
      ftfCents: ftfCents,
      quarter: quarter,
    );
    if (applied != null) return applied;
  }

  // Floor: baseline always applies if present.
  if (baseline != null) {
    return AppliedRate(
      rate: baseline.rate,
      pointSystemId: baseline.pointSystemId,
      effectiveCentsPerDollar:
          baseline.rate * centValueOf(baseline.pointSystemId) - ftfCents,
      ruleId: baseline.ruleId,
      reason: 'baseline',
      kind: RewardRuleKind.baseline,
    );
  }
  return AppliedRate.none;
}

bool _promoMatches(RewardRule r, RewardCategory category, String? brand) {
  if (r.category != null) return r.category == category;
  if (r.brand != null) return r.brand == brand;
  return true; // blanket promo
}

/// Applies one chosen rule, returning null to signal "cascade to next
/// priority" (excluded brand, or cap exhausted).
AppliedRate? _tryApply({
  required RewardRule rule,
  required RewardRule? baseline,
  required CatalogSnapshot snapshot,
  required String? brand,
  required double amount,
  required SpendLedger spend,
  required double ftfCents,
  required int quarter,
}) {
  // Exclusion: this brand is carved out of the rule → cascade.
  if (brand != null &&
      (snapshot.exclusionsByRule[rule.ruleId]?.contains(brand) ?? false)) {
    return null;
  }

  final ruleCent = snapshot.centValueOf(rule.pointSystemId);

  if (rule.capSpendAmountUsd != null) {
    final group = rule.capGroup ?? rule.ruleId;
    final remaining = rule.capSpendAmountUsd! - spend.spentInGroup(group);
    if (remaining <= 0) return null; // cap exhausted → cascade

    final capped = amount <= remaining ? amount : remaining;
    final overflow = amount - capped;
    final baselineRate = baseline?.rate ?? 0.0;
    final baselineCent = baseline != null
        ? snapshot.centValueOf(baseline.pointSystemId)
        : 1.0;
    final cents =
        capped * rule.rate * ruleCent + overflow * baselineRate * baselineCent;
    final eff = (amount > 0 ? cents / amount : 0.0) - ftfCents;
    return AppliedRate(
      rate: rule.rate,
      pointSystemId: rule.pointSystemId,
      effectiveCentsPerDollar: eff,
      ruleId: rule.ruleId,
      reason: overflow > 0 ? 'cap reached — baseline after' : _reasonFor(rule),
      kind: rule.kind,
    );
  }

  return AppliedRate(
    rate: rule.rate,
    pointSystemId: rule.pointSystemId,
    effectiveCentsPerDollar: rule.rate * ruleCent - ftfCents,
    ruleId: rule.ruleId,
    reason: _reasonFor(rule),
    kind: rule.kind,
  );
}

String _reasonFor(RewardRule r) {
  switch (r.kind) {
    case RewardRuleKind.promo:
      return 'promo';
    case RewardRuleKind.rotating:
      final q = r.rotationQuarter;
      return q != null ? 'Q$q rotating' : 'rotating';
    case RewardRuleKind.brand:
      return 'brand bonus';
    case RewardRuleKind.category:
      return 'category';
    case RewardRuleKind.baseline:
      return 'baseline';
    case RewardRuleKind.partnerPortal:
      return 'travel portal';
    case RewardRuleKind.unknown:
      return '';
  }
}
