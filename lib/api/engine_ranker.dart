import '../models/insights.dart';
import '../models/reward_category.dart';
import 'catalog_repository.dart';
import 'reward_category_mapper.dart';
import 'reward_engine.dart';
import 'types.dart';

/// Turns the pure [resolve] engine into the same ranking outputs the UI
/// already consumes — [BestCardLookup], the catch-all [CardPick], and
/// [RewardRankingResult] — by looping it over the user's linked cards.
///
/// This is the engine-side analogue of `RewardRepository`'s three ranking
/// queries. Cards are ranked on `effectiveCentsPerDollar` (cross-currency
/// comparable) but each entry's displayed `rate` stays the raw multiplier.
/// Ties break the same way the SQL did: preference order, then name desc.
class EngineRanker {
  EngineRanker({
    required this.snapshot,
    required this.linkedCards,
    required this.when,
    this.activationsByCard = const {},
    this.spendByCard = const {},
    this.cardPreferenceOrder = const [],
    this.isForeign = false,
    this.selectedBonusCategories = const {},
  });

  final CatalogSnapshot snapshot;
  final List<LinkedCard> linkedCards;
  final DateTime when;
  final Map<String, Set<(int, int)>> activationsByCard;
  final Map<String, SpendLedger> spendByCard;
  final List<String> cardPreferenceOrder;

  /// group_id → the categories the user chose for that selectable-bonus group
  /// (`CatalogRepository.bonusSelections`). Absent group = not answered yet.
  final Map<String, Set<RewardCategory>> selectedBonusCategories;

  /// When true (the user is abroad — see `travelIsForeignProvider`), each card's
  /// value is docked its foreign-transaction fee, so no-FX-fee cards win. N7.
  final bool isForeign;

  /// The snapshot every ranking method resolves against: [snapshot] with the
  /// selectable-bonus rules the wallet can't actually earn today removed.
  ///
  /// Ranking answers "which card should I pull out", so a rate that is merely
  /// *available for selection* is not an answer — a Customized Cash was being
  /// recommended for EV charging at 6% to someone who had chosen home
  /// improvement and would have earned 1%. Dropping the rule here (rather than
  /// discounting it) makes every ranking path fall through to whatever the
  /// card really pays, usually its baseline, with no other change in
  /// behaviour.
  ///
  /// Deliberately NOT applied to the card's own rule list
  /// (`CatalogRepository.rewardsForCard`): the card does pay that rate on the
  /// chosen category, and hiding it from the card's detail page would be a
  /// different lie. Only the ranking narrows.
  late final CatalogSnapshot _ranked = _withUnavailableBonusesRemoved(snapshot);

  CatalogSnapshot _withUnavailableBonusesRemoved(CatalogSnapshot s) {
    var changed = false;
    final rules = <String, List<RewardRule>>{};
    for (final e in s.rulesByProduct.entries) {
      final kept = [
        for (final r in e.value)
          if (_isEarnable(s, r)) r,
      ];
      if (kept.length != e.value.length) changed = true;
      rules[e.key] = kept;
    }
    if (!changed) return s;
    return CatalogSnapshot(
      products: s.products,
      rulesByProduct: rules,
      exclusionsByRule: s.exclusionsByRule,
      pointSystems: s.pointSystems,
      selectionGroups: s.selectionGroups,
    );
  }

  /// Whether a rule can be credited to a *recommendation* right now.
  ///
  ///   • no selection group        → always (the overwhelming majority)
  ///   • `user_choice`, chosen     → yes, it is an ordinary category bonus
  ///   • `user_choice`, not chosen → no, including "not answered yet"
  ///   • `automatic`               → never: the issuer picks from spend the
  ///     app cannot see, so no answer is provable. The `earnConstraint`
  ///     caveat on the card's detail page is what tells the user about it.
  ///   • group missing from the catalog → no, same reasoning as `automatic`:
  ///     an unresolvable group is not an earnable one.
  bool _isEarnable(CatalogSnapshot s, RewardRule r) {
    final groupId = r.selectionGroup;
    if (groupId == null) return true;
    final group = s.selectionGroups[groupId];
    if (group == null || group.mode != BonusSelectionMode.userChoice) {
      return false;
    }
    final category = r.category;
    if (category == null) return false;
    return selectedBonusCategories[groupId]?.contains(category) ?? false;
  }

