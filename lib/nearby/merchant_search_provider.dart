import 'dart:math' as math;
import 'merchant.dart';
import 'place_roots.dart';

String nearbyQueryKey(Set<String>? rootIds, int radiusMi) {
  var types = includedTypesForRoots(
    rootIds == null || rootIds.isEmpty ? defaultEnabledPlaceRootIds : rootIds,
  );
  if (types.isEmpty) types = includedTypesForRoots(defaultEnabledPlaceRootIds);
  return '$radiusMi:${(types.toList()..sort()).join(',')}';
}

double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  double rad(double d) => d * math.pi / 180;
  final a =
      math.pow(math.sin(rad(lat2 - lat1) / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(rad(lng2 - lng1) / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
}

/// One search's places, plus the circle inside which it found *every*
/// matching place.
///
/// Each Places request returns at most 20 places, nearest first, so a request
/// that comes back full is complete only out to its farthest result — in a
/// dense area about 300 m, far short of the search radius. Anything beyond is
/// unknown, not absent: a store there gets no fence until a search runs
/// closer to it.
class NearbySearchResult {
  const NearbySearchResult({
    required this.merchants,
    required this.centerLat,
    required this.centerLng,
    required this.coveredM,
    this.partial = false,
  });

  final List<NearbyMerchant> merchants;
  final double centerLat;
  final double centerLng;
  final double coveredM;

  /// Failed batches/fallback data may name known places, not complete coverage.
  final bool partial;
}

abstract class MerchantSearchProvider {
  Future<List<NearbyMerchant>> nearby({
    required double lat,
    required double lng,
    required int radiusMi,
    Set<String>? categoryIds,
  }) async => (await nearbyCovered(
    lat: lat,
    lng: lng,
    radiusMi: radiusMi,
    categoryIds: categoryIds,
  )).merchants;

  Future<NearbySearchResult> nearbyCovered({
    required double lat,
    required double lng,
    required int radiusMi,
    Set<String>? categoryIds,
  });
}

class MissingPlacesApiKey implements Exception {
  @override
  String toString() =>
      'GOOGLE_PLACES_KEY not configured. Run with --dart-define=GOOGLE_PLACES_KEY=<your-key>.';
}

/// Thrown by the provider's circuit breaker after repeated upstream failures
/// - we stop hammering the API until the cooldown elapses.
class MerchantSearchUnavailable implements Exception {
  final Duration retryAfter;
  final Object? lastError;
  MerchantSearchUnavailable({required this.retryAfter, this.lastError});
  @override
  String toString() {
    final secs = retryAfter.inSeconds;
    final waitText = secs > 60 ? '${secs ~/ 60} min' : '${secs}s';
    return 'Provider temporarily unavailable. Retrying in $waitText. '
        '(last error: $lastError)';
  }
}
