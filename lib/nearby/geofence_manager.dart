import 'dart:math' as math;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import '../api/brand_resolver.dart';
import '../api/data_repository.dart';
import '../api/reward_category_mapper.dart';
import '../api/types.dart';
import '../models/insights.dart';
import '../models/reward_category.dart';
import '../util/logger.dart';
import 'category_label_resolver.dart';
import 'geofence_channel.dart';
import 'location_service.dart';
import 'merchant.dart';
import 'merchant_search_provider.dart';
import 'tile_cache.dart';

class GeofenceManager {
  GeofenceManager({
    required this.cache,
    required this.search,
    required this.location,
    required this.repo,
  });

  final TileCache cache;
  final MerchantSearchProvider search;
  final LocationService location;
  final DataRepository repo;

  static const int merchantCap = 50;
  static const int defaultMerchantRadiusM = 100;
  static const int fallbackDwellSeconds = 60;
  // The boundary is the searched area's real coverage (see _buildBoundary),
  // ~300 m in a dense town; below this a GPS wobble alone would trip it.
  static const int boundaryMinM = 300;
  static const int boundaryMaxM = 10000;
  // If two merchants are within this distance, we treat them as the same
  // physical zone (mall food court, strip mall) and only register the
  // closer one - same OS dwell would fire on both otherwise, leading to
  // double notifications.
  static const int dedupRadiusM = 50;

  /// How far a big-box store's floor reaches past its Google pin. Its fence
  /// grows by this much (so standing deep inside still counts as entering),
  /// and the native dwell check measures to the store's edge rather than its
  /// pin. About physical size, not priority: every store kind is fenced alike.
  static const int bigBoxFootprintM = 80;
  static const Set<String> bigBoxPlaceTypes = {
    'department_store',
    'warehouse_store',
    'hypermarket',
    'supermarket',
    'home_improvement_store',
    'shopping_mall',
  };

  /// Display labels (CategoryLabelResolver) whose wait is the "Big-box" kind
  /// of visit in settings. Nothing produces a "Big-box" label itself, so
  /// before this mapping that setting changed nothing.
  static const Set<String> bigBoxLabels = {'Department Stores', 'Wholesale'};

  // RC2 coverage-gap beacon. On a failed re-register we deliberately keep the
  // last-good fence set (see the empty/catch paths below) — correct, but a
  // *silent* miss window if the user has since driven far. Fire a distinct
  // diagnostic non-fatal only when that kept set is BOTH this old AND this far
  // from the current best-known fix, so it flags real travel gaps (a new city,
  // a dead travel cell) rather than the transient Places blips the worker's
  // backoff already recovers from.
  static const Duration coverageGapMinAge = Duration(minutes: 30);
  static const double coverageGapMinDistanceKm = 10; // ≈ boundaryMaxM
  static const String _kLastRegister = 'geofence_last_register';
  // Native GeofencePlugin.registerSet raises this PlatformException code when
  // Google Play services is missing/disabled — geofences can never register,
  // so it routes to the geofence_degraded beacon rather than the generic
  // register-failed path.
  static const String _kGmsUnavailable = 'GMS_UNAVAILABLE';

