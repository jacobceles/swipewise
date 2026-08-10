import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import '../api/brand_resolver.dart';
import '../api/reward_category_mapper.dart';
import '../models/insights.dart';
import '../models/reward_category.dart';
import '../nearby/category_label_resolver.dart';
import '../nearby/google_places_provider.dart';
import '../nearby/geofence_manager.dart';
import '../nearby/location_service.dart';
import '../nearby/merchant.dart';
import '../nearby/merchant_search_provider.dart';
import '../nearby/tile_cache.dart';
import 'auth_provider.dart';
import 'data_providers.dart';
import 'settings_provider.dart';

final merchantSearchProvider = Provider<MerchantSearchProvider>(
  (_) => GooglePlacesProvider(),
);

final tileCacheProvider = Provider<TileCache>((_) => TileCache());

final locationServiceProvider = Provider<LocationService>(
  (_) => LocationService(),
);

final geofenceManagerProvider = Provider<GeofenceManager>(
  (ref) => GeofenceManager(
    cache: ref.read(tileCacheProvider),
    search: ref.read(merchantSearchProvider),
    location: ref.read(locationServiceProvider),
    repo: ref.read(dataRepositoryProvider),
  ),
);

/// Device-level per-store mute list (Google place ids) for dwell
/// notifications. Watched by the Nearby Stores rows to render the bell
/// toggle; `ref.invalidate` after a mute/unmute to refresh every row.
final mutedMerchantIdsProvider = FutureProvider.autoDispose<Set<String>>(
  (ref) => ref.read(dataRepositoryProvider).queryMutedMerchantIds(),
);

/// Full muted-store rows (newest-first) for the Muted Stores management
/// screen. Invalidate alongside [mutedMerchantIdsProvider] on unmute.
final mutedMerchantsListProvider =
    FutureProvider.autoDispose<List<Map<String, Object?>>>(
      (ref) => ref.read(dataRepositoryProvider).queryMutedMerchants(),
    );

/// Fire-and-forget geofence re-register after a mute/unmute so the fence set
/// updates promptly: a mute frees a slot under the 50-fence cap, an unmute
/// restores the fence. Mirrors the `ensureRegistered` call in `main.dart`'s
/// `_nearbyBootstrapInputs` bootstrap, but is driven by an explicit user
/// action (`trigger: 'mute'`) rather than an inputs-signature change.
Future<void> reregisterAfterMuteChange(WidgetRef ref) async {
  final userId = ref.read(authProvider).userId;
  if (userId == null || !ref.read(nearbyEnabledProvider)) return;
  await ref
      .read(geofenceManagerProvider)
      .ensureRegistered(
        userId: userId,
        enabled: true,
        radiusMi: ref.read(nearbyRadiusProvider),
        dwellByCategory: ref.read(nearbyDwellProvider),
        cardPreferenceOrder:
            ref.read(cardPreferenceOrderProvider).value ?? const [],
        categoryIds: ref.read(nearbyPlaceTypesProvider),
        trigger: 'mute',
      );
}

/// Current Android location permission. Re-fetched on demand (e.g. when the
/// user returns from system settings). Use `ref.invalidate` to refresh.
final locationPermissionProvider = FutureProvider<LocationPermission>(
  (ref) async => Geolocator.checkPermission(),
);

/// Whether the two background-reliability grants are in place: exact alarms
/// (deterministic dwell timers) and ignore-battery-optimizations (keeps OEM
/// battery managers from killing the geofence receivers). Drives the nudge
/// banner in the Stores view; re-fetched on demand like
/// [locationPermissionProvider].
final reliabilityGrantsProvider = FutureProvider<bool>((ref) async {
  final alarm = await Permission.scheduleExactAlarm.status;
  final battery = await Permission.ignoreBatteryOptimizations.status;
  return alarm.isGranted && battery.isGranted;
});

