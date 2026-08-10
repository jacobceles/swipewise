import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/insights.dart';
import '../models/reward_category.dart';
import '../nearby/google_places_provider.dart';
import '../nearby/merchant.dart';
import '../nearby/tile_cache.dart';
import '../providers/bank_sync_provider.dart';
import '../providers/data_providers.dart';
import '../providers/nearby_providers.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'nearby_categories_screen.dart';
import 'reward_ranking_sheet.dart';
import 'widgets/nearby_stores_view.dart';

/// Wireframe `dngVk` / `N86r3` - best card by nearby store, by reward
/// category, or by merchant brand. Three views toggled by a pill segmented
/// control; the search box runs one global lookup across all three (stores,
/// categories, brands). The tune button (Stores mode only) pushes the Nearby
/// Categories filter screen.
class AdvisorScreen extends ConsumerStatefulWidget {
  const AdvisorScreen({super.key});

  @override
  ConsumerState<AdvisorScreen> createState() => _AdvisorScreenState();
}

class _AdvisorScreenState extends ConsumerState<AdvisorScreen> {
  String _query = '';
  bool _searchOpen = false;
  AdvisorView? _viewOverride;
  late final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _onRefresh(AdvisorView view) async {
    switch (view) {
      case AdvisorView.stores:
        // Pull-to-refresh is an explicit user retry - bust the cache and
        // bypass the circuit breaker so we genuinely hit Google Places again.
        await GooglePlacesProvider().resetCircuitBreaker();
        await TileCache().clearAll();
        try {
          final newFuture = ref.refresh(nearbyMerchantsProvider.future);
          await newFuture;
        } catch (_) {}
      case AdvisorView.categories:
        try {
          final newFuture = ref.refresh(categoryTilesProvider.future);
          await newFuture;
        } catch (_) {}
      case AdvisorView.brands:
        try {
          final newFuture = ref.refresh(brandTilesProvider.future);
          await newFuture;
        } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // Off-screen in the HomeScreen IndexedStack, so this tab is built once and
    // kept mounted. The tile providers it reads are invalidated at the end of
    // every sync, but without a sync-coupled dependency `build` never re-runs
    // to pull the recomputed rankings — it kept showing pre-sync data (e.g. the
    // old best card for a category) until app relaunch. Watching the sync state
    // (same pattern as Cards/Breakdown) gives it that rebuild trigger.
    ref.watch(bankSyncProvider);
    final tilesAsync = ref.watch(categoryTilesProvider);
    final AdvisorView view = _viewOverride ?? ref.watch(advisorViewProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              showTune: view == AdvisorView.stores,
              searchOpen: _searchOpen,
              onTune: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const NearbyCategoriesScreen(),
                ),
              ),
              onToggleSearch: () => setState(() {
                _searchOpen = !_searchOpen;
                if (!_searchOpen) {
                  _query = '';
                  _searchController.clear();
                }
              }),
            ),
            if (_searchOpen)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                  style: AppText.bodyMd(),
                  decoration: InputDecoration(
                    hintText: 'Search store, category, card…',
                    prefixIcon: Icon(
                      LucideIcons.search,
                      size: 18,
                      color: palette.muted,
                    ),
                    isDense: true,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _ViewToggle(
                selected: view,
                onChanged: (v) => setState(() => _viewOverride = v),
              ),
            ),
            const _ForeignTravelBanner(),
            const SizedBox(height: 18),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _onRefresh(view),
                child: _query.trim().isNotEmpty
                    ? _GlobalSearchResults(query: _query)
                    : switch (view) {
                        AdvisorView.stores => ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                          children: [
                            _StoresCaption(),
                            const SizedBox(height: 12),
                            NearbyStoresView(query: _query),
                          ],
                        ),
                        AdvisorView.categories => ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                          children: [
                            tilesAsync.when(
                              loading: () => const Padding(
                                padding: EdgeInsets.symmetric(vertical: 40),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                              error: (e, _) => _CategoriesError(
                                error: '$e',
                                palette: palette,
                              ),
                              data: (tiles) =>
                                  _CategoryGrid(tiles: tiles, query: _query),
                            ),
                          ],
                        ),
                        AdvisorView.brands => const _BrandsView(),
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.showTune,
    required this.searchOpen,
    required this.onTune,
    required this.onToggleSearch,
  });

  final bool showTune;
  final bool searchOpen;
  final VoidCallback onTune;
  final VoidCallback onToggleSearch;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Card Advisor', style: AppText.titleLg()),
          Row(
            children: [
              if (showTune) ...[
                _RoundIconButton(
                  icon: LucideIcons.slidersHorizontal,
                  onTap: onTune,
                ),
                const SizedBox(width: 8),
              ],
              GestureDetector(
                onTap: onToggleSearch,
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: searchOpen ? AppColors.primary : palette.secondary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    searchOpen ? LucideIcons.x : LucideIcons.search,
                    size: 18,
                    color: searchOpen
                        ? AppColors.onPrimary
                        : AppColors.foreground,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.secondary,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: AppColors.foreground),
      ),
    );
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.selected, required this.onChanged});

  final AdvisorView selected;
  final ValueChanged<AdvisorView> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        children: [
          for (final v in AdvisorView.values)
            Expanded(
              child: _ToggleSeg(
                label: advisorViewLabel(v),
                selected: selected == v,
                onTap: () => onChanged(v),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToggleSeg extends StatelessWidget {
  const _ToggleSeg({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.foreground : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadiusPill),
        ),
        child: Text(
          label,
          style:
              AppText.bodyMd(
                color: selected ? AppColors.background : palette.muted,
              ).copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                fontSize: 14,
              ),
        ),
      ),
    );
  }
}

