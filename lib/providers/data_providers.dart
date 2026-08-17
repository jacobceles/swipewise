import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';
import '../models/transaction.dart';
import '../models/card.dart';
import '../models/insights.dart';
import '../models/reward_category.dart';
import '../api/card_link_service.dart';
import '../api/catalog_loader.dart';
import '../api/catalog_repository.dart';
import '../api/data_repository.dart';
import '../api/engine_ranker.dart';
import '../api/reward_category_mapper.dart';
import '../api/reward_engine.dart';
import '../api/settings_repository.dart';
import '../api/travel.dart';
import '../api/types.dart';
import '../nearby/location_service.dart';

final dataRepositoryProvider = Provider((ref) => DataRepository());

/// Filter passed to `pagedTransactionsProvider.family`. Implemented as a
/// concrete class with `==`/`hashCode` based on element-equal lists so
/// two filters built from the same inputs in different widget rebuilds
/// compare equal — the prior record-of-`List<String>?` shape compared
/// the lists by identity and produced a fresh provider instance (and a
/// page-1 reset) every time the consuming widget rebuilt.
class TxFilter {
  TxFilter({
    this.q = '',
    List<String>? cardNames,
    List<String>? categories,
    this.startDate,
    this.endDate,
    this.spendOnly = false,
    this.merchantExact,
  }) : cardNames = cardNames == null
           ? null
           : List<String>.unmodifiable(_sortedCopy(cardNames)),
       categories = categories == null
           ? null
           : List<String>.unmodifiable(_sortedCopy(categories));

  final String q;
  final List<String>? cardNames;
  final List<String>? categories;
  final DateTime? startDate;
  final DateTime? endDate;

  /// When true, restrict to debits (spend). Used by the spend
  /// drilldown so its list matches the spend-only category totals;
  /// the main history leaves it false to show all activity.
  final bool spendOnly;

  /// Exact merchant name for the merchant-detail drilldown. When set, the
  /// query matches `merchant = ?` (falling back to `name`) instead of the
  /// fuzzy `q` LIKE, so the history agrees with the merchant's stat tiles.
  final String? merchantExact;

  static List<String> _sortedCopy(List<String> xs) {
    final out = List<String>.of(xs);
    out.sort();
    return out;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TxFilter) return false;
    return q == other.q &&
        startDate == other.startDate &&
        endDate == other.endDate &&
        spendOnly == other.spendOnly &&
        merchantExact == other.merchantExact &&
        _listEq(cardNames, other.cardNames) &&
        _listEq(categories, other.categories);
  }

  @override
  int get hashCode => Object.hash(
    q,
    startDate,
    endDate,
    spendOnly,
    merchantExact,
    cardNames == null ? null : Object.hashAll(cardNames!),
    categories == null ? null : Object.hashAll(categories!),
  );

  static bool _listEq(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class PagedTxState {
  final List<Transaction> items;
  final int page;
  final int pages;
  final int total;
  final bool loadingMore;

  const PagedTxState({
    required this.items,
    required this.page,
    required this.pages,
    required this.total,
    required this.loadingMore,
  });

  bool get hasMore => page < pages;

  PagedTxState copyWith({
    List<Transaction>? items,
    int? page,
    int? pages,
    int? total,
    bool? loadingMore,
  }) => PagedTxState(
    items: items ?? this.items,
    page: page ?? this.page,
    pages: pages ?? this.pages,
    total: total ?? this.total,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

class PagedTxNotifier extends AsyncNotifier<PagedTxState> {
  PagedTxNotifier(this.filter);
  final TxFilter filter;
  static const _pageSize = 30;

  Future<TransactionResponse> _fetch(int page) async {
    final auth = ref.read(authProvider);
    if (!auth.isLoggedIn) throw Exception('Not logged in');
    final repo = ref.read(dataRepositoryProvider);
    return repo.queryTransactions(
      auth.userId!,
      q: filter.q,
      page: page,
      pageSize: _pageSize,
      cardNames: filter.cardNames,
      categories: filter.categories,
      startDate: filter.startDate,
      endDate: filter.endDate,
      spendOnly: filter.spendOnly,
      merchantExact: filter.merchantExact,
    );
  }

  @override
  Future<PagedTxState> build() async {
    final res = await _fetch(1);
    return PagedTxState(
      items: res.transactions,
      page: res.page,
      pages: res.pages,
      total: res.total,
      loadingMore: false,
    );
  }

  Future<void> loadMore() async {
    final s = state.value;
    if (s == null || s.loadingMore || !s.hasMore) return;
    // Flip `loadingMore` BEFORE the first await so two scroll callbacks
    // arriving in the same frame can't both pass the guard above.
    final marked = s.copyWith(loadingMore: true);
    state = AsyncData(marked);
    try {
      final res = await _fetch(s.page + 1);
      state = AsyncData(
        PagedTxState(
          items: [...s.items, ...res.transactions],
          page: res.page,
          pages: res.pages,
          total: res.total,
          loadingMore: false,
        ),
      );
    } catch (_) {
      state = AsyncData(s.copyWith(loadingMore: false));
      rethrow;
    }
  }
}

final pagedTransactionsProvider =
    AsyncNotifierProvider.family<PagedTxNotifier, PagedTxState, TxFilter>(
      PagedTxNotifier.new,
    );

final cardsProvider = FutureProvider<List<CardSummary>>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) throw Exception("Not logged in");

  final repo = ref.watch(dataRepositoryProvider);
  return await repo.queryAllCards(auth.userId!);
});

