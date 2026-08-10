import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/notifications/payment_reminder_service.dart';

/// Pins the due-date arithmetic behind payment reminders (N12).
///
/// The due day is a **day-of-month**, not a date, so every month-length edge
/// case has to be handled explicitly: a 31st due day must still fire in
/// February, and a lead time must be able to cross a month (or year) boundary.
/// Getting this wrong either fires on the wrong day or silently never fires.
void main() {
  _dueDateLineTests();

  DateTime? next(
    int dueDay,
    int leadDays,
    DateTime now, {
    int monthsAhead = 0,
  }) => PaymentReminderService.nextReminderInstant(
    dueDay: dueDay,
    leadDays: leadDays,
    now: now,
    monthsAhead: monthsAhead,
  );

  group('basic scheduling', () {
    test('fires leadDays before the due day, at the reminder hour', () {
      final r = next(15, 3, DateTime(2026, 3, 1, 8));
      expect(r, DateTime(2026, 3, 12, PaymentReminderService.reminderHour));
    });

    test('leadDays 0 fires on the due day itself', () {
      final r = next(15, 0, DateTime(2026, 3, 1, 8));
      expect(r, DateTime(2026, 3, 15, PaymentReminderService.reminderHour));
    });

    test('rolls to next month when this month has already passed', () {
      // The 12th 09:00 reminder is gone by the 20th — the user wants April's.
      final r = next(15, 3, DateTime(2026, 3, 20, 8));
      expect(r, DateTime(2026, 4, 12, PaymentReminderService.reminderHour));
    });
  });

  group('short months — a 31st due day must still fire', () {
    test('clamps to Feb 28 in a common year', () {
      final r = next(31, 0, DateTime(2026, 2, 1));
      expect(r, DateTime(2026, 2, 28, PaymentReminderService.reminderHour));
    });

    test('clamps to Feb 29 in a leap year', () {
      final r = next(31, 0, DateTime(2028, 2, 1));
      expect(r, DateTime(2028, 2, 29, PaymentReminderService.reminderHour));
    });

    test('clamps to the 30th in a 30-day month', () {
      final r = next(31, 0, DateTime(2026, 4, 1));
      expect(r, DateTime(2026, 4, 30, PaymentReminderService.reminderHour));
    });

    test('does not spill into the following month', () {
      final r = next(31, 0, DateTime(2026, 2, 1));
      expect(r!.month, 2, reason: 'a Feb 31st must not become Mar 3rd');
    });
  });

  group('boundary crossing', () {
    test('lead time can cross into the previous month', () {
      final r = next(2, 5, DateTime(2026, 3, 20));
      expect(r, DateTime(2026, 3, 28, PaymentReminderService.reminderHour));
    });

    test('lead time can cross a year boundary', () {
      final r = next(3, 5, DateTime(2026, 12, 20));
      expect(r, DateTime(2026, 12, 29, PaymentReminderService.reminderHour));
    });

    test('monthsAhead walks forward across the year boundary', () {
      final r = next(15, 0, DateTime(2026, 11, 1), monthsAhead: 2);
      expect(r!.year, 2027);
      expect(r.month, 1);
    });
  });

  group('rejects nonsense rather than firing wrongly', () {
    test('day 0 and day 32 are refused', () {
      expect(next(0, 3, DateTime(2026, 3, 1)), isNull);
      expect(next(32, 3, DateTime(2026, 3, 1)), isNull);
    });

    test('negative lead days are refused', () {
      expect(next(15, -1, DateTime(2026, 3, 1)), isNull);
    });
  });

  test('notification id is stable per card+month and differs across them', () {
    final a = PaymentReminderService.notificationId('card-a', 0);
    expect(
      PaymentReminderService.notificationId('card-a', 0),
      a,
      reason: 'must be stable so a reschedule replaces, not duplicates',
    );
    expect(PaymentReminderService.notificationId('card-a', 1), isNot(a));
    expect(PaymentReminderService.notificationId('card-b', 0), isNot(a));
    expect(a, greaterThanOrEqualTo(0), reason: 'Android ids must be positive');
  });
}

/// Pins the on-card "Due 15th · in 3 days" countdown. Shares the day-of-month
/// clamping problem with the scheduler, so the short-month cases are pinned
/// here too — a wrong countdown is visible on every Cards row.
void _dueDateLineTests() {
  int days(int dueDay, DateTime now) =>
      PaymentReminderService.daysUntilDue(dueDay, now);

  test('counts forward within the same month', () {
    expect(days(15, DateTime(2026, 3, 12)), 3);
  });

  test('is zero on the due day itself', () {
    expect(days(15, DateTime(2026, 3, 15)), 0);
  });

  test('rolls into next month once the day has passed', () {
    expect(days(1, DateTime(2026, 3, 20)), 12); // Mar 20 -> Apr 1
  });

  test('a 31st due day clamps in February rather than skipping the month', () {
    expect(days(31, DateTime(2026, 2, 20)), 8); // -> Feb 28
  });

  test('crosses the year boundary', () {
    expect(days(3, DateTime(2026, 12, 30)), 4); // -> Jan 3
  });
}
