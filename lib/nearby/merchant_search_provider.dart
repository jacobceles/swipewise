import 'merchant.dart';

abstract class MerchantSearchProvider {
  Future<List<NearbyMerchant>> nearby({
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
