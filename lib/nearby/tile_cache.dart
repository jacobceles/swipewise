import 'dart:math' as math;
import '../api/database_helper.dart';
import 'merchant.dart';
import 'merchant_search_provider.dart';

/// Caches nearby merchant lookups by ~1km grid cell with a 7-day TTL.
///
/// Two audit fixes baked in:
/// - **H4 (neighborhood-aware reads)**: a single `cellIdFor(lat, lng)` cell
///   bucketed by `round(*100)` puts a user 50m from a cell boundary on the
///   "wrong" side and serves them a different cache entirely. `read()` now
///   queries the 3×3 cell neighborhood and merges results, then filters by
///   actual distance — the user gets a stable set of merchants regardless
///   of which side of an arbitrary grid line they're on.
/// - **Coverage-aware hits**: a read counts only when the user stands inside a
///   cached search's covered circle (see [NearbySearchResult]) with at least
///   [edgeM] to spare. Serving any fresh 3×3 neighbourhood instead handed an
///   arrival 500 m from an old search that search's ~300 m ring, so the store
///   being walked into was never fenced (Flemington, 2026-10-16).
/// - **H5 (LRU eviction)**: `last_accessed_at` is bumped on every read, and
///   [evictTo] trims the cache to the N most-recently-accessed cells. Called
///   opportunistically on `write()` so the table doesn't grow unbounded.
class TileCache {
  static const _ttlDays = 7;

  /// Cap the cache at this many distinct cells. After a year of daily
  /// commuting through ~5 cells, expected steady-state is ~30; 200 leaves
  /// headroom for travel without letting it run away.
  static const int maxCells = 200;

  /// `cell_id = "<lat*100>:<lng*100>"` — buckets to a ~1.1km grid.
  String cellIdFor(double lat, double lng) {
    final ilat = (lat * 100).round();
    final ilng = (lng * 100).round();
    return '$ilat:$ilng';
  }

