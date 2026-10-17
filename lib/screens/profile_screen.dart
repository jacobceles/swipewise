import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/card.dart';
import '../nearby/geofence_channel.dart';
import '../providers/auth_provider.dart';
import '../providers/backup_provider.dart';
import '../providers/data_providers.dart';
import '../providers/entitlement_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'profile/about_page.dart';
import 'profile/account_page.dart';
import 'profile/card_preference_page.dart';
import 'profile/default_tabs_page.dart';
import 'profile/profile_ui.dart';
import 'profile/reminders_page.dart';
import 'profile/store_alerts_card.dart';

/// Wireframe `HPtUB` (Settings v4): a short first screen. Who you are and
/// whether your wallet is backed up, store alerts (quiet unless something
/// needs fixing), and a few plainly named entries; every detail is one page
/// away. The tab bar already says this is Profile, so the header is the
/// person, centred, rather than a title.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(proEntitlementProvider);
    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    final order = ref.watch(cardPreferenceOrderProvider).value ?? const [];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(kGutter, 28, kGutter, 120),
          children: [
            const _Header(),
            const SizedBox(height: 28),
            const StoreAlertsCard(),
            const SizedBox(height: 16),
            SettingsGroup(
              children: [
                SettingsRow(
                  icon: LucideIcons.listOrdered,
                  title: 'Card preference',
                  value: cardPreferenceSummary(cards, order),
                  chevron: true,
                  onTap: () =>
                      pushSettingsPage(context, const CardPreferencePage()),
                ),
                SettingsRow(
                  icon: LucideIcons.bell,
                  title: 'Reminders',
                  value: remindersSummary(ref),
                  chevron: true,
                  onTap: () => pushSettingsPage(context, const RemindersPage()),
                ),
                SettingsRow(
                  icon: LucideIcons.appWindow,
                  title: 'Default tabs',
                  value: defaultTabsSummary(ref),
                  chevron: true,
                  onTap: () =>
                      pushSettingsPage(context, const DefaultTabsPage()),
                ),
                // Only bank-synced accounts can be debit.
                if (isPro)
                  SettingsRow(
                    icon: LucideIcons.landmark,
                    title: 'Include debit accounts',
                    subtitle: 'In transactions and totals',
                    trailing: Switch.adaptive(
                      value: ref.watch(includeDebitAccountsProvider),
                      onChanged: (v) => ref
                          .read(includeDebitAccountsProvider.notifier)
                          .setEnabled(v),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            const _AboutLink(),
            if (kDebugMode) ...[
              const SizedBox(height: 24),
              const _DeveloperBlock(),
            ],
          ],
        ),
      ),
    );
  }
}

/// The person, centred: who is signed in and the state of their wallet's
/// backup, or — signed out — what signing in buys.
class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final auth = ref.watch(authProvider);
    // Signed in means "has a Google identity" — `isLoggedIn` is true even for
    // the device-local identity.
    final signedIn = auth.email != null;
    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    final supported = ref.watch(backupSupportedProvider);
    final meta = rowSubtitleStyle(palette);

    if (!signedIn) {
      return Column(
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.secondary,
              shape: BoxShape.circle,
            ),
            child: Icon(LucideIcons.wallet, size: 26, color: palette.muted),
          ),
          const SizedBox(height: 16),
          Text(
            supported ? 'Keep your wallet safe' : 'Sign in',
            textAlign: TextAlign.center,
            style: AppText.titleLg().copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (supported) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Sign in to back up your cards and bring them to a new phone.',
                textAlign: TextAlign.center,
                style: meta,
              ),
            ),
          ],
          if (auth.error != null) ...[
            const SizedBox(height: 10),
            Text(
              auth.error!,
              textAlign: TextAlign.center,
              style: AppText.bodySm(color: palette.red),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 44,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.foreground,
                foregroundColor: AppColors.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                shape: const StadiumBorder(),
              ),
              onPressed: auth.isLoading
                  ? null
                  : () => ref.read(authProvider.notifier).signInWithGoogle(),
              child: auth.isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'G',
                          style: AppText.titleMd(
                            color: AppColors.onPrimary,
                          ).copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Sign in with Google',
                          style: AppText.bodyMd(
                            color: AppColors.onPrimary,
                          ).copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.creditCard, size: 15, color: palette.muted),
              const SizedBox(width: 6),
              Text(
                cards.isEmpty
                    ? 'No cards yet — add one from Cards'
                    : '${countOf(cards.length, 'card')} on this phone',
                style: meta,
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      children: [
        ProfileAvatar(identifier: auth.identifier),
        const SizedBox(height: 14),
        Text(
          auth.identifier ?? auth.email!,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.titleLg().copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              cards.isEmpty ? 'No cards yet' : countOf(cards.length, 'card'),
              style: meta,
            ),
            if (supported) ...[
              Text('  ·  ', style: meta),
              const Flexible(child: _BackupLine()),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Material(
          color: AppPalette.of(context).secondary,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => pushSettingsPage(context, const AccountPage()),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 9, 12, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Account & backup',
                    style: AppText.bodyMd().copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(LucideIcons.chevronRight, size: 16),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Backup state as a fact, not a promise: the time of the last upload from
/// this phone, since backup is not continuous. Only "not backed up yet" is
/// coloured — it is the one that needs the user.
class _BackupLine extends ConsumerWidget {
  const _BackupLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final enabled = ref.watch(backupEnabledProvider);
    final last = ref.watch(lastBackupAtProvider).value;
    final (icon, color, text) = !enabled
        ? (LucideIcons.cloudOff, palette.muted, 'Backup is off')
        : last == null
        ? (LucideIcons.cloudUpload, palette.amber, 'Not backed up yet')
        : (
            LucideIcons.cloudCheck,
            palette.muted,
            'Backed up ${backupWhen(last)}',
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: rowSubtitleStyle(palette).copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// About as a quiet footer link rather than a row, so the first screen stays
/// one screen even when the alerts card is open.
class _AboutLink extends StatelessWidget {
  const _AboutLink();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadiusPill),
        onTap: () => pushSettingsPage(context, const AboutPage()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (_, snap) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  snap.hasData
                      ? 'About SwipeWise · ${snap.data!.version}'
                      : 'About SwipeWise',
                  style: rowSubtitleStyle(palette),
                ),
                const SizedBox(width: 2),
                Icon(LucideIcons.chevronRight, size: 15, color: palette.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Debug builds only, fenced off from everything a user sees.
class _DeveloperBlock extends StatelessWidget {
  const _DeveloperBlock();

  static const _cluster = [
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
  ];

  Future<void> _fire(BuildContext context, {bool cluster = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await GeofenceChannel.fireTestNotification(
        options: cluster ? _cluster : null,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Test alert fired — pull down to see it')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    Widget button(IconData icon, String label, VoidCallback onTap) => Expanded(
      child: Material(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusPill),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 8),
                Text(label, style: AppText.bodySm(color: AppColors.foreground)),
              ],
            ),
          ),
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(kRowInset),
      decoration: BoxDecoration(
        color: palette.amberBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(kGroupRadius),
        border: Border.all(color: palette.amber.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.bug, size: 15, color: palette.amber),
              const SizedBox(width: 6),
              Text(
                'DEVELOPER · debug build only',
                style: AppText.monoXs(
                  color: palette.amber,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              button(
                LucideIcons.bellRing,
                'Test store alert',
                () => _fire(context),
              ),
              const SizedBox(width: 10),
              button(
                LucideIcons.bellPlus,
                'Test multi-store',
                () => _fire(context, cluster: true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
