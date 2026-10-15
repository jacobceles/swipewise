import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../api/catalog_repository.dart';
import '../util/logger.dart';
import 'payment_reminder_service.dart';

/// "A new rotating quarter starts today — activate it at your bank" (D2/N3).
///
/// Chase Freedom Flex and Discover it pay their 5% only once the cardholder
/// activates each quarter with the issuer. The app can't see or do that, and
/// ranks at the bonus rate regardless; this reminder is the whole feature.
/// Wireframe `lw4YB`.
class ActivationReminderService {
  ActivationReminderService._();
  static final ActivationReminderService instance =
      ActivationReminderService._();

  /// Tags these notifications so [PaymentReminderService] leaves them alone
  /// when it clears its own.
  static const payload = 'activation';

  static const _channelId = 'swipewise_rotating_activation';
  static const _channelName = 'Rotating categories';
  static const _channelDescription =
      'A reminder to activate a card’s bonus categories when a new quarter starts.';

  final _plugin = FlutterLocalNotificationsPlugin();

  /// 09:00 local on the first day of the quarter after [now].
  static DateTime nextQuarterStart(DateTime now) {
    final nextQuarterMonth = ((now.month - 1) ~/ 3 + 1) * 3 + 1;
    return DateTime(
      now.year,
      nextQuarterMonth,
      1,
      PaymentReminderService.reminderHour,
    );
  }

  /// Title and body for [cardName]'s reminder. [quarter] is the starting
  /// quarter when the catalog has its categories; without it the reminder
  /// still fires, but names no categories it can't back up.
  static ({String title, String body}) text({
    required String cardName,
    required RotatingSchedule schedule,
    RotatingQuarter? quarter,
  }) {
    if (quarter == null) {
      return (
        title:
            '$cardName: a new ${_rate(schedule.rate, schedule.currency)} '
            'quarter starts today',
        body: 'Activate with ${schedule.issuerName} to earn it.',
      );
    }
    final labels = [for (final r in quarter.rows) r.label];
    final categories = labels.length == 1
        ? labels.single
        : '${labels.sublist(0, labels.length - 1).join(', ')} and ${labels.last}';
    final first = quarter.rows.first;
    return (
      title: '$cardName: Q${quarter.quarter} bonus categories start today',
      body:
          'Activate at ${schedule.issuerName} to earn '
          '${_rate(first.amount ?? schedule.rate, first.currency ?? schedule.currency)} '
          'on $categories through ${DateFormat('MMM d').format(quarter.end)}.',
    );
  }

  /// "5%" for cash back, "5x" for points and miles.
  static String _rate(double rate, String currency) {
    final n = rate.truncateToDouble() == rate
        ? rate.toStringAsFixed(0)
        : rate.toStringAsFixed(1);
    return currency == 'USD' ? '$n%' : '${n}x';
  }

  static int notificationId(String cardId) =>
      Object.hash(payload, cardId) & 0x7fffffff;

  /// Replaces every scheduled activation reminder with one per card in
  /// [cards], at the start of the next quarter. Topped up on each app open, so
  /// one quarter ahead is enough.
  Future<void> reschedule({
    required List<({String cardId, String cardName, RotatingSchedule schedule})>
    cards,
    required bool enabled,
    required DateTime now,
  }) async {
    await PaymentReminderService.instance.ensureInit();
    for (final p in await _plugin.pendingNotificationRequests()) {
      if (p.payload == payload) await _plugin.cancel(id: p.id);
    }
    if (!enabled) return;
    final fireAt = nextQuarterStart(now);
    for (final card in cards) {
      final t = text(
        cardName: card.cardName,
        schedule: card.schedule,
        quarter: card.schedule.next,
      );
      try {
        await _plugin.zonedSchedule(
          id: notificationId(card.cardId),
          title: t.title,
          body: t.body,
          payload: payload,
          scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDescription,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e) {
        Log.w('activation-reminder', 'schedule failed for ${card.cardId}', e);
      }
    }
    Log.i('activation-reminder', 'scheduled ${cards.length} for $fireAt');
  }
}