  /// Returns the 3×3 cell ids centered on (lat, lng). Used by [read] to
  /// stitch together neighbor cells so a user near a cell boundary
  /// doesn't see different caches on either side.
  List<String> neighborhoodCellIds(double lat, double lng) {
    final ilat = (lat * 100).round();
    final ilng = (lng * 100).round();
    final out = <String>[];
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        out.add('${ilat + dy}:${ilng + dx}');
      }
    }
    return out;
  }

  /// How far inside a cached search's covered circle the user must stand: a
  /// fence radius plus margin, so the store they're walking into is one that
  /// search saw.
  static const double edgeM = 150;

  /// Coverage the cached search centred at ([centerLat], [centerLng]) leaves
  /// around the user at ([lat], [lng]) — negative when they're outside it.
  static double coverageLeftM({
    required double centerLat,
    required double centerLng,
    required double coveredM,
    required double lat,
    required double lng,
  }) => coveredM - _distanceMi(centerLat, centerLng, lat, lng) * 1609.34;

  /// The cached places around ([lat], [lng]) with the search that covers this
  /// spot, or null when no fresh cached search does — the caller searches.
  Future<NearbySearchResult?> read({
    required double lat,
    required double lng,
  }) async {
    final db = await DatabaseHelper().database;
    final cells = neighborhoodCellIds(lat, lng);
    final cutoff = DateTime.now()
        .subtract(const Duration(days: _ttlDays))
        .millisecondsSinceEpoch;
    final placeholders = List.filled(cells.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM merchant_tile_cache '
      'WHERE cell_id IN ($placeholders) AND fetched_at >= ?',
      [...cells, cutoff],
    );
    if (rows.isEmpty) return null;
    Map<String, Object?>? covering;
    var bestLeft = edgeM;
    for (final r in rows) {
      final cLat = r['center_lat'] as num?;
      final cLng = r['center_lng'] as num?;
      final cov = r['covered_m'] as num?;
      if (cLat == null || cLng == null || cov == null) continue;
      final left = coverageLeftM(
        centerLat: cLat.toDouble(),
        centerLng: cLng.toDouble(),
        coveredM: cov.toDouble(),
        lat: lat,
        lng: lng,
      );
      if (left >= bestLeft) {
        bestLeft = left;
        covering = r;
      }
    }
    if (covering == null) return null;
    // Bump last_accessed_at for every hit cell — drives the LRU eviction.
    final now = DateTime.now().millisecondsSinceEpoch;
    final hitCells = rows.map((r) => r['cell_id'] as String).toSet();
    if (hitCells.isNotEmpty) {
      final hitPlaceholders = List.filled(hitCells.length, '?').join(',');
      await db.rawUpdate(
        'UPDATE merchant_tile_cache SET last_accessed_at = ? '
        'WHERE cell_id IN ($hitPlaceholders)',
        [now, ...hitCells],
      );
    }
    // Dedup by merchant_id (neighbor cells can re-emit the same place if
    // it sits near a boundary).
    final byId = <String, NearbyMerchant>{};
    for (final r in rows) {
      final id = r['merchant_id'] as String;
      if (byId.containsKey(id)) continue;
      final mlat = (r['lat'] as num).toDouble();
      final mlng = (r['lng'] as num).toDouble();
      byId[id] = NearbyMerchant(
        id: id,
        name: r['name'] as String,
        category: r['category'] as String?,
        placeType: r['foursquare_category_id'] as String?,
        businessStatus: r['business_status'] as String?,
        lat: mlat,
        lng: mlng,
        distanceMi: _distanceMi(lat, lng, mlat, mlng),
      );
    }
    return NearbySearchResult(
      merchants: byId.values.toList()
        ..sort((a, b) => a.distanceMi.compareTo(b.distanceMi)),
      centerLat: (covering['center_lat'] as num).toDouble(),
      centerLng: (covering['center_lng'] as num).toDouble(),
      coveredM: (covering['covered_m'] as num).toDouble(),
    );
  }

  Future<void> clearAll() async {
    final db = await DatabaseHelper().database;
    await db.delete('merchant_tile_cache');
  }

  /// Fallback when a live search fails (e.g. after reboot while offline or
  /// before App Check is ready): returns any cached merchants within
  /// [maxDistanceM] (default 1 km) of ([lat], [lng]), even if expired.
  Future<NearbySearchResult?> readFallback({
    required double lat,
    required double lng,
    double maxDistanceM = 1000,
  }) async {
    final db = await DatabaseHelper().database;
    final cells = neighborhoodCellIds(lat, lng);
    final placeholders = List.filled(cells.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM merchant_tile_cache WHERE cell_id IN ($placeholders)',
      cells,
    );
    if (rows.isEmpty) return null;
    final maxMi = maxDistanceM / 1609.34;
    final byId = <String, NearbyMerchant>{};
    for (final r in rows) {
      final id = r['merchant_id'] as String;
      if (byId.containsKey(id)) continue;
      final mlat = (r['lat'] as num).toDouble();
      final mlng = (r['lng'] as num).toDouble();
      final distMi = _distanceMi(lat, lng, mlat, mlng);
      if (distMi > maxMi) continue;
      byId[id] = NearbyMerchant(
        id: id,
        name: r['name'] as String,
        category: r['category'] as String?,
        placeType: r['foursquare_category_id'] as String?,
        businessStatus: r['business_status'] as String?,
        lat: mlat,
        lng: mlng,
        distanceMi: distMi,
      );
    }
    if (byId.isEmpty) return null;
    final merchants = byId.values.toList()
      ..sort((a, b) => a.distanceMi.compareTo(b.distanceMi));
    final farthestM = math.max(300.0, merchants.last.distanceMi * 1609.34);
    return NearbySearchResult(
      merchants: merchants,
      centerLat: lat,
      centerLng: lng,
      coveredM: math.min(maxDistanceM, farthestM),
    );
  }

  /// Stores [result] under the cell of ([lat], [lng]), the user's fix.
  Future<void> write({
    required double lat,
    required double lng,
    required NearbySearchResult result,
  }) async {
    final merchants = result.merchants;
    if (merchants.isEmpty) return; // Don't wipe a cell with no replacement.
    final db = await DatabaseHelper().database;
    final cell = cellIdFor(lat, lng);
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final batch = txn.batch();
      batch.delete(
        'merchant_tile_cache',
        where: 'cell_id = ?',
        whereArgs: [cell],
      );
      for (final m in merchants) {
        batch.insert('merchant_tile_cache', {
          'cell_id': cell,
          'merchant_id': m.id,
          'name': m.name,
          'category': m.category,
          'foursquare_category_id': m.placeType,
          'business_status': m.businessStatus,
          'lat': m.lat,
          'lng': m.lng,
          'fetched_at': now,
          'last_accessed_at': now,
          'center_lat': result.centerLat,
          'center_lng': result.centerLng,
          'covered_m': result.coveredM,
        });
      }
      await batch.commit(noResult: true);
    });
    await evictTo(maxCells);
  }

  /// Drops the least-recently-accessed cells until at most [keepCells]
  /// distinct cells remain. Cheap one-shot SQL — runs from `write()`
  /// after each new cell lands, so the cap is enforced without a
  /// background sweep.
  Future<void> evictTo(int keepCells) async {
    final db = await DatabaseHelper().database;
    await db.rawDelete(
      '''
      DELETE FROM merchant_tile_cache
      WHERE cell_id NOT IN (
        SELECT cell_id FROM merchant_tile_cache
        GROUP BY cell_id
        ORDER BY MAX(last_accessed_at) DESC
        LIMIT ?
      )
      ''',
      [keepCells],
    );
  }
}

double _distanceMi(double lat1, double lng1, double lat2, double lng2) {
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
  final km = earthKm * c;
  return km * 0.621371;
}

double _toRad(double deg) => deg * math.pi / 180;
