import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../nearby/geofence_channel.dart';
import '../theme/app_theme.dart';
import '../util/category_icons.dart';
import 'reward_ranking_sheet.dart';

/// Wireframe `H0wTB` - Shown when a clustered geofence fires (e.g. a strip
/// mall) and we can't tell which merchant the user actually walked into.
/// First (closest) option is highlighted green.
Future<void> showDisambiguationSheet(
  BuildContext context, {
  required List<PendingMerchantOption> options,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _DisambiguationSheet(options: options),
  );
}

class _DisambiguationSheet extends StatelessWidget {
  const _DisambiguationSheet({required this.options});
  final List<PendingMerchantOption> options;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final mediaH = MediaQuery.of(context).size.height;
    return Container(
      constraints: BoxConstraints(maxHeight: mediaH * 0.7, minHeight: 200),
      decoration: const BoxDecoration(
        color: AppColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusM)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
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
          Text('You may be at one of these', style: AppText.titleLg()),
          const SizedBox(height: 4),
          Text(
            'Closest first - tap the store you went to',
            style: AppText.bodySm(),
          ),
          const SizedBox(height: 18),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: options.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) =>
                  _OptionRow(option: options[i], highlighted: i == 0),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option, required this.highlighted});

  final PendingMerchantOption option;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final hl = highlighted;
    final bg = hl ? palette.green : palette.secondary;
    final fg = hl ? Colors.white : AppColors.foreground;
    final subFg = hl ? Colors.white.withValues(alpha: 0.85) : palette.muted;
    final borderColor = hl
        ? palette.green.withValues(alpha: 0.7)
        : palette.border;
    final iconBg = hl
        ? Colors.white.withValues(alpha: 0.15)
        : palette.secondary;
    final iconFg = hl ? Colors.white : AppColors.foreground;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(kRadiusM),
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadiusM),
        onTap: () {
          final cat = option.category;
          Navigator.of(context).pop();
          if (cat == null || cat.isEmpty) return;
          showRewardRankingSheetForLabel(
            context,
            label: cat,
            primary: RewardRankingPrimary.brand,
            merchantName: option.name,
          );
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(kRadiusM),
            border: Border.all(color: borderColor, width: hl ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  iconForCategory(option.category),
                  size: 18,
                  color: iconFg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      option.name,
                      style: AppText.titleMd(color: fg).copyWith(fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(option),
                      style: AppText.bodySm(
                        color: subFg,
                      ).copyWith(fontWeight: FontWeight.w500, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronRight, size: 18, color: subFg),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(PendingMerchantOption o) {
    final parts = <String>[];
    if (o.category != null && o.category!.isNotEmpty) parts.add(o.category!);
    if (o.bestCardName != null && o.bestCardName!.isNotEmpty) {
      final rate = o.bestRate;
      if (rate != null) {
        final r = rate % 1 == 0
            ? rate.toInt().toString()
            : rate.toStringAsFixed(1);
        parts.add('Best: ${o.bestCardName} · $r%');
      } else {
        parts.add('Best: ${o.bestCardName}');
      }
    }
    return parts.join(' · ');
  }
}
