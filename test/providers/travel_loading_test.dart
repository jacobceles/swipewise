import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
// ignore: depend_on_referenced_packages
import 'package:geocoding_platform_interface/geocoding_platform_interface.dart'
    as geo;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/catalog_repository.dart';
import 'package:swipewise/api/reward_engine.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/data_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'uncertain country does not block local rankings and later refreshes travel',
    () async {
      DatabaseHelper.setTestDatabaseFactory(
        () => databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 1,
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
            onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
          ),
        ),
      );
      final db = await DatabaseHelper().database;
      await db.insert('users', {'id': 'local:guest', 'identifier': 'You'});
      final originalLocation = GeolocatorPlatform.instance;
      final originalGeocoder = geo.GeocodingPlatformFactory.instance;
      final geocoder = _Geocoder();
      final location = _Location();
      GeolocatorPlatform.instance = location;
      geo.GeocodingPlatformFactory.instance = geocoder;
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(_Guest.new),
          catalogSnapshotProvider.overrideWith(
            (ref) async => CatalogSnapshot(
              products: {
                'p': const CardProduct(
                  id: 'p',
                  issuer: 'x',
                  displayName: 'P',
                  catalogVersion: 't',
                ),
              },
              rulesByProduct: const {},
              exclusionsByRule: const {},
              pointSystems: const {},
            ),
          ),
          cardLinksProvider.overrideWith(
            (ref) async => [
              const LinkedCard(
                cardId: 'c',
                cardProductId: 'p',
                cardName: 'Card',
              ),
            ],
          ),
          bonusSelectionsProvider.overrideWith((ref) async => {}),
        ],
      );
      final sub = container.listen(travelIsForeignProvider, (_, _) {});
      final rankingSub = container.listen(engineRankerProvider, (_, _) {});
      addTearDown(() async {
        sub.close();
        rankingSub.close();
        container.dispose();
        GeolocatorPlatform.instance = originalLocation;
        if (originalGeocoder != null) {
          geo.GeocodingPlatformFactory.instance = originalGeocoder;
        }
        await db.close();
        DatabaseHelper.setTestDatabaseFactory(null);
      });
      expect(await DataRepository().homeCountry('local:guest'), 'US');
      expect(
        await container
            .read(travelIsForeignProvider.future)
            .timeout(const Duration(seconds: 1)),
        isFalse,
      );
      await geocoder.started.future;
      expect(
        geocoder.result.isCompleted,
        isFalse,
        reason:
            'the ranking input completed while the OS lookup is still pending',
      );
      expect(
        (await container
                .read(engineRankerProvider.future)
                .timeout(const Duration(seconds: 1)))!
            .isForeign,
        isFalse,
      );
      geocoder.result.complete([const geo.Placemark(isoCountryCode: 'CA')]);
      await pumpEventQueue();
      expect(
        await container.read(travelIsForeignProvider.future),
        isTrue,
        reason: 'completion must invalidate the FX-fee ranking input',
      );
      expect(
        (await container.read(engineRankerProvider.future))!.isForeign,
        isTrue,
      );

      // A <1 km move across the border must not reuse a broad spatial cache.
      location.lat = 48.999;
      geocoder.result = Completer<List<geo.Placemark>>();
      container.invalidate(travelIsForeignProvider);
      expect(await container.read(travelIsForeignProvider.future), isFalse);
      await pumpEventQueue();
      expect(geocoder.calls, 2);
      geocoder.result.complete([const geo.Placemark(isoCountryCode: 'US')]);
      await pumpEventQueue();
      expect(await container.read(travelIsForeignProvider.future), isFalse);

      // Interior points do not start an OS request at all.
      location.lat = 51.05;
      location.lng = -114.07;
      container.invalidate(travelIsForeignProvider);
      expect(await container.read(travelIsForeignProvider.future), isTrue);
      expect(geocoder.calls, 2);
    },
  );
}

class _Guest extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoggedIn: true, userId: 'local:guest');
}

class _Location extends GeolocatorPlatform {
  double lat = 49.001;
  double lng = -110;
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

class _Geocoder extends geo.GeocodingPlatformFactory {
  final started = Completer<void>();
  var result = Completer<List<geo.Placemark>>();
  int calls = 0;
  @override
  geo.Geocoding createGeocoding(geo.GeocodingCreationParams params) =>
      _Lookup(params, this);
}

class _Lookup extends geo.Geocoding {
  _Lookup(super.params, this.owner) : super.implementation();
  final _Geocoder owner;
  @override
  Future<List<geo.Placemark>> placemarkFromCoordinates(
    double latitude,
    double longitude, {
    Locale? locale,
  }) {
    if (!owner.started.isCompleted) owner.started.complete();
    owner.calls++;
    return owner.result.future;
  }
}
