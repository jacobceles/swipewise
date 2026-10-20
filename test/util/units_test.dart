import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/util/units.dart';

void main() {
  test('miles where roads are in miles, kilometres elsewhere', () {
    expect(formatDistanceMi(0.4, region: 'US'), '0.4 mi');
    expect(formatDistanceMi(0.4, region: 'CA'), '644 m');
    expect(formatDistanceMi(2.0, region: 'CA'), '3.2 km');
    expect(formatRadiusMi(10, region: 'US'), '10 mi');
    expect(formatRadiusMi(10, region: 'CA'), '16 km');
  });
}
