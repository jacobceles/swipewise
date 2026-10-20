import 'dart:ui';

/// Regions whose roads are signed in miles. Everywhere else (Canada
/// included) reads distance in kilometres.
const _milesRegions = {'US', 'GB', 'LR', 'MM'};

bool _usesMiles(String? region) => _milesRegions.contains(
  (region ?? PlatformDispatcher.instance.locale.countryCode ?? 'US')
      .toUpperCase(),
);

/// A store's distance, given in miles: "0.4 mi", or "644 m" / "1.2 km".
String formatDistanceMi(double mi, {String? region}) {
  if (_usesMiles(region)) return '${mi.toStringAsFixed(1)} mi';
  final km = mi * 1.609344;
  return km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';
}

/// A search radius setting (stored in miles): "10 mi" or "16 km".
String formatRadiusMi(int mi, {String? region}) =>
    _usesMiles(region) ? '$mi mi' : '${(mi * 1.609344).round()} km';
