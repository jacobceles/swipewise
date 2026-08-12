import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'firebase_options.dart';
import 'api/app_check_service.dart';
import 'api/catalog_loader.dart';
import 'api/data_repository.dart';
import 'api/database_helper.dart';
import 'api/remote_asset_service.dart';
import 'api/reward_category_mapper.dart';
import 'api/settings_repository.dart';
import 'providers/entitlement_provider.dart';
import 'nearby/google_places_provider.dart';
import 'nearby/geofence_manager.dart';
import 'nearby/location_service.dart';
import 'nearby/tile_cache.dart';
import 'providers/auth_provider.dart';
import 'providers/data_providers.dart';
import 'providers/nearby_providers.dart';
import 'providers/popular_banks_cache_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/sync_provider.dart';
import 'router.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Device attestation for Worker calls. Must also be activated in the headless
  // geofence isolate below — App Check state is per-isolate.
  await AppCheckService.activate();

  // Route uncaught Flutter framework + async Dart errors to Crashlytics.
  // `onError` covers async zone errors too (Flutter 3.3+), so no
  // `runZonedGuarded` wrapper is needed. Collection is left on in every build
  // (dev + prod are both registered Firebase apps) so tester and dev-device
  // failures surface during internal testing.
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  // Load brand + category recognition into the in-memory classifier registry
  // before the first sync. Tries the local R2 cache first (fast, offline-safe),
  // then falls back to the bundled asset. A background fetch primes the cache
  // for the next cold start. Fallback-safe: a bad asset leaves the table empty.
  final remoteAssets = RemoteAssetService();
  await initBrandRegistry(remote: remoteAssets);
  await initCategoryRegistry(remote: remoteAssets);

  runApp(const ProviderScope(child: SwipeWiseApp()));
}

String? _lastBootstrapSig;

/// In-process debounce for the two `ensureRegistered` triggers (signature
/// change from `_nearbyBootstrapInputs` + sync-complete listener). Without
/// this, both fire within ~ms of each other on sync end and we double-
/// fetch from Google Places + double-write to the native channel. The
/// callback wins the race and the duplicate is cancelled.
Timer? _ensureRegisteredDebounce;

void _scheduleEnsureRegistered(VoidCallback run) {
  _ensureRegisteredDebounce?.cancel();
  _ensureRegisteredDebounce = Timer(const Duration(milliseconds: 750), run);
}

class SwipeWiseApp extends ConsumerWidget {
  const SwipeWiseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    // Re-register native geofences whenever auth or nearby settings change.
    // The signature dedupe stops us re-firing on every Notifier disk-load
    // rebuild during boot - only changed inputs trigger a real run.
    //
    // Gated on `permissionGateCompleteProvider` so the geofence manager's
    // internal `getOneShot()` (which calls Geolocator.requestPermission)
    // doesn't race the up-front permission gate on first launch and null
    // out its dialogs.
    final inputs = ref.watch(_nearbyBootstrapInputs);
    final gateDone = ref.watch(permissionGateCompleteProvider);
    final sig =
        '${inputs.userId}|${inputs.enabled}|${inputs.radius}|${inputs.dwell.entries.map((e) => '${e.key}:${e.value}').join(',')}|${inputs.cardOrder.join(',')}|${inputs.placeTypeIds.join(',')}';
    if (gateDone && inputs.userId != null && _lastBootstrapSig != sig) {
      _lastBootstrapSig = sig;
      _scheduleEnsureRegistered(() {
        ref
            .read(geofenceManagerProvider)
            .ensureRegistered(
              userId: inputs.userId!,
              enabled: inputs.enabled,
              radiusMi: inputs.radius,
              dwellByCategory: inputs.dwell,
              cardPreferenceOrder: inputs.cardOrder,
              categoryIds: inputs.placeTypeIds,
              trigger: 'app',
            );
      });
    }

    // Sync just brought in fresh bank data - re-register so dwell
    // notifications use the new best-card-per-merchant values, not the
    // stale ones we precomputed before the sync ran. Also refresh the
    // popular-banks logo cache so the Add Bank picker stays in sync with
    // any Sophtron-side rebrands without waiting for the next cold start.
    ref.listen<AsyncValue<void>>(syncProvider, (prev, next) {
      if (prev is! AsyncLoading || next is! AsyncData) return;
      // Pro only: the popular-banks cache exists to prime the Add Bank
      // picker, which a non-Pro user cannot open.
      if (ref.read(proEntitlementProvider)) {
        // ignore: unawaited_futures
        ref.read(popularBanksCacheProvider.notifier).refresh();
      }
      final fresh = ref.read(_nearbyBootstrapInputs);
      if (fresh.userId == null || !fresh.enabled) return;
      // Routed through the same debounce as the sig-based trigger so a
      // sync-completion event arriving alongside an inputs change doesn't
      // double-fetch from Google Places or double-write the geofence set.
      _scheduleEnsureRegistered(() {
        ref
            .read(geofenceManagerProvider)
            .ensureRegistered(
              userId: fresh.userId!,
              enabled: fresh.enabled,
              radiusMi: fresh.radius,
              dwellByCategory: fresh.dwell,
              cardPreferenceOrder: fresh.cardOrder,
              categoryIds: fresh.placeTypeIds,
              trigger: 'sync',
            );
      });
    });

