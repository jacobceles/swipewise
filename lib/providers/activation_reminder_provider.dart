import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/catalog_repository.dart';
import '../api/settings_repository.dart';
import '../models/card.dart';
import '../notifications/activation_reminder_service.dart';
import 'auth_provider.dart';
import 'data_providers.dart';

/// Owns "when do the quarter-start activation reminders get rebuilt": on app
/// open and when the toggle changes. Idempotent, like the payment reminders.
class ActivationReminderController {
  ActivationReminderController(this._ref);
  final Ref _ref;

  Future<void> reschedule() async {
    final userId = _ref.read(authProvider).userId;
    if (userId == null) return;
    final repo = _ref.read(dataRepositoryProvider);
    final enabled = await SettingsRepository(
      repo,
    ).getActivationRemindersEnabled(userId);
    final cards = _ref.read(cardsProvider).value ?? const <CardSummary>[];
    final now = DateTime.now();
    final due =
        <({String cardId, String cardName, RotatingSchedule schedule})>[];
    for (final c in cards) {
      final schedule = await repo.catalog.rotatingScheduleForCard(
        userId,
        c.cardId,
        now: now,
      );
      if (schedule == null || !schedule.requiresActivation) continue;
      due.add((
        cardId: c.cardId,
        cardName: c.customName ?? c.name,
        schedule: schedule,
      ));
    }
    await ActivationReminderService.instance.reschedule(
      cards: due,
      enabled: enabled,
      now: now,
    );
  }
}

final activationReminderControllerProvider =
    Provider<ActivationReminderController>(ActivationReminderController.new);

/// Master toggle. Default ON — see `SettingsRepository`.
final activationRemindersEnabledProvider = FutureProvider<bool>((ref) async {
  final userId = ref.watch(authProvider).userId;
  if (userId == null) return true;
  return SettingsRepository(
    ref.watch(dataRepositoryProvider),
  ).getActivationRemindersEnabled(userId);
});

/// Names of the wallet's cards that need quarterly activation, for the
/// Notifications screen's subtitle.
final activationCardNamesProvider = FutureProvider<List<String>>((ref) async {
  final userId = ref.watch(authProvider).userId;
  if (userId == null) return const [];
  final repo = ref.watch(dataRepositoryProvider);
  final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
  return [
    for (final c in cards)
      if ((await repo.catalog.rotatingScheduleForCard(
            userId,
            c.cardId,
          ))?.requiresActivation ==
          true)
        c.customName ?? c.name,
  ];
});
