import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:swipewise/models/card.dart';
import 'package:swipewise/models/reward_category.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/data_providers.dart';
import 'package:swipewise/screens/onboarding/intro_screen.dart';
import 'package:swipewise/screens/onboarding/onboarding_ui.dart';
import 'package:swipewise/screens/onboarding/setup_flow.dart';
import 'package:swipewise/screens/welcome_screen.dart';
import 'package:swipewise/theme/app_theme.dart';

/// The first-run setup (design "Onboarding v4 — hybrid"): which step comes
/// next, what the tracker shows, and that every screen lays out on a phone
/// and at large text without overflowing.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('nextAlertStep', () {
    test('asks in order: notifications, location, all the time', () {
      expect(nextAlertStep(const Perms()), FlowStep.notifications);
      expect(
        nextAlertStep(const Perms(notifications: true)),
        FlowStep.location,
      );
      expect(
        nextAlertStep(const Perms(notifications: true, location: true)),
        FlowStep.always,
      );
      expect(
        nextAlertStep(
          const Perms(notifications: true, location: true, always: true),
        ),
        FlowStep.done,
      );
    });

    test("a step Android won't ask for again goes to Settings", () {
      expect(
        nextAlertStep(const Perms(notificationsBlocked: true)),
        FlowStep.notificationsBlocked,
      );
      expect(
        nextAlertStep(const Perms(notifications: true, locationBlocked: true)),
        FlowStep.locationBlocked,
      );
    });
  });

  group('trackerFor', () {
    test('alerts off marks the first missing step red, later ones grey', () {
      final t = trackerFor(
        FlowStep.alertsOff,
        const Perms(notifications: true),
        true,
      );
      expect(t[SetupStep.cards], TrackState.done);
      expect(t[SetupStep.notifications], TrackState.done);
      expect(t[SetupStep.location], TrackState.off);
      expect(t[SetupStep.always], TrackState.todo);
    });

    test('the current step is ringed; done steps stay done', () {
      final t = trackerFor(
        FlowStep.always,
        const Perms(notifications: true, location: true),
        true,
      );
      expect(t[SetupStep.location], TrackState.done);
      expect(t[SetupStep.always], TrackState.now);
    });

    test('no cards: nothing asked, all four grey', () {
      final t = trackerFor(FlowStep.noCards, const Perms(), false);
      expect(t.values.toSet(), {TrackState.todo});
    });
  });

  group('stepFor (tapping the tracker)', () {
    test('each step opens its screen; a blocked one its Settings screen', () {
      const p = Perms(notifications: true, location: true);
      expect(stepFor(SetupStep.cards, p, true), FlowStep.cardsAdded);
      expect(stepFor(SetupStep.notifications, p, true), FlowStep.notifications);
      expect(stepFor(SetupStep.always, p, true), FlowStep.always);
      expect(
        stepFor(SetupStep.location, const Perms(locationBlocked: true), true),
        FlowStep.locationBlocked,
      );
    });

    test('all the time without location goes to location first', () {
      expect(
        stepFor(SetupStep.always, const Perms(notifications: true), true),
        FlowStep.location,
      );
    });

    test('no cards: every step leads to cards, nothing is asked', () {
      for (final s in SetupStep.values) {
        expect(stepFor(s, const Perms(), false), FlowStep.cards);
      }
    });
  });

  test('card names as the design shows them', () {
    expect(shortCardName('Chase Freedom Flex® Credit Card'), 'Freedom Flex');
    expect(
      shortCardName('Chase Sapphire Preferred® Card'),
      'Sapphire Preferred',
    );
    expect(shortCardName('Card'), 'Card');
    expect(formatPickRate(3, 'USD'), '3%');
    expect(formatPickRate(1.5, 'USD'), '1.5%');
    expect(formatPickRate(2, 'POINTS'), '2x');
  });

  final cards = [
    CardSummary(
      cardId: 'a',
      source: 'manual',
      name: 'Chase Freedom Flex® Credit Card',
      lastFour: '5764',
      network: 'Mastercard',
      txCount: 0,
      balance: 0,
    ),
    CardSummary(
      cardId: 'b',
      source: 'manual',
      name: 'Chase Sapphire Preferred® Credit Card',
      network: 'Visa',
      txCount: 0,
      balance: 0,
    ),
  ];
  final tiles = [
    CategoryTileData(
      category: RewardCategory.drugStores,
      bestRate: 3,
      bestCardName: 'Chase Freedom Flex® Credit Card',
      isBonus: true,
      brandBonusCount: 0,
    ),
    CategoryTileData(
      category: RewardCategory.dining,
      bestRate: 3,
      bestCardName: 'Chase Freedom Flex® Credit Card',
      isBonus: true,
      brandBonusCount: 0,
    ),
    CategoryTileData(
      category: RewardCategory.travel,
      bestRate: 2,
      bestCardName: 'Chase Sapphire Preferred® Credit Card',
      isBonus: true,
      brandBonusCount: 0,
      currency: 'POINTS',
    ),
  ];

  Future<void> pump(
    WidgetTester tester,
    FlowStep start, {
    Perms perms = const Perms(),
    List<CardSummary>? wallet,
    double textScale = 1,
    Size size = const Size(360, 740),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cardsProvider.overrideWith((ref) async => wallet ?? cards),
          categoryTilesProvider.overrideWith((ref) async => tiles),
        ],
        child: MaterialApp(
          theme: darkTheme(),
          home: SetupFlow(start: start, readPerms: () async => perms),
        ),
      ),
    );
    // Not pumpAndSettle: the map's pulse repeats for as long as it shows.
    await tester.pump(const Duration(seconds: 1));
  }

  const headings = {
    FlowStep.cards: 'Add your cards',
    FlowStep.cardsAdded: '2 cards added',
    FlowStep.notifications: 'Turn on notifications',
    FlowStep.notificationsBlocked: 'Turn on notifications in Settings',
    FlowStep.location: 'Allow location',
    FlowStep.locationBlocked: 'Turn on location in Settings',
    FlowStep.always: 'Allow location all the time',
    FlowStep.done: "You're set up",
    FlowStep.alertsOff: 'Store alerts are off',
    FlowStep.noCards: 'Add a card to get started',
  };

  for (final MapEntry(key: step, value: heading) in headings.entries) {
    testWidgets('${step.name} lays out on a small phone', (tester) async {
      await pump(tester, step, wallet: step == FlowStep.noCards ? [] : null);
      expect(find.text(heading), findsWidgets);
    });
  }

  testWidgets('cards added: their own cards and where each wins', (
    tester,
  ) async {
    await pump(tester, FlowStep.cardsAdded, size: const Size(412, 915));
    expect(find.text('Freedom Flex'), findsWidgets);
    expect(find.text('•••• 5764'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('Drug Stores'), findsOneWidget);
    expect(find.text('Sapphire Preferred'), findsWidgets);
    expect(find.text('2x'), findsOneWidget);
  });

  testWidgets('the alert names their own best card for the store', (
    tester,
  ) async {
    await pump(tester, FlowStep.notifications);
    expect(find.text("You're at Walgreens"), findsOneWidget);
    expect(find.text('Use Freedom Flex for'), findsOneWidget);
    expect(find.text('3%'), findsOneWidget);
  });

  testWidgets('all the time shows the full Play disclosure', (tester) async {
    await pump(
      tester,
      FlowStep.always,
      perms: const Perms(notifications: true, location: true),
    );
    expect(
      find.text('SwipeWise uses your location in the background'),
      findsOneWidget,
    );
    expect(find.textContaining('even when the app is closed'), findsOneWidget);
    expect(find.textContaining('Google Places'), findsOneWidget);
  });

  testWidgets('at 2x text the picture goes and nothing overflows', (
    tester,
  ) async {
    await pump(
      tester,
      FlowStep.always,
      perms: const Perms(notifications: true, location: true),
      textScale: 2,
    );
    expect(find.text('CLOSED'), findsNothing);
    expect(find.text('Allow location all the time'), findsOneWidget);
  });

  testWidgets('a restored wallet moves "Add your cards" on by itself', (
    tester,
  ) async {
    // The backup restore can land after setup opened at "Add your cards":
    // someone who signed in must not be asked for cards they already have.
    await pump(tester, FlowStep.cards);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2 cards added'), findsOneWidget);
  });

  testWidgets('tapping a step on the tracker goes back to it', (tester) async {
    await pump(
      tester,
      FlowStep.done,
      perms: const Perms(notifications: true, location: true, always: true),
    );
    expect(find.text("You're set up"), findsOneWidget);
    await tester.tap(find.text('Location'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Allow location'), findsWidgets);
  });

  testWidgets('Not now on cards asks nothing and says so', (tester) async {
    await pump(tester, FlowStep.cards, wallet: []);
    await tester.tap(find.text('Not now'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Add a card to get started'), findsOneWidget);
    expect(find.textContaining('nothing has been asked'), findsOneWidget);
  });

  testWidgets('Not now on notifications: alerts off, naming what is missing', (
    tester,
  ) async {
    await pump(tester, FlowStep.notifications);
    await tester.tap(find.text('Not now'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Store alerts are off'), findsOneWidget);
    expect(find.textContaining('They need notifications'), findsOneWidget);
    expect(find.text('PAUSED'), findsOneWidget);
  });

  testWidgets('intro at 2x text: no picture, nothing overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: IntroScreen(onStart: () {}),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('10:42'), findsNothing);
    expect(find.text('Start setup'), findsOneWidget);
  });

  testWidgets('intro: the welcome, with nothing asked', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: IntroScreen(onStart: () => started = true),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Welcome to SwipeWise'), findsOneWidget);
    expect(find.text('3x'), findsOneWidget);
    await tester.tap(find.text('Start setup'));
    expect(started, isTrue);
  });

  testWidgets('approximate location surfaces Precise location needed', (
    tester,
  ) async {
    await pump(
      tester,
      FlowStep.locationBlocked,
      perms: const Perms(
        notifications: true,
        locationBlocked: true,
        preciseLocation: false,
      ),
    );
    expect(find.text('Precise location needed'), findsOneWidget);
  });

  testWidgets('WelcomeScreen does not overflow in landscape at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_FixedAuth.new),
        ],
        child: MaterialApp(
          theme: darkTheme(),
          home: const WelcomeScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FixedAuth extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoggedIn: true, userId: 'local:test');
}
