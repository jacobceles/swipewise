import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/catalog_repository.dart';
import '../api/reward_engine.dart';
import '../models/card.dart';
import '../models/reward_category.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/async_action_button.dart';

/// N17: full-screen bonus-category picker, pushed from the Cards screen's
/// Rewards tab. A card may carry more than one independent selection group
/// (U.S. Bank Cash+ has two) — each renders as its own section with its own
/// "chosen" count, and Save writes each group separately so answering one
/// never bleeds into the other (`setBonusSelection` is scoped per group).
///
/// Pops `true` on a successful save so the caller (the Rewards tab's tap
/// handler, `_openBonusPicker` in `cards_screen.dart`) invalidates
/// `bonusSelectionsProvider` and confirms — mirrors `_editLimit`'s
/// pop-a-bool-then-react pattern rather than reaching back into providers
/// after this screen is already gone.
class BonusCategoryPickerScreen extends ConsumerStatefulWidget {
  const BonusCategoryPickerScreen({super.key, required this.cardId});
  final String cardId;

  @override
  ConsumerState<BonusCategoryPickerScreen> createState() =>
      _BonusCategoryPickerScreenState();
}

class _BonusCategoryPickerScreenState
    extends ConsumerState<BonusCategoryPickerScreen> {
  // group_id -> the categories currently picked for it, oldest first. A List
  // rather than a Set so hitting the `choose` cap can evict the oldest pick
  // instead of just refusing the tap — see `_toggle`.
  final Map<String, List<RewardCategory>> _selections = {};
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);

    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    CardSummary? foundCard;
    for (final c in cards) {
      if (c.cardId == widget.cardId) {
        foundCard = c;
        break;
      }
    }
    final links = ref.watch(cardLinksProvider).value ?? const <LinkedCard>[];
    String? foundProductId;
    for (final l in links) {
      if (l.cardId == widget.cardId) {
        foundProductId = l.cardProductId;
        break;
      }
    }
    final snapshot = ref.watch(catalogSnapshotProvider).value;
    final chosenAsync = ref.watch(bonusSelectionsProvider);
    final groupsAsync = foundProductId == null
        ? null
        : ref.watch(bonusSelectionGroupsProvider(foundProductId));

    if (foundCard == null ||
        foundProductId == null ||
        snapshot == null ||
        !chosenAsync.hasValue ||
        groupsAsync == null ||
        !groupsAsync.hasValue) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: _appBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final card = foundCard;
    final productId = foundProductId;
    final chosen = chosenAsync.value!;
    final rules = snapshot.rulesByProduct[productId] ?? const <RewardRule>[];

    final sections = <_GroupSection>[];
    for (final g in groupsAsync.value!) {
      final members = rules
          .where((r) => r.selectionGroup == g.groupId)
          .toList();
      // Defensive: a group whose member rules didn't come through (shouldn't
      // happen with a sound catalog) has nothing to offer, so it's skipped
      // rather than shown with no rate and no options.
      if (members.isEmpty) continue;
      // The issuer picks these from actual spend, so offering a choice would
      // contradict the card-detail row, which already reads "Chosen for you
      // each month". No card carries both modes today, but nothing stops one.
      if (g.mode != BonusSelectionMode.userChoice) continue;
      final categories = [
        for (final r in members)
          if (r.category != null) r.category!,
      ]..sort((a, b) => a.label.compareTo(b.label));
      if (!_seeded) {
        _selections[g.groupId] = (chosen[g.groupId] ?? const <RewardCategory>{})
            .toList();
      }
      sections.add(
        _GroupSection(
          group: g,
          rate: members.first.rate,
          currency:
              snapshot
                  .pointSystems[members.first.pointSystemId]
                  ?.currencyLabel ??
              'USD',
          categories: categories,
        ),
      );
    }
    _seeded = true;

    final product = snapshot.products[productId];
    final issuer = product == null ? '' : issuerDisplayName(product.issuer);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _appBar(),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(card.displayName, style: AppText.titleLg()),
              const SizedBox(height: 2),
              Text(
                '$issuer · choose where this card earns its bonus',
                style: AppText.bodySm(color: palette.muted),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView(
                  children: [
                    for (final s in sections) ...[
                      _GroupSectionView(
                        section: s,
                        selected: _selections[s.group.groupId] ?? const [],
                        onToggle: (cat) => _toggle(s.group, cat),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ],
                ),
              ),
              Text(
                'Applies from your next statement.',
                style: AppText.bodySm(color: palette.muted),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: AsyncActionButton(
                  onPressed: sections.isEmpty
                      ? null
                      : () => _save(sections, productId),
                  child: Text(
                    sections.length > 1 ? 'Save selections' : 'Save selection',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggle(BonusSelectionGroup group, RewardCategory category) {
    setState(() {
      final list = List<RewardCategory>.from(
        _selections[group.groupId] ?? const [],
      );
      if (list.contains(category)) {
        list.remove(category);
      } else {
        // At the cap: replace the oldest pick rather than refusing the tap.
        // For `choose == 1` (the common case) that's just normal
        // single-select radio behaviour; for `choose > 1` it means the user
        // can keep tapping to try combinations without ever hitting a tap
        // that silently does nothing.
        if (list.length >= group.choose && list.isNotEmpty) {
          list.removeAt(0);
        }
        list.add(category);
      }
      _selections[group.groupId] = list;
    });
  }

  Future<void> _save(List<_GroupSection> sections, String productId) async {
    final repo = ref.read(dataRepositoryProvider).catalog;
    for (final s in sections) {
      await repo.setBonusSelection(
        groupId: s.group.groupId,
        cardProductId: productId,
        categories: _selections[s.group.groupId] ?? const [],
      );
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  AppBar _appBar() => AppBar(
    leading: IconButton(
      icon: const Icon(LucideIcons.chevronLeft, size: 24),
      onPressed: () => Navigator.of(context).maybePop(),
    ),
    title: Text('Bonus categories', style: AppText.titleLg()),
  );
}

/// One group's picker-screen display data: the group itself plus the rate
/// and candidate category list read off its member reward rules (a
/// `BonusSelectionGroup` carries neither — see `selectionGroupsForProduct`'s
/// doc in `catalog_repository.dart`).
class _GroupSection {
  const _GroupSection({
    required this.group,
    required this.rate,
    required this.currency,
    required this.categories,
  });
  final BonusSelectionGroup group;
  final double rate;
  final String currency;
  final List<RewardCategory> categories;
}

class _GroupSectionView extends StatelessWidget {
  const _GroupSectionView({
    required this.section,
    required this.selected,
    required this.onToggle,
  });
  final _GroupSection section;
  final List<RewardCategory> selected;
  final void Function(RewardCategory) onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final group = section.group;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _headerRateText(section.rate, section.currency),
                    style: AppText.titleMd(),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Pick ${group.choose} of ${section.categories.length} '
                    '· ${_resetPhrase(group.period)}',
                    style: AppText.bodySm(color: palette.muted),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: palette.greenBg,
                borderRadius: BorderRadius.circular(kRadiusPill),
              ),
              child: Text(
                '${selected.length} of ${group.choose} chosen',
                style: AppText.labelSm(color: palette.green),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final c in section.categories) ...[
          _OptionRow(
            category: c,
            selected: selected.contains(c),
            onTap: () => onToggle(c),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.category,
    required this.selected,
    required this.onTap,
  });
  final RewardCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusM),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF241703) : AppColors.card,
          border: Border.all(
            color: selected ? AppColors.primary : palette.border,
          ),
          borderRadius: BorderRadius.circular(kRadiusM),
        ),
        child: Row(
          children: [
            Icon(
              category.icon,
              size: 18,
              color: selected ? AppColors.primary : palette.muted,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(category.label, style: AppText.bodyMd())),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.primary : Colors.transparent,
                border: Border.all(
                  color: selected ? AppColors.primary : palette.border,
                  width: 2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "3%" for a USD (cash back) rule, "3x" for a points/miles one.
String _rateText(double rate, String currency) {
  final n = rate.truncateToDouble() == rate
      ? rate.toStringAsFixed(0)
      : rate.toStringAsFixed(1);
  return currency == 'USD' ? '$n%' : '${n}x';
}

/// "5% cash back" / "3x miles" — the group section header.
String _headerRateText(double rate, String currency) {
  final r = _rateText(rate, currency);
  return currency == 'USD' ? '$r cash back' : '$r ${currency.toLowerCase()}';
}

/// A quarter/year group genuinely resets on that cadence; a monthly group
/// (BoA Customized Cash) can be changed on demand rather than on a fixed
/// reset, hence "change anytime" for `month` and the unset `null`.
String _resetPhrase(String? period) => switch (period) {
  'quarter' => 'resets each quarter',
  'year' => 'resets each year',
  _ => 'change anytime',
};
