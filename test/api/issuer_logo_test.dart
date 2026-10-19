import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/catalog_repository.dart';

/// Every issuer in the bundled catalog has a logo file, so a new issuer
/// shows up here instead of silently getting a letter tile.
void main() {
  test('every catalog issuer has a bundled logo', () {
    final data =
        jsonDecode(File('assets/catalog/free.json').readAsStringSync())
            as Map<String, dynamic>;
    final issuers = {
      for (final p in data['card_products'] as List) p['issuer'] as String,
    };
    final missing = [
      for (final i in issuers)
        if (issuerLogoAsset(i) == null ||
            !File(issuerLogoAsset(i)!).existsSync())
          i,
    ];
    expect(missing, isEmpty);
  });

  test('an unknown issuer has no logo', () {
    expect(issuerLogoAsset('Some New Bank'), isNull);
  });
}
