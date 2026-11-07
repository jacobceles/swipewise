import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/providers/auth_provider.dart';
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
  Future<void> setSeconds(String category, int seconds) async {
    state = {...state, category: seconds};
  }
}

class _SignedOut extends AuthNotifier {
  @override
  AuthState build() => AuthState();
}

void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Map<String, int>? initial,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_SignedOut.new),
          nearbyDwellProvider.overrideWith(
            () =>
                _MemoryDwell(initial ?? SettingsRepository.defaultDwellSeconds),
          ),
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

  testWidgets('always shows each kind with its default and ten-second steps', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final container = await pump(tester);
    expect(find.text('Same for all'), findsNothing);
    expect(find.text('By kind of visit'), findsNothing);
    expect(find.text('Every visit'), findsNothing);
    expect(find.byType(WaitStepper), findsNWidgets(6));
    for (final kind in SettingsRepository.defaultDwellSeconds.keys) {
      expect(find.text(kind), findsOneWidget);
    }
    expect(container.read(nearbyDwellProvider)['Gas'], 10);
    expect(container.read(nearbyDwellProvider)['Dining'], 30);
    expect(
      tester.widget<WaitStepper>(find.byType(WaitStepper).first).options,
      List.generate(90, (i) => (i + 1) * 10),
    );
    await tester.tap(find.bySemanticsLabel('Longer wait for Dining'));
    await tester.pumpAndSettle();
    expect(container.read(nearbyDwellProvider)['Dining'], 40);
    expect(container.read(nearbyDwellProvider)['Gas'], 10);
    await tester.ensureVisible(find.bySemanticsLabel('Shorter wait for Gas'));
    await tester.tap(find.bySemanticsLabel('Shorter wait for Gas'));
    await tester.pumpAndSettle();
    expect(container.read(nearbyDwellProvider)['Gas'], 10);
    await tester.tap(find.bySemanticsLabel('Longer wait for Gas'));
    await tester.pumpAndSettle();
    expect(container.read(nearbyDwellProvider)['Gas'], 20);
    expect(container.read(nearbyDwellProvider)['Dining'], 40);
    semantics.dispose();
  });

  testWidgets(
    'uniform saved values remain per-kind and Reset restores every default',
    (tester) async {
      final container = await pump(
        tester,
        initial: {
          for (final k in SettingsRepository.defaultDwellSeconds.keys) k: 60,
        },
      );
      expect(find.byType(WaitStepper), findsNWidgets(6));
      expect(container.read(nearbyDwellProvider).values.toSet(), {60});
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(
        container.read(nearbyDwellProvider),
        SettingsRepository.defaultDwellSeconds,
      );
      expect(container.read(nearbyDwellProvider)['Gas'], 10);
      expect(container.read(nearbyDwellProvider)['Dining'], 30);
    },
  );

  testWidgets('narrow screen fits and stepping stops at fifteen minutes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final container = await pump(
      tester,
      initial: {...SettingsRepository.defaultDwellSeconds, 'Dining': 890},
    );
    expect(find.text('14m 50s'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Longer wait for Dining'));
    await tester.pumpAndSettle();
    expect(find.text('15 min'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Longer wait for Dining'));
    await tester.pumpAndSettle();
    expect(container.read(nearbyDwellProvider)['Dining'], 900);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
