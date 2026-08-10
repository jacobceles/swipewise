import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/entitlement_provider.dart';
import 'providers/auth_provider.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/add_bank_v2_screen.dart';
import 'screens/add_cards_screen.dart';

class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen<AuthState>(authProvider, (prev, next) {
      if (prev?.isLoggedIn != next.isLoggedIn) notifyListeners();
    });
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable(ref);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: listenable,
    redirect: (context, state) {
      // Without Pro there is nothing to sign in to: `AuthNotifier` provisions
      // a device-local identity on first launch, so there is no signed-out
      // state to guard. Read, not watched — a redirect callback runs per
      // navigation and re-reads this each time.
      if (!ref.read(proEntitlementProvider)) return null;

      final isLoggedIn = ref.read(authProvider).isLoggedIn;
      final isLoggingIn = state.matchedLocation == '/login';

      if (!isLoggedIn && !isLoggingIn) return '/login';
      if (isLoggedIn && isLoggingIn) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
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
