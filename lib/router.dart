import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/settings_provider.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding/intro_screen.dart';
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
/// flashes the app — and worse, `HomeScreen` opens the setup flow from its
/// first post-frame callback, so the flash would start it *before* the user
/// had chosen anything.
class _LaunchGate extends ConsumerWidget {
  const _LaunchGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(onboardingSeenProvider)
        .when(
          data: (seen) => seen ? const HomeScreen() : const _FirstRun(),
          loading: () => const _Splash(),
          // Not the welcome screen: an unreadable database (a lost startup
          // race, 2026-10-19) is not a new user, and "Sign in, or skip" to a
          // signed-in user reads as "your data is gone".
          error: (_, _) => _LaunchError(
            onRetry: () => ref.invalidate(onboardingSeenProvider),
          ),
        );
  }
}

/// A new install: what SwipeWise does (no asks), then sign in or skip. The
/// rest of setup (cards, alerts) runs from Home, because answering the welcome
/// screen re-keys the user on sign-in and rebuilds this gate.
class _FirstRun extends StatefulWidget {
  const _FirstRun();

  @override
  State<_FirstRun> createState() => _FirstRunState();
}

class _FirstRunState extends State<_FirstRun> {
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: _started
          ? const WelcomeScreen()
          : IntroScreen(onStart: () => setState(() => _started = true)),
    );
  }
}

/// The onboarding flag couldn't be read even after retries.
class _LaunchError extends StatelessWidget {
  const _LaunchError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "SwipeWise couldn't open your data",
                style: AppText.titleMd(),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Nothing is lost. Try again in a moment.',
                style: AppText.bodySm(),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Held for the few milliseconds it takes to read the onboarding flag.
///
/// Deliberately empty: Android's own launch screen (the card logo on this same
/// dark background, `res/values-v31/styles.xml`) has just been on screen, and a
/// second, different logo here read as two splash screens (2026-10-20).
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: AppColors.background);
  }
}
