import 'merchant.dart';

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
  });

  final List<NearbyMerchant> merchants;
  final double centerLat;
  final double centerLng;
  final double coveredM;
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