/// Foreground discovery: one-shot location → tile cache → Google Places on miss
/// → enrich with the user's best card per resolved category.
final nearbyMerchantsProvider = FutureProvider<List<NearbyMerchantWithReward>>((
  ref,
) async {
  // Watch the stable `sessionProvider` (identity-only) rather than the raw
  // `authProvider` — the latter emits a new `AuthState` on every transient
  // `isLoading`/`error` flip (audit §F4), which would re-run this whole
  // location+Places pipeline for no reason.
  final auth = ref.watch(sessionProvider);
  if (auth.userId == null) return const [];
  if (!ref.watch(nearbyEnabledProvider)) return const [];
  // Block until the up-front permission gate has finished. Without this,
  // the Stores tab's Geolocator request races permission_handler's bulk
  // request inside the gate and silently nullifies the other dialogs.
  if (!ref.watch(permissionGateCompleteProvider)) return const [];

  final radiusMi = ref.watch(nearbyRadiusProvider);
  final categoryIds = ref.watch(nearbyPlaceTypesProvider);
  if (kDebugMode) {
    // ignore: avoid_print
    print('[nearby] requesting one-shot location…');
  }
  final fix = await ref.read(locationServiceProvider).getOneShot();
  if (kDebugMode) {
    // ignore: avoid_print
    print('[nearby] got fix lat=${fix.lat}, lng=${fix.lng}');
  }
  final cache = ref.read(tileCacheProvider);

  var raw = await cache.read(lat: fix.lat, lng: fix.lng);
  if (raw.isEmpty) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[nearby] cache miss, calling Google Places…');
    }
    final search = ref.read(merchantSearchProvider);
    raw = await search.nearby(
      lat: fix.lat,
      lng: fix.lng,
      radiusMi: radiusMi,
      categoryIds: categoryIds,
    );
    if (kDebugMode) {
      // ignore: avoid_print
      print('[nearby] Google Places returned ${raw.length} merchants');
    }
    if (raw.isNotEmpty) {
      await cache.write(lat: fix.lat, lng: fix.lng, merchants: raw);
    }
  } else if (kDebugMode) {
    // ignore: avoid_print
    print('[nearby] cache hit (${raw.length} merchants)');
  }

  final repo = ref.read(dataRepositoryProvider);
  final brandResolver = repo.loadBrandResolver();
  final prefOrder = await ref.watch(cardPreferenceOrderProvider.future);
  final lookup = await repo.queryBestCardByCategory(
    auth.userId!,
    cardPreferenceOrder: prefOrder,
  );
  final catchAll = await repo.queryBestCatchAllCard(
    auth.userId!,
    cardPreferenceOrder: prefOrder,
  );

  raw.sort((a, b) => a.distanceMi.compareTo(b.distanceMi));
  return raw.map((m) {
    final label = CategoryLabelResolver.labelFor(
      categoryId: m.placeType,
      categoryName: m.category,
    );
    // Authoritative: the curated place-type → category map (categories.json
    // googlePlaceTypes). Fall back to the label/name heuristics for any
    // primaryType not yet curated, so uncurated types behave as before.
    final category =
        categoryForPlaceType(m.placeType) ??
        (label == null ? RewardCategory.other : classifyLooseLabel(label));
    // Brand match wins over category. We test the merchant's display
    // name against any brand-bonus the user has - "Whole Foods Market"
    // (Google Places) → "whole foods" (in bonus_brand) lights up Prime
    // Visa even though the resolver only tagged it "Grocery."
    final brandHit = _findBrandHit(m.name, lookup.byBrand, brandResolver);
    // Travel sub-categories (hotels/airlines/car rentals/transit) fall back to
    // the user's best `travel` card when no card bonuses the specific
    // sub-category — travel is the superset.
    final categoryBest =
        lookup.byCategory[category] ??
        (category.isTravelSubcategory
            ? lookup.byCategory[RewardCategory.travel]
            : null);
    final String? bestName;
    final double? bestRate;
    if (brandHit != null) {
      bestName = brandHit.name;
      bestRate = brandHit.rate;
    } else if (categoryBest != null) {
      bestName = categoryBest.name;
      bestRate = categoryBest.rate;
    } else if (catchAll != null) {
      bestName = catchAll.name;
      bestRate = catchAll.rate;
    } else {
      bestName = null;
      bestRate = null;
    }
    return NearbyMerchantWithReward(
      merchant: m,
      bestCardName: bestName,
      bestRate: bestRate,
      resolvedLabel: label,
      resolvedCategory: category,
      matchedBrand: brandHit?.brand,
    );
  }).toList();
});

/// Resolves the merchant name to a canonical `brand_id` via [BrandResolver]
/// (whole-token, longest-match) and returns the user's best card for that
/// brand, if any. Uses the SAME resolver as the ranking sheet
/// (`rewardRankingProvider`) and the geofence notification, so the badge,
/// sheet, and notification always agree — e.g. "Costco Gasoline" resolves to
/// `costco-gas` (5%), not the warehouse `costco` (2%). The previous
/// bidirectional-substring match diverged from those (and matched "Walmart"
/// inside "Mart Coffee").
BestCardEntry? _findBrandHit(
  String merchantName,
  Map<String, BestCardEntry> byBrand,
  BrandResolver resolver,
) {
  if (byBrand.isEmpty) return null;
  final brandId = resolver.resolve(merchantName);
  return brandId == null ? null : byBrand[brandId];
}
