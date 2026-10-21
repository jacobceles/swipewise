import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/providers/data_providers.dart';
import 'package:swipewise/screens/add_cards_screen.dart';

/// The issuer grid has a fixed tile height, so the tallest tile — a country
/// tag AND an "N added" line — must still fit (Crashlytics: a 4 px
/// RenderFlex overflow from this tile).
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('a tile with a country tag and an added count fits', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogIssuersProvider.overrideWith(
            (ref) async => const [
              CatalogIssuer(
                id: 'amex',
                displayName: 'American Express',
                productCount: 12,
                countries: {'US', 'CA'},
              ),
            ],
          ),
          walletCountsByIssuerProvider.overrideWith(
            (ref) async => const {'amex': 2},
          ),
        ],
        child: const MaterialApp(home: AddCardsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('US + CANADA'), findsOneWidget);
    expect(find.text('2 added'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
