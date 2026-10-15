import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/providers/data_providers.dart';
import 'package:swipewise/screens/add_cards_screen.dart';

/// The Add-a-Card country filter replaced Profile's "Card Country" setting.
/// It opens on All every time, narrows the grid in place, and tags only the
/// issuers that sell in Canada — and only while nothing is filtered.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  const issuers = [
    CatalogIssuer(
      id: 'Amex',
      displayName: 'American Express',
      productCount: 38,
      countries: {'US', 'CA'},
    ),
    CatalogIssuer(
      id: 'Bmo',
      displayName: 'BMO',
      productCount: 9,
      countries: {'CA'},
    ),
    CatalogIssuer(id: 'Chase', displayName: 'Chase', productCount: 20),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogIssuersProvider.overrideWith((ref) async => issuers),
          walletCountsByIssuerProvider.overrideWith((ref) async => {}),
        ],
        child: const MaterialApp(home: AddCardsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opens on All with every issuer, tagging only Canadian ones', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('ALL ISSUERS'), findsOneWidget);
    expect(find.text('3 issuers'), findsOneWidget);
    expect(find.text('US + CANADA'), findsOneWidget);
    expect(find.text('CANADA'), findsOneWidget);
    expect(find.text('Chase'), findsOneWidget);
  });

  testWidgets('Canada narrows the grid and drops the tags', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Canada'));
    await tester.pumpAndSettle();

    expect(find.text('CANADIAN ISSUERS'), findsOneWidget);
    expect(find.text('2 issuers'), findsOneWidget);
    expect(find.text('Chase'), findsNothing);
    expect(find.text('BMO'), findsOneWidget);
    expect(find.text('US + CANADA'), findsNothing);
  });

  testWidgets('United States keeps Amex and drops BMO', (tester) async {
    await pump(tester);
    await tester.tap(find.text('United States'));
    await tester.pumpAndSettle();

    expect(find.text('US ISSUERS'), findsOneWidget);
    expect(find.text('American Express'), findsOneWidget);
    expect(find.text('BMO'), findsNothing);
  });
}
