import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/settings_repository.dart';
import '../providers/entitlement_provider.dart';
import '../nearby/geofence_channel.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/app_tab_bar.dart';
import 'card_preference_screen.dart';
import 'notification_settings_screen.dart';
import 'muted_stores_screen.dart';
import 'privacy_policy_screen.dart';
import 'subscriptions_screen.dart';

/// Wireframe `YUfiL` - Profile tab. Hero block with initials avatar +
/// identifier, then a flat list of settings rows in the spec-defined order.
/// No theme switcher (single dark theme commitment).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  String _initials(String? identifier) {
    if (identifier == null || identifier.isEmpty) return 'U';
    final local = identifier.contains('@')
        ? identifier.split('@').first
        : identifier;
    final parts = local.split(RegExp(r'[._\-+ ]'));
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return local.substring(0, local.length >= 2 ? 2 : 1).toUpperCase();
  }

  Future<void> _pickDefaultScreen() async {
    final isPro = ref.read(proEntitlementProvider);
    final current = effectiveDefaultScreen(
      ref.read(defaultScreenProvider),
      isPro: isPro,
    );
    final picked = await _showPicker<DefaultScreen>(
      title: 'Default Screen',
      subtitle: 'Pick which tab opens when you launch the app',
      // Only tabs this build has — offering Transactions in free would let the
      // user save a preference that silently resolves back to Advisor.
      options: DefaultScreen.values
          .where((s) => shellTabs(isPro).contains(shellTabForDefaultScreen(s)))
          .toList(),
      current: current,
      labelOf: defaultScreenLabel,
    );
    if (picked != null) {
      await ref.read(defaultScreenProvider.notifier).set(picked);
    }
  }

  Future<void> _pickDefaultAdvisorView() async {
    final current = ref.read(advisorViewProvider);
    final picked = await _showPicker<AdvisorView>(
      title: 'Default Advisor View',
      subtitle: 'Pick which Advisor view opens by default',
      options: AdvisorView.values,
      current: current,
      labelOf: advisorViewLabel,
    );
    if (picked != null) {
      await ref.read(advisorViewProvider.notifier).set(picked);
    }
  }

  Future<void> _pickNearbyRadius() async {
    final current = ref.read(nearbyRadiusProvider);
    final picked = await _showPicker<int>(
      title: 'Search Radius',
      subtitle: 'How far Stores looks for nearby merchants',
      options: const [5, 10, 25],
      current: current,
      labelOf: (m) => '$m miles',
    );
    if (picked != null) {
      await ref.read(nearbyRadiusProvider.notifier).set(picked);
    }
  }

  Future<void> _checkForUpdates() async {
    final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=com.appsoflife.swipewise',
    );
    // externalApplication so Android routes the play.google.com link to the
    // Play Store app (in-app webview would show the web listing instead).
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open the Play Store")),
      );
    }
  }

  Future<void> _fireTestNotification() async {
    if (!mounted) return;
    try {
      await GeofenceChannel.fireTestNotification();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fake notification fired - pull down to find it'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _fireTestClusterNotification() async {
    if (!mounted) return;
    try {
      await GeofenceChannel.fireTestNotification(
        options: const [
          PendingMerchantOption(
            merchantId: 'test-cluster-1',
            name: 'Five Guys',
            category: 'Dining',
            bestCardName: 'Chase Sapphire Preferred',
            bestRate: 3.0,
          ),
          PendingMerchantOption(
            merchantId: 'test-cluster-2',
            name: 'Sephora',
            category: 'Shopping',
            bestCardName: 'Citi Custom Cash',
            bestRate: 5.0,
          ),
          PendingMerchantOption(
            merchantId: 'test-cluster-3',
            name: "Kohl's",
            category: 'Shopping',
            bestCardName: 'Citi Custom Cash',
            bestRate: 5.0,
          ),
          PendingMerchantOption(
            merchantId: 'test-cluster-4',
            name: 'JCPenney',
            category: 'Shopping',
            bestCardName: 'Citi Custom Cash',
            bestRate: 5.0,
          ),
        ],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fake cluster notification fired - pull down'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _openDwellEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.sheet,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _DwellEditorSheet(),
    );
  }

  Future<T?> _showPicker<T>({
    required String title,
    required String subtitle,
    required List<T> options,
    required T current,
    required String Function(T) labelOf,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.sheet,
      builder: (ctx) => SafeArea(
        child: Padding(
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
                    color: AppPalette.of(ctx).muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(title, style: AppText.titleLg()),
              const SizedBox(height: 4),
              Text(subtitle, style: AppText.bodySm()),
              const SizedBox(height: 12),
              for (final opt in options)
                _PickerRow(
                  label: labelOf(opt),
                  selected: opt == current,
                  onTap: () => Navigator.pop(ctx, opt),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isPro = ref.watch(proEntitlementProvider);
    final auth = ref.watch(authProvider);
    // Signed in means "has a Google identity", which is independent of Pro:
    // anyone can sign in, and a subscriber who skipped it has not. The email
    // is the marker — `isLoggedIn` is true even for the device-local identity.
    final signedIn = auth.email != null;
    final defaultScreen = ref.watch(defaultScreenProvider);
    final advisorView = ref.watch(advisorViewProvider);
    final nearbyRadius = ref.watch(nearbyRadiusProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Profile',
                    style: AppText.displayLg().copyWith(fontSize: 28),
                  ),
                  // Offered to anyone holding a Google identity, not just
                  // Pro. Safe to tap now that `logout()` re-keys onto a local
                  // id instead of deleting the `users` row — it used to
                  // cascade through every user-scoped table and wipe the
                  // wallet.
                  if (signedIn)
                    GestureDetector(
                      onTap: () => ref.read(authProvider.notifier).logout(),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: palette.secondary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(LucideIcons.logOut, size: 18),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
                children: [
                  if (signedIn)
                    Center(
                      child: Column(
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                            // Initials come from a Google account name, which
                            // a signed-out user doesn't have — their
                            // identifier is the literal "You", so `_initials`
                            // rendered "YO" above the word "You".
                            child: Text(
                              _initials(auth.identifier),
                              style: AppText.displayLg(
                                color: AppColors.onPrimary,
                              ).copyWith(fontSize: 28),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            auth.identifier ?? '-',
                            style: AppText.bodyMd(color: palette.muted),
                          ),
                        ],
                      ),
                    )
                  else
                    const _SignInCard(),
                  const SizedBox(height: 28),
                  _SettingsRow(
                    label: 'Default Screen',
                    trailing: _ValueChevron(
                      value: defaultScreenLabel(
                        effectiveDefaultScreen(defaultScreen, isPro: isPro),
                      ),
                    ),
                    onTap: _pickDefaultScreen,
                  ),
                  _SettingsRow(
                    label: 'Default Advisor View',
                    trailing: _ValueChevron(
                      value: advisorViewLabel(advisorView),
                    ),
                    onTap: _pickDefaultAdvisorView,
                  ),
                  _SettingsRow(
                    label: 'Notifications',
                    trailing: const _Chevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const NotificationSettingsScreen(),
                      ),
                    ),
                  ),
                  _SettingsRow(
                    label: 'Preferred Card Order',
                    trailing: const _Chevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CardPreferenceScreen(),
                      ),
                    ),
                  ),
                  _SettingsRow(
                    label: 'Search Radius',
                    trailing: _ValueChevron(value: '$nearbyRadius mi'),
                    onTap: _pickNearbyRadius,
                  ),
                  _SettingsRow(
                    label: 'Alert Wait Time',
                    trailing: _ValueChevron(
                      value: _dwellSummary(ref.watch(nearbyDwellProvider)),
                    ),
                    onTap: _openDwellEditor,
                  ),
                  _SettingsRow(
                    label: 'Muted Stores',
                    trailing: const _Chevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const MutedStoresScreen(),
                      ),
                    ),
                  ),
                  // Both are bank-sync features: Recurring Transactions reads
                  // the `transactions` table, and the debit toggle triggers a
                  // sync. Gated on construction so `SubscriptionsScreen`
                  // leaves the free binary along with the rest of that path.
                  if (isPro) ...[
                    _SettingsRow(
                      label: 'Recurring Transactions',
                      trailing: const _Chevron(),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SubscriptionsScreen(),
                        ),
                      ),
                    ),
                    _IncludeDebitAccountsRow(
                      enabled: ref.watch(includeDebitAccountsProvider),
                      onChanged: (v) => ref
                          .read(includeDebitAccountsProvider.notifier)
                          .setEnabled(v),
                    ),
                  ],
                  _SettingsRow(
                    label: 'Privacy Policy',
                    trailing: const _Chevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PrivacyPolicyScreen(),
                      ),
                    ),
                  ),
                  _SettingsRow(
                    label: 'Check for Updates',
                    trailing: const _Chevron(),
                    onTap: _checkForUpdates,
                  ),
                  if (kDebugMode) ...[
                    _SettingsRow(
                      label: 'Fire Test Notification (debug)',
                      trailing: Icon(
                        LucideIcons.bug,
                        size: 16,
                        color: palette.muted,
                      ),
                      onTap: _fireTestNotification,
                    ),
                    _SettingsRow(
                      label: 'Fire Test Cluster Notification (debug)',
                      trailing: Icon(
                        LucideIcons.bug,
                        size: 16,
                        color: palette.muted,
                      ),
                      onTap: _fireTestClusterNotification,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _dwellSummary(Map<String, int> dwell) {
  final defaults = SettingsRepository.defaultDwellSeconds;
  for (final e in dwell.entries) {
    if (defaults[e.key] != e.value) return 'Custom';
  }
  return 'Default';
}

/// Sign-in entry for anyone who skipped the welcome screen.
///
/// Signs in in place rather than navigating back to the welcome screen: that
/// screen is first-run framing built around a choice this user already made,
/// and returning them to it would read as starting over. The promise here is
/// the same one the welcome screen makes, and just as hedged — neither backup
/// nor cross-device Pro exists yet.
class _SignInCard extends ConsumerWidget {
  const _SignInCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final auth = ref.watch(authProvider);
    final error = auth.error;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                LucideIcons.user,
                size: 20,
                color: AppColors.primary,
              ),
              const SizedBox(width: 10),
              Text("You're not signed in", style: AppText.titleMd()),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Your cards live on this device and nothing is uploaded. Signing '
            'in readies the account for backup and cross-device Pro — both '
            'coming soon, and backup will be opt-in.',
            style: AppText.bodySm(color: palette.muted),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error, style: AppText.bodySm(color: palette.red)),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: auth.isLoading
                  ? null
                  : () => ref.read(authProvider.notifier).signInWithGoogle(),
              child: auth.isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.onPrimary,
                      ),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.login, size: 18),
                        SizedBox(width: 10),
                        Text('Continue with Google'),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DwellEditorSheet extends ConsumerWidget {
  const _DwellEditorSheet();

  static const List<int> _options = [60, 120, 180, 300, 480, 600, 900];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final dwell = ref.watch(nearbyDwellProvider);
    final categories = SettingsRepository.defaultDwellSeconds.keys.toList();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
            Text('Alert Wait Time', style: AppText.titleLg()),
            const SizedBox(height: 4),
            Text(
              'How long you need to linger near a place before we send an alert',
              style: AppText.bodySm(),
            ),
            const SizedBox(height: 12),
            for (final cat in categories)
              InkWell(
                onTap: () => _pickFor(context, ref, cat, dwell[cat] ?? 300),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: palette.border)),
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text(cat, style: AppText.bodyMd())),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: palette.secondary,
                          borderRadius: BorderRadius.circular(kRadiusPill),
                        ),
                        child: Text(
                          _formatSeconds(dwell[cat] ?? 300),
                          style: AppText.monoXs().copyWith(
                            fontSize: 12,
                            color: AppColors.foreground,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        LucideIcons.chevronRight,
                        size: 16,
                        color: palette.muted,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFor(
    BuildContext context,
    WidgetRef ref,
    String category,
    int current,
  ) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.sheet,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
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
                    color: AppPalette.of(ctx).muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(category, style: AppText.titleLg()),
              const SizedBox(height: 4),
              Text(
                'How long to wait near a $category place before alerting you',
                style: AppText.bodySm(),
              ),
              const SizedBox(height: 12),
              for (final s in _options)
                _PickerRow(
                  label: _formatSeconds(s),
                  selected: s == current,
                  onTap: () => Navigator.pop(ctx, s),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != current) {
      await ref.read(nearbyDwellProvider.notifier).setSeconds(category, picked);
    }
  }

  static String _formatSeconds(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final r = s % 60;
    if (r == 0) return '$m min';
    return '${m}m ${r}s';
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
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
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(kRadiusS),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style:
                    AppText.bodyMd(
                      color: selected
                          ? AppColors.primary
                          : AppColors.foreground,
                    ).copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
              ),
            ),
            Icon(
              selected ? LucideIcons.circleCheck : LucideIcons.circle,
              color: selected ? AppColors.primary : palette.muted,
              size: 20,
            ),
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.trailing, this.onTap});

  final String label;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.border)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppText.bodyMd().copyWith(fontSize: 16)),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// Two-line settings row: label + toggle on the top line, explainer
/// sub-copy underneath. Different shape from the rest of the list because
/// the consequence of flipping this setting is non-obvious - users need
/// the explainer to understand it affects every screen.
class _IncludeDebitAccountsRow extends StatelessWidget {
  const _IncludeDebitAccountsRow({
    required this.enabled,
    required this.onChanged,
  });
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Include Debit Accounts',
                  style: AppText.bodyMd().copyWith(fontSize: 16),
                ),
              ),
              Switch.adaptive(value: enabled, onChanged: onChanged),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Only credit cards are tracked by default. Enable to include '
            'checking & savings across transactions, breakdowns, and totals.',
            style: AppText.bodySm(color: palette.muted),
          ),
        ],
      ),
    );
  }
}

class _ValueChevron extends StatelessWidget {
  const _ValueChevron({required this.value});
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: AppText.bodySm()),
        const SizedBox(width: 6),
        Icon(LucideIcons.chevronRight, size: 16, color: palette.muted),
      ],
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) {
    return Icon(
      LucideIcons.chevronRight,
      size: 16,
      color: AppPalette.of(context).muted,
    );
  }
}
