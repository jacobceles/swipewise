import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../api/data_repository.dart';
import '../util/logger.dart';
import 'merchant.dart';
import 'merchant_search_provider.dart';
import 'place_roots.dart';

/// A *transient* network failure talking to Places — no connectivity, socket
/// reset, or timeout (the classic dead-travel-cell shape). Deliberately
/// distinct from [PlacesUpstreamError]: RC3 keeps this off the circuit breaker
/// so a dead cell doesn't latch a cooldown that then fast-fails the in-coverage
/// retries. Recovery is immediate the moment the network returns.
class PlacesNetworkTransient implements Exception {
  PlacesNetworkTransient(this.message);
  final String message;
  @override
  String toString() => 'PlacesNetworkTransient: $message';
}

/// An *upstream-broken* Places failure — a non-200 (bad key, 429 quota, 5xx)
/// or a malformed/wrong-shaped 200 body. This is a real service problem, so it
/// DOES feed the circuit breaker.
class PlacesUpstreamError implements Exception {
  PlacesUpstreamError(this.message);
  final String message;
  @override
  String toString() => 'PlacesUpstreamError: $message';
}

/// Google Places API (New) implementation of [MerchantSearchProvider].
///
/// Uses `POST places.googleapis.com/v1/places:searchNearby` with a field mask
/// that covers only the free-tier and cheap-tier fields:
///   - `places.id` / `places.displayName` / `places.location` — free
///   - `places.primaryType` — free
///   - `places.businessStatus` — free
///
/// Distance is computed client-side via Haversine — the API doesn't return it.
/// Privacy coarsening: lat/lng sent to the API is rounded to 3 decimal places
/// (~110 m).
///
/// Circuit breaker state lives in SQLite (`api_circuit_breakers` table,
/// shared between isolates) so the foreground UI and the background geofence
/// re-register isolate share state rather than diverging.
class GooglePlacesProvider implements MerchantSearchProvider {
  GooglePlacesProvider({DataRepository? repo})
    : _repo = repo ?? DataRepository();

  final DataRepository _repo;

  static const _kApiKey = String.fromEnvironment('GOOGLE_PLACES_KEY');
  // Android app restriction: GCP key is locked to specific package+cert.
  // Raw HTTP calls must supply these headers (the Android SDK does it
  // automatically; we do it manually).
  static const _kAndroidPackage = String.fromEnvironment(
    'GOOGLE_ANDROID_PACKAGE',
  );

  /// SHA-1 of the certificate this build is signed with, sent as
  /// `X-Android-Cert` so GCP can match the key's Android restriction.
  ///
  /// ⛔ This **must** come from the keys file, because it differs per build and
  /// getting it wrong fails silently in exactly the worst place. Confirmed
  /// 2026-08-09: the old hardcoded default below is the *debug* keystore's
  /// fingerprint, so every build — including release — was announcing itself as
  /// the debug cert. The upload key is a different SHA again, and Play App
  /// Signing re-signs with Google's key, a third. A Play-installed build
  /// therefore presents a certificate matching none of them, Places rejects the
  /// request, and the Stores tab is simply empty — in production only, after
  /// passing every local test.
  ///
  /// Set `GOOGLE_ANDROID_CERT` in each keys file:
  ///   - debug builds → the debug keystore SHA-1
  ///     (`keytool -list -v -keystore ~/.android/debug.keystore -storepass android`)
  ///   - the Play build → the **App signing** SHA-1 from Play Console →
  ///     Setup → App signing (NOT the upload certificate)
  /// and register every package × cert pair on the API key in GCP.
  ///
  /// The default keeps existing debug builds working unchanged; it is
  /// deliberately not used for anything else.
  static const _kAndroidCert = String.fromEnvironment(
    'GOOGLE_ANDROID_CERT',
    defaultValue: '05e29b39eb58a763a326c1ca43bc3727e5e73c8a',
  );
  static const _serviceName = 'google_places';
  static const _endpoint =
      'https://places.googleapis.com/v1/places:searchNearby';
  static const _fieldMask =
      'places.id,places.displayName,places.location,places.primaryType,places.businessStatus';

  static const int _failureThreshold = 3;
  static const Duration _cooldown = Duration(minutes: 5);

  Future<void> resetCircuitBreaker() => _repo.resetCircuitBreaker(_serviceName);

