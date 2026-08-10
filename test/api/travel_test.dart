import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/travel.dart';

/// N7 — the pure decision helpers behind foreign-travel mode. (The OS geocoder
/// in `countryForCoordinate` is runtime-only and exercised on a device.)
void main() {
  group('homeCountryForCurrency', () {
    test('maps the supported account currencies', () {
      expect(homeCountryForCurrency('USD'), 'US');
      expect(homeCountryForCurrency('usd'), 'US');
      expect(homeCountryForCurrency('CAD'), 'CA');
    });
    test('unknown / null / empty → null (no guess)', () {
      expect(homeCountryForCurrency('GBP'), isNull);
      expect(homeCountryForCurrency(null), isNull);
      expect(homeCountryForCurrency(''), isNull);
    });
  });

  group('isForeignTravel', () {
    test('different countries → abroad', () {
      expect(isForeignTravel(home: 'US', current: 'FR'), isTrue);
      expect(
        isForeignTravel(home: 'us', current: 'FR'),
        isTrue,
      ); // case-insensitive
    });
    test('same country → not abroad', () {
      expect(isForeignTravel(home: 'US', current: 'US'), isFalse);
      expect(isForeignTravel(home: 'US', current: 'us'), isFalse);
    });
    test('unknown on either side → not abroad (never guess)', () {
      expect(isForeignTravel(home: null, current: 'FR'), isFalse);
      expect(isForeignTravel(home: 'US', current: null), isFalse);
      expect(isForeignTravel(home: null, current: null), isFalse);
    });
  });
}