/// Sophtron connection rows keyed by stable `institution_id`. The Cards
/// screen groups its bank sections by `institution_id` too, so the
/// lookup is unambiguous - no more smart-case fuzzy matching against
/// `institution_name`, no broken-state mismatches for multi-word banks.
///
/// Map value contains all columns of `bank_connections` - most
/// importantly `last_sync_status` ('ok' | 'failed' | null) and
/// `institution_logo` (link-time URL preferred over the v1 lookup).
final bankConnectionsByInstitutionIdProvider =
    FutureProvider<Map<String, BankConnectionRow>>((ref) async {
      final auth = ref.watch(sessionProvider);
      if (!auth.isLoggedIn) return const {};
      final repo = ref.watch(dataRepositoryProvider);
      final rows = await repo.queryBankConnections(auth.userId!);
      return {
        for (final r in rows)
          if (r.institutionId != null) r.institutionId!: r,
      };
    });

final monthlyTrendProvider =
    FutureProvider.family<
      List<({String month, double total})>,
      ({List<String> cardIds, DateTime? startDate, DateTime? endDate})
    >((ref, arg) async {
      final auth = ref.watch(sessionProvider);
      if (!auth.isLoggedIn) throw Exception("Not logged in");
      final repo = ref.watch(dataRepositoryProvider);
      return await repo.queryMonthlyTrend(
        auth.userId!,
        cardIds: arg.cardIds,
        startDate: arg.startDate,
        endDate: arg.endDate,
      );
    });

// sync: opt-out — icon taxonomy, doesn't change per-user on sync.
final categoryIconMapProvider = FutureProvider<Map<String, String?>>((
  ref,
) async {
  final repo = ref.watch(dataRepositoryProvider);
  return await repo.categoryIconMap();
});

final categoriesProvider = FutureProvider<List<String>>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) throw Exception("Not logged in");
  final repo = ref.watch(dataRepositoryProvider);
  return await repo.distinctCategories(auth.userId!);
});

final lastSyncProvider = FutureProvider<DateTime?>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return null;
  final repo = ref.watch(dataRepositoryProvider);
  return SettingsRepository(repo).getLastSyncAt(auth.userId!);
});

/// Oldest stored transaction date — floors the date pickers, since there is no
/// on-demand remote backfill (the local DB is the entire showable range).
final earliestTransactionDateProvider = FutureProvider<DateTime?>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return null;
  final repo = ref.watch(dataRepositoryProvider);
  return repo.getEarliestTransactionDate(auth.userId!);
});

