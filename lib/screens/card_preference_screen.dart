import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/card.dart';
import '../providers/data_providers.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// Wireframe `NYNRZ` - Drag-reorderable list of cards used as a tiebreaker
/// when two cards earn the same rate. Header banner toggles amber/saved.
class CardPreferenceScreen extends ConsumerWidget {
  const CardPreferenceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final cardsAsync = ref.watch(cardsProvider);
    final savedOrder = ref.watch(cardPreferenceOrderProvider).value ?? const [];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.chevronLeft, size: 24),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Card preference', style: AppText.titleLg()),
      ),
      body: cardsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '$e',
              style: AppText.bodySm(color: palette.muted),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (cards) {
          if (cards.length < 2) return _EmptyState(palette: palette);
          final ordered = _applySavedOrder(cards, savedOrder);
          final hasSaved = savedOrder.isNotEmpty;
          return Column(
            children: [
              _Banner(hasSavedOrder: hasSaved),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                  itemCount: ordered.length,
                  onReorderItem: (oldIndex, newIndex) async {
                    // `onReorderItem` pre-adjusts `newIndex` for the
                    // removed item, so the index passed in is the slot
                    // the moved item should land at - no manual
                    // `newIndex > oldIndex ? newIndex - 1 : newIndex`
                    // dance.
                    final next = [...ordered];
                    final moved = next.removeAt(oldIndex);
                    next.insert(newIndex, moved);
                    await ref
                        .read(cardPreferenceOrderProvider.notifier)
                        .set(next.map((c) => c.cardId).toList());
                  },
                  itemBuilder: (context, i) => _CardRow(
                    key: ValueKey(ordered[i].cardId),
                    rank: i + 1,
                    card: ordered[i],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<CardSummary> _applySavedOrder(
    List<CardSummary> cards,
    List<String> savedOrder,
  ) {
    if (savedOrder.isEmpty) return cards;
    final byId = {for (final c in cards) c.cardId: c};
    final out = <CardSummary>[];
    final consumed = <String>{};
    for (final id in savedOrder) {
      final c = byId[id];
      if (c != null && consumed.add(id)) out.add(c);
    }
    for (final c in cards) {
      if (!consumed.contains(c.cardId)) out.add(c);
    }
    return out;
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.hasSavedOrder});
  final bool hasSavedOrder;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: hasSavedOrder ? palette.secondary : palette.amberBg,
          borderRadius: BorderRadius.circular(kRadiusM),
          border: hasSavedOrder
              ? null
              : Border.all(color: palette.amber.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasSavedOrder ? LucideIcons.circleCheck : LucideIcons.info,
                  size: 16,
                  color: hasSavedOrder ? palette.green : palette.amber,
                ),
                const SizedBox(width: 8),
                Text(
                  hasSavedOrder
                      ? 'Preference saved'
                      : 'No preference saved yet',
                  style: AppText.titleMd().copyWith(fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              hasSavedOrder
                  ? 'When two cards earn the same rate, the one higher in this list wins.'
                  : 'Drag any card to save this order. Until you do, ties resolve reverse-alphabetically (Z→A).',
              style: AppText.bodySm(),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({super.key, required this.rank, required this.card});

  final int rank;
  final CardSummary card;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(kRadiusM),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '$rank',
                textAlign: TextAlign.center,
                style: AppText.monoMd(
                  color: palette.muted,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            _CardArt(card: card),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    card.displayName,
                    style: AppText.titleMd().copyWith(fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (card.lastFour != null && card.lastFour!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('**** ${card.lastFour}', style: AppText.monoXs()),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            ReorderableDragStartListener(
              index: rank - 1,
              child: Icon(
                LucideIcons.gripVertical,
                size: 22,
                color: palette.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardArt extends StatelessWidget {
  const _CardArt({required this.card});
  final CardSummary card;

  @override
  Widget build(BuildContext context) {
    // Match the cards screen's art preference order: the seed catalog
    // image first, then the bank's logo (the only bank-specific art a
    // debit/unidentified card ever has), then the gradient fallback.
    final art = card.imageUrl?.trim().isNotEmpty == true
        ? card.imageUrl
        : (card.institutionLogo?.trim().isNotEmpty == true
              ? card.institutionLogo
              : null);
    final colors = _gradientFor(card.name);
    return Container(
      width: 44,
      height: 28,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: art != null
            ? null
            : LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
      ),
      child: art != null
          ? CachedNetworkImage(
              imageUrl: art,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: colors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            )
          : null,
    );
  }

  static List<Color> _gradientFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('platinum')) {
      return [const Color(0xFF1E293B), const Color(0xFF475569)];
    }
    if (n.contains('sapphire')) {
      return [const Color(0xFF1E3A8A), const Color(0xFF3B82F6)];
    }
    if (n.contains('gold')) {
      return [const Color(0xFF92400E), const Color(0xFFD97706)];
    }
    if (n.contains('venture') || n.contains('capital one')) {
      return [const Color(0xFF7F1D1D), const Color(0xFFDC2626)];
    }
    if (n.contains('discover')) {
      return [const Color(0xFFC2410C), const Color(0xFFFB923C)];
    }
    if (n.contains('freedom')) {
      return [const Color(0xFF2563EB), const Color(0xFF60A5FA)];
    }
    if (n.contains('costco') || n.contains('visa')) {
      return [const Color(0xFFEA580C), const Color(0xFFF97316)];
    }
    return [AppColors.primary, AppColors.primary.withValues(alpha: 0.7)];
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.secondary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                LucideIcons.creditCard,
                size: 26,
                color: palette.muted,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Add a second card to set a preference order',
              textAlign: TextAlign.center,
              style: AppText.titleMd().copyWith(fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'Tiebreakers only matter when you have two or more cards.',
              textAlign: TextAlign.center,
              style: AppText.bodySm(),
            ),
          ],
        ),
      ),
    );
  }
}
