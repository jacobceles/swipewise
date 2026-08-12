import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/data_repository.dart';
import '../api/entitlement_client.dart';
import '../api/settings_repository.dart';
import '../build_config.dart';
import 'auth_provider.dart';

final _settings = SettingsRepository(DataRepository());

final entitlementClientProvider = Provider<EntitlementClient>(
  (ref) => EntitlementClient(),
);

/// Whether this user has Pro.
///
/// The single question every Pro-gated screen, tab and setting asks — and
/// deliberately still a **synchronous `bool`**, even though the answer now
/// comes from a server. Seventeen call sites across eight files read it; making
/// it a `FutureProvider` would push an `AsyncValue` into every one of their
/// build methods for no gain. As a `Notifier` it seeds from cache, refreshes in
/// the background, and every watcher rebuilds the moment the answer lands —
/// which *is* "the UI changes when you subscribe".
///
/// ## This is not the security boundary
///
/// A patched binary can force this true. That is inherent and accepted: the
/// features it would reveal need data only the account service can produce, and
/// that service checks entitlement itself before signing anything. Forcing this
/// true buys a set of empty screens.
///
/// ## Offline
///
/// The cached answer is trusted **indefinitely**, and downgraded only when the
/// server explicitly says `false`. A stale `true` can never hand out free
/// service, so the cost of trusting it too long is cosmetic — while expiring it
/// would strand a paying subscriber who was simply out of signal. The cache
/// lives in `settings` and is excluded from wallet backup, so it cannot travel
/// to another phone.
class ProEntitlementNotifier extends Notifier<bool> {
  @override
  bool build() {
    final userId = ref.watch(authProvider.select((s) => s.userId));
    if (userId != null) {
      Future.microtask(() => _load(userId));
    }
    // `proSeed` is the local-development escape hatch: a `keys.pro.json` build
    // is Pro without a server. Released builds ship false, so the server is the
    // only thing that can grant it.
    return BuildConfig.proSeed;
  }

  Future<void> _load(String userId) async {
    final cached = await _settings.getProCached(userId);
    if (!ref.mounted) return;
    if (cached && !state) state = true;

    final answer = await ref.read(entitlementClientProvider).isPro();
    if (!ref.mounted || answer == null) return; // couldn't find out — keep cache
    await _settings.setProCached(userId, answer);
    if (!ref.mounted) return;
    if (state != (answer || BuildConfig.proSeed)) {
      state = answer || BuildConfig.proSeed;
    }
  }

  /// Re-asks the server. Call after anything that could change the answer —
  /// signing in, or completing a purchase.
  Future<void> refresh() async {
    final userId = ref.read(authProvider).userId;
    if (userId != null) await _load(userId);
  }
}

final proEntitlementProvider = NotifierProvider<ProEntitlementNotifier, bool>(
  ProEntitlementNotifier.new,
);
