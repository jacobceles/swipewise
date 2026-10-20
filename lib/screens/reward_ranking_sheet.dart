import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../api/reward_category_mapper.dart';
import '../models/insights.dart';
import '../models/reward_category.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';

/// Where the user entered the sheet from. Determines which section
/// renders on top:
///   - `brand`   - user is at a merchant (notification tap, Stores-tab
///                 row tap, Merchant detail). Brand bonuses go first;
///                 the matched-brand row is highlighted.
///   - `general` - user picked a category tile or a category-detail
///                 callout. General ranking goes first.
enum RewardRankingPrimary { general, brand }

/// Wireframe `BnJ7q` - Bottom sheet listing the user's owned cards split
/// into a general ranking + an optional brand-bonuses section.
Future<void> showRewardRankingSheet(
  BuildContext context, {
  required RewardCategory category,
  RewardRankingPrimary primary = RewardRankingPrimary.general,
  String? merchantName,
  String? brandId,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _RewardRankingSheet(
      category: category,
      primary: primary,
      merchantName: merchantName,
      brandId: brandId,
    ),
  );
}

/// Convenience wrapper for callers holding a free-form label string
/// (transaction.category, CategoryLabelResolver result).
Future<void> showRewardRankingSheetForLabel(
  BuildContext context, {
  required String label,
  RewardRankingPrimary primary = RewardRankingPrimary.general,
  String? merchantName,
  String? brandId,
}) {
  return showRewardRankingSheet(
    context,
    category: classifyLooseLabel(label),
    primary: primary,
    merchantName: merchantName,
    brandId: brandId,
  );
}

class _RewardRankingSheet extends ConsumerStatefulWidget {
  const _RewardRankingSheet({
    required this.category,
    required this.primary,
    this.merchantName,
    this.brandId,
  });

  final RewardCategory category;
  final RewardRankingPrimary primary;
  final String? merchantName;
  final String? brandId;

  @override
  ConsumerState<_RewardRankingSheet> createState() =>
      _RewardRankingSheetState();
}

class _RewardRankingSheetState extends ConsumerState<_RewardRankingSheet> {
  /// The filter tab; null is "All".
  _Tab? _filter;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final category = widget.category;
    final merchantName = widget.merchantName;
    final rankingAsync = ref.watch(
      rewardRankingProvider((
        category: category,
        merchantName: merchantName,
        brandId: widget.brandId,
      )),
    );
    final mediaH = MediaQuery.of(context).size.height;
    final cardCount = rankingAsync.asData?.value.isEmpty == false
        ? _cardCount(_entriesOf(rankingAsync.asData!.value), null)
        : null;
    final subtitle = cardCount == null
        ? (merchantName != null ? category.label : 'Ranked by value per \$1')
        : [
            if (merchantName != null) category.label,
            '$cardCount of your ${cardCount == 1 ? 'card' : 'cards'}',
          ].join(' · ');