class _StoresCaption extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final radiusMi = ref.watch(nearbyRadiusProvider);
    final count = ref.watch(nearbyMerchantsProvider).value?.length;
    final caption = count == null
        ? 'within $radiusMi mi'
        : '$count within $radiusMi mi';
    return Text(
      caption,
      textAlign: TextAlign.center,
      style: AppText.bodySm(color: palette.muted),
    );
  }
}

class _CategoryGrid extends ConsumerWidget {
  const _CategoryGrid({required this.tiles, this.query = ''});

  final List<CategoryTileData> tiles;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final q = query.trim().toLowerCase();
    final earning = tiles
        .where(
          (t) => (t.bestRate ?? 0) > 0 && (t.bestCardName ?? '').isNotEmpty,
        )
        .toList();

    if (earning.isEmpty) {
      // Distinguish three states so the copy isn't a lie:
      //   - No cards yet → "link a bank" (the original "sync your wallet"
      //     case).
      //   - Cards present but the bundled reward seed couldn't fuzzy-match
      //     them to a catalog entry → "we don't have rewards for these
      //     cards" (no amount of refreshing will fix it client-side).
      //   - Cards present and matched, but rewards genuinely empty → fall
      //     into the second bucket as the closest truthful copy.
      final hasCards = (ref.watch(cardsProvider).value ?? const []).isNotEmpty;
      final (icon, message) = hasCards
          ? (
              LucideIcons.gift,
              "We don't have rewards data for your cards yet. "
                  'Pull down to refresh - if the issue persists, the card '
                  "may not be in our catalog.",
            )
          : (LucideIcons.wallet, 'Add a card to see recommendations.');
      return Padding(
        padding: EdgeInsets.symmetric(
          vertical: MediaQuery.of(context).size.height * 0.2,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: palette.muted),
              const SizedBox(height: 12),
              SizedBox(
                width: 320,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppText.bodyMd(
                    color: palette.muted,
                  ).copyWith(fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = q.isEmpty
        ? earning
        : earning.where((t) {
            final label = t.category.label.toLowerCase();
            final card = (t.bestCardName ?? '').toLowerCase();
            return label.contains(q) || card.contains(q);
          }).toList();
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            'No categories match "${query.trim()}"',
            textAlign: TextAlign.center,
            style: AppText.bodySm(color: palette.muted),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < filtered.length; i += 2)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _CategoryTile(tile: filtered[i])),
                  const SizedBox(width: 12),
                  Expanded(
                    child: i + 1 < filtered.length
                        ? _CategoryTile(tile: filtered[i + 1])
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.tile});
  final CategoryTileData tile;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final tint = _tintFor(tile.category);
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(kRadiusM),
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadiusM),
        onTap: () => showRewardRankingSheet(context, category: tile.category),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadiusM),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tint,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      tile.category.icon,
                      size: 18,
                      color: AppColors.foreground,
                    ),
                  ),
                  Text(
                    _rateText(tile.bestRate),
                    style: AppText.titleLg(
                      color: AppColors.primary,
                    ).copyWith(fontWeight: FontWeight.w800, fontSize: 22),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                tile.category.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.titleMd().copyWith(fontSize: 14),
              ),
              if ((tile.bestCardName ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  tile.bestCardName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodySm(),
                ),
              ],
              if (tile.brandBonusCount > 0) ...[
                const SizedBox(height: 8),
                _BrandBonusPill(count: tile.brandBonusCount),
              ],
              const Spacer(),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    'Compare cards',
                    style: AppText.bodySm().copyWith(fontSize: 11),
                  ),
                  Icon(LucideIcons.arrowRight, size: 12, color: palette.muted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _rateText(double? rate) {
    if (rate == null || rate == 0) return '-';
    final s = rate % 1 == 0 ? rate.toInt().toString() : rate.toStringAsFixed(1);
    return '$s%';
  }

  Color _tintFor(RewardCategory c) {
    switch (c) {
      case RewardCategory.dining:
        return const Color(0xFF4E2E12);
      case RewardCategory.coffee:
        return const Color(0xFF3D2F1E);
      case RewardCategory.grocery:
      case RewardCategory.onlineGrocery:
      case RewardCategory.wholesale:
        return const Color(0xFF143E27);
      case RewardCategory.gas:
      case RewardCategory.evCharging:
        return const Color(0xFF1F2A33);
      case RewardCategory.travel:
      case RewardCategory.airlines:
        return const Color(0xFF143452);
      case RewardCategory.transit:
        return const Color(0xFF12384B);
      case RewardCategory.hotels:
        return const Color(0xFF2A1A52);
      case RewardCategory.carRentals:
        return const Color(0xFF12404B);
      case RewardCategory.streaming:
      case RewardCategory.entertainment:
      case RewardCategory.movieTheaters:
        return const Color(0xFF4B1A1F);
      case RewardCategory.onlineShopping:
      case RewardCategory.departmentStores:
      case RewardCategory.apparel:
      case RewardCategory.electronics:
        return const Color(0xFF4B1A39);
      case RewardCategory.phoneAndInternet:
      case RewardCategory.advertising:
        return const Color(0xFF1F1F4B);
      case RewardCategory.officeSupply:
      case RewardCategory.shipping:
        return const Color(0xFF24333A);
      case RewardCategory.homeImprovement:
      case RewardCategory.rent:
        return const Color(0xFF3A2A12);
      case RewardCategory.fitness:
      case RewardCategory.sportingGoods:
        return const Color(0xFF143E34);
      case RewardCategory.drugStores:
      case RewardCategory.pets:
      case RewardCategory.medical:
        return const Color(0xFF381A4B);
      case RewardCategory.utilities:
        return const Color(0xFF333312);
      case RewardCategory.other:
        return const Color(0xFF2E2E2E);
    }
  }
}