  ActivationState _activations(String cardId) =>
      ActivationState(activationsByCard[cardId] ?? const <(int, int)>{});

  SpendLedger _spend(String cardId) => spendByCard[cardId] ?? SpendLedger.empty;

  AppliedRate _resolve(LinkedCard c, RewardCategory category, String? brand) =>
      resolve(
        snapshot: _ranked,
        product: c.cardProductId,
        category: category,
        brand: brand,
        when: when,
        activations: _activations(c.cardId),
        spend: _spend(c.cardId),
        isForeign: isForeign,
      );

  /// The country whose store rules apply: the one most of the wallet's cards
  /// are from (a product with no country is American). Costco takes Visa in
  /// the US and Mastercard in Canada, and the wallet is the best signal we have
  /// for which Costco the user walks into.
  late final String _walletCountry = () {
    var ca = 0;
    for (final c in linkedCards) {
      if (_ranked.products[c.cardProductId]?.country == 'CA') ca++;
    }
    return ca * 2 > linkedCards.length ? 'CA' : 'US';
  }();

  /// Why [brand]'s stores won't take card [c] ("Costco takes Visa only"), or
  /// null when they will. An uncurated store or a card whose network is
  /// unknown never rules a card out.
  String? _notAcceptedReason(LinkedCard c, String? brand) {
    if (brand == null) return null;
    final accepted = brandAcceptedNetworks(brand, _walletCountry);
    if (accepted == null || accepted.isEmpty) return null;
    final network = normalizeCardNetwork(
      _ranked.products[c.cardProductId]?.network,
    );
    if (network == null || accepted.contains(network)) return null;
    final store = brandDisplayNameFor(brand) ?? brand;
    return accepted.length == 1
        ? '$store takes ${_networkLabel(accepted.single)} only'
        : "$store doesn't take ${_networkLabel(network)}";
  }

  static String _networkLabel(String network) => switch (network) {
    'visa' => 'Visa',
    'mastercard' => 'Mastercard',
    'amex' => 'Amex',
    'discover' => 'Discover',
    _ => network,
  };

  /// Whether [a] is a store's own rate (a brand rule, or a rotating rule pinned
  /// to a brand) rather than the card's category rate.
  bool _isBrandEarn(LinkedCard c, AppliedRate a) {
    if (a.kind == RewardRuleKind.brand) return true;
    if (a.kind != RewardRuleKind.rotating) return false;
    for (final r
        in _ranked.rulesByProduct[c.cardProductId] ?? const <RewardRule>[]) {
      if (r.ruleId == a.ruleId) return r.brand != null;
    }
    return false;
  }

  int _prefRank(String cardId) {
    final i = cardPreferenceOrder.indexOf(cardId);
    return i < 0 ? cardPreferenceOrder.length : i;
  }

  /// Whether this card's foreign-transaction fee was ever captured.
  ///
  /// Only consulted abroad. Unknown is never charged a fee it might not have,
  /// so an unknown card ties with a known-0% one on effective rate — and
  /// without a tie-break the winner would come down to alphabetical order.
  bool _fxFeeKnown(String cardId) =>
      _ranked.products[cardId]?.foreignTxFeePct != null;

  /// Tie-break: effective desc → **known FX fee (abroad only)** → preference
  /// asc → name desc → id asc.
  int _compare(_Scored a, _Scored b) {
    final byEff = b.applied.effectiveCentsPerDollar.compareTo(
      a.applied.effectiveCentsPerDollar,
    );
    if (byEff != 0) return byEff;
    // Abroad, prefer the card we know charges nothing over one we simply never
    // captured. A tie-break, not a penalty: we never invent a fee, we just stop
    // an unevidenced card outranking an evidenced one on a coin flip.
    if (isForeign) {
      final ka = _fxFeeKnown(a.card.cardProductId);
      final kb = _fxFeeKnown(b.card.cardProductId);
      if (ka != kb) return ka ? -1 : 1;
    }
    final pa = _prefRank(a.card.cardId), pb = _prefRank(b.card.cardId);
    if (pa != pb) return pa.compareTo(pb);
    final byName = b.card.cardName.toLowerCase().compareTo(
      a.card.cardName.toLowerCase(),
    );
    if (byName != 0) return byName;
    return a.card.cardId.compareTo(b.card.cardId);
  }

