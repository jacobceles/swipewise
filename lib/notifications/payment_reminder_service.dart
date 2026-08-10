import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../util/logger.dart';

/// Schedules "your payment is due soon" notifications (N12).
///
/// The due day is **user-entered** — FDX/Sophtron does not supply one (the
/// 2026-06-01 probe found a `DueDate` on 2 of 6 cards, inconsistently even
/// within one issuer), so `card_overrides.due_day` is the only source and a card
/// without one simply gets no reminder.
///
/// Scheduling is calendar-based, which the app had no mechanism for before this:
/// the only pre-existing alarms are dwell timers on `ELAPSED_REALTIME_WAKEUP`
/// (relative seconds), and WorkManager only runs a fixed 8-hourly sync.
class PaymentReminderService {
  PaymentReminderService._();
  static final PaymentReminderService instance = PaymentReminderService._();

  static const _channelId = 'swipewise_payment_due';
  static const _channelName = 'Payment reminders';
  static const _channelDescription =
      'A heads-up before a credit card payment is due.';

  /// Local hour-of-day a reminder fires. Morning, so a same-day nudge still
  /// leaves time to actually pay.
  static const int reminderHour = 9;

  /// How many months ahead to keep scheduled. A day-of-month reminder does not
  /// map onto any repeat interval the plugin offers (months vary in length), so
  /// each occurrence is scheduled individually and topped up on app open.
  static const int horizonMonths = 3;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> _ensureInit() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    // The device's zone matters: a due date is a wall-clock date, so a reminder
    // must fire at 09:00 *where the user is*, not 09:00 UTC.
    tz.setLocalLocation(tz.getLocation(await _deviceTimeZone()));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _ready = true;
  }

  Future<String> _deviceTimeZone() async {
    try {
      final name = DateTime.now().timeZoneName;
      // `timeZoneName` yields an abbreviation (PST/IST) on some platforms, which
      // the tz database can't resolve. Fall back to UTC rather than throwing —
      // a reminder an hour off beats no reminder at all.
      tz.getLocation(name);
      return name;
    } catch (_) {
      return 'UTC';
    }
  }

  /// The next instant a reminder should fire for a card, or null when it can't
  /// be computed. Pure — all date edge cases live here so they're testable.
  ///
  /// [dueDay] is a day-of-month (1-31). Months are shorter than 31 days, so a
  /// due day past the month's end **clamps to the last day** rather than
  /// spilling into the next month (a 31st due date must fire in February).
  static DateTime? nextReminderInstant({
    required int dueDay,
    required int leadDays,
    required DateTime now,
    int monthsAhead = 0,
  }) {
    if (dueDay < 1 || dueDay > 31) return null;
    if (leadDays < 0) return null;

    var year = now.year;
    var month = now.month + monthsAhead;
    year += (month - 1) ~/ 12;
    month = (month - 1) % 12 + 1;

    for (var attempt = 0; attempt < 2; attempt++) {
      final lastDay = DateTime(year, month + 1, 0).day;
      final due = DateTime(year, month, dueDay.clamp(1, lastDay));
      final fireAt = DateTime(
        due.year,
        due.month,
        due.day,
        reminderHour,
      ).subtract(Duration(days: leadDays));
      // Only roll forward on the first pass: if the reminder for this month has
      // already passed, the user wants next month's.
      if (fireAt.isAfter(now) || attempt == 1) {
        return fireAt.isAfter(now) ? fireAt : null;
      }
      month += 1;
      if (month > 12) {
        month = 1;
        year += 1;
      }
    }
    return null;
  }

  /// Whole days from [now] until the next occurrence of [dueDay], 0 on the day
  /// itself. Shares this class's month-length clamping so the on-card countdown
  /// and the scheduled reminder can never disagree about when a payment falls.
  static int daysUntilDue(int dueDay, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    for (var monthOffset = 0; monthOffset <= 1; monthOffset++) {
      var year = now.year;
      var month = now.month + monthOffset;
      if (month > 12) {
        month -= 12;
        year += 1;
      }
      final lastDay = DateTime(year, month + 1, 0).day;
      final due = DateTime(year, month, dueDay.clamp(1, lastDay));
      final diff = due.difference(today).inDays;
      if (diff >= 0) return diff;
    }
    return 0;
  }

  /// Stable per-card notification id so a re-schedule replaces rather than
  /// duplicates. `hashCode` is stable within a run and collisions across two of
  /// a user's own cards are vanishingly unlikely.
  static int notificationId(String cardId, int monthOffset) =>
      Object.hash(cardId, monthOffset) & 0x7fffffff;

  /// Replaces all scheduled reminders with ones derived from [cards].
  /// Cards with no due day are simply absent — that is the normal case.
  Future<void> reschedule({
    required List<({String cardId, String cardName, int? dueDay, int leadDays})>
    cards,
    required bool enabled,

    /// Fallback used only where a card hasn't pinned its own lead time.
    required int leadDays,
    DateTime? now,
  }) async {
    await _ensureInit();
    await _plugin.cancelAll();
    if (!enabled) {
      Log.i('payment-reminder', 'reminders off — cleared all');
      return;
    }
    final at = now ?? DateTime.now();
    var scheduled = 0;
    for (final card in cards) {
      final dueDay = card.dueDay;
      if (dueDay == null) {
        continue; // no due date, or the card opted out of reminders
      }
      // Per-card lead time wins; `leadDays` is the Settings default for cards
      // that haven't pinned one.
      final cardLead = card.leadDays;
      for (var m = 0; m < horizonMonths; m++) {
        final fireAt = nextReminderInstant(
          dueDay: dueDay,
          leadDays: cardLead,
          now: at,
          monthsAhead: m,
        );
        if (fireAt == null) continue;
        await _scheduleOne(
          id: notificationId(card.cardId, m),
          title: '${card.cardName} payment due',
          body: cardLead == 0
              ? 'Due today (the ${_ordinal(dueDay)}).'
              : 'Due in $cardLead day${cardLead == 1 ? '' : 's'} — the ${_ordinal(dueDay)}.',
          when: fireAt,
        );
        scheduled++;
      }
    }
    Log.i('payment-reminder', 'scheduled $scheduled reminder(s)');
  }

  Future<void> _scheduleOne({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(when, tz.local),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e) {
      // Exact-alarm permission can be revoked at any time on Android 12+. A
      // failed schedule must not break the caller (usually a settings toggle).
      Log.w('payment-reminder', 'schedule failed for id=$id', e);
    }
  }

  static String _ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    return switch (day % 10) {
      1 => '${day}st',
      2 => '${day}nd',
      3 => '${day}rd',
      _ => '${day}th',
    };
  }
}
