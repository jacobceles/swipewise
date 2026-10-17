import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../api/settings_repository.dart';
import '../../models/card.dart';
import '../../providers/activation_reminder_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/data_providers.dart';
import '../../providers/nearby_providers.dart';
import '../../providers/payment_reminder_provider.dart';
import '../../theme/app_theme.dart';
import 'profile_ui.dart';

/// Wireframes `QRg80` / `O5WdC` — payment-due and rotating-category reminders.
class RemindersPage extends ConsumerWidget {
  const RemindersPage({super.key});

  SettingsRepository _settings(WidgetRef ref) =>
      SettingsRepository(ref.read(dataRepositoryProvider));

  Future<void> _setPayment(WidgetRef ref, bool on) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    await _settings(ref).setPaymentRemindersEnabled(userId, on);
    ref.invalidate(paymentRemindersEnabledProvider);
    await ref.read(paymentReminderControllerProvider).reschedule();
  }

  Future<void> _setLeadDays(WidgetRef ref, int days) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    await _settings(ref).setPaymentReminderLeadDays(userId, days);
    ref.invalidate(paymentReminderLeadDaysProvider);
    await ref.read(paymentReminderControllerProvider).reschedule();
  }

  Future<void> _setActivation(WidgetRef ref, bool on) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    await _settings(ref).setActivationRemindersEnabled(userId, on);
    ref.invalidate(activationRemindersEnabledProvider);
    await ref.read(activationReminderControllerProvider).reschedule();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final notificationsOk =
        ref.watch(alertChecksProvider).value?[AlertCheck.notifications] ?? true;
    final paymentOn = ref.watch(paymentRemindersEnabledProvider).value ?? false;
    final leadDays = ref.watch(paymentReminderLeadDaysProvider).value ?? 3;
    final activationOn =
        ref.watch(activationRemindersEnabledProvider).value ?? true;
    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    final withDue = cards.where((c) => c.dueDay != null).length;

    return SettingsPage(
      title: 'Reminders',
      children: [
        if (!notificationsOk) ...[
          SettingsGroup(
            color: palette.amberBg,
            children: [
              SettingsRow(
                iconTile: IconTile(
                  LucideIcons.bellOff,
                  color: palette.amber,
                  background: Colors.black26,
                ),
                title: 'Notifications are off',
                subtitle: "Reminders can't reach you until you allow them.",
                trailing: ActionPill(
                  label: 'Allow',
                  onTap: () async {
                    final s = await Permission.notification.request();
                    if (!s.isGranted) await openAppSettings();
                    ref.invalidate(alertChecksProvider);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: kGroupGap),
        ],
        SettingsGroup(
          children: [
            SettingsRow(
              icon: LucideIcons.calendarClock,
              title: 'Payment due',
              subtitle: withDue == 0
                  ? 'Add a due date to a card first'
                  : 'A heads-up before each due date',
              enabled: withDue > 0,
              trailing: Switch.adaptive(
                value: paymentOn && withDue > 0,
                onChanged: withDue > 0 ? (v) => _setPayment(ref, v) : null,
              ),
            ),
            if (paymentOn && withDue > 0)
              PopupMenuButton<int>(
                initialValue: leadDays,
                onSelected: (d) => _setLeadDays(ref, d),
                color: AppColors.sheet,
                itemBuilder: (_) => [
                  for (final d in const [1, 3, 5, 7])
                    PopupMenuItem(value: d, child: Text(daysBefore(d))),
                ],
                child: SettingsRow(
                  title: 'Remind me',
                  value: daysBefore(leadDays),
                  chevron: true,
                ),
              ),
          ],
        ),
        GroupCaption(
          withDue == 0
              ? "None of your cards has a due date yet. Add one from a card's "
                    'details.'
              : '$withDue of ${countOf(cards.length, 'card')} '
                    "${withDue == 1 ? 'has' : 'have'} a due date. Add one from "
                    "a card's details.",
        ),
        const SizedBox(height: kGroupGap),
        SettingsGroup(
          children: [
            SettingsRow(
              icon: LucideIcons.refreshCw,
              title: 'Rotating categories',
              subtitle: 'When a new quarter starts',
              trailing: Switch.adaptive(
                value: activationOn,
                onChanged: (v) => _setActivation(ref, v),
              ),
            ),
          ],
        ),
        const GroupCaption('So you can activate them before you shop.'),
      ],
    );
  }
}

String daysBefore(int d) => d == 1 ? '1 day before' : '$d days before';

/// The main-screen value: "2 on", "Off", or "Paused" while notifications are
/// off (the reminders exist but can't arrive).
String remindersSummary(WidgetRef ref) {
  final notificationsOk =
      ref.watch(alertChecksProvider).value?[AlertCheck.notifications] ?? true;
  if (!notificationsOk) return 'Paused';
  final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
  final payment =
      (ref.watch(paymentRemindersEnabledProvider).value ?? false) &&
      cards.any((c) => c.dueDay != null);
  final activation =
      ref.watch(activationRemindersEnabledProvider).value ?? true;
  final on = (payment ? 1 : 0) + (activation ? 1 : 0);
  return on == 0 ? 'Off' : '$on on';
}