  // ─────────────── Best card per category / brand ───────────────

  BestCardLookup bestCardByCategory() {
    // Categories worth a tile: any with a non-baseline rule across the linked
    // cards, plus the catch-all 'other' (resolved from baseline). Mirrors the
    // SQL `categories` CTE.
    final candidateCategories = <RewardCategory>{RewardCategory.other};
    final brandToCategory = <String, RewardCategory>{};
    for (final c in linkedCards) {
      for (final r
          in _ranked.rulesByProduct[c.cardProductId] ?? const <RewardRule>[]) {
        if (r.kind == RewardRuleKind.category ||
            r.kind == RewardRuleKind.rotating) {
          if (r.category != null) candidateCategories.add(r.category!);
        }
        if (r.brand != null) {
          brandToCategory.putIfAbsent(
            r.brand!,
            () => r.category ?? RewardCategory.other,
          );
        }
      }
    }

    final byCategory = <RewardCategory, BestCardEntry>{};
    for (final cat in candidateCategories) {
      final best = _pickBest((c) => _resolve(c, cat, null));
      if (best == null) continue;
      byCategory[cat] = BestCardEntry(
        id: best.card.cardId,
        name: best.card.cardName,
        rate: best.applied.rate,
        category: cat,
        brand: null,
        currency: _currencyOf(best.applied.pointSystemId),
      );
    }

    // Superset sub-categories that no reward rule names directly (a movie
    // theater earns only via a card's broader `entertainment` bonus, which a
    // rule may exclude — Freedom Flex's rotating live-entertainment 5% does).
    // Compute their best card through the same exclusion-aware engine so the
    // nearby flow and Categories grid agree with per-transaction ranking.
    // Skip when nothing earns above baseline — no bonus means no tile, just
    // the catch-all.
    for (final cat in const [
      RewardCategory.movieTheaters,
      RewardCategory.coffee,
    ]) {
      if (byCategory.containsKey(cat)) continue;
      final best = _pickBest((c) => _resolve(c, cat, null));
      if (best == null || best.applied.kind == RewardRuleKind.baseline) {
        continue;
      }
      byCategory[cat] = BestCardEntry(
        id: best.card.cardId,
        name: best.card.cardName,
        rate: best.applied.rate,
        category: cat,
        brand: null,
        currency: _currencyOf(best.applied.pointSystemId),
      );
    }

    final byBrand = <String, BestCardEntry>{};
    for (final entry in brandToCategory.entries) {
      final brand = entry.key;
      final best = _pickBest((c) => _resolve(c, entry.value, brand));
      // Only surface a brand bonus when the winning rule is actually a brand
      // (or rotating-brand) hit — not a baseline fallback.
      if (best == null ||
          (best.applied.kind != RewardRuleKind.brand &&
              best.applied.kind != RewardRuleKind.rotating)) {
        continue;
      }
      byBrand[brand] = BestCardEntry(
        id: best.card.cardId,
        name: best.card.cardName,
        rate: best.applied.rate,
        category: entry.value,
        brand: brand,
        currency: _currencyOf(best.applied.pointSystemId),
      );
    }

    // A store that only takes some networks gets its best card from the ones
    // it takes, so the Stores list and arrival notifications never name a card
    // the till will refuse. Done for every curated store, not only ones with a
    // brand bonus: the plain category winner may be the refused card.
    for (final b in registeredBrands()) {
      if (brandAcceptedNetworks(b.brandId, _walletCountry) == null) continue;
      final best = _pickBest(
        (c) => _resolve(c, b.category, b.brandId),
        where: (c) => _notAcceptedReason(c, b.brandId) == null,
      );
      if (best == null) {
        byBrand.remove(b.brandId);
        continue;
      }
      byBrand[b.brandId] = BestCardEntry(
        id: best.card.cardId,
        name: best.card.cardName,
        rate: best.applied.rate,
        category: b.category,
        // Only a real store bonus names the brand — the Stores list reads it
        // as "· Costco bonus", which an everyday rate isn't.
        brand: _isBrandEarn(best.card, best.applied) ? b.brandId : null,
        currency: _currencyOf(best.applied.pointSystemId),
      );
    }

    return BestCardLookup(byCategory: byCategory, byBrand: byBrand);
  }