    return Container(
      constraints: BoxConstraints(
        minHeight: mediaH * 0.32,
        maxHeight: mediaH * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusM)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: palette.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            merchantName != null
                ? 'Best cards at $merchantName'
                : 'Best cards for ${category.label}',
            style: AppText.titleLg(),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: AppText.bodySm()),
          const SizedBox(height: 16),
          Flexible(
            child: rankingAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '$e',
                    style: AppText.bodySm(color: palette.red),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              data: (result) {
                if (result.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        Icon(
                          LucideIcons.creditCard,
                          size: 36,
                          color: palette.muted,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No reward data for this category yet',
                          style: AppText.bodySm(color: palette.muted),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }
                return _buildRanking(context, result);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRanking(BuildContext context, RewardRankingResult result) {
    final (:general, :brand) = _entriesOf(result);
    // Brand-first mode is only meaningful when *this* merchant
    // actually matches one of the brand bonuses. Otherwise the
    // top row would be a brand bonus for an unrelated merchant
    // and the Stores list's "Best:" (general fallback) would
    // disagree with the sheet's headline.
    final hasMatchedBrand = brand.any((b) => b.isMatchedBrand);
    final brandPrimary =
        widget.primary == RewardRankingPrimary.brand && hasMatchedBrand;

    // The overall winner. An `other` reward has no known value, so it can
    // never be called best.
    final topEntry = brandPrimary
        ? brand.first
        : (general.isEmpty ? null : general.first);
    final best = topEntry?.kind == RewardKind.other ? null : topEntry;

    final filter = _filter;
    bool shown(_Entry e) => filter == null || e.tab == filter;
    final visibleGeneral = general.where(shown).toList();
    final visibleBrand = brand.where(shown).toList();
    final bestHidden = best != null && !shown(best);

    final allCount = _cardCount((general: general, brand: brand), null);
    final segments = _KindFilter(
      selected: filter,
      counts: {
        null: allCount,
        for (final k in _Tab.values)
          k: _cardCount((general: general, brand: brand), k),
      },
      onChanged: (k) => setState(() => _filter = k),
    );
    final header = _RankHeader(onInfo: () => _showHowWeRank(context));

    final Widget body;
    if (visibleGeneral.isEmpty && visibleBrand.isEmpty) {
      body = _EmptyFilter(
        kind: filter!,
        where: widget.merchantName != null
            ? 'at ${widget.merchantName}'
            : 'in ${widget.category.label}',
        counts: {
          for (final k in _Tab.values)
            if (k != filter) k: _cardCount((general: general, brand: brand), k),
        },
        allCount: allCount,
        onShowAll: () => setState(() => _filter = null),
      );
    } else {
      // Neutral "Top cash"/"Top points" on the first valued row when the
      // filter hides the real winner.
      final firstVisible = brandPrimary
          ? [...visibleBrand, ...visibleGeneral]
          : [...visibleGeneral, ...visibleBrand];
      final topPillEntry = bestHidden
          ? firstVisible.where((e) => e.kind != RewardKind.other).firstOrNull
          : null;
      final showSectionHeaders = visibleBrand.isNotEmpty;
      final generalSection = visibleGeneral.isEmpty
          ? null
          : _Section(
              title: showSectionHeaders ? 'General ranking' : null,
              entries: visibleGeneral,
              best: best,
              topPill: topPillEntry,
            );
      final brandSection = visibleBrand.isEmpty
          ? null
          : _Section(
              title: 'Brand bonuses',
              icon: LucideIcons.sparkles,
              entries: visibleBrand,
              best: best,
              topPill: topPillEntry,
            );
      final ordered = brandPrimary
          ? [brandSection, generalSection]
          : [generalSection, brandSection];
      final sections = <Widget>[];
      for (final s in ordered.nonNulls) {
        if (sections.isNotEmpty) sections.add(const SizedBox(height: 20));
        sections.add(s);
      }
      final anyOther = [
        ...visibleGeneral,
        ...visibleBrand,
      ].any((e) => e.kind == RewardKind.other);
      body = SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...sections,
            if (anyOther) const _IssuerWordingFootnote(),
            if (bestHidden) ...[
              const SizedBox(height: 12),
              _HiddenBestCallout(
                best: best,
                onShowAll: () => setState(() => _filter = null),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        segments,
        const SizedBox(height: 16),
        header,
        const SizedBox(height: 12),
        Flexible(child: body),
      ],
    );
  }
}

/// One rendered row, general or brand bonus — the two share a layout.
class _Entry {
  const _Entry({
    required this.cardId,
    required this.title,
    required this.detail,
    this.cardName,
    this.cardImage,
    required this.kind,
    required this.rate,
    required this.eff,
    this.programName,
    this.wording,
    this.isMatchedBrand = false,
    this.miles = false,
  });

  final String cardId;

  /// Card name for a general row, the brand for a brand bonus.
  final String title;

  /// The line under the title: "•••• 1234  $0.00 earned recently" or the card.
  final String detail;
  final String? cardName;
  final String? cardImage;
  final RewardKind kind;
  final double rate;
  final double eff;
  final String? programName;
  final String? wording;
  final bool isMatchedBrand;

  /// A miles programme (United MileagePlus): a points kind, labelled "Miles".
  final bool miles;

  _Tab get tab => miles
      ? _Tab.miles
      : switch (kind) {
          RewardKind.cash => _Tab.cash,
          RewardKind.points => _Tab.points,
          RewardKind.other => _Tab.other,
        };
}

/// The filter tabs. Miles are a points kind to the engine, but they get their
/// own tab: people collect airline miles apart from bank points.
enum _Tab { cash, points, miles, other }

String _tabLabel(_Tab t) => switch (t) {
  _Tab.cash => 'Cash',
  _Tab.points => 'Points',
  _Tab.miles => 'Miles',
  _Tab.other => 'Other',
};

IconData _tabIcon(_Tab t) => switch (t) {
  _Tab.cash => LucideIcons.banknote,
  _Tab.points => LucideIcons.coins,
  _Tab.miles => LucideIcons.plane,
  _Tab.other => LucideIcons.tag,
};

typedef _Entries = ({List<_Entry> general, List<_Entry> brand});

_Entries _entriesOf(RewardRankingResult result) => (
  general: [
    for (final r in result.general)
      _Entry(
        cardId: r.cardId,
        title: r.cardName ?? 'Card',
        detail:
            '•••• ${r.lastFour ?? '----'}  '
            '${NumberFormat.simpleCurrency().format(r.earnedRecently)} earned recently',
        cardName: r.cardName,
        cardImage: r.cardImage,
        kind: r.kind,
        rate: r.rate,
        eff: r.effectiveCentsPerDollar,
        programName: r.programName,
        wording: r.issuerWording,
        miles: r.currency == 'MILES',
      ),
  ],
  brand: [
    for (final r in result.brandBonuses)
      _Entry(
        cardId: r.cardId,
        title: r.brand,
        detail: r.cardName ?? 'Card',
        cardName: r.cardName,
        cardImage: r.cardImage,
        kind: r.kind,
        rate: r.rate,
        eff: r.effectiveCentsPerDollar,
        programName: r.programName,
        wording: r.issuerWording,
        isMatchedBrand: r.isMatchedBrand,
        miles: r.currency == 'MILES',
      ),
  ],
);

/// Distinct cards with a row in [tab] (any tab when null).
int _cardCount(_Entries entries, _Tab? tab) => {
  for (final e in [...entries.general, ...entries.brand])
    if (tab == null || e.tab == tab) e.cardId,
}.length;

class _KindFilter extends StatelessWidget {
  const _KindFilter({
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  final _Tab? selected;
  final Map<_Tab?, int> counts;
  final ValueChanged<_Tab?> onChanged;

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
          for (final k in <_Tab?>[null, ..._Tab.values])
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(k),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected == k
                        ? AppColors.foreground
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(kRadiusPill),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          k == null ? 'All' : _tabLabel(k),
                          style:
                              AppText.bodyMd(
                                color: selected == k
                                    ? AppColors.background
                                    : counts[k] == 0
                                    ? palette.muted
                                    : AppColors.foreground,
                              ).copyWith(
                                fontWeight: selected == k
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                fontSize: 14,
                              ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '${counts[k] ?? 0}',
                          style: AppText.bodySm(
                            color: palette.muted,
                          ).copyWith(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RankHeader extends StatelessWidget {
  const _RankHeader({required this.onInfo});
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text('RANKED BY VALUE PER \$1', style: AppText.labelSm()),
        ),
        GestureDetector(
          onTap: onInfo,
          child: Row(
            children: [
              const Icon(LucideIcons.info, size: 14, color: AppColors.primary),
              const SizedBox(width: 5),
              Text(
                'How we rank',
                style: AppText.bodySm(
                  color: AppColors.primary,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    this.title,
    this.icon,
    required this.entries,
    required this.best,
    required this.topPill,
  });

  final String? title;
  final IconData? icon;
  final List<_Entry> entries;
  final _Entry? best;
  final _Entry? topPill;

  @override
  Widget build(BuildContext context) {
    final valued = [
      for (final e in entries)
        if (e.kind != RewardKind.other) e,
    ];
    final others = [
      for (final e in entries)
        if (e.kind == RewardKind.other) e,
    ];
    Widget row(_Entry e) => _RewardRow(
      entry: e,
      isBest: identical(e, best),
      topPill: identical(e, topPill),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          _SectionHeader(title: title!, icon: icon),
          const SizedBox(height: 8),
        ],
        for (final e in valued) row(e),
        if (others.isNotEmpty) ...[
          if (valued.isNotEmpty) const _OtherDivider(),
          for (final e in others) row(e),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.icon});
  final String title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: palette.amber),
          const SizedBox(width: 6),
        ],
        Text(title.toUpperCase(), style: AppText.labelSm()),
      ],
    );
  }
}

class _OtherDivider extends StatelessWidget {
  const _OtherDivider();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
      child: Row(
        children: [
          Text(
            'NO RELIABLE VALUE · LISTED LAST',
            style: AppText.labelSm(color: palette.muted),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(height: 1, color: palette.border)),
        ],
      ),
    );
  }
}

class _RewardRow extends StatelessWidget {
  const _RewardRow({
    required this.entry,
    required this.isBest,
    required this.topPill,
  });

  final _Entry entry;
  final bool isBest;
  final bool topPill;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final e = entry;
    final isOther = e.kind == RewardKind.other;
    final Color borderColor;
    final double borderWidth;
    final Color rateColor;
    final Color bgColor;
    if (isBest) {
      borderColor = palette.green;
      borderWidth = 1.5;
      rateColor = palette.green;
      bgColor = palette.secondary;
    } else if (e.isMatchedBrand) {
      borderColor = AppColors.primary;
      borderWidth = 1.5;
      rateColor = AppColors.primary;
      bgColor = AppColors.primary.withValues(alpha: 0.06);
    } else {
      borderColor = palette.border;
      borderWidth = 1;
      rateColor = AppColors.foreground;
      bgColor = palette.secondary;
    }
    final String description;
    switch (e.kind) {
      case RewardKind.cash:
        description = 'cash back';
      case RewardKind.points:
        description = e.programName ?? (e.miles ? 'miles' : 'points');
      case RewardKind.other:
        description = _otherWording(e);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(kRadiusS + 2),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _CardArt(image: e.cardImage, name: e.cardName ?? ''),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      style: AppText.titleMd().copyWith(fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.detail,
                      style: AppText.monoXs(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (!isOther) ...[
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (isBest)
                      _Pill(
                        label: 'Best',
                        color: palette.green,
                        background: palette.greenBg,
                      )
                    else if (topPill)
                      _Pill(
                        label: e.miles
                            ? 'Top miles'
                            : 'Top ${_kindLabel(e.kind).toLowerCase()}',
                        color: AppColors.foreground,
                        background: AppColors.card,
                      ),
                    Text(
                      _bigNumber(e),
                      style: AppText.monoMd(
                        color: rateColor,
                      ).copyWith(fontWeight: FontWeight.w700, fontSize: 18),
                    ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _KindPill(kind: e.kind, miles: e.miles),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  description,
                  style: AppText.bodySm(
                    color: isOther ? AppColors.foreground : palette.muted,
                  ).copyWith(fontSize: isOther ? 13 : 12),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _valueLine(e),
                  textAlign: TextAlign.end,
                  style: isOther
                      ? AppText.bodySm(color: palette.muted)
                      : AppText.bodySm(
                          color: AppColors.foreground,
                        ).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.color,
    required this.background,
  });
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(kRadiusXs),
      ),
      child: Text(
        label,
        style: AppText.bodySm(
          color: color,
        ).copyWith(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _KindPill extends StatelessWidget {
  const _KindPill({required this.kind, this.miles = false});
  final RewardKind kind;
  final bool miles;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = kind == RewardKind.other
        ? palette.muted
        : AppColors.foreground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            miles ? LucideIcons.plane : _kindIcon(kind),
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            miles ? 'Miles' : _kindLabel(kind),
            style: AppText.bodySm(
              color: color,
            ).copyWith(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _IssuerWordingFootnote extends StatelessWidget {
  const _IssuerWordingFootnote();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(LucideIcons.quote, size: 12, color: palette.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Wording in quotes comes straight from the card issuer.',
              style: AppText.bodySm(
                color: palette.muted,
              ).copyWith(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _HiddenBestCallout extends StatelessWidget {
  const _HiddenBestCallout({required this.best, required this.onShowAll});
  final _Entry best;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.greenBg,
        borderRadius: BorderRadius.circular(kRadiusS + 2),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.trendingUp, size: 18, color: palette.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${best.cardName ?? best.title} earns more here',
                  style: AppText.titleMd().copyWith(fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_valueLine(best)} in '
                  '${best.miles ? 'miles' : _kindLabel(best.kind).toLowerCase()}'
                  ' — hidden by this filter',
                  style: AppText.bodySm().copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onShowAll,
            child: Text(
              'Show all',
              style: AppText.bodyMd(
                color: palette.green,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({
    required this.kind,
    required this.where,
    required this.counts,
    required this.allCount,
    required this.onShowAll,
  });

  final _Tab kind;

  /// "at Joe's Diner" / "in Dining".
  final String where;

  /// Card counts for the other tabs.
  final Map<_Tab, int> counts;
  final int allCount;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final what = switch (kind) {
      _Tab.cash => 'cash back',
      _Tab.points => 'points',
      _Tab.miles => 'miles',
      _Tab.other => 'store money or special points',
    };
    final parts = [
      for (final e in counts.entries)
        if (e.value > 0) '${e.value} ${_tabLabel(e.key).toLowerCase()}',
    ];
    final elsewhere = parts.isEmpty
        ? ''
        : ' Your ${parts.length == 1 ? parts.single : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}'} '
              '${allCount == 1 ? 'card is' : 'cards are'} under All.';
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: palette.secondary,
                shape: BoxShape.circle,
              ),
              child: Icon(_tabIcon(kind), size: 24, color: palette.muted),
            ),
            const SizedBox(height: 16),
            Text(
              'No “${_tabLabel(kind)}” rewards here',
              style: AppText.titleMd(),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'None of your cards earn $what $where.$elsewhere',
              style: AppText.bodySm(color: palette.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: onShowAll,
              style: TextButton.styleFrom(
                backgroundColor: palette.secondary,
                foregroundColor: AppColors.foreground,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              child: Text(
                'Show all $allCount ${allCount == 1 ? 'card' : 'cards'}',
                style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wireframe `rl3zB` - what each reward kind's value means.
void _showHowWeRank(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _HowWeRankSheet(),
  );
}

class _HowWeRankSheet extends StatelessWidget {
  const _HowWeRankSheet();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    Widget kindRow(RewardKind kind, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _KindPill(kind: kind),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.titleMd().copyWith(fontSize: 14)),
                const SizedBox(height: 2),
                Text(body, style: AppText.bodySm(color: palette.muted)),
              ],
            ),
          ),
        ],
      ),
    );
    Widget exampleRow(String label, String value, Color color) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            value,
            style: AppText.bodyMd(
              color: color,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusM)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text('How we rank cards', style: AppText.titleLg()),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(LucideIcons.x, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: palette.secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'We compare what each card gives back for every \$1 you spend.',
              style: AppText.bodyMd().copyWith(fontSize: 16),
            ),
            const SizedBox(height: 20),
            kindRow(
              RewardKind.cash,
              'Exact',
              '5% cash back = 5¢ back per \$1.',
            ),
            kindRow(
              RewardKind.points,
              'Estimate',
              'We use a typical value for each program — e.g. Amex '
                  'Membership Rewards ≈ 2¢ per point, so 4x ≈ 8¢ back per \$1. '
                  'What you actually get depends on how you redeem.',
            ),
            kindRow(
              RewardKind.other,
              'Value unknown',
              'Store money and per-litre points have no reliable value, so '
                  "they're listed last. Their wording comes straight from the "
                  'card issuer.',
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(kRadiusS + 2),
                border: Border.all(color: palette.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'WHY A BIGGER NUMBER CAN RANK LOWER',
                    style: AppText.labelSm(),
                  ),
                  const SizedBox(height: 8),
                  exampleRow(
                    '4x Membership Rewards',
                    '≈ 8¢ back per \$1',
                    palette.green,
                  ),
                  exampleRow(
                    '7x Hilton Honors',
                    '≈ 4.2¢ back per \$1',
                    AppColors.foreground,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Hilton points are worth less each, so 7x gives back less.',
                    style: AppText.bodySm(color: palette.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                backgroundColor: AppColors.foreground,
                foregroundColor: AppColors.background,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                'Got it',
                style: AppText.bodyMd(
                  color: AppColors.background,
                ).copyWith(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardArt extends StatelessWidget {
  const _CardArt({required this.image, required this.name});
  final String? image;
  final String name;

  @override
  Widget build(BuildContext context) {
    final colors = _gradientFor(name);
    return Container(
      width: 48,
      height: 32,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: image != null && image!.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: image!,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            )
          : const SizedBox.shrink(),
    );
  }

  static List<Color> _gradientFor(String name) {
    final h = name.hashCode.abs();
    const palette = [
      [Color(0xFF1A3A6E), Color(0xFF0A1A3A)],
      [Color(0xFF8B6914), Color(0xFF4A3508)],
      [Color(0xFF6B1A1A), Color(0xFF2A0808)],
      [Color(0xFF1F4F2A), Color(0xFF0A2A14)],
      [Color(0xFF3D2E12), Color(0xFF1A1208)],
    ];
    return palette[h % palette.length];
  }
}

String _kindLabel(RewardKind kind) => switch (kind) {
  RewardKind.cash => 'Cash',
  RewardKind.points => 'Points',
  RewardKind.other => 'Other',
};

IconData _kindIcon(RewardKind kind) => switch (kind) {
  RewardKind.cash => LucideIcons.banknote,
  RewardKind.points => LucideIcons.coins,
  RewardKind.other => LucideIcons.tag,
};

/// A whole number bare, otherwise one decimal: 8 → "8", 4.2 → "4.2".
String _num(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// The rate as the issuer markets it: "5%" cash, "4x" points.
String _bigNumber(_Entry e) =>
    e.kind == RewardKind.cash ? '${_num(e.rate)}%' : '${_num(e.rate)}x';

String _valueLine(_Entry e) => switch (e.kind) {
  RewardKind.cash => '${_num(e.eff)}¢ back per \$1',
  RewardKind.points => '≈ ${_num(e.eff)}¢ back per \$1',
  RewardKind.other => 'Value unknown',
};

/// The issuer's wording in quotes, led by the rate when the wording itself
/// carries no number ("3x · “at Canadian Tire…”").
String _otherWording(_Entry e) {
  final w = e.wording?.trim() ?? '';
  if (w.isEmpty) return '${_num(e.rate)}x';
  final quoted = '“$w”';
  return w.contains(RegExp(r'\d')) ? quoted : '${_num(e.rate)}x · $quoted';
}