  @override
  Future<List<NearbyMerchant>> nearby({
    required double lat,
    required double lng,
    required int radiusMi,
    Set<String>? categoryIds,
  }) async {
    if (_kApiKey.isEmpty) {
      throw Exception('GOOGLE_PLACES_KEY is not set');
    }
    final breakerState = await _repo.getCircuitBreaker(_serviceName);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (breakerState.openedUntil != null && breakerState.openedUntil! > nowMs) {
      throw MerchantSearchUnavailable(
        retryAfter: Duration(milliseconds: breakerState.openedUntil! - nowMs),
        lastError: null,
      );
    }
    try {
      final results = await _fetch(
        lat: lat,
        lng: lng,
        radiusMi: radiusMi,
        rootIds: categoryIds,
      );
      await _repo.resetCircuitBreaker(_serviceName);
      return results;
    } on PlacesNetworkTransient catch (e) {
      // No connectivity (dead travel cell). Do NOT trip the breaker: a
      // guard-only cooldown here would fast-fail the in-coverage retries the
      // instant signal returns. Leaving the breaker untouched lets the very
      // next successful call proceed, so recovery latches immediately on
      // arrival. Rethrow so the caller/worker retries. Same service key is
      // shared by foreground + background — unchanged.
      Log.w('google_places', 'network-transient (breaker untouched)', e);
      rethrow;
    } catch (e) {
      // Upstream-broken (non-200, bad key, 429, 5xx, malformed body). This is
      // a real service problem — feed the breaker so we back off.
      final next = await _repo.recordCircuitBreakerFailure(
        _serviceName,
        threshold: _failureThreshold,
        cooldown: _cooldown,
      );
      Log.w(
        'google_places',
        'failure ${next.failureCount}/$_failureThreshold; '
            'breaker ${next.openedUntil == null ? 'closed' : 'OPEN'}',
        e,
      );
      rethrow;
    }
  }

  Future<List<NearbyMerchant>> _fetch({
    required double lat,
    required double lng,
    required int radiusMi,
    Set<String>? rootIds,
  }) async {
    final radiusM = (radiusMi * 1609.34).clamp(0, 50000).toDouble();
    // Privacy: coarsen to 3 decimal places (~110 m).
    final coarseLat = double.parse(lat.toStringAsFixed(3));
    final coarseLng = double.parse(lng.toStringAsFixed(3));

    final effectiveRootIds = (rootIds == null || rootIds.isEmpty)
        ? defaultEnabledPlaceRootIds
        : rootIds;
    var types = includedTypesForRoots(effectiveRootIds);
    if (types.isEmpty) {
      // The saved selection references only roots that no longer exist (e.g.
      // renamed by a catalog update). Searching nothing would leave the
      // Stores tab empty and register no geofences, so degrade to defaults.
      types = includedTypesForRoots(defaultEnabledPlaceRootIds);
    }

    // API limit: max 50 includedTypes per request. Round-robin the types across
    // the minimum number of batches rather than slicing positionally: `types` is
    // grouped by place-root (all dining types together, all grocery together, …),
    // so positional chunking clustered the densest types into one batch, and the
    // per-batch `maxResultCount` cap then starved rarer types sharing it in a dense
    // area (A2-F6). Interleaving spreads dense and rare types evenly so each batch's
    // result slots are contested across a diverse type set — at no extra request
    // cost (identical batch count; each batch stays ≤ 50 types).
    const maxTypesPerRequest = 50;
    final batchCount = (types.length / maxTypesPerRequest).ceil();
    final batches = List.generate(batchCount, (_) => <String>[]);
    for (var i = 0; i < types.length; i++) {
      batches[i % batchCount].add(types[i]);
    }

    // Tolerate partial failure. With the default categories this fans out
    // into several parallel requests, and one flaky batch (common in a
    // Doze-throttled background re-register window) must not abort the whole
    // fetch via `Future.wait`'s all-or-nothing semantics. Keep every batch
    // that succeeds; only fail the call when *all* batches failed, so the
    // circuit breaker still trips on a real outage (bad key, quota, no
    // network) rather than on a single transient timeout.
    final outcomes = await Future.wait(
      batches.map((batch) async {
        try {
          final r = await _fetchBatch(
            coarseLat: coarseLat,
            coarseLng: coarseLng,
            radiusM: radiusM,
            originLat: lat,
            originLng: lng,
            types: batch,
          );
          return (merchants: r, error: null as Object?);
        } catch (e) {
          return (merchants: <NearbyMerchant>[], error: e as Object?);
        }
      }),
    );
    // Only surface a failure when there *were* batches and every one failed —
    // an empty `batches` (no resolved types) is "nothing to search", not an
    // error, and must return [] rather than tripping `.first` on an empty list.
    if (outcomes.isNotEmpty && outcomes.every((o) => o.error != null)) {
      // Classify the aggregate: an upstream-broken batch (bad key, quota, 5xx)
      // outranks a transient one, so a real outage still trips the breaker
      // even if one batch merely timed out. All-transient (every dead cell
      // batch) stays transient and spares the breaker.
      final errors = outcomes.map((o) => o.error!).toList();
      final upstream = errors.whereType<PlacesUpstreamError>();
      throw upstream.isNotEmpty ? upstream.first : errors.first;
    }

    // Merge, dedup by place id, preserve closest occurrence.
    final seen = <String, NearbyMerchant>{};
    for (final o in outcomes) {
      for (final m in o.merchants) {
        final existing = seen[m.id];
        if (existing == null || m.distanceMi < existing.distanceMi) {
          seen[m.id] = m;
        }
      }
    }
    return seen.values.toList();
  }

