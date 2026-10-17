import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/card.dart';
import '../../providers/data_providers.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/card_art_thumb.dart';
import 'profile_ui.dart';

/// Wireframes `gC3uf` / `WnEia` — which card wins when two earn the same.
class CardPreferencePage extends ConsumerWidget {
  const CardPreferencePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    final order = ref.watch(cardPreferenceOrderProvider).value ?? const [];
    final ordered = orderCards(cards, order);

    if (cards.length < 2) {
      return SettingsPage(
        title: 'Card preference',
        children: [
          const SizedBox(height: 96),
          Center(
            child: Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.secondary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                LucideIcons.listOrdered,
                size: 26,
                color: palette.muted,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Nothing to break a tie yet',
            textAlign: TextAlign.center,
            style: AppText.titleMd(),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Once you have two or more cards, you can pick which one we '
              'suggest when they earn the same. Add cards from the Cards tab.',
              textAlign: TextAlign.center,
              style: rowSubtitleStyle(palette),
            ),
          ),
        ],
      );
    }

    return SettingsPage(
      title: 'Card preference',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kRowInset, 0, kRowInset, 24),
          child: Text(
            'When two cards earn the same reward, we suggest the one higher on '
            'this list.',
            style: AppText.bodyMd().copyWith(height: 1.4),
          ),
        ),
        SectionHeader(
          'Your cards',
          action: order.isEmpty ? null : 'Reset',
          onAction: () =>
              ref.read(cardPreferenceOrderProvider.notifier).set(const []),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(kGroupRadius),
          child: ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: ordered.length,
            proxyDecorator: (child, _, _) => Material(
              color: palette.secondary,
              borderRadius: BorderRadius.circular(kGroupRadius),
              elevation: 6,
              child: child,
            ),
            onReorderItem: (oldIndex, newIndex) async {
              // `onReorderItem` pre-adjusts `newIndex` for the removed item.
              final next = [...ordered];
              next.insert(newIndex, next.removeAt(oldIndex));
              await ref
                  .read(cardPreferenceOrderProvider.notifier)
                  .set(next.map((c) => c.cardId).toList());
            },
            itemBuilder: (context, i) => _OrderRow(
              key: ValueKey(ordered[i].cardId),
              index: i,
              card: ordered[i],
              last: i == ordered.length - 1,
            ),
          ),
        ),
        GroupCaption(
          order.isEmpty
              ? 'Hold and drag a card to move it. Until you do, ties go Z→A.'
              : 'Hold and drag a card to move it.',
        ),
      ],
    );
  }
}

/// [cards] in the saved tie-break [order]; cards the order doesn't name keep
/// their original position after it.
List<CardSummary> orderCards(List<CardSummary> cards, List<String> order) {
  if (order.isEmpty) return cards;
  final byId = {for (final c in cards) c.cardId: c};
  final out = <CardSummary>[];
  final seen = <String>{};
  for (final id in order) {
    final c = byId[id];
    if (c != null && seen.add(id)) out.add(c);
  }
  return [...out, ...cards.where((c) => !seen.contains(c.cardId))];
}

/// The main-screen value: "Sapphire Preferred first", "Needs 2 cards", or
/// null while no order is saved.
String cardPreferenceSummary(List<CardSummary> cards, List<String> order) {
  if (cards.length < 2) return 'Needs 2 cards';
  if (order.isEmpty) return 'Not set';
  return '${orderCards(cards, order).first.displayName} first';
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({
    super.key,
    required this.index,
    required this.card,
    required this.last,
  });

  final int index;
  final CardSummary card;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      color: AppColors.card,
      foregroundDecoration: last
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: palette.border)),
            ),
      child: SettingsRow(
        iconTile: CardArtThumb(card: card, width: kIconSlot, height: 21),
        title: card.displayName,
        subtitle: card.lastFour == null ? null : '•• ${card.lastFour}',
        trailing: ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              LucideIcons.gripVertical,
              size: 20,
              color: palette.muted,
            ),
          ),
        ),
      ),
    );
  }
}
