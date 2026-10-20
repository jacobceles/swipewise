import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:swipewise/models/insights.dart';
import 'package:swipewise/models/reward_category.dart';
import 'package:swipewise/providers/data_providers.dart';
import 'package:swipewise/screens/reward_ranking_sheet.dart';
import 'package:swipewise/theme/app_theme.dart';

/// The ranking sheet's reward-kind filter: it narrows the rows in place, and a
/// kind nobody earns shows an empty state that leads back to All.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  CategoryRewardRanking row(
    String id,
    String name,
    RewardKind kind,
    double rate,
    double eff, {
    bool isBest = false,
    String? currency,
  }) => CategoryRewardRanking(
    cardId: id,
    cardName: name,
    lastFour: '1234',
    rate: rate,
    earnedRecently: 0,
    isBest: isBest,
    kind: kind,
    effectiveCentsPerDollar: eff,
    programName: kind == RewardKind.points ? 'Membership Rewards' : null,
    currency: currency,
  );

  final result = RewardRankingResult(
    general: [
      row('g', 'Amex Gold', RewardKind.points, 4, 8, isBest: true),
      row('f', 'Freedom Flex', RewardKind.cash, 5, 5),
      row('d', 'Double Cash', RewardKind.cash, 2, 2),
      row('u', 'United Explorer', RewardKind.points, 2, 2.6, currency: 'MILES'),
    ],
    brandBonuses: const [],
  );

  Future<void> open(WidgetTester tester) async {
    // Phone-sized, so a row or the filter that overflows fails the test.
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rewardRankingProvider((
            category: RewardCategory.dining,
            merchantName: null,
            brandId: null,
          )).overrideWith((ref) async => result),
        ],
        child: MaterialApp(
          theme: darkTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRewardRankingSheet(
                context,
                category: RewardCategory.dining,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a row shows its last four, never a \$0.00 earned line', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('•••• 1234'), findsWidgets);
    expect(find.textContaining('earned recently'), findsNothing);
  });

  testWidgets('All shows every card with the winner marked Best', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Amex Gold'), findsOneWidget);
    expect(find.text('Freedom Flex'), findsOneWidget);
    expect(find.text('Best'), findsOneWidget);
    expect(find.text('≈ 8¢ back per \$1'), findsOneWidget);
    expect(find.text('5%'), findsOneWidget);

    await tester.tap(find.text('How we rank'));
    await tester.pumpAndSettle();
    expect(find.text('How we rank cards'), findsOneWidget);
    await tester.ensureVisible(find.text('Got it'));
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('How we rank cards'), findsNothing);
  });

  testWidgets('Cash keeps only cash rows and points to the hidden winner', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Cash').first);
    await tester.pumpAndSettle();

    expect(find.text('Amex Gold'), findsNothing);
    expect(find.text('Freedom Flex'), findsOneWidget);
    expect(find.text('Double Cash'), findsOneWidget);
    expect(find.text('Best'), findsNothing);
    expect(find.text('Top cash'), findsOneWidget);
    expect(find.text('Amex Gold earns more here'), findsOneWidget);

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(find.text('Amex Gold'), findsOneWidget);
  });

  testWidgets('Other with no such rewards shows the empty state', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Other'));
    await tester.pumpAndSettle();

    expect(find.text('No “Other” rewards here'), findsOneWidget);
    expect(find.text('Freedom Flex'), findsNothing);

    await tester.tap(find.text('Show all 4 cards'));
    await tester.pumpAndSettle();
    expect(find.text('Freedom Flex'), findsOneWidget);
  });

  testWidgets('Miles get their own tab, apart from Points', (tester) async {
    await open(tester);
    await tester.tap(find.text('Miles').first);
    await tester.pumpAndSettle();
    expect(find.text('United Explorer'), findsOneWidget);
    expect(find.text('Amex Gold'), findsNothing);

    await tester.tap(find.text('Points').first);
    await tester.pumpAndSettle();
    expect(find.text('Amex Gold'), findsOneWidget);
    expect(find.text('United Explorer'), findsNothing);
  });
}