  Future<List<NearbyMerchant>> _fetchBatch({
    required double coarseLat,
    required double coarseLng,
    required double radiusM,
    required double originLat,
    required double originLng,
    required List<String> types,
  }) async {
    final body = jsonEncode({
      'includedTypes': types,
      'locationRestriction': {
        'circle': {
          'center': {'latitude': coarseLat, 'longitude': coarseLng},
          'radius': radiusM,
        },
      },
      'maxResultCount': 20,
      'rankPreference': 'DISTANCE',
    });

    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'X-Goog-Api-Key': _kApiKey,
              'Content-Type': 'application/json',
              'X-Goog-FieldMask': _fieldMask,
              if (_kAndroidPackage.isNotEmpty)
                'X-Android-Package': _kAndroidPackage,
              if (_kAndroidCert.isNotEmpty) 'X-Android-Cert': _kAndroidCert,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw PlacesNetworkTransient('timeout');
    } on SocketException catch (e) {
      throw PlacesNetworkTransient('network: ${e.message}');
    }

    if (resp.statusCode != 200) {
      throw PlacesUpstreamError('${resp.statusCode}: ${resp.body}');
    }

    // A 200 with a non-JSON or wrong-shaped body (proxy error page, truncated
    // response) must not throw an uncaught FormatException/TypeError into the
    // isolate — degrade to a normal failure the caller already handles.
    final dynamic decoded;
    try {
      decoded = jsonDecode(resp.body);
    } on FormatException catch (e) {
      throw PlacesUpstreamError('malformed JSON response: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw PlacesUpstreamError('unexpected response shape');
    }
    final json = decoded;
    final places = (json['places'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    final out = <NearbyMerchant>[];
    for (final p in places) {
      // Skip permanently closed places (free field).
      if (p['businessStatus'] == 'CLOSED_PERMANENTLY') continue;

      final loc = p['location'] as Map<String, dynamic>?;
      final mlat = (loc?['latitude'] as num?)?.toDouble();
      final mlng = (loc?['longitude'] as num?)?.toDouble();
      if (mlat == null || mlng == null) continue;

      final id = p['id'] as String?;
      if (id == null || id.isEmpty) continue;

      final displayName = p['displayName'] as Map<String, dynamic>?;
      final name = displayName?['text'] as String? ?? 'Unknown';
      final primaryType = p['primaryType'] as String?;

      out.add(
        NearbyMerchant(
          id: id,
          name: name,
          category: primaryType,
          placeType: primaryType,
          lat: mlat,
          lng: mlng,
          distanceMi: _haversineMi(originLat, originLng, mlat, mlng),
          businessStatus: p['businessStatus'] as String?,
        ),
      );
    }
    return out;
  }
}

double _haversineMi(double lat1, double lng1, double lat2, double lng2) {
  const earthKm = 6371.0;
  final dLat = _toRad(lat2 - lat1);
  final dLng = _toRad(lng2 - lng1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_toRad(lat1)) *
          math.cos(_toRad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthKm * c * 0.621371;
}

double _toRad(double deg) => deg * math.pi / 180;
