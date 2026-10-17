import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/nearby/geofence_manager.dart';
import 'package:swipewise/nearby/merchant.dart';
import 'package:swipewise/nearby/tile_cache.dart';

double _metres(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

NearbyMerchant _m(String id, double lat, double lng, double distanceMi) =>
    NearbyMerchant(
      id: id,
      name: id,
      lat: lat,
      lng: lng,
      distanceMi: distanceMi,
    );

void main() {
  // A strip mall: three storefronts within 50 m, plus a pad site ~150 m away.
  const lat = 40.5014, lng = -74.8549;
  List<NearbyMerchant> stripMall({required bool userAtSouthEnd}) => [
    _m('kyoto', lat, lng, userAtSouthEnd ? 0.02 : 0.05),
    _m('atm', lat + 0.0002, lng, userAtSouthEnd ? 0.04 : 0.03),
    _m('lennys', lat + 0.0003, lng, userAtSouthEnd ? 0.05 : 0.01),
    _m('pad', lat + 0.0014, lng, 0.1),
  ];

  List<String> anchors(List<NearbyMerchant> ms) => [
    for (final c in clusterMerchantsForTest(ms, _metres)) c.anchor.id,
  ];

  test('the same places give the same fence ids wherever the user stands', () {
    // Distance-anchored clustering named this strip after whichever store was
    // nearest at registration, so a re-register mid-visit renamed the fence and
    // orphaned its running dwell timer.
    final a = anchors(stripMall(userAtSouthEnd: true));
    final b = anchors(stripMall(userAtSouthEnd: false).reversed.toList());
    expect(a.toSet(), b.toSet());
    expect(a.toSet(), {'atm', 'pad'});
  });

  test(
    'storefronts within 50 m share one fence; the pad site gets its own',
    () {
      final clusters = clusterMerchantsForTest(
        stripMall(userAtSouthEnd: true),
        _metres,
      );
      final mall = clusters.firstWhere((c) => c.anchor.id == 'atm');
      expect(
        {mall.anchor.id, ...mall.others.map((m) => m.id)},
        {'atm', 'kyoto', 'lennys'},
      );
      expect(
        clusters.any((c) => c.anchor.id == 'pad' && c.others.isEmpty),
        isTrue,
      );
    },
  );

  test(
    'clusters come closest first, so the merchant cap keeps the nearest',
    () {
      final clusters = clusterMerchantsForTest(
        stripMall(userAtSouthEnd: true),
        _metres,
      );
      expect(clusters.first.anchor.id, 'atm');
      expect(clusters.last.anchor.id, 'pad');
    },
  );

  test('Big-box stores take the Big-box wait; unknown kinds fall back', () {
    const dwell = {'Big-box': 300, 'Shopping': 120};
    expect(dwellSecondsFor('Department Stores', dwell), 300);
    expect(dwellSecondsFor('Wholesale', dwell), 300);
    expect(dwellSecondsFor('Shopping', dwell), 120);
    expect(dwellSecondsFor('ATM', dwell), GeofenceManager.fallbackDwellSeconds);
    expect(dwellSecondsFor(null, dwell), GeofenceManager.fallbackDwellSeconds);
  });

  test('a cached search covers only the user standing well inside it', () {
    // A dense-town search: complete out to 300 m from its centre.
    double left(double dLat) => TileCache.coverageLeftM(
      centerLat: lat,
      centerLng: lng,
      coveredM: 300,
      lat: lat + dLat,
      lng: lng,
    );
    expect(left(0), closeTo(300, 1));
    // ~100 m from the centre: still a hit (200 m to spare).
    expect(left(0.0009), greaterThanOrEqualTo(TileCache.edgeM));
    // ~500 m away (the Flemington arrival): outside, so search afresh.
    expect(left(0.0045), lessThan(0));
  });
}