/// Issuers the user can pick from when building a wallet by hand.
///
/// Not session-scoped — the catalog is global, and this list is the *entry*
/// to owning a card rather than something derived from what is owned. It does
/// wait on `catalogReadyProvider`, because on a first launch the tables are
/// still being filled and an unguarded read returns an empty picker.
// sync: opt-out — derived from the global catalog tables, not user sync data;
// a bank sync cannot add or remove an issuer.
final catalogIssuersProvider = FutureProvider<List<CatalogIssuer>>((ref) async {
  final repo = ref.watch(dataRepositoryProvider);
  await ref.watch(catalogReadyProvider.future);
  // Watched, not read: changing the country in Profile has to rebuild the
  // picker, and this provider is what the picker renders from.
  final country = ref.watch(catalogCountryProvider);
  return repo.catalog.issuers(country: country);
});

/// How many cards the wallet already holds per issuer. Watched by the issuer
/// picker so the counts update the moment the user comes back from adding
/// some — `cardsProvider` is invalidated on every add, which re-runs this.
///
/// Listed in the sync-invalidation registry at the foot of this file as well:
/// a bank sync creates `card_links` for cards it matched to the catalog, so
/// the counts go stale without it. (Naming that list here in brackets would
/// break the coverage test — its parser takes the first textual occurrence of
/// the name as the list itself.)
final walletCountsByIssuerProvider = FutureProvider<Map<String, int>>((
  ref,
) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const {};
  ref.watch(cardsProvider);
  final repo = ref.watch(dataRepositoryProvider);
  await ref.watch(catalogReadyProvider.future);
  return repo.catalog.linkedCountsByIssuer(auth.userId!);
});

final cardPerksProvider = FutureProvider.family<List<CardPerk>, String>((
  ref,
  cardId,
) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const [];
  final repo = ref.watch(dataRepositoryProvider);
  await ref.watch(catalogReadyProvider.future);
  return repo.catalog.perksForCard(auth.userId!, cardId);
});

final cardRewardsByCardProvider =
    FutureProvider.family<List<WalletRewardRow>, String>((ref, cardId) async {
      final auth = ref.watch(sessionProvider);
      if (!auth.isLoggedIn) return const [];
      final repo = ref.watch(dataRepositoryProvider);
      await ref.watch(catalogReadyProvider.future);
      return repo.catalog.rewardsForCard(auth.userId!, cardId);
    });

final recurringPaymentsProvider = FutureProvider<RecurringPaymentsSummary>((
  ref,
) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) {
    return const RecurringPaymentsSummary(
      items: [],
      monthlyTotal: 0,
      paidThisMonth: 0,
    );
  }
  final repo = ref.watch(dataRepositoryProvider);
  return repo.queryRecurringPayments(auth.userId!);
});

/// A live "switch card" nudge for a recurring charge: the card it's billed to
/// earns less than a card the user owns, for the charge's category. Never
/// persisted — recomputed each build so it self-updates as cards / spend change.
class RecurringSwitchTip {
  const RecurringSwitchTip({required this.cardName, required this.deltaLabel});
  final String cardName;
  final String deltaLabel;
}

/// Best-card nudges keyed by recurring-payment id. A payment appears only when
/// a card the user owns earns strictly more than the card it's charged to.
/// The dismissed set is applied by the UI, not here — this is the live signal.
// sync: opt-out — cascades via recurringPaymentsProvider + engineRankerProvider (both listed).
final recurringSwitchTipsProvider =
    FutureProvider<Map<String, RecurringSwitchTip>>((ref) async {
      final summary = await ref.watch(recurringPaymentsProvider.future);
      final ranker = await ref.watch(engineRankerProvider.future);
      if (ranker == null) return const {};
      final tips = <String, RecurringSwitchTip>{};
      for (final p in summary.items) {
        final charged = p.chargedCardId;
        if (charged == null) continue;
        // Resolve the charge to a category via the same classifier the sync /
        // advisor use: merchant first (may also name a brand's category), then
        // the transaction category label as a fallback.
        var category = classifyLabel(p.merchant ?? '').category;
        if (category == RewardCategory.other && p.category != null) {
          category = classifyLooseLabel(p.category!);
        }
        final ranking = ranker.rewardRanking(category).general;
        if (ranking.isEmpty) continue;
        final best = ranking.first;
        if (best.cardId == charged) continue;
        CategoryRewardRanking? chargedRow;
        for (final r in ranking) {
          if (r.cardId == charged) {
            chargedRow = r;
            break;
          }
        }
        if (chargedRow == null || best.currency != chargedRow.currency) {
          continue;
        }
        final delta = best.rate - chargedRow.rate;
        if (delta <= 0) continue;
        tips[p.id] = RecurringSwitchTip(
          cardName: best.cardName ?? 'another card',
          deltaLabel: _formatRateDelta(delta, best.currency),
        );
      }
      return tips;
    });