  /// Best card for EVERY category — the Advisor "Categories" grid.
  ///
  /// Deliberately not [bestCardByCategory], which only answers for categories
  /// some linked card names in a rule. That is right for the nearby flow (no
  /// bonus, no tile) but wrong for a browsable grid: a category vanishing
  /// entirely reads as "SwipeWise doesn't know about groceries", when the truth
  /// is "none of your cards pay extra there, and this one is your best
  /// everyday rate". Same shape as [bestCardByBrand] — resolve through the
  /// exclusion-aware engine, keep the baseline tail, and flag it with
  /// [CategoryPick.isBonus] so the UI can say which it is.
  ///
  /// When NO linked card has an applicable rule the category still gets a
  /// pick, at **rate 0 with no card named**. That is not an invented rate: 118
  /// of the catalog's 410 products carry no earn rule at all (secured,
  /// balance-transfer, credit-builder, store cards), and 0% is what they pay.
  /// The card is left null because there is no winner to name — every card
  /// ties at nothing.
  List<CategoryPick> bestCardByCategoryAll() {
    final out = <CategoryPick>[];
    for (final cat in RewardCategory.values) {
      final best = _pickBest((c) => _resolve(c, cat, null));
      out.add(
        CategoryPick(
          category: cat,
          cardId: best?.card.cardId,
          cardName: best?.card.cardName,
          rate: best?.applied.rate ?? 0,
          isBonus: best != null && best.applied.kind != RewardRuleKind.baseline,
          currency: best == null
              ? 'USD'
              : _currencyOf(best.applied.pointSystemId),
        ),
      );
    }
    return out;
  }

  /// Best card for every registered brand — the Advisor "Brands" tab. Iterates
  /// the FULL brand registry (not just brands named in reward rules) and
  /// resolves each against the wallet (brand bonus → category → baseline). A
  /// brand is dropped only when no linked card has any applicable rule (the
  /// no-baseline store-card edge case → `AppliedRate.none`). Sorted wins-first:
  /// bonus before baseline-tail, then richest effective rate, then name — so
  /// merchant-specific deals surface above the flat-rate long tail.
  List<BrandPick> bestCardByBrand() {
    final scored = <({BrandPick pick, double eff})>[];
    for (final brand in registeredBrands()) {
      final cat = brandDefaultCategory(brand.brandId);
      final best = _pickBest(
        (c) => _resolve(c, cat, brand.brandId),
        where: (c) => _notAcceptedReason(c, brand.brandId) == null,
      );
      if (best == null) continue;
      scored.add((
        pick: BrandPick(
          brandId: brand.brandId,
          displayName: brand.displayName,
          cardId: best.card.cardId,
          cardName: best.card.cardName,
          rate: best.applied.rate,
          currency: _currencyOf(best.applied.pointSystemId),
          category: cat,
          isBonus: best.applied.kind != RewardRuleKind.baseline,
        ),
        eff: best.applied.effectiveCentsPerDollar,
      ));
    }
    scored.sort((a, b) {
      if (a.pick.isBonus != b.pick.isBonus) return a.pick.isBonus ? -1 : 1;
      final byEff = b.eff.compareTo(a.eff);
      if (byEff != 0) return byEff;
      return a.pick.displayName.toLowerCase().compareTo(
        b.pick.displayName.toLowerCase(),
      );
    });
    return [for (final s in scored) s.pick];
  }

