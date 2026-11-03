import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/providers/nearby_providers.dart';
import 'package:swipewise/providers/settings_provider.dart';
import 'package:swipewise/screens/profile/alert_timing_page.dart';
import 'package:swipewise/theme/app_theme.dart';

class _MemoryDwell extends NearbyDwellNotifier {
  _MemoryDwell(this.initial);
  final Map<String, int> initial;

  @override
  Map<String, int> build() => Map.of(initial);

  @override
  Future<void> setAll(int seconds) async {
    state = {for (final kind in state.keys) kind: seconds};
  }

  @override
  Future<void> setSeconds(String category, int seconds) async {
    state = {...state, category: seconds};
  }
}

void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Map<String, int> initial = SettingsRepository.defaultDwellSeconds,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nearbyDwellProvider.overrideWith(() => _MemoryDwell(initial)),
          mutedMerchantsListProvider.overrideWith((_) async => []),
        ],
        child: MaterialApp(theme: darkTheme(), home: const AlertTimingPage()),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(AlertTimingPage)),
    );
  }

  testWidgets(
    'every ten-second wait is selectable without changing the default',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final container = await pump(tester);
        expect(find.text('30 s'), findsOneWidget);
        expect(
          tester.widget<WaitStepper>(find.byType(WaitStepper)).options,
          List.generate(90, (i) => (i + 1) * 10),
        );
        for (final seconds in [20, 10]) {
          await tester.tap(
            find.bySemanticsLabel('Shorter wait for every visit'),
          );
          await tester.pumpAndSettle();
          expect(find.text('$seconds s'), findsOneWidget);
          expect(container.read(nearbyDwellProvider).values.toSet(), {seconds});
        }
        await tester.tap(find.bySemanticsLabel('Shorter wait for every visit'));
        await tester.pumpAndSettle();
        expect(container.read(nearbyDwellProvider).values.toSet(), {10});
        for (var seconds = 20; seconds <= 70; seconds += 10) {
          await tester.tap(
            find.bySemanticsLabel('Longer wait for every visit'),
          );
          await tester.pumpAndSettle();
          expect(container.read(nearbyDwellProvider).values.toSet(), {seconds});
        }
        expect(find.text('1m 10s'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('per-kind ten-second change does not alter other kinds', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final container = await pump(
        tester,
        initial: {...SettingsRepository.defaultDwellSeconds, 'Dining': 10},
      );
      await tester.tap(find.bySemanticsLabel('Longer wait for Dining'));
      await tester.pumpAndSettle();
      expect(container.read(nearbyDwellProvider)['Dining'], 20);
      expect(container.read(nearbyDwellProvider)['Coffee'], 30);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'opening preserves a saved minute and Reset uses thirty seconds',
    (tester) async {
      final container = await pump(
        tester,
        initial: {
          for (final k in SettingsRepository.defaultDwellSeconds.keys) k: 60,
        },
      );
      expect(find.text('1 min'), findsOneWidget);
      expect(container.read(nearbyDwellProvider).values.toSet(), {60});
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(find.text('30 s'), findsOneWidget);
      expect(container.read(nearbyDwellProvider).values.toSet(), {30});
    },
  );

  testWidgets(
    'long fractional-minute label fits a narrow screen and stops at fifteen minutes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        final container = await pump(
          tester,
          initial: {
            for (final k in SettingsRepository.defaultDwellSeconds.keys) k: 890,
          },
        );
        expect(find.text('14m 50s'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.bySemanticsLabel('Longer wait for every visit'));
        await tester.pumpAndSettle();
        expect(find.text('15 min'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Longer wait for every visit'));
        await tester.pumpAndSettle();
        expect(container.read(nearbyDwellProvider).values.toSet(), {900});
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
