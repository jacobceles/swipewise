import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../providers/entitlement_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/app_tab_bar.dart';
import 'profile_ui.dart';

/// Wireframe `uh6l1` — the tab the app opens on, and the view Advisor opens on.
class DefaultTabsPage extends ConsumerWidget {
  const DefaultTabsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(proEntitlementProvider);
    // Only tabs this build has — offering Transactions without it would save a
    // preference that silently resolves back to Advisor.
    final screens = DefaultScreen.values
        .where((s) => shellTabs(isPro).contains(shellTabForDefaultScreen(s)))
        .toList();

    return SettingsPage(
      title: 'Default tabs',
      children: [
        const SectionHeader('When you open the app'),
        SegmentedChoice<DefaultScreen>(
          options: screens,
          selected: effectiveDefaultScreen(
            ref.watch(defaultScreenProvider),
            isPro: isPro,
          ),
          labelOf: defaultScreenLabel,
          onChanged: (s) => ref.read(defaultScreenProvider.notifier).set(s),
        ),
        const SizedBox(height: kGroupGap),
        const SectionHeader('When you open Advisor'),
        SegmentedChoice<AdvisorView>(
          options: AdvisorView.values,
          selected: ref.watch(advisorViewProvider),
          labelOf: advisorViewLabel,
          onChanged: (v) => ref.read(advisorViewProvider.notifier).set(v),
        ),
        const GroupCaption('The tab and view you land on each time.'),
      ],
    );
  }
}

/// The main-screen value: "Cards · Stores".
String defaultTabsSummary(WidgetRef ref) {
  final isPro = ref.watch(proEntitlementProvider);
  final screen = effectiveDefaultScreen(
    ref.watch(defaultScreenProvider),
    isPro: isPro,
  );
  return '${defaultScreenLabel(screen)} · '
      '${advisorViewLabel(ref.watch(advisorViewProvider))}';
}
