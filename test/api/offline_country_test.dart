import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/offline_country.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final boundaries = OfflineCountry.fromJson(
    jsonDecode(File('assets/boundaries/us_ca.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  test('classifies US and Canadian interiors using bundled polygons', () async {
    for (final (lat, lng, country) in [
      (39.74, -104.99, 'US'), // Denver
      (33.45, -112.07, 'US'), // Phoenix
      (64.84, -147.72, 'US'), // Fairbanks
      (51.05, -114.07, 'CA'), // Calgary
      (53.55, -113.49, 'CA'), // Edmonton
      (45.42, -75.7, 'CA'), // Ottawa
    ]) {
      expect(boundaries.classify(lat, lng), country, reason: '$lat,$lng');
      expect(
        await OfflineCountry.countryAt(lat, lng),
        country,
        reason: 'the asset must also be registered in pubspec',
      );
    }
  });

  test('never guesses near generalized borders, lakes or coasts', () {
    for (final (lat, lng) in [
      (49.001, -110.0), (48.999, -110.0), // opposite sides, < 1 km
      (42.32, -83.04), (42.33, -83.04), // Detroit / Windsor
      (43.09, -79.06), // Niagara
      (49.0, -123.0), // Pacific border
      (60.3, -141.0), // Alaska / Yukon border
      (32.54, -117.03), // US / Mexico
      (40.71, -74.0), // NYC coast
    ]) {
      expect(boundaries.classify(lat, lng), isNull, reason: '$lat,$lng');
    }
  });

  test('does not turn bounding-box ocean or other countries into US or CA', () {
    for (final (lat, lng) in [
      (25.7, -100.3), // Monterrey, inside US mainland bounding box
      (47.0, -60.0), // ocean inside Canadian mainland bounding box
      (48.85, 2.35), (0.0, 0.0),
      (80.0, -90.0), // polar projection deliberately unsupported
      (double.nan, -100.0), (45.0, double.infinity),
    ]) {
      expect(boundaries.classify(lat, lng), isNull, reason: '$lat,$lng');
    }
  });
}