/// Formats a rate delta the way the reward-ranking sheet formats a rate:
/// `+2%` for cash, `+1x` for a points/miles multiplier.
String _formatRateDelta(double delta, String? currency) {
  final cur = (currency ?? '').toUpperCase();
  if (cur == 'POINTS' || cur == 'MILES') {
    final s = delta % 1 == 0
        ? delta.toInt().toString()
        : delta.toStringAsFixed(1);
    return '+${s}x';
  }
  return '+${delta.toStringAsFixed(delta % 1 == 0 ? 0 : 1)}%';
}

/// Recurring-payment ids the user dismissed the switch nudge for, persisted via
/// [SettingsRepository]. `dismiss` writes through and updates state so the row
/// hides immediately.
class DismissedRecurringTipsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final auth = ref.watch(sessionProvider);
    if (auth.isLoggedIn) {
      Future.microtask(() async {
        final repo = ref.read(dataRepositoryProvider);
        final loaded = await SettingsRepository(
          repo,
        ).getDismissedRecurringTips(auth.userId!);
        if (state.length != loaded.length || !state.containsAll(loaded)) {
          state = loaded;
        }
      });
    }
    return const {};
  }

  Future<void> dismiss(String paymentId) async {
    final auth = ref.read(sessionProvider);
    if (!auth.isLoggedIn) return;
    final next = {...state, paymentId};
    state = next;
    await SettingsRepository(
      ref.read(dataRepositoryProvider),
    ).setDismissedRecurringTips(auth.userId!, next);
  }
}

// sync: opt-out — user-set dismissals (a settings KV), not sync data.
final dismissedRecurringTipsProvider =
    NotifierProvider<DismissedRecurringTipsNotifier, Set<String>>(
      DismissedRecurringTipsNotifier.new,
    );

final merchantSummaryProvider =
    FutureProvider.family<
      MerchantSummary?,
      ({String merchant, DateTime? startDate, DateTime? endDate})
    >((ref, arg) async {
      final auth = ref.watch(sessionProvider);
      if (!auth.isLoggedIn) return null;
      final repo = ref.watch(dataRepositoryProvider);
      return repo.queryMerchantSummary(
        auth.userId!,
        arg.merchant,
        startDate: arg.startDate,
        endDate: arg.endDate,
      );
    });

final categoryDrilldownProvider =
    FutureProvider.family<
      CategoryDrilldown,
      ({String category, DateTime? startDate, DateTime? endDate})
    >((ref, arg) async {
      final auth = ref.watch(sessionProvider);
      if (!auth.isLoggedIn) throw Exception('Not logged in');
      final repo = ref.watch(dataRepositoryProvider);
      return repo.queryCategoryDrilldown(
        auth.userId!,
        arg.category,
        startDate: arg.startDate,
        endDate: arg.endDate,
      );
    });

final cardCurrencyMapProvider = FutureProvider<Map<String, String>>((
  ref,
) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const {};
  final repo = ref.watch(dataRepositoryProvider);
  await ref.watch(catalogReadyProvider.future);
  return repo.catalog.cardCurrencyMap(auth.userId!);
});

// ─────────────── Catalog RewardEngine (Track B) ───────────────
//
// These feed the pure engine. `catalogReadyProvider` hydrates the bundled
// catalog once at boot; `catalogSnapshotProvider` reads it into the immutable
// engine input; `cardLinksProvider` is the user's card→product bindings; and
// `engineRankerProvider` assembles a ready-to-rank EngineRanker. The ranking
// providers below are fully driven by the catalog RewardEngine.

