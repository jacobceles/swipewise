import 'dart:convert';
import '../api/database_helper.dart';
import 'merchant.dart';
import 'merchant_search_provider.dart';

/// Bounded snapshots of coarse search footprints, never a fabricated coverage
/// circle spanning the union of unrelated searches or category selections.
class TileCache {
  static const maxCells = 200;
  static const maxFootprintsPerCell = 8;
  static const double edgeM = 150;
  static const _table = 'merchant_search_cache';

  String cellIdFor(double lat, double lng) =>
      '${(lat * 100).round()}:${(lng * 100).round()}';

  List<String> neighborhoodCellIds(double lat, double lng) => [
    for (var y = -1; y <= 1; y++)
      for (var x = -1; x <= 1; x++)
        '${(lat * 100).round() + y}:${(lng * 100).round() + x}',
  ];

  static double coverageLeftM({
    required double centerLat,
    required double centerLng,
    required double coveredM,
    required double lat,
    required double lng,
  }) => coveredM - distanceMeters(centerLat, centerLng, lat, lng);

  Future<List<Map<String, Object?>>> _rows(
    double lat,
    double lng,
    String queryKey, {
    bool stale = false,
  }) async {
    final db = await DatabaseHelper().database;
    final cells = neighborhoodCellIds(lat, lng);
    return db.query(
      _table,
      where:
          'cell_id IN (${List.filled(cells.length, '?').join(',')}) AND query_key = ?${stale ? '' : ' AND fetched_at >= ?'}',
      whereArgs: [
        ...cells,
        queryKey,
        if (!stale)
          DateTime.now()
              .subtract(const Duration(days: 7))
              .millisecondsSinceEpoch,
      ],
      orderBy: 'fetched_at DESC',
    );
  }

  Future<NearbySearchResult?> read({
    required double lat,
    required double lng,
    String queryKey = '',
    bool allowDegraded = false,
  }) async {
    final rows = await _rows(lat, lng, queryKey);
    Map<String, Object?>? selected;
    var bestLeft = edgeM;
    for (final r in rows) {
      if (r['partial'] == 1) continue;
      final left = coverageLeftM(
        centerLat: (r['center_lat'] as num).toDouble(),
        centerLng: (r['center_lng'] as num).toDouble(),
        coveredM: (r['covered_m'] as num).toDouble(),
        lat: lat,
        lng: lng,
      );
      if (left >= bestLeft) {
        selected = r;
        bestLeft = left;
      }
    }
    // Reuse a saturated but successful query at the same coarse point. Recovery
    // still checks location; repeating the identical capped request adds no coverage.
    if (selected == null && allowDegraded) {
      for (final r in rows) {
        if (r['partial'] == 0 &&
            r['center_lat'] == double.parse(lat.toStringAsFixed(3)) &&
            r['center_lng'] == double.parse(lng.toStringAsFixed(3))) {
          selected = r;
          break;
        }
      }
    }
    if (selected == null) return null;
    final db = await DatabaseHelper().database;
    await db.update(
      _table,
      {'last_accessed_at': DateTime.now().millisecondsSinceEpoch},
      where:
          'cell_id = ? AND query_key = ? AND center_lat = ? AND center_lng = ?',
      whereArgs: [
        selected['cell_id'],
        queryKey,
        selected['center_lat'],
        selected['center_lng'],
      ],
    );
    return NearbySearchResult(
      merchants: _merchants(rows, lat, lng),
      centerLat: (selected['center_lat'] as num).toDouble(),
      centerLng: (selected['center_lng'] as num).toDouble(),
      coveredM: (selected['covered_m'] as num).toDouble(),
    );
  }

  Future<NearbySearchResult?> readFallback({
    required double lat,
    required double lng,
    String queryKey = '',
    double maxDistanceM = 1000,
  }) async {
    final merchants = _merchants(
      await _rows(lat, lng, queryKey, stale: true),
      lat,
      lng,
    ).where((m) => m.distanceMi * 1609.34 <= maxDistanceM).toList();
    if (merchants.isEmpty) return null;
    return NearbySearchResult(
      merchants: merchants,
      centerLat: lat,
      centerLng: lng,
      coveredM: 0,
      partial: true,
    );
  }

  List<NearbyMerchant> _merchants(
    List<Map<String, Object?>> rows,
    double lat,
    double lng,
  ) {
    final byId = <String, NearbyMerchant>{};
    for (final r in rows) {
      for (final item in jsonDecode(r['merchants_json'] as String) as List) {
        final m = item as Map<String, dynamic>;
        final mlat = (m['lat'] as num).toDouble(),
            mlng = (m['lng'] as num).toDouble();
        byId.putIfAbsent(
          m['id'] as String,
          () => NearbyMerchant(
            id: m['id'] as String,
            name: m['name'] as String,
            category: m['category'] as String?,
            placeType: m['type'] as String?,
            businessStatus: m['status'] as String?,
            lat: mlat,
            lng: mlng,
            distanceMi: distanceMeters(lat, lng, mlat, mlng) / 1609.34,
          ),
        );
      }
    }
    return byId.values.toList()
      ..sort((a, b) => a.distanceMi.compareTo(b.distanceMi));
  }

  Future<void> write({
    required double lat,
    required double lng,
    required NearbySearchResult result,
    String queryKey = '',
  }) async {
    final db = await DatabaseHelper().database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cell = cellIdFor(lat, lng);
    await db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT OR REPLACE INTO $_table VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          cell,
          queryKey,
          result.centerLat,
          result.centerLng,
          result.coveredM,
          result.partial ? 1 : 0,
          jsonEncode([
            for (final m in result.merchants)
              {
                'id': m.id,
                'name': m.name,
                'category': m.category,
                'type': m.placeType,
                'status': m.businessStatus,
                'lat': m.lat,
                'lng': m.lng,
              },
          ]),
          now,
          now,
        ],
      );
      await txn.rawDelete(
        'DELETE FROM $_table WHERE rowid IN (SELECT rowid FROM $_table WHERE cell_id = ? ORDER BY last_accessed_at DESC, rowid DESC LIMIT -1 OFFSET ?)',
        [cell, maxFootprintsPerCell],
      );
    });
    await evictTo(maxCells);
  }

  Future<void> clearAll() async =>
      (await DatabaseHelper().database).delete(_table);

  Future<void> evictTo(int keepCells) async {
    final db = await DatabaseHelper().database;
    await db.rawDelete(
      'DELETE FROM $_table WHERE cell_id NOT IN (SELECT cell_id FROM $_table GROUP BY cell_id ORDER BY MAX(last_accessed_at) DESC LIMIT ?)',
      [keepCells],
    );
  }
}
