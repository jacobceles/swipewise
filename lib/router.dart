import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'providers/settings_provider.dart';
import 'screens/home_screen.dart';
import 'screens/welcome_screen.dart';
import 'screens/add_bank_v2_screen.dart';
import 'screens/add_cards_screen.dart';
import 'theme/app_theme.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // No redirect, and no auth guard. Signing in is optional in both tiers —
  // it attaches an identity, it does not unlock the app — so there is no
  // signed-out state to bounce anyone out of. What used to live here as a
  // Pro-only `/login` redirect is now [_LaunchGate], which decides between
  // the welcome screen and the app from the user's own answer.
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const _LaunchGate()),
      // Build a wallet straight off the catalog, no bank. The only way to add
      // a card in a free build, and available in Pro too — plenty of cards
      // aren't behind a linkable bank.
      GoRoute(
        path: '/add-cards',
        builder: (context, state) => const AddCardsScreen(),
      ),
      // Bank linking now uses the v2 in-app flow (institution picker +
      // credentials form + MFA loop). The old `widget.sophtron.com`
      // WebView flow was removed when we migrated to v2 entirely.
      // Registered unconditionally. Entitlement gates the *entry points* to
      // this screen, not the route: a route table that changes shape with
      // entitlement makes navigation depend on when the answer arrived, and
      // an unregistered route throws rather than degrading. Reaching it
      // without Pro yields a screen that cannot connect anything.
      GoRoute(
        path: '/add-bank',
        // Optional query params: mode=reconnect, institutionId,
        // institutionName, institutionLogo - when set, AddBankV2Screen skips
        // the Institution Picker and lands the user straight on the
        // credentials form for the named bank. `wasBroken=1` is additionally
        // passed only when the user came from a connection actually flagged
        // failed, so the credentials form shows "your connection has
        // expired" copy. Manual reconnects (from the bank info sheet) omit
        // `wasBroken` so we don't lie about the state.
        builder: (context, state) => AddBankV2Screen(
          mode: state.uri.queryParameters['mode'],
          institutionId: state.uri.queryParameters['institutionId'],
          institutionName: state.uri.queryParameters['institutionName'],
          institutionLogo: state.uri.queryParameters['institutionLogo'],
          wasBroken: state.uri.queryParameters['wasBroken'] == '1',
        ),
      ),
    ],
  );
});

/// Chooses between the welcome screen and the app itself.
///
/// Done as a widget rather than a `redirect` because the answer comes out of
/// SQLite: a redirect would have to let `/` build first and then bounce, which
/// flashes the app — and worse, `HomeScreen` fires the four OS permission
/// dialogs from its first post-frame callback, so the flash would put system
/// prompts on screen *before* the user had chosen anything.
class _LaunchGate extends ConsumerWidget {
  const _LaunchGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(onboardingSeenProvider)
        .when(
          data: (seen) => seen ? const HomeScreen() : const WelcomeScreen(),
          loading: () => const _Splash(),
          // Nothing here is worth an error screen: if the flag can't be read,
          // offering the choice again is harmless — the cost of asking twice
          // is far lower than skipping the choice entirely.
          error: (_, _) => const WelcomeScreen(),
        );
  }
}

/// Held for the few milliseconds it takes to read the onboarding flag.
///
/// Deliberately the welcome screen's own hero, so the first frame the user
/// sees is already in place and neither branch arrives as a jump cut.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SizedBox(
          width: 88,
          height: 88,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              LucideIcons.creditCard,
              size: 38,
              color: AppColors.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