  /// Idempotent. On app open this fetches a location fix, refreshes the merchant
  /// tile cache if needed, computes the user's best card per merchant, and hands
  /// the closest N to native to register as DWELL geofences.
  /// Returns true when the registration completed (including the legitimate
  /// "nothing nearby / disabled" cases), false when it failed and should be
  /// retried — the background [ReregisterWorker] maps false to `Result.retry`.
  ///
  /// Calls in one isolate run one at a time: two interleaved `registerSet`s
  /// can leave the fences from one run and the metadata from the other
  /// (`no_meta`). The background worker's own isolate is serialised natively
  /// (`ReregisterScheduler`, APPEND_OR_REPLACE).
  Future<bool> ensureRegistered({
    required String userId,
    required bool enabled,
    required int radiusMi,
    required Map<String, int> dwellByCategory,
    List<String> cardPreferenceOrder = const [],
    Set<String>? categoryIds,
    String trigger = 'app',
  }) {
    final previous = _inFlight;
    final run = () async {
      if (previous != null) await previous.catchError((_) => false);
      return _ensureRegistered(
        userId: userId,
        enabled: enabled,
        radiusMi: radiusMi,
        dwellByCategory: dwellByCategory,
        cardPreferenceOrder: cardPreferenceOrder,
        categoryIds: categoryIds,
        trigger: trigger,
      );
    }();
    _inFlight = run;
    run.whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    }).ignore();
    return run;
  }

  Future<bool>? _inFlight;

  /// A WARN line (survives release builds) that also lands in the native
  /// walk-in log file, so "fences were never set up here" is visible after a
  /// day out, not just in a logcat buffer that has long rolled over.
  Future<void> _trace(String message) async {
    Log.w('geofence', message);
    await GeofenceChannel.walkinLog('geofence: $message');
  }

  Future<bool> _ensureRegistered({
    required String userId,
    required bool enabled,
    required int radiusMi,
    required Map<String, int> dwellByCategory,
    required List<String> cardPreferenceOrder,
    required Set<String>? categoryIds,
    required String trigger,
  }) async {
    if (!enabled) {
      await GeofenceChannel.unregisterAll();
      await _trace('trigger=$trigger disabled -> unregistered all');
      return true;
    }
    try {
      final fix = await location.getOneShot();
      var area = await cache.read(lat: fix.lat, lng: fix.lng);
      var source = 'cache';
      if (area == null) {
        source = 'search';
        area = await search.nearbyCovered(
          lat: fix.lat,
          lng: fix.lng,
          radiusMi: radiusMi,
          categoryIds: categoryIds,
        );
        await cache.write(lat: fix.lat, lng: fix.lng, result: area);
      }
      var merchants = area.merchants;
      if (merchants.isEmpty) {
        // Don't wipe the last-good geofence set (including the boundary
        // tripwire) on an empty result. An empty return can be a transient
        // Google miss or a partial-batch failure, not a real "nothing here" —
        // wiping would leave you with no geofences AND no boundary to trigger
        // the next re-registration. Keeping the previous set is harmless (you
        // aren't near those old merchants, so they won't fire) and the next
        // successful register replaces the whole set atomically. Only an
        // explicit `enabled == false` unregisters.
        await _trace(
          'trigger=$trigger source=$source found nothing -> kept last fences',
        );
        await _beacon(
          trigger,
          await GeofenceChannel.getRegisteredCount(),
          countMeaningful: false,
        );
        return true;
      }
      // Drop muted stores so no fence (and thus no dwell notification) is
      // registered for them. They still appear in the Nearby Stores list UI —
      // only fences are suppressed. An empty result here is safe: the boundary
      // tripwire is still registered below (`_buildBoundary` handles it).
      final mutedIds = await repo.queryMutedMerchantIds();
      if (mutedIds.isNotEmpty) {
        merchants = merchants.where((m) => !mutedIds.contains(m.id)).toList();
      }
      final clusters = _clusterMerchants(merchants, _haversineMeters);
      final cappedClusters = clusters.length > merchantCap
          ? clusters.sublist(0, merchantCap)
          : clusters;
      // Abroad, rank with FX fees (travel mode), as the Advisor does. The
      // search point decides; a failed geocode reads as home.
      final isForeign = await repo.isAbroadAt(userId, fix.lat, fix.lng);
      final lookup = await repo.queryBestCardByCategory(
        userId,
        cardPreferenceOrder: cardPreferenceOrder,
        isForeign: isForeign,
      );
      final catchAll = await repo.queryBestCatchAllCard(
        userId,
        cardPreferenceOrder: cardPreferenceOrder,
        isForeign: isForeign,
      );
      final brandResolver = repo.loadBrandResolver();
      final payload = _buildPayload(
        cappedClusters,
        lookup,
        catchAll,
        dwellByCategory,
        brandResolver,
      );
      final boundary = _buildBoundary(
        centerLat: fix.lat,
        centerLng: fix.lng,
        coveredM: TileCache.coverageLeftM(
          centerLat: area.centerLat,
          centerLng: area.centerLng,
          coveredM: area.coveredM,
          lat: fix.lat,
          lng: fix.lng,
        ),
        capped: clusters.length > merchantCap ? cappedClusters : null,
      );
      final count = await GeofenceChannel.registerSet(
        zones: payload,
        boundary: boundary,
      );
      // One line that says where fences came from and how they sit, for
      // diagnosing walk-ins after the fact.
      await _trace(
        'registered $count fences trigger=$trigger source=$source '
        'merchants=${merchants.length} clusters=${clusters.length} '
        'covered=${area.coveredM.round()}m '
        'overlapping=${_overlappingPairs(cappedClusters)} '
        'boundary=${boundary['radius_m']}m',
      );
      await _beacon(trigger, count, countMeaningful: true);
      await _recordSuccessfulRegistration(userId, fix.lat, fix.lng);
      return true;
    } catch (e, st) {
      if (e is PlatformException && e.code == _kGmsUnavailable) {
        // Play services missing/disabled: not a transient register failure —
        // the GeofencingClient can never register. Fire the existing degraded
        // beacon (not geofence_register_failed) and let the worker retry in
        // case Play services is later updated/re-enabled.
        Log.e(
          'geofence',
          'Google Play services unavailable; geofencing degraded',
          e,
          st,
        );
        await _beacon(trigger, 0, countMeaningful: false, gmsUnavailable: true);
        await _trace('trigger=$trigger FAILED: Play services unavailable');
        return false;
      }
      Log.e('geofence', 'ensureRegistered failed', e, st);
      await GeofenceChannel.walkinLog(
        'geofence: trigger=$trigger FAILED: ${e.runtimeType}: $e',
      );
      // `trigger` (app/sync/background) names which re-registration path
      // failed in the field — the A2-F1 blind spot we couldn't see before.
      FirebaseCrashlytics.instance.setCustomKey('geofence_trigger', trigger);
      // ignore: unawaited_futures
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'geofence_register_failed',
        fatal: false,
      );
      // RC2: this failure leaves the last-good fence set in place. If that set
      // is now stale + far, flag the silent-miss window (diagnosis only).
      await _maybeCoverageGapBeacon(userId, trigger);
      return false;
    }
  }

  /// Pushes geofence health to Crashlytics on each enabled register attempt.
  /// Records a non-fatal for the *silent* degradation that never throws —
  /// chiefly permission != always, where background geofences quietly never
  /// fire (the A2-F1 class). Best-effort: telemetry must never break
  /// re-registration, so the whole body is guarded.
  Future<void> _beacon(
    String trigger,
    int count, {
    required bool countMeaningful,
    bool gmsUnavailable = false,
  }) async {
    try {
      final perm = await location.currentPermission();
      final label = isAlwaysAllowed(perm)
          ? 'always'
          : isAtLeastWhileInUse(perm)
          ? 'whileInUse'
          : 'denied';
      final c = FirebaseCrashlytics.instance;
      c.setCustomKey('geofence_trigger', trigger);
      c.setCustomKey('geofence_permission', label);
      c.setCustomKey('geofence_fence_count', count);
      c.setCustomKey('geofence_gms_available', !gmsUnavailable);
      if (label != 'always' ||
          (countMeaningful && count == 0) ||
          gmsUnavailable) {
        await c.recordError(
          StateError(
            'geofence_degraded permission=$label count=$count '
            'gms=${!gmsUnavailable}',
          ),
          StackTrace.current,
          reason: 'geofence_degraded',
          fatal: false,
        );
      }
    } catch (e) {
      Log.w('geofence', 'beacon failed (non-fatal): $e');
    }
  }

  /// Persists the center + time of the last *successful* registration so the
  /// coverage-gap beacon can later measure how stale/far the kept fence set
  /// has become across process restarts. Center is coarsened to ~110 m (3 dp)
  /// to match the boundary privacy convention — km-scale distance math is
  /// unaffected. Best-effort: never breaks a successful register.
  Future<void> _recordSuccessfulRegistration(
    String userId,
    double lat,
    double lng,
  ) async {
    try {
      await repo.setSetting(
        userId,
        _kLastRegister,
        '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)},'
        '${DateTime.now().toUtc().toIso8601String()}',
      );
    } catch (e) {
      Log.w('geofence', 'record last-register failed (non-fatal): $e');
    }
  }

  /// RC2: on a failed re-register, flag the silent-miss window when the kept
  /// (last-good) fence set is BOTH older than [coverageGapMinAge] AND farther
  /// than [coverageGapMinDistanceKm] from the current best-known fix — the
  /// "running on stale far fences" signature that was previously invisible.
  /// Diagnosis only; the keep-old-fences behavior is unchanged. Best-effort.
  Future<void> _maybeCoverageGapBeacon(String userId, String trigger) async {
    try {
      final raw = await repo.getSetting(userId, _kLastRegister);
      if (raw == null || raw.isEmpty) return;
      final parts = raw.split(',');
      if (parts.length != 3) return;
      final lat = double.tryParse(parts[0]);
      final lng = double.tryParse(parts[1]);
      final at = DateTime.tryParse(parts[2]);
      if (lat == null || lng == null || at == null) return;
      final best = await location.lastKnown();
      if (best == null) return; // no position estimate → can't measure a gap
      final age = DateTime.now().difference(at);
      final distKm = _haversineMeters(lat, lng, best.lat, best.lng) / 1000;
      if (age < coverageGapMinAge || distKm < coverageGapMinDistanceKm) return;
      final ageMin = age.inMinutes;
      final distStr = distKm.toStringAsFixed(1);
      Log.w('geofence', 'coverage_gap age=${ageMin}m dist=${distStr}km');
      final c = FirebaseCrashlytics.instance;
      c.setCustomKey('geofence_trigger', trigger);
      c.setCustomKey('geofence_gap_age_min', ageMin);
      c.setCustomKey('geofence_gap_dist_km', distStr);
      // ignore: unawaited_futures
      c.recordError(
        StateError('coverage_gap age=${ageMin}m dist=${distStr}km'),
        StackTrace.current,
        reason: 'geofence_coverage_gap',
        fatal: false,
      );
    } catch (e) {
      Log.w('geofence', 'coverage_gap beacon failed (non-fatal): $e');
    }
  }

  /// Fence pairs whose circles overlap: each one a place where a single walk-in
  /// can wake two dwell timers (the native visit lock keeps it to one post).
  int _overlappingPairs(List<_MerchantCluster> clusters) {
    var n = 0;
    for (var a = 0; a < clusters.length; a++) {
      for (var b = a + 1; b < clusters.length; b++) {
        final d = _haversineMeters(
          clusters[a].primary.lat,
          clusters[a].primary.lng,
          clusters[b].primary.lat,
          clusters[b].primary.lng,
        );
        if (d < 2 * defaultMerchantRadiusM) n++;
      }
    }
    return n;
  }

  /// Tripwire: fire when the user leaves the area whose stores are all
  /// fenced, so the next registration runs where they are.
  ///
  /// That area is what the search actually covered around the user
  /// ([coveredM]), not a guess from where the fenced stores sit: Places returns
  /// at most 20 per request, nearest first, so a dense town is covered only
  /// ~300 m out. The old median-of-fences radius (min 1 km) let the user park
  /// 500 m from the covered ring without crossing anything — no
  /// re-registration, no fence at the store (Flemington, 2026-10-16). When the
  /// fence cap dropped clusters ([capped] is the kept ones), coverage also ends
  /// at the farthest kept fence.
  Map<String, dynamic> _buildBoundary({
    required double centerLat,
    required double centerLng,
    required double coveredM,
    required List<_MerchantCluster>? capped,
  }) {
    var radiusM = coveredM;
    if (capped != null && capped.isNotEmpty) {
      final last = capped.last.primary;
      radiusM = math.min(
        radiusM,
        _haversineMeters(centerLat, centerLng, last.lat, last.lng),
      );
    }
    final radius = radiusM
        .clamp(boundaryMinM.toDouble(), boundaryMaxM.toDouble())
        .round();
    // Privacy: the boundary center is the user's position when geofences
    // were registered, and it gets persisted in `boundary_geofence`. Round
    // it to ~110 m before storing; the error is small against the radius and
    // keeps a precise fix off disk. (The radius above is computed from the
    // full-precision center.)
    return {
      'geofence_id': 'boundary',
      'lat': double.parse(centerLat.toStringAsFixed(3)),
      'lng': double.parse(centerLng.toStringAsFixed(3)),
      'radius_m': radius,
    };
  }

  double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
    const earthM = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthM * c;
  }

  double _toRad(double deg) => deg * math.pi / 180;

  List<Map<String, dynamic>> _buildPayload(
    List<_MerchantCluster> clusters,
    BestCardLookup lookup,
    CardPick? catchAll,
    Map<String, int> dwellByCategory,
    BrandResolver brandResolver,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final c in clusters) {
      final primary = c.primary;
      final all = [primary, ...c.others];
      // Dwell is the shortest wait among the cluster's stores: the anchor is
      // just the lowest place id, so its kind says nothing about which store
      // the user walks into, and a longer wait would hold back that store's
      // alert.
      var dwell = 0;
      var footprint = 0;
      final options = <Map<String, dynamic>>[];
      for (final m in all) {
        final label = CategoryLabelResolver.labelFor(
          categoryId: m.placeType,
          categoryName: m.category,
        );
        final wait = dwellSecondsFor(label, dwellByCategory);
        if (dwell == 0 || wait < dwell) dwell = wait;
        final storeFootprint = bigBoxPlaceTypes.contains(m.placeType)
            ? bigBoxFootprintM
            : 0;
        footprint = math.max(footprint, storeFootprint);
        // Authoritative curated place-type → category map (categories.json
        // googlePlaceTypes); label/name heuristics are the fallback.
        final category =
            categoryForPlaceType(m.placeType) ??
            (label == null ? RewardCategory.other : classifyLooseLabel(label));
        // Brand match first. The merchant name is resolved via the
        // canonical `BrandResolver` (token-level aliases out of the
        // `brands` table); we then look up the brand-best card by
        // `brand_id`. Replaces the prior bidirectional-substring match
        // that falsely fired on partial-word collisions like "Mart
        // Coffee" matching the Walmart brand.
        final brandId = brandResolver.resolve(m.name);
        final brandHit = brandId == null ? null : lookup.byBrand[brandId];
        // Travel sub-categories fall back to the best `travel` card (superset).
        final categoryBest =
            lookup.byCategory[category] ??
            (category.isTravelSubcategory
                ? lookup.byCategory[RewardCategory.travel]
                : null);
        final String? bestName;
        final double? bestRate;
        final String? bestCurrency;
        if (brandHit != null) {
          bestName = brandHit.name;
          bestRate = brandHit.rate;
          bestCurrency = brandHit.currency;
        } else if (categoryBest != null) {
          bestName = categoryBest.name;
          bestRate = categoryBest.rate;
          bestCurrency = categoryBest.currency;
        } else if (catchAll != null) {
          bestName = catchAll.name;
          bestRate = catchAll.rate;
          bestCurrency = catchAll.currency;
        } else {
          bestName = null;
          bestRate = null;
          bestCurrency = null;
        }
        options.add({
          'merchant_id': m.id,
          'name': m.name,
          // Lets the native dwell check name the closest store from a fresh
          // fix rather than every store in the cluster.
          'lat': m.lat,
          'lng': m.lng,
          'footprint_m': storeFootprint,
          // A shopping plaza's own pin: never the store you pay at.
          if (m.placeType == 'shopping_mall') 'plaza': true,
          'category': label,
          'category_enum': category.name,
          'matched_brand': brandHit?.brand,
          'best_card_name': bestName,
          'best_rate': bestRate,
          // 'USD' (any cash back) | 'POINTS' | 'MILES': "5%" vs "5x points".
          'best_currency': bestCurrency,
        });
      }
      out.add({
        'geofence_id': 'm_${primary.id}',
        'lat': primary.lat,
        'lng': primary.lng,
        'radius_m': defaultMerchantRadiusM + footprint,
        'dwell_seconds': dwell,
        'options': options,
      });
    }
    return out;
  }
}

