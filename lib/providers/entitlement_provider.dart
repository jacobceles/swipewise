import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../build_config.dart';

/// Whether this user has Pro.
///
/// The single question every Pro-gated screen, tab and setting asks. It is a
/// provider rather than a constant on purpose: Pro is sold as an in-app
/// subscription, so the answer belongs to the *user*, not to the build, and it
/// can change while the app is running (the moment a purchase completes).
///
/// Today it answers from [BuildConfig.proSeed], a `--dart-define` — which makes
/// a local `keys.pro.json` build fully Pro for development, and the published
/// build fail closed. That is scaffolding. When the entitlement service exists
/// this becomes a real lookup:
///
/// ```dart
/// final proEntitlementProvider = FutureProvider<bool>((ref) async {
///   final token = await ref.watch(idTokenProvider.future);
///   return ref.watch(entitlementApiProvider).isPro(token);   // server-verified
/// });
/// ```
///
/// Everything downstream is already written against "ask this provider", so
/// that swap touches this file and nothing else.
///
/// ⚠️ **Ordering, and it is not negotiable.** The aggregator credentials must
/// move server-side *before* this starts returning true for anyone but the
/// developer. Today the Pro code is dormant because the published build has no
/// credentials to run it with; flipping entitlement on without having moved
/// them would hand those credentials to every subscriber, and to anyone who
/// pirates the APK. See `analysis/free-tier-split-plan.md` §B3-S1.
///
/// A patched binary can force this true. That is inherent to the model and
/// accepted: the Pro features it would reveal need credentials the app doesn't
/// carry and data the server won't serve, so the reward is a set of empty
/// screens.
final proEntitlementProvider = Provider<bool>((ref) => BuildConfig.proSeed);