// sync: opt-out — global catalog, hydrated at boot; changes only on a bundle
// dataVersion bump, never on a bank sync.
final catalogReadyProvider = FutureProvider<CatalogLoadResult>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return CatalogLoadResult.upToDate;
  final result = await CatalogLoader().hydrateIfNeeded(auth.userId!);
  // Bind the user's existing cards now so the engine has data on app open,
  // not only after the next sync. Idempotent; never downgrades a confirmed link.
  await CardLinkService().seedLinks(auth.userId!);
  return result;
});

// sync: opt-out — derived from the global catalog tables, not user sync data;
// cascades off catalogReadyProvider when the bundle changes.
final catalogSnapshotProvider = FutureProvider<CatalogSnapshot>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return CatalogSnapshot.empty;
  await ref.watch(catalogReadyProvider.future);
  final repo = ref.watch(dataRepositoryProvider);
  return repo.catalog.loadSnapshot();
});

final cardLinksProvider = FutureProvider<List<LinkedCard>>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const [];
  final repo = ref.watch(dataRepositoryProvider);
  // Structural dep on the wallet: a sync that re-binds cards refreshes links.
  await ref.watch(cardsProvider.future);
  return repo.catalog.linkedCards(auth.userId!);
});

/// A fully-assembled [EngineRanker], or null when not logged in / the catalog
/// isn't hydrated / the user has no linked cards (nothing for the engine to
/// rank). Built from the snapshot, links, activations, and preference order.
/// Whether the user is currently abroad (country ≠ home) — flips the engine's
/// FX-fee-aware ranking (N7). Home = the dominant account currency's country
/// (device region as fallback); current = the reverse-geocoded last-known fix.
/// Any unknown → false, so we never wrongly assume "abroad". Best-effort and
/// bounded (the geocode is timed out); never throws.
final travelIsForeignProvider = FutureProvider<bool>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return false;
  final repo = ref.watch(dataRepositoryProvider);
  final home =
      homeCountryForCurrency(
        await repo.dominantAccountCurrency(auth.userId!),
      ) ??
      deviceLocaleCountry();
  if (home == null) return false;
  // Everything below is best-effort, and the catch is load-bearing rather
  // than defensive. `Geolocator.getLastKnownPosition` THROWS when location
  // permission is denied — and this provider gates `engineRankerProvider`,
  // which produces every recommendation in the app. Without the catch, a user
  // who declines location doesn't lose travel detection, they lose the whole
  // Advisor tab: the error propagates and the screen sits on a spinner
  // forever. Verified on-device 2026-08-09 by revoking the permission.
  try {
    final fix = await LocationService().lastKnown();
    if (fix == null) return false;
    final current = await countryForCoordinate(fix.lat, fix.lng);
    return isForeignTravel(home: home, current: current);
  } catch (_) {
    return false;
  }
});

final engineRankerProvider = FutureProvider<EngineRanker?>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return null;
  final repo = ref.watch(dataRepositoryProvider);
  final snapshot = await ref.watch(catalogSnapshotProvider.future);
  if (snapshot.isEmpty) return null;
  final links = await ref.watch(cardLinksProvider.future);
  if (links.isEmpty) return null;
  final activations = await repo.catalog.activations(auth.userId!);
  final prefOrder = await ref.watch(cardPreferenceOrderProvider.future);
  final isForeign = await ref.watch(travelIsForeignProvider.future);
  return EngineRanker(
    snapshot: snapshot,
    linkedCards: links,
    when: DateTime.now(),
    activationsByCard: activations,
    cardPreferenceOrder: prefOrder,
    isForeign: isForeign,
  );
});

/// The user's cards that charge no foreign-transaction fee — the "take these
/// abroad" list for foreign-travel mode (N7). A card whose product is missing
/// (or defaults its fee to 0) is treated the same as the engine treats it, so
/// this list stays consistent with the FX-aware ranking.
// sync: opt-out — cascades via cardLinksProvider + the global catalog snapshot.
final noForeignFeeCardsProvider = FutureProvider<List<LinkedCard>>((ref) async {
  final links = await ref.watch(cardLinksProvider.future);
  final snapshot = await ref.watch(catalogSnapshotProvider.future);
  return [
    for (final c in links)
      // `== 0`, not `?? 0 == 0`. `foreignTxFeePct` is null when the fee was
      // never captured, and `?? 0` used to fold that into "charges nothing" —
      // so this banner named cards as fee-free on no evidence, to a user
      // standing in another country deciding which card to hand over. Null is
      // now excluded: the banner claims only what the catalog actually knows.
      if (snapshot.products[c.cardProductId]?.foreignTxFeePct == 0) c,
  ];
});

