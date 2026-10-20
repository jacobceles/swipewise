import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/models/card.dart';
import 'package:swipewise/providers/data_providers.dart';
import 'package:swipewise/providers/entitlement_provider.dart';
import 'package:swipewise/screens/cards_screen.dart';
import 'package:swipewise/theme/app_theme.dart';

/// The Cards tab has two versions (wireframe "Cards — Free tier", z8kQf):
/// free has no bank data, so it never shows Used or Available.
void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    sqfliteFfiInit();
  });

  setUp(() {
    DatabaseHelper.setTestDatabaseFactory(
      () => databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      ),
    );
  });

  tearDown(() async {
    await (await DatabaseHelper().database).close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  CardSummary card(String id, String name, {double? limit}) => CardSummary(
    cardId: id,
    source: 'manual',
    provider: 'Amex',
    name: name,
    institutionId: 'manual:amex',
    accountType: 'CREDIT_CARD',
    txCount: 0,
    balance: 0,
    creditLimit: limit,
  );

  Future<void> pump(
    WidgetTester tester, {
    required bool pro,
    required List<CardSummary> cards,
  }) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cardsProvider.overrideWith((ref) async => cards),
          bankConnectionsByInstitutionIdProvider.overrideWith(
            (ref) async => const {},
          ),
          proEntitlementProvider.overrideWith(() => _Fixed(pro)),
        ],
        child: MaterialApp(
          theme: darkTheme(),
          home: const Scaffold(body: CardsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('free without limits: no totals, no Used/Available', (
    tester,
  ) async {
    await pump(tester, pro: false, cards: [card('a', 'Gold')]);
    expect(find.text('Used'), findsNothing);
    expect(find.text('Available'), findsNothing);
    expect(find.text('Total limit'), findsNothing);
  });

  testWidgets('free with a limit: one Total limit tile', (tester) async {
    await pump(
      tester,
      pro: false,
      cards: [card('a', 'Gold', limit: 10000), card('b', 'Blue Cash')],
    );
    expect(find.text('Total limit'), findsOneWidget);
    expect(find.text(r'$10,000'), findsWidgets);
    expect(find.text('Used'), findsNothing);
    expect(find.text('Available'), findsNothing);
  });

  testWidgets('pro keeps Used / Limit / Available', (tester) async {
    await pump(tester, pro: true, cards: [card('a', 'Gold', limit: 10000)]);
    expect(find.text('Used'), findsWidgets);
    expect(find.text('Available'), findsWidgets);
    expect(find.text('Total limit'), findsNothing);
  });
}

class _Fixed extends ProEntitlementNotifier {
  _Fixed(this.value);
  final bool value;

  @override
  bool build() => value;
}
