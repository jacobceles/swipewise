import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
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

class _RewardRankingSheet extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final rankingAsync = ref.watch(
      rewardRankingProvider((
        category: category,
        merchantName: merchantName,
        brandId: brandId,
      )),
    );
    final mediaH = MediaQuery.of(context).size.height;

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
            'Best Cards for ${merchantName ?? category.label}',
            style: AppText.titleLg(),
          ),
          const SizedBox(height: 4),
          Text(
            merchantName != null ? category.label : 'Ranked by reward rate',
            style: AppText.bodySm(),
          ),
          const SizedBox(height: 20),
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
                // Brand-first mode is only meaningful when *this* merchant
                // actually matches one of the brand bonuses. Otherwise the
                // top row would be a brand bonus for an unrelated merchant
                // and the Stores list's "Best:" (general fallback) would
                // disagree with the sheet's headline.
                final hasMatchedBrand = result.brandBonuses.any(
                  (b) => b.isMatchedBrand,
                );
                final brandPrimary =
                    primary == RewardRankingPrimary.brand && hasMatchedBrand;
                final generalSection = _GeneralSection(
                  rows: result.general,
                  suppressBest: brandPrimary,
                );
                final brandSection = result.brandBonuses.isEmpty
                    ? null
                    : _BrandSection(
                        rows: result.brandBonuses,
                        primaryHighlight: brandPrimary,
                      );
                final sections = <Widget>[];
                if (brandPrimary && brandSection != null) {
                  sections.add(brandSection);
                  sections.add(const SizedBox(height: 20));
                  sections.add(generalSection);
                } else {
                  sections.add(generalSection);
                  if (brandSection != null) {
                    sections.add(const SizedBox(height: 20));
                    sections.add(brandSection);
                  }
                }
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: sections,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GeneralSection extends StatelessWidget {
  const _GeneralSection({required this.rows, this.suppressBest = false});
  final List<CategoryRewardRanking> rows;
  final bool suppressBest;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(title: 'General ranking'),
        const SizedBox(height: 8),
        for (final r in rows)
          _RankRow(item: r, highlightBest: !suppressBest && r.isBest),
      ],
    );
  }
}

class _BrandSection extends StatelessWidget {
  const _BrandSection({required this.rows, this.primaryHighlight = false});
  final List<BrandBonusRow> rows;
  final bool primaryHighlight;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(
          title: 'Brand bonuses',
          icon: LucideIcons.sparkles,
        ),
        const SizedBox(height: 8),
        for (final r in rows)
          _BrandRow(
            item: r,
            primaryHighlight: primaryHighlight && r.isMatchedBrand,
          ),
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

class _RankRow extends StatelessWidget {
  const _RankRow({required this.item, required this.highlightBest});
  final CategoryRewardRanking item;
  final bool highlightBest;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusS + 2),
        border: Border.all(
          color: highlightBest ? palette.green : palette.border,
          width: highlightBest ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          _CardArt(image: item.cardImage, name: item.cardName ?? ''),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.cardName ?? 'Card',
                  style: AppText.titleMd().copyWith(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '•••• ${item.lastFour ?? '----'}',
                  style: AppText.monoXs(),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatRate(item.rate, item.currency),
                style: AppText.monoMd(
                  color: highlightBest ? palette.green : AppColors.foreground,
                ).copyWith(fontWeight: FontWeight.w700, fontSize: 18),
              ),
              const SizedBox(height: 2),
              Text(
                '${NumberFormat.simpleCurrency().format(item.earnedRecently)} earned recently',
                style: AppText.bodySm().copyWith(fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  const _BrandRow({required this.item, required this.primaryHighlight});
  final BrandBonusRow item;
  final bool primaryHighlight;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final Color borderColor;
    final double borderWidth;
    final Color rateColor;
    final Color bgColor;
    if (primaryHighlight) {
      borderColor = palette.green;
      borderWidth = 1.5;
      rateColor = palette.green;
      bgColor = palette.greenBg;
    } else if (item.isMatchedBrand) {
      borderColor = AppColors.primary;
      borderWidth = 1.5;
      rateColor = AppColors.primary;
      bgColor = AppColors.primary.withValues(alpha: 0.06);
    } else {
      borderColor = palette.border;
      borderWidth = 1;
      rateColor = palette.amber;
      bgColor = palette.secondary;
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(kRadiusS + 2),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: Row(
        children: [
          _CardArt(image: item.cardImage, name: item.cardName ?? ''),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.brand,
                  style: AppText.titleMd().copyWith(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  item.cardName ?? 'Card',
                  style: AppText.bodySm().copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatRate(item.rate, item.currency),
                style: AppText.monoMd(
                  color: rateColor,
                ).copyWith(fontWeight: FontWeight.w700, fontSize: 18),
              ),
              const SizedBox(height: 2),
              Text(
                'vs ${_formatRate(item.generalBest, item.currency)} general',
                style: AppText.bodySm().copyWith(fontSize: 10),
              ),
            ],
          ),
        ],
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

String _formatRate(double rate, String? currency) {
  final cur = (currency ?? '').toUpperCase();
  final isPoints = cur == 'POINTS' || cur == 'MILES';
  if (isPoints) {
    final s = rate % 1 == 0 ? rate.toInt().toString() : rate.toStringAsFixed(1);
    return '${s}x ${cur == 'MILES' ? 'Miles' : 'Points'}';
  }
  return '${rate.toStringAsFixed(rate % 1 == 0 ? 0 : 1)}%';
}
