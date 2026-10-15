import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/types.dart';
import 'package:swipewise/notifications/activation_reminder_service.dart';

/// The quarter-start activation reminder (D2/N3): when it fires, and that it
/// never names categories the catalog doesn't have.
void main() {
  WalletRewardRow row(String label) => WalletRewardRow(
    ruleId: label,
    label: label,
    categoryName: label.toLowerCase(),
    brandId: null,
    isBaseline: false,
    amount: 5,
    currency: 'POINTS',
    iconId: null,
  );

  group('nextQuarterStart', () {
    test('mid-quarter points at the next quarter, 09:00', () {
      expect(
        ActivationReminderService.nextQuarterStart(DateTime(2026, 10, 14)),
        DateTime(2027, 1, 1, 9),
      );
      expect(
        ActivationReminderService.nextQuarterStart(DateTime(2026, 2, 28)),
        DateTime(2026, 4, 1, 9),
      );
    });

    test('a quarter-start day still points at the following quarter', () {
      // Fired today already (or is about to); the top-up on app open must not
      // reschedule it for the same instant.
      expect(
        ActivationReminderService.nextQuarterStart(DateTime(2026, 7, 1, 8)),
        DateTime(2026, 10, 1, 9),
      );
    });
  });

  group('text', () {
    const flex = RotatingSchedule(
      issuerName: 'Chase',
      requiresActivation: true,
      rate: 5,
      currency: 'POINTS',
    );

    test('names the starting quarter\'s categories and end date', () {
      final t = ActivationReminderService.text(
        cardName: 'Freedom Flex',
        schedule: flex,
        quarter: RotatingQuarter(
          year: 2027,
          quarter: 1,
          rows: [row('Grocery'), row('Streaming')],
        ),
      );
      expect(t.title, 'Freedom Flex: Q1 bonus categories start today');
      expect(
        t.body,
        'Activate at Chase to earn 5x on Grocery and Streaming through Mar 31.',
      );
    });

    test('with no categories announced, names none', () {
      final t = ActivationReminderService.text(
        cardName: 'Discover it',
        schedule: const RotatingSchedule(
          issuerName: 'Discover',
          requiresActivation: true,
          rate: 5,
          currency: 'USD',
        ),
      );
      expect(t.title, 'Discover it: a new 5% quarter starts today');
      expect(t.body, 'Activate with Discover to earn it.');
    });
  });
}
