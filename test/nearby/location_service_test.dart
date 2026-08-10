import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:swipewise/nearby/location_service.dart';

/// Programmable [GeolocatorPlatform] stand-in. The platform methods have
/// throwing defaults on the base class, so we only override the handful
/// [LocationService.getOneShot] touches. Because it `extends` (not
/// `implements`) [GeolocatorPlatform], it inherits the base class's private
/// token and so passes `GeolocatorPlatform.instance`'s verification without
/// any mock mixin.
class _FakeGeolocator extends GeolocatorPlatform {
  _FakeGeolocator({required this.onGetCurrent, this.lastKnown});

  /// Called for every getCurrentPosition; branch on `accuracy` to distinguish
  /// the first medium attempt from the high-accuracy retry.
  final Future<Position> Function(LocationAccuracy accuracy) onGetCurrent;
  Position? lastKnown;

  int currentCalls = 0;
  final List<LocationAccuracy> requestedAccuracies = [];

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.always;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.always;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => lastKnown;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    currentCalls++;
    final accuracy = locationSettings?.accuracy ?? LocationAccuracy.best;
    requestedAccuracies.add(accuracy);
    return onGetCurrent(accuracy);
  }
}

Position _pos({
  double lat = 10,
  double lng = 20,
  required DateTime timestamp,
}) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: timestamp,
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GeolocatorPlatform original;

  setUp(() => original = GeolocatorPlatform.instance);
  tearDown(() => GeolocatorPlatform.instance = original);

  test('happy path returns the live fix, no fallback', () async {
    final live = _pos(lat: 1, lng: 2, timestamp: DateTime.now());
    final fake = _FakeGeolocator(onGetCurrent: (_) async => live);
    GeolocatorPlatform.instance = fake;

    final fix = await LocationService().getOneShot();

    expect(fix.lat, 1);
    expect(fix.lng, 2);
    expect(fake.currentCalls, 1); // no retry
  });

  test('timeout + FRESH last-known → uses last-known, no retry', () async {
    final fresh = _pos(
      lat: 5,
      lng: 6,
      timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    final fake = _FakeGeolocator(
      lastKnown: fresh,
      onGetCurrent: (_) => throw TimeoutException('cold gps'),
    );
    GeolocatorPlatform.instance = fake;

    final fix = await LocationService().getOneShot();

    expect(fix.lat, 5);
    expect(fix.lng, 6);
    // Only the initial attempt ran; a fresh fallback must NOT trigger a retry.
    expect(fake.currentCalls, 1);
  });

  test('timeout + STALE last-known → retries once at high accuracy', () async {
    final stale = _pos(
      lat: 39.696,
      lng: -119.441,
      timestamp: DateTime.now().subtract(const Duration(minutes: 20)),
    );
    final retryFix = _pos(lat: 7, lng: 8, timestamp: DateTime.now());
    final fake = _FakeGeolocator(
      lastKnown: stale,
      onGetCurrent: (accuracy) async {
        if (accuracy == LocationAccuracy.high) return retryFix;
        throw TimeoutException('cold gps');
      },
    );
    GeolocatorPlatform.instance = fake;

    final fix = await LocationService().getOneShot();

    // The stale Nevada point is NOT returned — the retry fix is.
    expect(fix.lat, 7);
    expect(fix.lng, 8);
    expect(fake.currentCalls, 2);
    expect(fake.requestedAccuracies.last, LocationAccuracy.high);
  });

  test('timeout + STALE last-known + retry also fails → throws', () async {
    final stale = _pos(
      timestamp: DateTime.now().subtract(const Duration(minutes: 20)),
    );
    final fake = _FakeGeolocator(
      lastKnown: stale,
      onGetCurrent: (_) => throw TimeoutException('cold gps'),
    );
    GeolocatorPlatform.instance = fake;

    await expectLater(
      LocationService().getOneShot(),
      throwsA(isA<TimeoutException>()),
    );
    expect(fake.currentCalls, 2); // attempted the retry before giving up
  });

  test('timeout + NO last-known → retries once', () async {
    final retryFix = _pos(lat: 3, lng: 4, timestamp: DateTime.now());
    final fake = _FakeGeolocator(
      lastKnown: null,
      onGetCurrent: (accuracy) async {
        if (accuracy == LocationAccuracy.high) return retryFix;
        throw TimeoutException('cold gps');
      },
    );
    GeolocatorPlatform.instance = fake;

    final fix = await LocationService().getOneShot();

    expect(fix.lat, 3);
    expect(fake.currentCalls, 2);
  });
}
