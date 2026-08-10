import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart';

import '../api/settings_repository.dart';
import '../models/card.dart';
import '../providers/auth_provider.dart';
import '../providers/data_providers.dart';
import '../providers/payment_reminder_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// Wireframe `lc1fO` / `wTpts` — one place to manage every notification the app
/// sends: payment reminders (N12) and the existing near-store recommendations.
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen> {
  bool? _osGranted;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final status = await Permission.notification.status;
    if (mounted) setState(() => _osGranted = status.isGranted);
  }

  SettingsRepository get _settings =>
      SettingsRepository(ref.read(dataRepositoryProvider));

  Future<void> _setEnabled(bool value) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    await _settings.setPaymentRemindersEnabled(userId, value);
    ref.invalidate(paymentRemindersEnabledProvider);
    await ref.read(paymentReminderControllerProvider).reschedule();
  }

  /// Bottom-sheet picker behind the "Remind me" row (wireframe uses a
  /// value+chevron row here, not inline chips).
  Future<void> _pickLeadDays() async {
    final palette = AppPalette.of(context);
    final current = ref.read(paymentReminderLeadDaysProvider).value ?? 3;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: palette.sheet,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            for (final d in const [1, 3, 5, 7])
              ListTile(
                title: Text(d == 1 ? '1 day before' : '$d days before'),
                trailing: d == current
                    ? Icon(
                        LucideIcons.check,
                        size: 18,
                        color: AppColors.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(context, d),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) await _setLeadDays(picked);
  }

  Future<void> _setLeadDays(int days) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    await _settings.setPaymentReminderLeadDays(userId, days);
    ref.invalidate(paymentReminderLeadDaysProvider);
    await ref.read(paymentReminderControllerProvider).reschedule();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final enabled = ref.watch(paymentRemindersEnabledProvider).value ?? false;
    final leadDays = ref.watch(paymentReminderLeadDaysProvider).value ?? 3;
    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    final withDueDay = cards.where((c) => c.dueDay != null).length;
    final denied = _osGranted == false;

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (denied) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.amberBg,
                borderRadius: BorderRadius.circular(kRadiusM),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Notifications are turned off',
                    style: AppText.titleMd(color: palette.amber),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Turn them on in system settings to get payment reminders '
                    'and store recommendations.',
                    style: AppText.bodySm(color: palette.muted),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: openAppSettings,
                    child: const Text('Open Settings'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
          Text(
            'PAYMENT REMINDERS',
            style: AppText.labelSm(color: palette.muted),
          ),
          const SizedBox(height: 8),
          _ToggleRow(
            icon: LucideIcons.bell,
            title: 'Payment reminders',
            subtitle: 'A heads-up before a card’s due date',
            value: enabled && !denied,
            onChanged: denied ? null : _setEnabled,
          ),
          if (enabled && !denied)
            _ValueRow(
              label: 'Remind me',
              value: leadDays == 1 ? '1 day before' : '$leadDays days before',
              onTap: _pickLeadDays,
            ),
          const SizedBox(height: 8),
          // The honest caveat: banks don't send a due date, so a reminder only
          // exists for cards the user has typed one into.
          Text(
            withDueDay == 0
                ? 'No cards have a due date yet. Add one from a card to get reminders.'
                : 'Reminders fire for the $withDueDay card${withDueDay == 1 ? '' : 's'} with a due date set.',
            style: AppText.bodySm(color: palette.muted),
          ),
          const SizedBox(height: 28),
          Text('NEARBY STORES', style: AppText.labelSm(color: palette.muted)),
          const SizedBox(height: 8),
          const _NearbyToggle(),
        ],
      ),
    );
  }
}

/// Near-store recommendations reuse the existing `nearby_enabled` setting so
/// this screen doesn't fork a second source of truth.
class _NearbyToggle extends ConsumerWidget {
  const _NearbyToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(nearbyEnabledProvider);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: enabled,
      onChanged: (v) => ref.read(nearbyEnabledProvider.notifier).setEnabled(v),
      title: const Text('Store recommendations'),
      subtitle: const Text('Your best card to use at nearby stores'),
    );
  }
}

/// Wireframe row: an accent icon disc, title + subtitle, and a switch.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final dim = onChanged == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: dim ? palette.secondary : palette.amberBg,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 17,
              color: dim ? palette.muted : AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.bodyMd(color: dim ? palette.muted : null),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: AppText.bodySm(color: palette.muted)),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: AppColors.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Wireframe row: label on the left, current value + chevron on the right.
class _ValueRow extends StatelessWidget {
  const _ValueRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.border)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppText.bodyMd()),
            Row(
              children: [
                Text(value, style: AppText.bodySm(color: palette.muted)),
                const SizedBox(width: 6),
                Icon(LucideIcons.chevronRight, size: 16, color: palette.muted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
