import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:swipewise/models/card.dart';
import 'package:swipewise/providers/nearby_providers.dart';
import 'package:swipewise/providers/settings_provider.dart';
import 'package:swipewise/screens/profile/account_page.dart';
import 'package:swipewise/screens/profile/alert_timing_page.dart';
import 'package:swipewise/screens/profile/card_preference_page.dart';
import 'package:swipewise/screens/profile/profile_ui.dart';
import 'package:swipewise/screens/profile/store_alerts_card.dart';
import 'package:swipewise/theme/app_theme.dart';

CardSummary _card(String id) =>
    CardSummary(cardId: id, source: 'manual', name: id, txCount: 0, balance: 0);

class _FixedNearby extends NearbyEnabledNotifier {
  _FixedNearby(this.on);
  final bool on;

  @override
  bool build() => on;
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required bool nearbyOn,
  required Map<AlertCheck, bool> checks,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        nearbyEnabledProvider.overrideWith(() => _FixedNearby(nearbyOn)),
        alertChecksProvider.overrideWith((ref) async => checks),
      ],
      child: MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: StoreAlertsCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _allOk = {
  AlertCheck.notifications: true,
  AlertCheck.location: true,
  AlertCheck.activity: true,
  AlertCheck.battery: true,
  AlertCheck.alarms: true,
};

void main() {
  group('StoreAlertsCard', () {
    testWidgets('healthy: one quiet line, nothing to fix', (tester) async {
      await _pumpCard(tester, nearbyOn: true, checks: _allOk);
      expect(find.text("All set — we'll nudge you in stores"), findsOneWidget);
      expect(find.text('Fix'), findsNothing);
      expect(find.text('Allow'), findsNothing);
      // The four requirements only appear when one is missing.
      expect(find.text('Battery'), findsNothing);
      expect(find.text('Alert timing & muted stores'), findsOneWidget);
    });

    testWidgets('paused: notifications or location missing, one fix row each', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        nearbyOn: true,
        checks: {
          ..._allOk,
          AlertCheck.notifications: false,
          AlertCheck.location: false,
        },
      );
      expect(find.text('Store alerts are paused'), findsOneWidget);
      expect(find.text('2 phone settings need a quick fix'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
      expect(
        find.text('Physical activity, battery and alarms are fine'),
        findsOneWidget,
      );
    });

    testWidgets('physical activity has its own row, and alerts still arrive', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        nearbyOn: true,
        checks: {..._allOk, AlertCheck.activity: false},
      );
      expect(find.text("All set — we'll nudge you in stores"), findsOneWidget);
      expect(find.text('Alerts may be late'), findsNothing);
      expect(find.text('Physical activity'), findsOneWidget);
      expect(find.text('Tells walking in from driving past'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);
    });

    testWidgets('paused: location alone is enough to stop alerts', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        nearbyOn: true,
        checks: {..._allOk, AlertCheck.location: false},
      );
      expect(find.text('Store alerts are paused'), findsOneWidget);
    });

    testWidgets('late: only battery missing still delivers, later', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        nearbyOn: true,
        checks: {..._allOk, AlertCheck.battery: false},
      );
      expect(find.text('Alerts may be late'), findsOneWidget);
      expect(find.text('1 phone setting needs a quick fix'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
    });

    testWidgets('off: no checks shown — they only matter when alerts are on', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        nearbyOn: false,
        checks: {..._allOk, AlertCheck.notifications: false},
      );
      expect(find.text('Get your best card as you walk in'), findsOneWidget);
      expect(find.text('Notifications'), findsNothing);
      expect(find.text('Allow'), findsNothing);
    });
  });

  group('helpers', () {
    test('uniformDwell is the shared wait, or null once any kind differs', () {
      expect(uniformDwell({'Dining': 60, 'Gas': 60}), 60);
      expect(uniformDwell({'Dining': 60, 'Gas': 300}), isNull);
    });

    test(
      'orderCards follows the saved order, then keeps the rest in place',
      () {
        final cards = [_card('a'), _card('b'), _card('c')];
        expect(orderCards(cards, const []).map((c) => c.cardId), [
          'a',
          'b',
          'c',
        ]);
        expect(
          orderCards(cards, const ['c', 'gone', 'a']).map((c) => c.cardId),
          ['c', 'a', 'b'],
        );
      },
    );

    test('backupWhen reads as a day, not a timestamp', () {
      final now = DateTime(2026, 10, 16, 21);
      expect(
        backupWhen(DateTime(2026, 10, 16, 9, 12), now: now),
        startsWith('today, 9:12'),
      );
      expect(
        backupWhen(DateTime(2026, 10, 15, 9, 12), now: now),
        startsWith('yesterday'),
      );
      expect(backupWhen(DateTime(2026, 10, 3, 9, 12), now: now), '3 Oct');
    });

    test('initialsOf takes a display name, or the local part of an email', () {
      expect(initialsOf('Jacob Celestine'), 'JC');
      expect(initialsOf('jacob.celestine@example.com'), 'JC');
      expect(initialsOf('jacob@example.com'), 'JA');
      expect(initialsOf(null), '?');
    });

    test('fineLine names what works in a sentence', () {
      expect(fineLine([AlertCheck.alarms]), 'Alarms are fine');
      expect(fineLine([AlertCheck.location]), 'Location is fine');
      expect(
        fineLine([AlertCheck.battery, AlertCheck.alarms]),
        'Battery and alarms are fine',
      );
      expect(
        fineLine([
          AlertCheck.notifications,
          AlertCheck.location,
          AlertCheck.alarms,
        ]),
        'Notifications, location and alarms are fine',
      );
    });

    test('cardPreferenceSummary', () {
      final cards = [_card('a'), _card('b')];
      expect(cardPreferenceSummary([_card('a')], const []), 'Needs 2 cards');
      expect(cardPreferenceSummary(cards, const []), 'Not set');
      expect(cardPreferenceSummary(cards, const ['b']), 'b first');
    });

    test('formatWait and countOf', () {
      expect(formatWait(60), '1 min');
      expect(formatWait(90), '1m 30s');
      expect(countOf(1, 'card'), '1 card');
      expect(countOf(3, 'card'), '3 cards');
    });
  });
}