class _BrandBonusPill extends StatelessWidget {
  const _BrandBonusPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.sparkles, size: 10, color: AppColors.primary),
          const SizedBox(width: 4),
          Text(
            '$count Brand ${count == 1 ? 'Bonus' : 'Bonuses'}',
            style: AppText.labelSm(
              color: AppColors.primary,
            ).copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _CategoriesError extends StatelessWidget {
  const _CategoriesError({required this.error, required this.palette});
  final String error;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(LucideIcons.wifiOff, size: 36, color: palette.muted),
          const SizedBox(height: 12),
          Text(
            'Could not load categories',
            style: AppText.bodyMd(color: palette.muted),
          ),
          const SizedBox(height: 4),
          Text(
            error,
            style: AppText.bodySm(color: palette.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Renders a raw multiplier as "5%" for cashback or "5x" for points/miles.
String _formatRate(double? rate, {String currency = 'USD'}) {
  if (rate == null || rate == 0) return '-';
  final s = rate % 1 == 0 ? rate.toInt().toString() : rate.toStringAsFixed(1);
  return currency == 'USD' ? '$s%' : '${s}x';
}

/// Uppercase muted section label shared by the Brands tab and global search.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(label.toUpperCase(), style: AppText.labelSm());
  }
}

/// A merchant/category/store result row: icon, title, "card · rate" subtitle.
/// Shared by the Brands tab and the global search overlay.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusM),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusM),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.secondary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 18, color: AppColors.foreground),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppText.titleMd().copyWith(fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: AppText.bodySm(
                          color: AppColors.primary,
                        ).copyWith(fontSize: 12, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _openBrandSheet(BuildContext context, BrandPick pick) =>
    showRewardRankingSheet(
      context,
      category: pick.category,
      merchantName: pick.displayName,
      brandId: pick.brandId,
      primary: RewardRankingPrimary.brand,
    );

enum _BrandItemKind { header, row, tailHeader }

/// Lightweight descriptor for one row of the Brands tab's lazy list, so the
/// list can mix a section header, brand rows, and the collapsible tail header
/// without building every widget eagerly.
class _BrandItem {
  const _BrandItem.header(this.header)
    : kind = _BrandItemKind.header,
      pick = null,
      tailCount = 0,
      tailCard = '',
      tailRate = '',
      expanded = false;
  const _BrandItem.row(this.pick)
    : kind = _BrandItemKind.row,
      header = null,
      tailCount = 0,
      tailCard = '',
      tailRate = '',
      expanded = false;
  const _BrandItem.tailHeader({
    required int count,
    required String cardName,
    required String rate,
    required this.expanded,
  }) : kind = _BrandItemKind.tailHeader,
       header = null,
       pick = null,
       tailCount = count,
       tailCard = cardName,
       tailRate = rate;

  final _BrandItemKind kind;
  final String? header;
  final BrandPick? pick;
  final int tailCount;
  final String tailCard;
  final String tailRate;
  final bool expanded;
}

/// Advisor "Brands" tab: every registered merchant resolved to the user's best
/// card. Wins (rate above baseline) list on top; the flat-rate tail — which all
/// resolves to the same catch-all card — sits behind a collapsed header. Uses a
/// lazy `ListView.builder` since the full registry is ~700 merchants.
class _BrandsView extends ConsumerStatefulWidget {
  const _BrandsView();

  @override
  ConsumerState<_BrandsView> createState() => _BrandsViewState();
}

class _BrandsViewState extends ConsumerState<_BrandsView> {
  bool _tailExpanded = false;

  Widget _scrollable(List<Widget> children) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
    children: children,
  );

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final picksAsync = ref.watch(brandTilesProvider);

    return picksAsync.when(
      loading: () => _scrollable(const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        ),
      ]),
      error: (e, _) =>
          _scrollable([_CategoriesError(error: '$e', palette: palette)]),
      data: (picks) {
        if (picks.isEmpty) {
          final hasCards =
              (ref.watch(cardsProvider).value ?? const []).isNotEmpty;
          return _scrollable([_BrandsEmpty(hasCards: hasCards)]);
        }
        final wins = [
          for (final p in picks)
            if (p.isBonus) p,
        ];
        final tail = [
          for (final p in picks)
            if (!p.isBonus) p,
        ];

        final items = <_BrandItem>[];
        if (wins.isNotEmpty) {
          items.add(const _BrandItem.header('Where your cards win'));
          items.addAll(wins.map(_BrandItem.row));
        }
        if (tail.isNotEmpty) {
          items.add(
            _BrandItem.tailHeader(
              count: tail.length,
              cardName: tail.first.cardName,
              rate: _formatRate(tail.first.rate, currency: tail.first.currency),
              expanded: _tailExpanded,
            ),
          );
          if (_tailExpanded) items.addAll(tail.map(_BrandItem.row));
        }

        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
          itemCount: items.length,
          itemBuilder: (context, i) => _buildItem(items[i]),
        );
      },
    );
  }

  Widget _buildItem(_BrandItem item) {
    switch (item.kind) {
      case _BrandItemKind.header:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _SectionLabel(item.header!),
        );
      case _BrandItemKind.row:
        final p = item.pick!;
        return _ResultRow(
          icon: p.category.icon,
          title: p.displayName,
          subtitle:
              '${p.cardName} · ${_formatRate(p.rate, currency: p.currency)}',
          onTap: () => _openBrandSheet(context, p),
        );
      case _BrandItemKind.tailHeader:
        return _BrandTailHeader(
          count: item.tailCount,
          cardName: item.tailCard,
          rateText: item.tailRate,
          expanded: item.expanded,
          onTap: () => setState(() => _tailExpanded = !_tailExpanded),
        );
    }
  }
}

