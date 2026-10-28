import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/account_delete_client.dart';
import '../../providers/auth_provider.dart';
import '../../providers/backup_provider.dart';
import '../../providers/entitlement_provider.dart';
import '../../sync/wallet_backup_client.dart';
import '../../theme/app_theme.dart';
import 'profile_ui.dart';

/// Wireframe `VncYe` — backup, sign out and delete, for a signed-in user.
/// Sign out and delete sit after everything else, labelled, and both confirm.
class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
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

  Future<void> _backUpNow() async {
    // Automatic backup stopped because this would remove cards; the tap is
    // the user choosing this phone's copy, so say what it costs once more.
    final held = ref.read(backupHeldCardsProvider).value ?? 0;
    if (held > 0) {
      final replace = await confirmAction(
        context,
        title: 'Replace your backup?',
        body:
            'Your backup has $held ${held == 1 ? 'card' : 'cards'} that this '
            'phone does not. Backing up replaces it with what is here, and '
            'those cards would be gone.',
        action: 'Replace',
      );
      if (!replace) return;
    }
    await _backUpNowConfirmed();
  }

  Future<void> _backUpNowConfirmed() => _run(() async {
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
          : 'Your backup from ${DateFormat('d MMM').format(remote.capturedAt!.toLocal())}';
      final replace = await confirmAction(
        context,
        title: 'This would lose cards',
        body:
            '$when has $n ${n == 1 ? 'card' : 'cards'} that this phone does '
            'not. Turning on backup uploads what is here, replacing it — and '
            'those cards would be gone. To bring them here instead, cancel '
            'and use Restore first.',
        action: 'Replace anyway',
      );
      if (!replace) return;
    }

    // seedBackup: the upload is now something the user has agreed to, either
    // explicitly above or implicitly because there was nothing to lose.
    await notifier.setEnabled(true);
    if (mounted) _say('Wallet backed up.');
  }

  Future<void> _restore() async {
    final last = ref.read(lastBackupAtProvider).value;
    final isPro = ref.read(proEntitlementProvider);
    final confirmed = await confirmAction(
      context,
      title: 'Restore from backup?',
      body:
          'Replaces the cards, nicknames and settings on this phone with your '
          'backup${last == null ? '' : ' from ${backupWhen(last)}'}. Anything '
          'added here since then is lost.'
          '${isPro ? ' Your transactions are not affected.' : ''}',
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

  Future<void> _signOut() async {
    final confirmed = await confirmAction(
      context,
      title: 'Sign out?',
      body:
          'Your wallet stays on this phone. Backups stop until you sign in '
          'again.',
      action: 'Sign out',
    );
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop();
    // Re-keys the wallet onto a local id — nothing is deleted.
    await ref.read(authProvider.notifier).logout();
  }

  /// Deletes the account and everything belonging to it, after one plain
  /// confirmation. Everything destroyed here is unrecoverable — there is no
  /// archived copy and no grace window — so the dialog says exactly what goes.
  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _DeleteDialog(),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final failure = await ref.read(authProvider.notifier).deleteAccount();
    if (failure == null && mounted) Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (failure) {
          null => 'Your account and data were deleted.',
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

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final auth = ref.watch(authProvider);
    final isPro = ref.watch(proEntitlementProvider);
    final supported = ref.watch(backupSupportedProvider);
    final available = ref.watch(backupAvailableProvider);
    final enabled = ref.watch(backupEnabledProvider) && available;
    final last = ref.watch(lastBackupAtProvider).value;
    final held = ref.watch(backupHeldCardsProvider).value ?? 0;
    final paused = enabled && held > 0;

    return SettingsPage(
      title: 'Account',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kRowInset, 4, kRowInset, 0),
          child: Row(
            children: [
              ProfileAvatar(identifier: auth.identifier, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      auth.identifier ?? auth.email ?? '',
                      style: AppText.titleLg().copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${auth.email ?? ''} · Google',
                      style: rowSubtitleStyle(palette),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: kGroupGap),
        // A build with no sync service has no backup feature. Saying "turn on
        // backup" there would promise something that cannot exist.
        if (supported) ...[
          const SectionHeader('Backup'),
          SettingsGroup(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsRow(
                    icon: LucideIcons.cloud,
                    title: 'Back up my wallet',
                    subtitle: 'Cards, nicknames and settings',
                    trailing: Switch.adaptive(
                      value: enabled,
                      onChanged: available && !_busy ? _toggleBackup : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      kTextColumn,
                      0,
                      kRowInset,
                      16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(
                                last == null || paused
                                    ? LucideIcons.cloudAlert
                                    : LucideIcons.circleCheck,
                                size: 15,
                                color: last == null || paused
                                    ? palette.amber
                                    : palette.muted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                paused
                                    ? 'Automatic backup paused. Your backup '
                                          'has $held ${held == 1 ? 'card' : 'cards'} '
                                          'this phone doesn\'t, and backing up '
                                          'would remove them. Restore to bring '
                                          'them here, or Back up now to '
                                          'replace the backup.'
                                    : last == null
                                    ? 'Not backed up from this phone yet'
                                    : 'Backed up ${backupWhen(last)}',
                                style: rowSubtitleStyle(palette).copyWith(
                                  color: last == null || paused
                                      ? palette.amber
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              // "Back up now" is the upload, so it follows
                              // the opt-in.
                              child: _PillButton(
                                icon: LucideIcons.cloudUpload,
                                label: 'Back up now',
                                onTap: enabled && !_busy ? _backUpNow : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              // Restore is NOT gated on the switch. Turning
                              // backup on first would upload this phone over
                              // the very backup the user came to retrieve.
                              child: _PillButton(
                                icon: LucideIcons.cloudDownload,
                                label: 'Restore…',
                                onTap: available && !_busy ? _restore : null,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (isPro) const GroupCaption('Transactions never leave this phone.'),
          const SizedBox(height: kGroupGap),
        ],
        SettingsGroup(
          children: [
            SettingsRow(
              icon: LucideIcons.logOut,
              title: 'Sign out',
              subtitle: 'Your wallet stays on this phone',
              chevron: true,
              onTap: _signOut,
            ),
            SettingsRow(
              iconTile: IconTile(
                LucideIcons.trash2,
                color: palette.red,
                background: palette.redBg,
              ),
              title: 'Delete account',
              titleColor: palette.red,
              subtitle: 'Erases your account and its backup',
              chevron: true,
              onTap: _deleteAccount,
            ),
          ],
        ),
      ],
    );
  }
}

/// "today, 9:12 AM", "yesterday, 9:12 AM", "3 Oct".
String backupWhen(DateTime at, {DateTime? now}) {
  final local = at.toLocal();
  final today = now ?? DateTime.now();
  final days = DateTime(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime(local.year, local.month, local.day)).inDays;
  final time = DateFormat.jm().format(local);
  if (days == 0) return 'today, $time';
  if (days == 1) return 'yesterday, $time';
  return DateFormat('d MMM').format(local);
}

/// A two-button confirmation whose action is coloured as a warning.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final palette = AppPalette.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.sheet,
      title: Text(title, style: AppText.titleMd()),
      content: Text(body, style: AppText.bodySm(color: palette.muted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(action, style: AppText.bodyMd(color: palette.red)),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Wireframe `c9CWNc`: one plain confirmation.
class _DeleteDialog extends ConsumerWidget {
  const _DeleteDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final isPro = ref.watch(proEntitlementProvider);
    return Dialog(
      backgroundColor: AppColors.sheet,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.redBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(LucideIcons.trash2, size: 22, color: palette.red),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Delete your account?',
              style: AppText.titleLg().copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isPro
                  ? 'Your account, its backup, any linked bank and everything on '
                        "this phone, including transactions, are erased for good. You'll "
                        "sign in again first to confirm it's you. This can't be undone."
                  : 'Your account, its backup and everything on this phone are '
                        "erased for good. You'll sign in again first to confirm "
                        "it's you. This can't be undone.",
              style: rowSubtitleStyle(palette),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: palette.red,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  'Delete account',
                  style: AppText.bodyMd(
                    color: Colors.white,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'Keep my account',
                style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = onTap == null ? palette.muted : AppColors.foreground;
    return Material(
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
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: AppText.bodyMd(
                  color: color,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
