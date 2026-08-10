import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/card.dart';
import '../notifications/payment_reminder_service.dart';
import 'auth_provider.dart';
import '../api/settings_repository.dart';
import 'data_providers.dart';

/// Owns "when do the scheduled payment reminders get rebuilt".
///
/// Reminders are calendar instants, not a repeat rule (months vary in length),
/// so the schedule is regenerated wholesale whenever an input changes: a card's
/// due day, the master toggle, the lead time, or the wallet itself.
class PaymentReminderController {
  PaymentReminderController(this._ref);
  final Ref _ref;

  /// Rebuilds every scheduled reminder from current state. Safe to call often —
  /// it cancels and re-adds, so it is idempotent.
  Future<void> reschedule() async {
    final userId = _ref.read(authProvider).userId;
    if (userId == null) return;
    final settings = SettingsRepository(_ref.read(dataRepositoryProvider));
    final enabled = await settings.getPaymentRemindersEnabled(userId);
    final leadDays = await settings.getPaymentReminderLeadDays(userId);
    final cards = _ref.read(cardsProvider).value ?? const <CardSummary>[];
    await PaymentReminderService.instance.reschedule(
      cards: [
        for (final c in cards.where((c) => c.isCreditCard))
          (
            cardId: c.cardId,
            cardName: c.customName ?? c.name,
            // A card that opted out contributes no due day, so it schedules
            // nothing — without this the per-card toggle would be decorative.
            dueDay: (c.reminderEnabled == false) ? null : c.dueDay,
            leadDays: c.reminderLeadDays ?? leadDays,
          ),
      ],
      enabled: enabled,
      leadDays: leadDays,
    );
  }
}

final paymentReminderControllerProvider = Provider<PaymentReminderController>(
  PaymentReminderController.new,
);

/// Master toggle. Default OFF — see `SettingsRepository`.
final paymentRemindersEnabledProvider = FutureProvider<bool>((ref) async {
  final userId = ref.watch(authProvider).userId;
  if (userId == null) return false;
  return SettingsRepository(
    ref.watch(dataRepositoryProvider),
  ).getPaymentRemindersEnabled(userId);
});

/// Days before the due date to fire. Default 3.
final paymentReminderLeadDaysProvider = FutureProvider<int>((ref) async {
  final userId = ref.watch(authProvider).userId;
  if (userId == null) return 3;
  return SettingsRepository(
    ref.watch(dataRepositoryProvider),
  ).getPaymentReminderLeadDays(userId);
});
