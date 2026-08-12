import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/account_delete_client.dart';
import '../api/settings_repository.dart';
import '../providers/entitlement_provider.dart';
import '../nearby/geofence_channel.dart';
import '../providers/auth_provider.dart';
import '../providers/backup_provider.dart';
import '../sync/wallet_backup_client.dart';
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

  /// Deletes the account and everything belonging to it.
  ///
  /// Two barriers, not one: a plain confirm, then a typed word. Everything
  /// destroyed here is unrecoverable — there is no archived copy and no grace
  /// window — and a single dialog is too easy to dismiss by reflex.
  Future<void> _deleteAccount() async {
    final palette = AppPalette.of(context);
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: Text('Delete your account?', style: AppText.titleMd()),
        content: Text(
          'This permanently deletes your account, your backup, any linked '
          'bank, and everything on this phone including your transactions. '
          'It cannot be undone, and a deleted wallet cannot be restored.',
          style: AppText.bodySm(color: palette.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Continue', style: AppText.bodyMd(color: palette.red)),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;

    final typed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            backgroundColor: AppColors.sheet,
            title: Text('Type DELETE to confirm', style: AppText.titleMd()),
            content: TextField(
              controller: controller,
              autofocus: true,
              onChanged: (_) => setLocal(() {}),
              decoration: const InputDecoration(hintText: 'DELETE'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: controller.text.trim().toUpperCase() == 'DELETE'
                    ? () => Navigator.of(ctx).pop(true)
                    : null,
                child: Text(
                  'Delete everything',
                  style: AppText.bodyMd(
                    color: controller.text.trim().toUpperCase() == 'DELETE'
                        ? palette.red
                        : palette.muted,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (typed != true || !mounted) return;

    final failure = await ref.read(authProvider.notifier).deleteAccount();
    if (!mounted) return;
    if (failure == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your account and data were deleted.')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (failure) {
          // Google requires a fresh sign-in before deleting an account. Said
          // plainly, because "it failed" with no reason is unactionable.
          DeleteFailure.needsRecentLogin =>
            'For security, sign in again and then retry deleting.',
          DeleteFailure.unavailable => 'Sign in first to delete your account.',
          DeleteFailure.failed => "Couldn't delete your account. Try again.",
        }),
      ),
    );
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
                  const SizedBox(height: 20),

                  // Grouped rather than one flat list of a dozen rows, which stopped being
                  // scannable. It also gives a destructive action its own neighbourhood
                  // instead of a row that looks like "Check for Updates".
                  //
                  // The Pro header sits INSIDE the entitlement gate: a free user sees no
                  // section at all rather than an empty one. Pro is not on sale, so
                  // advertising a tier nobody can buy is a tease, not information.
                  const _SectionHeader('Account'),
                  const _BackupSection(),
                  if (signedIn)
                    _SettingsRow(
                      label: 'Delete My Account',
                      destructive: true,
                      trailing: const _Chevron(),
                      onTap: _deleteAccount,
                    ),

                  const _SectionHeader('Alerts'),
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

                  const _SectionHeader('Display'),
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
                    label: 'Preferred Card Order',
                    trailing: const _Chevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CardPreferenceScreen(),
                      ),
                    ),
                  ),

                  if (isPro) ...[
                    const _SectionHeader('Pro'),
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

                  const _SectionHeader('About'),
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
            'Sign in to back up your cards and restore them on a new phone. '
            'Backup is opt-in — nothing is uploaded unless you turn it on. '
            'Cross-device Pro is coming soon.',
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
  const _SettingsRow({
    required this.label,
    required this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final String label;
  final Widget trailing;
  final VoidCallback? onTap;

  /// Renders in the warning colour. Reserved for actions that destroy
  /// something — a row that looks like every other row is not a fair warning
  /// when tapping it deletes an account.
  final bool destructive;

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
            Text(
              label,
              style: AppText.bodyMd(
                color: destructive ? AppPalette.of(context).red : null,
              ).copyWith(fontSize: 16),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// Wallet backup: the opt-in toggle, plus the two manual directions.
///
/// Shown even when it cannot be used, disabled with the reason, rather than
/// hidden — a feature nobody can find is not a feature, and "sign in to turn
/// this on" is a better answer than an empty space.
///
/// The manual rows exist because automatic restore deliberately only fires
/// onto an empty wallet. When both sides hold cards there is no safe automatic
/// answer, so the user picks a direction and is told exactly what it destroys.
class _BackupSection extends ConsumerStatefulWidget {
  const _BackupSection();

  @override
  ConsumerState<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<_BackupSection> {
  bool _busy = false;

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _say(await action());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backUpNow() => _run(() async {
    final status = await ref.read(walletBackupControllerProvider).backUpNow();
    return switch (status) {
      BackupStatus.ok => 'Wallet backed up.',
      BackupStatus.unavailable => 'Sign in to back up your wallet.',
      BackupStatus.empty || BackupStatus.failed => "Backup didn't complete.",
    };
  });

  /// Turning backup on uploads this phone's wallet, replacing whatever the
  /// service holds.
  ///
  /// The prompt fires on one condition only: the upload would destroy cards
  /// that are not on this phone. A backup merely existing is not a reason to
  /// interrupt — the user already agreed to back up when they made it, and
  /// re-enabling on the phone that made it loses nothing. The case that
  /// matters is a *first sign-in on a new phone*, where a thin local wallet
  /// would overwrite a full one and "restore" would then hand back the wallet
  /// the user came to escape.
  Future<void> _toggleBackup(bool enable) async {
    final notifier = ref.read(backupEnabledProvider.notifier);
    if (!enable) {
      await notifier.setEnabled(false);
      return;
    }

    setState(() => _busy = true);
    final RemoteBackupInfo remote;
    try {
      remote = await ref.read(walletBackupControllerProvider).remoteInfo();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    if (remote.uploadWouldLoseCards) {
      final n = remote.cardsNotOnThisPhone;
      final when = remote.capturedAt == null
          ? 'Your backup'
          : 'Your backup from ${_shortDate(remote.capturedAt!)}';
      final replace = await _confirm(
        title: 'This would lose cards',
        body:
            '$when has $n ${n == 1 ? 'card' : 'cards'} that this phone does '
            'not. Turning on backup uploads what is here, replacing it — and '
            'those cards would be gone. To bring them here instead, cancel '
            'and use Restore From Backup first.',
        action: 'Replace anyway',
      );
      if (!replace) return;
    }

    // seedBackup: the upload is now something the user has agreed to, either
    // explicitly above or implicitly because there was nothing to lose.
    await notifier.setEnabled(true);
    if (mounted) _say('Wallet backed up.');
  }

  static String _shortDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = d.toLocal();
    return '${local.day} ${months[local.month - 1]}';
  }

  Future<void> _restore() async {
    final confirmed = await _confirm(
      title: 'Restore from backup?',
      body:
          'This replaces the cards, nicknames and preferences on this phone '
          'with the ones in your backup. Anything here that is not in the '
          'backup is lost. Your transactions are not affected.',
      action: 'Restore',
    );
    if (!confirmed) return;
    await _run(() async {
      final outcome = await ref
          .read(walletBackupControllerProvider)
          .restoreNow();
      return switch (outcome) {
        RestoreOutcome.restored => 'Wallet restored from backup.',
        RestoreOutcome.nothingToRestore => 'No backup found for your account.',
        RestoreOutcome.unavailable => 'Sign in to restore your wallet.',
        RestoreOutcome.failed => "Restore didn't complete.",
      };
    });
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final palette = AppPalette.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: Text(title, style: AppText.titleMd()),
        content: Text(body, style: AppText.bodySm(color: palette.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action, style: AppText.bodyMd(color: palette.red)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // A build with no sync service has no backup feature. Saying "sign in to
    // turn on backup" there would promise something no amount of signing in
    // could deliver.
    if (!ref.watch(backupSupportedProvider)) return const SizedBox.shrink();
    final available = ref.watch(backupAvailableProvider);
    final enabled = ref.watch(backupEnabledProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
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
                      'Back Up My Wallet',
                      style: AppText.bodyMd().copyWith(
                        fontSize: 16,
                        color: available ? null : palette.muted,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: enabled && available,
                    onChanged: available && !_busy ? _toggleBackup : null,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                available
                    ? 'Keeps a copy of your cards, nicknames and preferences '
                          'so you can restore them on a new phone. Your '
                          'transactions are never uploaded.'
                    : 'Sign in to turn on backup — a backup has to belong to '
                          'an account so it can be restored later.',
                style: AppText.bodySm(color: palette.muted),
              ),
            ],
          ),
        ),
        // "Back Up Now" is the upload, so it follows the opt-in.
        if (available && enabled)
          _SettingsRow(
            label: 'Back Up Now',
            trailing: const _Chevron(),
            onTap: _busy ? null : _backUpNow,
          ),
        // Restore is NOT gated on the toggle. Pulling your own backup onto
        // your own signed-in phone needs no opt-in — and gating it was a trap:
        // the only way to reach Restore was to switch backup on first, which
        // uploaded this phone's wallet over the very backup you came to
        // retrieve. Someone arriving on a new phone would have destroyed it
        // with the tap meant to recover it.
        if (available)
          _SettingsRow(
            label: 'Restore From Backup',
            trailing: const _Chevron(),
            onTap: _busy ? null : _restore,
          ),
      ],
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

/// A settings group label.
///
/// The list reached a dozen rows, at which point a flat list stops being
/// scannable. Grouping also carries information the rows cannot: an empty
/// "Pro" section reads as a tier you do not have, where the same rows simply
/// missing reads as a bug.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 22, 0, 8),
      child: Text(
        label.toUpperCase(),
        style: AppText.labelSm(
          color: AppPalette.of(context).muted,
        ).copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w600),
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
