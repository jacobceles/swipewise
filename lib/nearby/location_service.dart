import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:geolocator/geolocator.dart';

import '../util/logger.dart';

bool isAlwaysAllowed(LocationPermission p) => p == LocationPermission.always;

bool isAtLeastWhileInUse(LocationPermission p) =>
    p == LocationPermission.whileInUse || p == LocationPermission.always;

Future<bool> openAppLocationSettings() => Geolocator.openAppSettings();

class LocationDenied implements Exception {
  final bool permanent;
  LocationDenied({required this.permanent});
  @override
  String toString() => permanent
      ? 'Location permission permanently denied. Enable in system settings.'
      : 'Location permission denied.';
}

class LocationServiceDisabled implements Exception {
  @override
  String toString() => 'Location services are turned off on this device.';
}

class LocationService {
  /// A last-known fix older than this is too stale to register area-level
  /// geofences around: at highway speed 5 min ≈ 6 mi of drift, enough to
  /// fence the town you already left. RC1 froze a Nevada fix
  /// (39.696,-119.441) across five cross-state re-registrations because the
  /// fallback had no age bound; this is that bound.
  static const Duration maxLastKnownAge = Duration(minutes: 5);

  /// Current location grant. `always` is the only state where background
  /// geofences fire; `whileInUse` silently doesn't — the signal the beacon
  /// reports.
  Future<LocationPermission> currentPermission() =>
      Geolocator.checkPermission();

  Future<({double lat, double lng})> getOneShot() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationServiceDisabled();
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      throw LocationDenied(permanent: true);
    }
    if (perm == LocationPermission.denied) {
      throw LocationDenied(permanent: false);
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return (lat: pos.latitude, lng: pos.longitude);
    } on TimeoutException {
      // Cold-GPS fixes routinely exceed 10 s in a Doze-throttled background
      // isolate. A *recent* last-known position is good enough to register
      // area-level geofences, so fall back to it — but only if it is recent.
      final last = await Geolocator.getLastKnownPosition();
      final age = last == null
          ? null
          : DateTime.now().difference(last.timestamp);
      if (last != null && age != null && age <= maxLastKnownAge) {
        _reportFallback(fresh: true, age: age);
        return (lat: last.latitude, lng: last.longitude);
      }
      // Stale or absent last-known fix: do NOT register around a point the
      // user may have driven far past. Retry once for a real fix — high
      // accuracy + a longer budget gives cold GPS a genuine chance — and if
      // that also fails let it throw so the worker retries rather than
      // freezing the fence set on the wrong town.
      _reportFallback(fresh: false, age: age);
      final retry = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 30),
        ),
      );
      return (lat: retry.latitude, lng: retry.longitude);
    }
  }

  /// Raw OS last-known fix — no age bound, no fallback/retry logic. For
  /// diagnosis paths that need *some* position estimate even when
  /// [getOneShot] itself failed. Returns null when the OS has none.
  Future<({double lat, double lng, Duration age})?> lastKnown() async {
    final p = await Geolocator.getLastKnownPosition();
    if (p == null) return null;
    return (
      lat: p.latitude,
      lng: p.longitude,
      age: DateTime.now().difference(p.timestamp),
    );
  }

  /// Fresh-vs-stale telemetry for the last-known fallback (RC1) so a frozen
  /// fix reappearing across re-registrations becomes countable in Crashlytics
  /// (repeated `location_fallback_stale` non-fatals = the exact bug
  /// signature). Best-effort: guarded so a Firebase-less isolate/test never
  /// breaks the location fetch.
  void _reportFallback({required bool fresh, Duration? age}) {
    final ageMin = age == null
        ? 'none'
        : (age.inSeconds / 60).toStringAsFixed(1);
    final label = age == null
        ? 'no last-known fix'
        : fresh
        ? 'fix fresh age=${ageMin}m'
        : 'fix stale age=${ageMin}m';
    Log.w('location', 'getOneShot timeout; $label');
    try {
      final c = FirebaseCrashlytics.instance;
      c.setCustomKey(
        'location_fix_source',
        age == null
            ? 'last_known_absent'
            : fresh
            ? 'last_known_fresh'
            : 'last_known_stale',
      );
      c.setCustomKey('location_fix_age_min', ageMin);
      // ignore: unawaited_futures
      c.recordError(
        StateError('location_$label'),
        StackTrace.current,
        reason: fresh ? 'location_fallback_fresh' : 'location_fallback_stale',
        fatal: false,
      );
    } catch (_) {
      // No Firebase (background isolate w/o init, or a unit test) — telemetry
      // is strictly optional and must never break location fetch.
    }
  }
}