/// Collapsible header for the flat-rate brand tail. All tail brands resolve to
/// the same catch-all card, so the subtitle can name it once.
class _BrandTailHeader extends StatelessWidget {
  const _BrandTailHeader({
    required this.count,
    required this.cardName,
    required this.rateText,
    required this.expanded,
    required this.onTap,
  });

  final int count;
  final String cardName;
  final String rateText;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusM),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusM),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'All other brands ($count)',
                        style: AppText.titleMd().copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Your $cardName earns $rateText everywhere else',
                        style: AppText.bodySm(color: palette.muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 18,
                  color: palette.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandsEmpty extends StatelessWidget {
  const _BrandsEmpty({required this.hasCards});
  final bool hasCards;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final (icon, message) = hasCards
        ? (
            LucideIcons.gift,
            "We don't have rewards data for your cards yet. "
                'Pull down to refresh - if the issue persists, the card '
                "may not be in our catalog.",
          )
        : (LucideIcons.wallet, 'Add a card to see recommendations.');
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: MediaQuery.of(context).size.height * 0.2,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: palette.muted),
            const SizedBox(height: 12),
            SizedBox(
              width: 320,
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: AppText.bodyMd(
                  color: palette.muted,
                ).copyWith(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Unified search results across nearby stores, reward categories, and brands.
/// Shown in place of the active tab whenever the search box has a query, so the
/// one bar searches everything — the user doesn't pick a tab first.
class _GlobalSearchResults extends ConsumerWidget {
  const _GlobalSearchResults({required this.query});
  final String query;

  static const int _maxBrandHits = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final q = query.trim().toLowerCase();

    final tiles = ref.watch(categoryTilesProvider).value ?? const [];
    final catHits = [
      for (final t in tiles)
        if ((t.bestRate ?? 0) > 0 &&
            (t.bestCardName ?? '').isNotEmpty &&
            (t.category.label.toLowerCase().contains(q) ||
                (t.bestCardName ?? '').toLowerCase().contains(q)))
          t,
    ];

    final picks = ref.watch(brandTilesProvider).value ?? const <BrandPick>[];
    final brandHits = [
      for (final p in picks)
        if (p.displayName.toLowerCase().contains(q) ||
            p.cardName.toLowerCase().contains(q))
          p,
    ];

    // Only fold in nearby stores the user already loaded — never start location
    // work from a text search.
    final nearbyOn = ref.watch(nearbyEnabledProvider);
    final stores = nearbyOn
        ? (ref.watch(nearbyMerchantsProvider).value ??
              const <NearbyMerchantWithReward>[])
        : const <NearbyMerchantWithReward>[];
    final storeHits = [
      for (final m in stores)
        if (m.name.toLowerCase().contains(q) ||
            (m.resolvedLabel ?? '').toLowerCase().contains(q))
          m,
    ];

    if (catHits.isEmpty && brandHits.isEmpty && storeHits.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'No matches for "${query.trim()}"',
                textAlign: TextAlign.center,
                style: AppText.bodySm(color: palette.muted),
              ),
            ),
          ),
        ],
      );
    }

    final brandShown = brandHits.length > _maxBrandHits
        ? brandHits.sublist(0, _maxBrandHits)
        : brandHits;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      children: [
        if (storeHits.isNotEmpty) ...[
          const _SectionLabel('Nearby stores'),
          const SizedBox(height: 10),
          for (final m in storeHits)
            _ResultRow(
              icon: LucideIcons.store,
              title: m.name,
              subtitle: _storeSubtitle(m),
              onTap: (m.resolvedLabel == null || m.resolvedLabel!.isEmpty)
                  ? null
                  : () => showRewardRankingSheetForLabel(
                      context,
                      label: m.resolvedLabel!,
                      merchantName: m.name,
                      primary: RewardRankingPrimary.brand,
                    ),
            ),
          const SizedBox(height: 14),
        ],
        if (catHits.isNotEmpty) ...[
          const _SectionLabel('Categories'),
          const SizedBox(height: 10),
          for (final t in catHits)
            _ResultRow(
              icon: t.category.icon,
              title: t.category.label,
              subtitle: '${t.bestCardName} · ${_formatRate(t.bestRate)}',
              onTap: () =>
                  showRewardRankingSheet(context, category: t.category),
            ),
          const SizedBox(height: 14),
        ],
        if (brandHits.isNotEmpty) ...[
          const _SectionLabel('Brands'),
          const SizedBox(height: 10),
          for (final p in brandShown)
            _ResultRow(
              icon: p.category.icon,
              title: p.displayName,
              subtitle:
                  '${p.cardName} · ${_formatRate(p.rate, currency: p.currency)}',
              onTap: () => _openBrandSheet(context, p),
            ),
          if (brandHits.length > brandShown.length)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '+${brandHits.length - brandShown.length} more — refine your search',
                style: AppText.bodySm(color: palette.muted),
              ),
            ),
        ],
      ],
    );
  }

  String _storeSubtitle(NearbyMerchantWithReward m) {
    if (m.bestCardName == null || m.bestCardName!.isEmpty) {
      return 'No matched card';
    }
    final r = _formatRate(m.bestRate);
    return r == '-'
        ? 'Best: ${m.bestCardName}'
        : 'Best: ${m.bestCardName} · $r';
  }
}

/// Shown only when the user is abroad (N7): a compact reminder of which of their
/// cards charge no foreign-transaction fee, right where they check which card to
/// use. Renders nothing at home, or abroad with no fee-free card to name.
class _ForeignTravelBanner extends ConsumerWidget {
  const _ForeignTravelBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isForeign = ref.watch(travelIsForeignProvider).value ?? false;
    if (!isForeign) return const SizedBox.shrink();
    final cards = ref.watch(noForeignFeeCardsProvider).value ?? const [];
    if (cards.isEmpty) return const SizedBox.shrink();

    final palette = AppPalette.of(context);
    final names = cards.map((c) => c.cardName).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: palette.amberBg,
          borderRadius: BorderRadius.circular(kRadiusM),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.plane, size: 16, color: palette.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "You're abroad — skip foreign fees",
                    style: AppText.labelSm(
                      color: palette.amber,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'No-fee cards: $names',
                    style: AppText.bodySm(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
