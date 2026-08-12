import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../api/settings_repository.dart';
import '../theme/app_theme.dart';

enum ShellTab { transactions, cards, advisor, profile }

/// The tabs this user has, in bar order.
///
/// Without Pro, Transactions is absent: it reads the
/// `transactions` table, which only bank sync ever fills, so they would be
/// permanently empty rather than merely unpopulated.
///
/// A function of entitlement rather than a constant, because entitlement is a
/// property of the user and can change mid-session the moment a subscription
/// completes. This is the single source of truth for tab ordering —
/// `HomeScreen` indexes its `IndexedStack` by position in this list, so the two
/// must agree. The order is stable across tiers: Pro inserts its two tabs, it
/// doesn't reshuffle the rest.
List<ShellTab> shellTabs(bool isPro) => isPro
    ? const [
        ShellTab.transactions,
        ShellTab.cards,
        ShellTab.advisor,
        ShellTab.profile,
      ]
    : const [ShellTab.cards, ShellTab.advisor, ShellTab.profile];

/// The tab a saved "default screen" preference names. Lives here rather than
/// in the screen so the Profile picker and the shell agree on the mapping —
/// the picker uses it to hide options this build can't honour.
ShellTab shellTabForDefaultScreen(DefaultScreen s) => switch (s) {
  DefaultScreen.transactions => ShellTab.transactions,
  DefaultScreen.cards => ShellTab.cards,
  DefaultScreen.advisor => ShellTab.advisor,
  DefaultScreen.profile => ShellTab.profile,
};

/// The preference this user can actually be shown.
///
/// The shipped default is `transactions`, which a non-Pro user has no tab for —
/// so the stored value and the observable behaviour disagree, and the Profile
/// row would otherwise claim the app opens on a tab that isn't in the tab bar.
/// Resolving for display keeps the setting honest without rewriting the stored
/// preference, which must survive so it comes back if the user subscribes.
DefaultScreen effectiveDefaultScreen(DefaultScreen s, {required bool isPro}) =>
    shellTabs(isPro).contains(shellTabForDefaultScreen(s))
    ? s
    : DefaultScreen.advisor;

/// Floating capsule tab bar that lives over the IndexedStack body. Visual
/// contract matches the wireframe's `kr0AR` component - 56pt capsule, semi
/// transparent dark fill, primary-tinted pill on the active segment with
/// black foreground on top of the orange.
class AppTabBar extends StatelessWidget {
  const AppTabBar({
    super.key,
    required this.tabs,
    required this.active,
    required this.onTap,
  });

  /// From [shellTabs] — passed in rather than read here so the bar and the
  /// `IndexedStack` it drives can never disagree about which tabs exist.
  final List<ShellTab> tabs;
  final ShellTab active;
  final ValueChanged<ShellTab> onTap;

  static const _labels = <ShellTab, (IconData, String)>{
    ShellTab.transactions: (LucideIcons.receiptText, 'Transactions'),
    ShellTab.cards: (LucideIcons.creditCard, 'Cards'),
    ShellTab.advisor: (LucideIcons.lightbulb, 'Advisor'),
    ShellTab.profile: (LucideIcons.user, 'Profile'),
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        12 + MediaQuery.of(context).padding.bottom * 0.0,
      ),
      child: Container(
        height: 56,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xCC1A1A1A),
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 16,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (final tab in tabs)
              Expanded(
                child: _Segment(
                  active: tab == active,
                  icon: _labels[tab]!.$1,
                  label: _labels[tab]!.$2,
                  onTap: () => onTap(tab),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.active,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool active;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.onPrimary : AppColors.mutedFg;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: AppText.bodySm(color: color).copyWith(
                fontSize: 10,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