/// A rotating-bonus card whose categories are live this quarter and require
/// activation (Track B / B6). The engine already demotes an unactivated card
/// to its baseline; this surfaces the set so the UI can offer the toggle.
class RotatingCardStatus {
  const RotatingCardStatus({
    required this.cardId,
    required this.cardName,
    required this.cardProductId,
    required this.year,
    required this.quarter,
    required this.categories,
    required this.activated,
  });

  final String cardId;
  final String cardName;
  final String cardProductId;
  final int year;
  final int quarter;
  final List<RewardCategory> categories;
  final bool activated;
}

// sync: opt-out — derived from card_links + the global catalog; cascades via
// cardLinksProvider rather than reading a sync-replaced table directly.
final rotatingCardsProvider = FutureProvider<List<RotatingCardStatus>>((
  ref,
) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const [];
  final repo = ref.watch(dataRepositoryProvider);
  final snapshot = await ref.watch(catalogSnapshotProvider.future);
  if (snapshot.isEmpty) return const [];
  final links = await ref.watch(cardLinksProvider.future);
  final activations = await repo.rotatingActivations(auth.userId!);
  final now = DateTime.now();
  final year = now.year;
  final quarter = quarterOf(now);
  final out = <RotatingCardStatus>[];
  for (final c in links) {
    final cats = <RewardCategory>{};
    for (final r
        in snapshot.rulesByProduct[c.cardProductId] ?? const <RewardRule>[]) {
      if (r.kind != RewardRuleKind.rotating || !r.requiresActivation) continue;
      if (r.rotationYear != year) continue;
      if (r.rotationQuarter != null && r.rotationQuarter != quarter) continue;
      if (r.category != null) cats.add(r.category!);
    }
    if (cats.isEmpty) continue;
    out.add(
      RotatingCardStatus(
        cardId: c.cardId,
        cardName: c.cardName,
        cardProductId: c.cardProductId,
        year: year,
        quarter: quarter,
        categories: cats.toList(),
        activated: activations[c.cardId]?.contains((year, quarter)) ?? false,
      ),
    );
  }
  return out;
});

final bestCardByCategoryProvider = FutureProvider<BestCardLookup>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return BestCardLookup.empty;
  final ranker = await ref.watch(engineRankerProvider.future);
  return ranker?.bestCardByCategory() ?? BestCardLookup.empty;
});

/// Categories-tab tile data: best general rate per category + count of brand
/// bonuses inside that category. Both come from the engine ranker, which
/// already depends on the wallet via `cardLinksProvider`, so the tiles
/// auto-refresh when a sync or preference-order change lands.
final categoryTilesProvider = FutureProvider<List<CategoryTileData>>((
  ref,
) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const [];
  final ranker = await ref.watch(engineRankerProvider.future);
  // Every category, bonus or not — see `bestCardByCategoryAll`. Categories the
  // wallet cannot price at all are absent from the picks and keep null
  // rate/name, which the grid renders as "no card offers this".
  final picks = {
    for (final p in ranker?.bestCardByCategoryAll() ?? const <CategoryPick>[])
      p.category: p,
  };
  final brandCounts =
      ranker?.brandBonusCountsByCategory() ?? const <RewardCategory, int>{};
  return [
    for (final c in RewardCategory.values)
      CategoryTileData(
        category: c,
        bestRate: picks[c]?.rate,
        bestCardName: picks[c]?.cardName,
        isBonus: picks[c]?.isBonus ?? false,
        brandBonusCount: brandCounts[c] ?? 0,
      ),
  ];
});

class CategoryTileData {
  final RewardCategory category;
  final double? bestRate;
  final String? bestCardName;

  /// True when [bestRate] beats the wallet's everyday rate. False means the
  /// tile is showing a baseline fallback — still worth displaying, but it must
  /// not be dressed up as a bonus.
  final bool isBonus;
  final int brandBonusCount;