/// The wait before a walk-in alert for a store with display [label]: its kind
/// of visit's setting, else [GeofenceManager.fallbackDwellSeconds].
@visibleForTesting
int dwellSecondsFor(String? label, Map<String, int> dwellByCategory) {
  final kind = GeofenceManager.bigBoxLabels.contains(label) ? 'Big-box' : label;
  return dwellByCategory[kind ?? ''] ?? GeofenceManager.fallbackDwellSeconds;
}

class _MerchantCluster {
  final NearbyMerchant primary;
  List<NearbyMerchant> others;
  _MerchantCluster({required this.primary, required this.others});
}

/// Groups merchants within [GeofenceManager.dedupRadiusM] of each other into
/// one fence each, closest cluster first.
///
/// Anchored on place id, not on distance from the user. The fence id is
/// `m_<anchor id>`, and anchoring on "the store nearest to wherever the user
/// was at registration" gave the same strip mall a new id on every
/// re-registration — orphaning any dwell timer already running for it
/// (`no_meta`, diagnosed 2026-10-16). The same set of places now always
/// produces the same fences.
@visibleForTesting
List<({NearbyMerchant anchor, List<NearbyMerchant> others})>
clusterMerchantsForTest(
  List<NearbyMerchant> merchants,
  double Function(double, double, double, double) distanceM,
) => [
  for (final c in _clusterMerchants(merchants, distanceM))
    (anchor: c.primary, others: c.others),
];

List<_MerchantCluster> _clusterMerchants(
  List<NearbyMerchant> merchants,
  double Function(double, double, double, double) distanceM,
) {
  final byId = [...merchants]..sort((a, b) => a.id.compareTo(b.id));
  final clusters = <_MerchantCluster>[];
  for (final m in byId) {
    _MerchantCluster? hit;
    for (final c in clusters) {
      if (distanceM(c.primary.lat, c.primary.lng, m.lat, m.lng) <=
          GeofenceManager.dedupRadiusM) {
        hit = c;
        break;
      }
    }
    if (hit == null) {
      clusters.add(_MerchantCluster(primary: m, others: const []));
    } else {
      hit.others = [...hit.others, m];
    }
  }
  // Closest first: the merchant cap keeps the nearest fences.
  clusters.sort((a, b) => a.primary.distanceMi.compareTo(b.primary.distanceMi));
  for (final c in clusters) {
    c.others = [...c.others]
      ..sort((a, b) => a.distanceMi.compareTo(b.distanceMi));
  }
  return clusters;
}
