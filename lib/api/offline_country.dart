import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Generalized, public-domain Natural Earth polygons. See the asset's LICENSE.
/// Only confidently interior points are classified; this is not a border map.
class OfflineCountry {
  OfflineCountry.fromJson(Map<String, dynamic> json)
    : _rings = json.map(
        (country, polygons) => MapEntry(
          country,
          (polygons as List)
              .map(
                (ring) => (ring as List)
                    .map(
                      (p) =>
                          ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
                    )
                    .toList(),
              )
              .toList(),
        ),
      );

  final Map<String, List<List<(double, double)>>> _rings;
  static const uncertaintyKm = 40.0;
  static Future<OfflineCountry>? _loaded;

  static Future<String?> countryAt(double lat, double lng) async {
    try {
      final boundaries = await (_loaded ??= rootBundle
          .loadString('assets/boundaries/us_ca.json')
          .then(
            (text) => OfflineCountry.fromJson(
              jsonDecode(text) as Map<String, dynamic>,
            ),
          ));
      return boundaries.classify(lat, lng);
    } catch (_) {
      _loaded = null;
      return null;
    }
  }

  String? classify(double lat, double lng) {
    // The local distance projection is deliberately not used near the poles.
    if (!lat.isFinite || !lng.isFinite || lat.abs() > 75 || lng.abs() > 180) {
      return null;
    }
    final scaleX = 111.195 * math.cos(lat * math.pi / 180);
    String? result;
    for (final country in _rings.entries) {
      for (final ring in country.value) {
        var inside = false;
        var nearest = double.infinity;
        for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
          final (ax, ay) = ring[j];
          final (bx, by) = ring[i];
          if ((ay > lat) != (by > lat) &&
              lng < (bx - ax) * (lat - ay) / (by - ay) + ax) {
            inside = !inside;
          }
          final x = (ax - lng) * scaleX;
          final y = (ay - lat) * 111.195;
          final dx = (bx - ax) * scaleX;
          final dy = (by - ay) * 111.195;
          final length2 = dx * dx + dy * dy;
          final t = length2 == 0
              ? 0.0
              : (-(x * dx + y * dy) / length2).clamp(0.0, 1.0);
          nearest = math.min(
            nearest,
            math.sqrt(math.pow(x + t * dx, 2) + math.pow(y + t * dy, 2)),
          );
        }
        if (inside) {
          if (nearest <= uncertaintyKm || result != null) return null;
          result = country.key;
        }
      }
    }
    return result;
  }
}