  /// Count of distinct brand bonuses per category across the linked cards —
  /// the "N brand bonuses" caption on the Advisor category tiles. Deduped per
  /// (card, brand, category) the same way the old SQL count was.
  Map<RewardCategory, int> brandBonusCountsByCategory() {
    final counts = <RewardCategory, int>{};
    final seen = <String>{};
    for (final c in linkedCards) {
      for (final r
          in _ranked.rulesByProduct[c.cardProductId] ?? const <RewardRule>[]) {
        if (r.brand == null) continue;
        if (r.kind != RewardRuleKind.brand &&
            r.kind != RewardRuleKind.rotating) {
          continue;
        }
        final cat = r.category ?? RewardCategory.other;
        if (!seen.add('${c.cardId}|${r.brand}|${cat.name}')) continue;
        counts[cat] = (counts[cat] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Best catch-all card — the highest baseline rate. Computed directly off
  /// the baseline rule (not `resolve(other)`, which a rotating-'other' rule
  /// could otherwise inflate).
  CardPick? bestCatchAllCard() {
    _Scored? best;
    for (final c in linkedCards) {
      final baseline = _baselineOf(c.cardProductId);
      if (baseline == null) continue;
      // Abroad, the FX fee comes off the everyday rate too, the same way
      // `resolve` docks every other rule (unknown fee: nothing).
      final fee = isForeign
          ? (_ranked.products[c.cardProductId]?.foreignTxFeePct ?? 0.0)
          : 0.0;
      final eff =
          baseline.rate * _ranked.centValueOf(baseline.pointSystemId) - fee;
      final scored = _Scored(
        c,
        AppliedRate(
          rate: baseline.rate,
          pointSystemId: baseline.pointSystemId,
          effectiveCentsPerDollar: eff,
          ruleId: baseline.ruleId,
          kind: RewardRuleKind.baseline,
        ),
      );
      if (best == null || _compare(scored, best) < 0) best = scored;
    }
    if (best == null) return null;
    return CardPick(
      id: best.card.cardId,
      name: best.card.cardName,
      rate: best.applied.rate,
      currency: _currencyOf(best.applied.pointSystemId),
    );
  }

  // ─────────────── Reward ranking sheet ───────────────

  RewardRankingResult rewardRanking(
    RewardCategory category, {
    String? brandFilter,
  }) {
    // At a store (brandFilter set) each card is resolved WITH the brand, so its
    // row carries what it earns there: the store's own bonus when it has one,
    // its category rate otherwise. One list, each card once — a separate
    // brand-bonus section on top used to win "Best" even when a category rate
    // below it paid more (Prime Visa 5% over Amex Gold 4x ≈ 8¢ at Whole Foods).
    final storeBrand = brandFilter;
    // General: every linked card that earns *something* in this category.
    final scored = <_Scored>[
      for (final c in linkedCards)
        if (_resolve(c, category, storeBrand) case final a when a.hasRule)
          _Scored(c, a),
    ];
    // Nothing in the wallet has a rule here — a wallet of no-rewards cards
    // (secured / balance-transfer / store), which is 118 of the catalog's 410
    // products. Listing them at 0 beats returning an empty sheet: "none of
    // your cards earn here" is the answer, and an empty list looks like a bug.
    // Guarded on `isEmpty` so a normal category is untouched — a card that
    // simply loses at dining must NOT start appearing as a 0% row.
    if (scored.isEmpty) {
      scored.addAll([
        for (final c in linkedCards) _Scored(c, AppliedRate.none),
      ]);
    }
    // Cards the store refuses go last, after every card it takes.
    final refused = <String, String>{
      for (final s in scored)
        s.card.cardId: ?_notAcceptedReason(s.card, storeBrand),
    };
    scored.sort((a, b) {
      final ra = refused.containsKey(a.card.cardId);
      final rb = refused.containsKey(b.card.cardId);
      if (ra != rb) return ra ? 1 : -1;
      return _compare(a, b);
    });
    final storeName = storeBrand == null
        ? null
        : brandDisplayNameFor(storeBrand);
    final general = <CategoryRewardRanking>[
      for (var i = 0; i < scored.length; i++)
        CategoryRewardRanking(
          cardId: scored[i].card.cardId,
          cardName: scored[i].card.cardName,
          lastFour: scored[i].card.lastFour,
          cardImage: scored[i].card.imageUrl,
          rate: scored[i].applied.rate,
          currency: _currencyOf(scored[i].applied.pointSystemId),
          // The transactions-based "earned recently" badge has no engine
          // equivalent yet — it moves out of SQL in the cutover sub-task.
          earnedRecently: 0,
          isBest: i == 0 && !refused.containsKey(scored[i].card.cardId),
          kind: RewardKind.of(scored[i].applied.pointSystemId),
          effectiveCentsPerDollar: scored[i].applied.effectiveCentsPerDollar,
          programName: _programNameOf(scored[i].applied.pointSystemId),
          issuerWording: _issuerWordingOf(scored[i].card, scored[i].applied),
          bonusBrand:
              storeName != null &&
                  _isBrandEarn(scored[i].card, scored[i].applied)
              ? storeName
              : null,
          notAcceptedReason: refused[scored[i].card.cardId],
        ),
    ];

    // At a store, other stores' bonuses don't belong on the sheet — they stay
    // on the Brands tab and the category sheet, where browsing them is the
    // point.
    if (storeBrand != null) {
      return RewardRankingResult(general: general, brandBonuses: const []);
    }

    // Brand bonuses (category sheet): one row per (card, brand) in this
    // category.
    final brandRows = <BrandBonusRow>[];
    final seen = <String>{};
    for (final c in linkedCards) {
      for (final r
          in _ranked.rulesByProduct[c.cardProductId] ?? const <RewardRule>[]) {
        final brand = r.brand;
        if (brand == null) continue;
        if (r.kind != RewardRuleKind.brand &&
            r.kind != RewardRuleKind.rotating) {
          continue;
        }
        if (r.category != category) continue;

        final key = '${c.cardId}|$brand';
        if (!seen.add(key)) continue;

        final applied = _resolve(c, r.category ?? category, brand);
        if (!applied.hasRule) continue;
        brandRows.add(
          BrandBonusRow(
            cardId: c.cardId,
            cardName: c.cardName,
            lastFour: c.lastFour,
            cardImage: c.imageUrl,
            brand: brandDisplayNameFor(brand) ?? brand,
            rate: applied.rate,
            currency: _currencyOf(applied.pointSystemId),
            isMatchedBrand: false,
            kind: RewardKind.of(applied.pointSystemId),
            effectiveCentsPerDollar: applied.effectiveCentsPerDollar,
            programName: _programNameOf(applied.pointSystemId),
            issuerWording: _issuerWordingOf(c, applied),
          ),
        );
      }
    }
    // Effective value, not raw rate: 7x Hilton is worth less than 4x Amex.
    brandRows.sort(
      (a, b) => b.effectiveCentsPerDollar.compareTo(a.effectiveCentsPerDollar),
    );

    return RewardRankingResult(general: general, brandBonuses: brandRows);
  }

  // ─────────────── helpers ───────────────

  _Scored? _pickBest(
    AppliedRate Function(LinkedCard) resolveFor, {
    bool Function(LinkedCard)? where,
  }) {
    _Scored? best;
    for (final c in linkedCards) {
      if (where != null && !where(c)) continue;
      final applied = resolveFor(c);
      if (!applied.hasRule) continue;
      final scored = _Scored(c, applied);
      if (best == null || _compare(scored, best) < 0) best = scored;
    }
    return best;
  }

  RewardRule? _baselineOf(String productId) {
    for (final r in _ranked.rulesByProduct[productId] ?? const <RewardRule>[]) {
      if (r.kind == RewardRuleKind.baseline) return r;
    }
    return null;
  }

  String _currencyOf(String pointSystemId) =>
      _ranked.pointSystems[pointSystemId]?.currencyLabel ?? 'USD';

  String? _programNameOf(String pointSystemId) =>
      _ranked.pointSystems[pointSystemId]?.displayName;

  /// The issuer's own wording for an `other` reward — the applied rule's
  /// `notes`. Null for cash/points, where the rate says it all.
  String? _issuerWordingOf(LinkedCard c, AppliedRate applied) {
    if (RewardKind.of(applied.pointSystemId) != RewardKind.other) return null;
    for (final r
        in _ranked.rulesByProduct[c.cardProductId] ?? const <RewardRule>[]) {
      if (r.ruleId == applied.ruleId) return r.notes;
    }
    return null;
  }
}

class _Scored {
  _Scored(this.card, this.applied);
  final LinkedCard card;
  final AppliedRate applied;
}
