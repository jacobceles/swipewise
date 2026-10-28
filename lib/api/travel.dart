import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'package:geocoding/geocoding.dart';
import 'offline_country.dart';

/// Foreign-travel mode (N7) — deciding whether the user is abroad so the reward
/// engine can rank FX-fee-aware. The pieces are kept as small pure functions
/// (unit-testable); only [countryForCoordinate] touches the OS geocoder.

/// Maps a bank-account currency to the ISO-3166 alpha-2 country we treat as the
/// user's home. Only the currencies the app supports (USD/CAD); null otherwise.
String? homeCountryForCurrency(String? currency) {
  switch ((currency ?? '').toUpperCase()) {
    case 'USD':
      return 'US';
    case 'CAD':
      return 'CA';
    default:
      return null;
  }
}

/// The device's configured region — a home-country fallback for before the
/// first sync tags any transaction with a currency.
String? deviceLocaleCountry() => WidgetsBinding
    .instance
    .platformDispatcher
    .locale
    .countryCode
    ?.toUpperCase();

/// True only when [home] and [current] are both known and differ. Unknown on
/// either side → false: we never guess "abroad" (a false positive would steer
/// the user off their best domestic card).
bool isForeignTravel({String? home, String? current}) {
  if (home == null || current == null) return false;
  return home.toUpperCase() != current.toUpperCase();
}

/// Offline US/CA polygon interiors first, then the OS geocoder (free, no
/// Places key) for uncertain points. Background fence registration may await
/// this; UI rankings use the non-blocking provider instead.
Future<String?> countryForCoordinate(double lat, double lng) async {
  final offline = await OfflineCountry.countryAt(lat, lng);
  if (offline != null) return offline;
  return geocodedCountryForCoordinate(lat, lng);
}

Future<String?> geocodedCountryForCoordinate(double lat, double lng) async {
  try {
    final placemarks = await Geocoding()
        .placemarkFromCoordinates(lat, lng)
        .timeout(const Duration(seconds: 4));
    if (placemarks.isEmpty) return null;
    final iso = placemarks.first.isoCountryCode;
    return (iso == null || iso.isEmpty) ? null : iso.toUpperCase();
  } catch (_) {
    return null;
  }
}