  /// No linked card earns anything here, so [bestRate] is 0 and there is no
  /// winning card to name. Not "unknown" — a secured / balance-transfer /
  /// credit-builder card genuinely pays nothing.
  bool get earnsNothing => (bestCardName ?? '').isEmpty;

  const CategoryTileData({
    required this.category,
    required this.bestRate,
    required this.bestCardName,
    required this.isBonus,
    required this.brandBonusCount,
  });
}

/// Brands-tab rows: best card per registered merchant, resolved against the
/// wallet and sorted wins-first. Like `categoryTilesProvider`, it rides
/// `engineRankerProvider`, so it auto-refreshes on sync / preference changes.
final brandTilesProvider = FutureProvider<List<BrandPick>>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const [];
  final ranker = await ref.watch(engineRankerProvider.future);
  return ranker?.bestCardByBrand() ?? const [];
});

typedef RewardRankingKey = ({
  RewardCategory category,
  String? merchantName,
  String? brandId,
});

final rewardRankingProvider =
    FutureProvider.family<RewardRankingResult, RewardRankingKey>((
      ref,
      key,
    ) async {
      final auth = ref.watch(sessionProvider);
      if (!auth.isLoggedIn) return RewardRankingResult.empty;
      final repo = ref.watch(dataRepositoryProvider);
      final ranker = await ref.watch(engineRankerProvider.future);
      if (ranker == null) return RewardRankingResult.empty;
      // Prefer an explicit brand_id (the Brands tab passes one directly); else
      // resolve the merchant *name* via the same BrandResolver the sync/geofence
      // use, so the brand-bonus row matches and the highlighted card agrees with
      // the Stores listing.
      final merchant = key.merchantName;
      final brandId =
          key.brandId ??
          ((merchant != null && merchant.isNotEmpty)
              ? repo.loadBrandResolver().resolve(merchant)
              : null);
      return ranker.rewardRanking(key.category, brandFilter: brandId);
    });

// sync: opt-out — debug diagnostic counts, manually refreshed via the
// dev surface; not part of the live UI invalidation chain.
final dataDiagnosticsProvider = FutureProvider<Map<String, int>>((ref) async {
  final auth = ref.watch(sessionProvider);
  if (!auth.isLoggedIn) return const {};
  final repo = ref.watch(dataRepositoryProvider);
  return repo.queryDataDiagnostics(auth.userId!);
});

/// Set of `institution_id`s the user just linked or reconnected via
/// addbank in this session. The `HomeScreen` sync-completion listener
/// drains this set: for each entry it looks up the resolved card's
/// `last_four`, queries orphan transactions with matching last_four
/// (the previous link via a different Sophtron catalog entry), and
/// shows the reconciliation sheet if matches exist. Set is cleared as
/// each entry is handled.
class PendingReconciliationNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void enqueue(String institutionId) {
    state = {...state, institutionId};
  }

  void dequeue(String institutionId) {
    state = state.where((id) => id != institutionId).toSet();
  }
}

final pendingReconciliationProvider =
    NotifierProvider<PendingReconciliationNotifier, Set<String>>(
      PendingReconciliationNotifier.new,
    );

/// Providers that read sync-replaced tables and must be invalidated after
/// every successful sync. Keep this co-located with the providers themselves
/// so adding a new sync-derived provider is one diff, not two.
final List<ProviderOrFamily> syncInvalidatedProviders = [
  pagedTransactionsProvider,
  cardsProvider,
  bankConnectionsByInstitutionIdProvider,
  monthlyTrendProvider,
  categoriesProvider,
  lastSyncProvider,
  earliestTransactionDateProvider,
  recurringPaymentsProvider,
  cardPerksProvider,
  cardRewardsByCardProvider,
  merchantSummaryProvider,
  categoryDrilldownProvider,
  rewardRankingProvider,
  cardCurrencyMapProvider,
  bestCardByCategoryProvider,
  categoryTilesProvider,
  brandTilesProvider,
  cardLinksProvider,
  engineRankerProvider,
  travelIsForeignProvider,
  walletCountsByIssuerProvider,
];
