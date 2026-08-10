import 'dart:math' as math;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
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
  static const int boundaryMinM = 1000;
  static const int boundaryMaxM = 10000;
  // If two merchants are within this distance, we treat them as the same
  // physical zone (mall food court, strip mall) and only register the
  // closer one - same OS dwell would fire on both otherwise, leading to
  // double notifications.
  static const int dedupRadiusM = 50;

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
  Future<bool> ensureRegistered({
    required String userId,
    required bool enabled,
    required int radiusMi,
    required Map<String, int> dwellByCategory,
    List<String> cardPreferenceOrder = const [],
    Set<String>? categoryIds,
    String trigger = 'app',
  }) async {
    if (!enabled) {
      await GeofenceChannel.unregisterAll();
      return true;
    }
    try {
      final fix = await location.getOneShot();
      var merchants = await cache.read(lat: fix.lat, lng: fix.lng);
      if (merchants.isEmpty) {
        merchants = await search.nearby(
          lat: fix.lat,
          lng: fix.lng,
          radiusMi: radiusMi,
          categoryIds: categoryIds,
        );
        if (merchants.isNotEmpty) {
          await cache.write(lat: fix.lat, lng: fix.lng, merchants: merchants);
        }
      }
      if (merchants.isEmpty) {
        // Don't wipe the last-good geofence set (including the boundary
        // tripwire) on an empty result. An empty return can be a transient
        // Google miss or a partial-batch failure, not a real "nothing here" —
        // wiping would leave you with no geofences AND no boundary to trigger
        // the next re-registration. Keeping the previous set is harmless (you
        // aren't near those old merchants, so they won't fire) and the next
        // successful register replaces the whole set atomically. Only an
        // explicit `enabled == false` unregisters.
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
      merchants.sort((a, b) => a.distanceMi.compareTo(b.distanceMi));
      final clusters = _buildClusters(merchants);
      final cappedClusters = clusters.length > merchantCap
          ? clusters.sublist(0, merchantCap)
          : clusters;
      final lookup = await repo.queryBestCardByCategory(
        userId,
        cardPreferenceOrder: cardPreferenceOrder,
      );
      final catchAll = await repo.queryBestCatchAllCard(
        userId,
        cardPreferenceOrder: cardPreferenceOrder,
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
        clusters: cappedClusters,
      );
      final count = await GeofenceChannel.registerSet(
        zones: payload,
        boundary: boundary,
      );
      Log.i('geofence', 'registered $count geofences');
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
        return false;
      }
      Log.e('geofence', 'ensureRegistered failed', e, st);
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

  /// Groups merchants within `dedupRadiusM` of each other into clusters.
  /// Each cluster has a primary (closest to the user) and any number of
  /// additional merchants. Driven by the pre-sorted-by-distance list - the
  /// first merchant we visit in a region anchors that region.
  List<_MerchantCluster> _buildClusters(List<NearbyMerchant> merchants) {
    final clusters = <_MerchantCluster>[];
    for (final m in merchants) {
      _MerchantCluster? hit;
      for (final c in clusters) {
        if (_haversineMeters(c.primary.lat, c.primary.lng, m.lat, m.lng) <=
            dedupRadiusM) {
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
    return clusters;
  }

  Map<String, dynamic> _buildBoundary({
    required double centerLat,
    required double centerLng,
    required List<_MerchantCluster> clusters,
  }) {
    // Tripwire semantics: fire when the user leaves the area we actually
    // covered densely with merchant geofences. The old formula (furthest
    // merchant + 500m outward buffer) created a dead ring — the 2026-07-03
    // debug trail caught a store visit at 3570m from the registration
    // center sitting 75m INSIDE the 3645m boundary: no EXIT, no
    // re-registration, no geofence at the store, no notification. Google's
    // distance-ranked, 20-per-batch results thin out well before the
    // furthest hit, so real coverage ends around the median registered
    // cluster, not the furthest one. Use the median (min-clamped to 1km);
    // moving beyond it re-registers, and the tile cache absorbs the extra
    // churn for short hops.
    final dists =
        clusters
            .map(
              (c) => _haversineMeters(
                centerLat,
                centerLng,
                c.primary.lat,
                c.primary.lng,
              ),
            )
            .toList()
          ..sort();
    final medianM = dists.isEmpty ? 0.0 : dists[dists.length ~/ 2];
    final radius = medianM
        .clamp(boundaryMinM.toDouble(), boundaryMaxM.toDouble())
        .round();
    // Privacy: the boundary center is the user's position when geofences
    // were registered, and it gets persisted in `boundary_geofence`. Round
    // it to ~110 m before storing — the boundary is kilometers wide, so
    // this is lossless for exit detection but keeps a precise fix off disk.
    // (The radius above is computed from the full-precision center.)
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
      // Cluster's circle: center + radius based on the primary merchant.
      // Dwell time is the primary's category - we'd over-suppress if we
      // averaged across mixed categories.
      final primaryLabel = CategoryLabelResolver.labelFor(
        categoryId: primary.placeType,
        categoryName: primary.category,
      );
      final dwell = dwellByCategory[primaryLabel ?? ''] ?? fallbackDwellSeconds;
      final options = <Map<String, dynamic>>[];
      for (final m in all) {
        final label = CategoryLabelResolver.labelFor(
          categoryId: m.placeType,
          categoryName: m.category,
        );
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
        options.add({
          'merchant_id': m.id,
          'name': m.name,
          'category': label,
          'category_enum': category.name,
          'matched_brand': brandHit?.brand,
          'best_card_name': bestName,
          'best_rate': bestRate,
        });
      }
      out.add({
        'geofence_id': 'm_${primary.id}',
        'lat': primary.lat,
        'lng': primary.lng,
        'radius_m': defaultMerchantRadiusM,
        'dwell_seconds': dwell,
        'options': options,
      });
    }
    return out;
  }
}

class _MerchantCluster {
  final NearbyMerchant primary;
  List<NearbyMerchant> others;
  _MerchantCluster({required this.primary, required this.others});
}