    // App-boot prefetch of the popular-banks logo cache so the Add Bank
    // picker renders brand logos instantly the first time it's opened.
    // Fires on the first auth resolution and again whenever the userId
    // flips (post-logout / re-login), best-effort.
    // Pro only, same reason as above.
    if (ref.watch(proEntitlementProvider)) {
      ref.listen<String?>(authProvider.select((s) => s.userId), (prev, next) {
        if (next == null || prev == next) return;
        // ignore: unawaited_futures
        ref.read(popularBanksCacheProvider.notifier).refresh();
      });
      // Initial fire - `ref.listen` itself doesn't deliver the current value,
      // so handle the cold-start case (auth resolves before this listener was
      // attached) explicitly.
      if (ref.read(authProvider).userId != null) {
        Future.microtask(
          () => ref.read(popularBanksCacheProvider.notifier).refresh(),
        );
      }
    }

    return MaterialApp.router(
      title: 'SwipeWise',
      theme: darkTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (context, child) =>
          CatalogStatusGate(child: child ?? const SizedBox.shrink()),
    );
  }
}

/// Wraps the app with a non-blocking banner when the rewards catalog can't be
/// loaded or needs a newer app build. Without it the failure is invisible — the
/// app silently shows stale/empty rewards. Renders nothing in the normal case.
class CatalogStatusGate extends ConsumerWidget {
  const CatalogStatusGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(catalogReadyProvider).asData?.value;
    final (String, bool)? notice = switch (result) {
      CatalogLoadResult.needsAppUpdate => (
        'Update SwipeWise to see the latest rewards — this version is behind the catalog.',
        false,
      ),
      CatalogLoadResult.error => (
        "Couldn't load the latest rewards. Showing what's saved on this device.",
        true,
      ),
      _ => null,
    };
    if (notice == null) return child;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      notice.$1,
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (notice.$2)
                    TextButton(
                      onPressed: () => ref.invalidate(catalogReadyProvider),
                      child: const Text('Retry'),
                    ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Bundles the inputs that should trigger a geofence re-register so we can
/// react to all of them with a single `ref.listen`.
final _nearbyBootstrapInputs =
    Provider<
      ({
        String? userId,
        bool enabled,
        int radius,
        Map<String, int> dwell,
        List<String> cardOrder,
        Set<String> placeTypeIds,
      })
    >((ref) {
      final auth = ref.watch(authProvider);
      return (
        userId: auth.userId,
        enabled: ref.watch(nearbyEnabledProvider),
        radius: ref.watch(nearbyRadiusProvider),
        dwell: ref.watch(nearbyDwellProvider),
        cardOrder: ref.watch(cardPreferenceOrderProvider).value ?? const [],
        placeTypeIds: ref.watch(nearbyPlaceTypesProvider),
      );
    });

/// Entrypoint for the spawned-engine background re-registration. Triggered by
/// `BoundaryGeofenceReceiver` → `ReregisterWorker` when the user moves out of
/// the boundary geofence. Runs in its own isolate; reads user/settings from
/// disk and calls `GeofenceManager.ensureRegistered` directly (no Riverpod).
@pragma('vm:entry-point')
void geofenceReregisterEntrypoint() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.appsoflife/geofence-reregister');
  channel.setMethodCallHandler((call) async {
    if (call.method == 'run') {
      try {
        return await _runGeofenceReregister();
      } catch (e) {
        if (kDebugMode) {
          // ignore: avoid_print
          print('[reregister] failed: $e');
        }
        return false;
      }
    }
    return null;
  });
}

Future<bool> _runGeofenceReregister() async {
  // Headless isolate: init Firebase so `ensureRegistered`'s Crashlytics
  // beacon/failure non-fatals actually record (without this the background
  // path's `FirebaseCrashlytics.instance` throws — no reporting).
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  // App Check is per-isolate, and this isolate calls Places through the Worker
  // via `GooglePlacesProvider` below. Without this the background path is
  // tokenless: geofences stop re-registering and arrival notifications stop,
  // with nothing logged. See `AppCheckService`.
  await AppCheckService.activate();
  final repo = DataRepository();
  final db = await DatabaseHelper().database;
  final users = await db.query('users', limit: 1);
  if (users.isEmpty) return true;
  final userId = users.first['id'] as String;

  // The classifier registries are per-isolate in-memory state, and this
  // worker runs in its own headless isolate. Without loading them here,
  // `categoryForPlaceType`/`classifyLooseLabel` return `other` for EVERY
  // merchant and the brand resolver matches nothing — so every background-
  // registered fence got the catch-all card baked into its notification
  // ("Use United Explorer 1x" at a restaurant) while the foreground sheet,
  // with registries loaded, correctly ranked the real category (CSP 3x).
  final remoteAssets = RemoteAssetService();
  await initBrandRegistry(remote: remoteAssets);
  await initCategoryRegistry(remote: remoteAssets);

  final settings = SettingsRepository(repo);
  final enabled = await settings.getNearbyEnabled(userId);
  if (!enabled) return true;
  final radius = await settings.getNearbyRadiusMi(userId);
  final dwell = await settings.getDwellSecondsByCategory(userId);
  final cardOrder = await settings.getCardPreferenceOrder(userId);
  final placeTypeIds = await settings.getNearbyPlaceTypeIds(userId);

  final manager = GeofenceManager(
    cache: TileCache(),
    search: GooglePlacesProvider(),
    location: LocationService(),
    repo: repo,
  );
  return manager.ensureRegistered(
    userId: userId,
    enabled: true,
    radiusMi: radius,
    dwellByCategory: dwell,
    cardPreferenceOrder: cardOrder,
    categoryIds: placeTypeIds ?? const {},
    trigger: 'background',
  );
}
