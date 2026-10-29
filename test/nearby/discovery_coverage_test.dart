import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/nearby/geofence_manager.dart';
import 'package:swipewise/nearby/location_service.dart';
import 'package:swipewise/nearby/google_places_provider.dart';
import 'package:swipewise/nearby/merchant.dart';
import 'package:swipewise/nearby/merchant_search_provider.dart';
import 'package:swipewise/nearby/tile_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await DatabaseHelper.bootstrapSchema(db);
    DatabaseHelper.setTestDatabaseFactory(() async => db);
  });
  tearDown(() async {
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });
  NearbySearchResult area(
    String id,
    double lat, {
    double coverage = 1000,
    bool partial = false,
  }) => NearbySearchResult(
    centerLat: lat,
    centerLng: -100,
    coveredM: coverage,
    partial: partial,
    merchants: [
      NearbyMerchant(id: id, name: id, lat: lat, lng: -100, distanceMi: 0),
    ],
  );

  test(
    'retains multiple footprints and never confuses category selections',
    () async {
      final cache = TileCache();
      await cache.write(
        lat: 40,
        lng: -100,
        queryKey: 'dining',
        result: area('one', 40),
      );
      await cache.write(
        lat: 40.002,
        lng: -100,
        queryKey: 'dining',
        result: area('two', 40.002),
      );
      expect(
        (await cache.read(
          lat: 40,
          lng: -100,
          queryKey: 'dining',
        ))!.merchants.map((m) => m.id),
        containsAll(['one', 'two']),
      );
      expect(await cache.read(lat: 40, lng: -100, queryKey: 'retail'), isNull);
      expect(await db.query('merchant_search_cache'), hasLength(2));
    },
  );
  test(
    'tiny coverage is reusable only as degraded and fallback has no fictional radius',
    () async {
      final cache = TileCache();
      await cache.write(
        lat: 40,
        lng: -100,
        result: area('one', 40, coverage: 42),
      );
      expect(await cache.read(lat: 40, lng: -100), isNull);
      expect(
        (await cache.read(lat: 40, lng: -100, allowDegraded: true))!.coveredM,
        42,
      );
      expect(
        await cache.read(lat: 40.002, lng: -100, allowDegraded: true),
        isNull,
      );
      final fallback = (await cache.readFallback(lat: 40, lng: -100))!;
      expect(fallback.partial, isTrue);
      expect(fallback.coveredM, 0);
      await cache.write(
        lat: 40,
        lng: -100,
        result: area('partial', 40, partial: true),
      );
      expect(await cache.read(lat: 40, lng: -100, allowDegraded: true), isNull);
    },
  );
  test('footprints per cell are bounded', () async {
    final cache = TileCache();
    for (var i = 0; i < 12; i++) {
      await cache.write(
        lat: 40,
        lng: -100,
        queryKey: '$i',
        result: area('$i', 40),
      );
    }
    expect(
      await db.query('merchant_search_cache'),
      hasLength(TileCache.maxFootprintsPerCell),
    );
  });
  test(
    'v21 upgrade creates cache without clearing wallet or user choices',
    () async {
      await db.execute('DROP TABLE merchant_search_cache');
      await db.insert('users', {'id': 'u', 'identifier': 'User'});
      await db.insert('cards', {
        'id': 'c',
        'user_id': 'u',
        'name': 'Card',
        'source': 'manual',
      });
      await db.insert('muted_merchants', {
        'merchant_id': 'm',
        'name': 'Muted',
        'muted_at': 1,
      });
      await db.insert('store_picks', {'merchant_id': 'p', 'picked_at': 1});
      await DatabaseHelper.runUpgrade(db, 21, 22);
      await DatabaseHelper.runUpgrade(db, 21, 22);
      for (final table in [
        'users',
        'cards',
        'muted_merchants',
        'store_picks',
      ]) {
        expect(await db.query(table), hasLength(1), reason: table);
      }
      expect(await db.query('merchant_search_cache'), isEmpty);
    },
  );
  for (final dense in [false, true]) {
    test(
      '${dense ? 'saturated' : 'sparse'} search respects bounded refinement and honest coverage',
      () async {
        var calls = 0;
        final provider = GooglePlacesProvider(
          apiKey: 'test',
          proxyUrl: '',
          client: MockClient((request) async {
            calls++;
            final center =
                ((jsonDecode(request.body)
                        as Map)['locationRestriction']['circle']['center'])
                    as Map;
            return http.Response(
              jsonEncode({
                'places': [
                  for (var i = 0; i < (dense ? 20 : 1); i++)
                    {
                      'id': '$calls-$i',
                      'displayName': {'text': 'Store'},
                      'primaryType': 'clothing_store',
                      'location': {
                        'latitude': (center['latitude'] as num) + i * 0.00001,
                        'longitude': center['longitude'],
                      },
                    },
                ],
              }),
              200,
            );
          }),
        );
        final result = await provider.nearbyCovered(
          lat: 40,
          lng: -100,
          radiusMi: 1,
          categoryIds: {'retail'},
        );
        expect(
          calls,
          dense
              ? inInclusiveRange(2, 7) // One base request plus six extra calls.
              : 1,
        );
        expect(result.coveredM, dense ? lessThan(300) : greaterThan(1000));
        expect(result.partial, isFalse);
      },
    );
  }

  test('partial batch failure cannot claim complete coverage', () async {
    var calls = 0;
    final provider = GooglePlacesProvider(
      apiKey: 'test',
      proxyUrl: '',
      client: MockClient((_) async {
        calls++;
        if (calls == 1) return http.Response('upstream failed', 500);
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'known',
                'displayName': {'text': 'Known store'},
                'location': {'latitude': 40, 'longitude': -100},
              },
            ],
          }),
          200,
        );
      }),
    );
    final result = await provider.nearbyCovered(
      lat: 40,
      lng: -100,
      radiusMi: 1,
    );
    expect(result.merchants, isNotEmpty);
    expect(result.partial, isTrue);
    expect(result.coveredM, 0);
  });

  for (final kind in ['dense', 'partial-empty', 'complete-empty', 'capped']) {
    test('$kind registration preserves explicit recovery contract', () async {
      await db.insert('users', {'id': 'u', 'identifier': 'User'});
      await db.insert('cards', {
        'id': 'c',
        'user_id': 'u',
        'name': 'Card',
        'source': 'manual',
      });
      final location = _MovingLocation();
      if (kind == 'capped') location.lat = 40.00049;
      final search = _AreaSearch(kind);
      final registrations = <Map<Object?, Object?>>[];
      var refreshes = 0;
      const channel = MethodChannel('com.appsoflife/geofence');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'accountEpoch') return 7;
            if (call.method == 'recoveryGeneration') return 11;
            if (call.method == 'requestRefresh') {
              refreshes++;
              return null;
            }
            if (call.method == 'registerSet') {
              final args = call.arguments as Map<Object?, Object?>;
              registrations.add(args);
              return (args['zones'] as List).length;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final manager = GeofenceManager(
        cache: TileCache(),
        search: search,
        location: location,
        repo: DataRepository(),
      );
      Future<bool> run() => manager.ensureRegistered(
        userId: 'u',
        enabled: true,
        radiusMi: 1,
        dwellByCategory: {},
        trigger: 'background',
      );
      expect(await run(), isTrue);
      if (kind == 'partial-empty') {
        expect(registrations, isEmpty);
        expect(refreshes, 1);
      } else {
        expect(registrations.single['recovery_generation'], 11);
        if (kind != 'capped') expect(refreshes, kind == 'dense' ? 1 : 0);
        if (kind == 'complete-empty') {
          expect(registrations.single['zones'], isEmpty);
        }
      }
      if (kind == 'capped') {
        final zones = registrations.single['zones'] as List;
        expect(zones, hasLength(50));
        final boundary = registrations.single['boundary'] as Map;
        final shift = distanceMeters(
          location.lat,
          -100,
          boundary['lat'] as double,
          boundary['lng'] as double,
        );
        final farthest = zones
            .map(
              (z) => distanceMeters(
                location.lat,
                -100,
                (z as Map)['lat'] as double,
                z['lng'] as double,
              ),
            )
            .reduce((a, b) => a > b ? a : b);
        expect(
          boundary['radius_m'],
          (farthest - shift).clamp(300, 10000).round(),
        );
        if (farthest - shift < 300) expect(refreshes, 1);
      }
      if (kind == 'dense') {
        expect(await run(), isTrue);
        expect(
          search.calls,
          1,
          reason: 'Do not repeat a capped query while stationary',
        );
        location.lat = 40.002;
        expect(await run(), isTrue);
        expect(
          search.calls,
          2,
          reason:
              'Recovery searches the new uncovered coarse point without AR/EXIT',
        );
        final options = (registrations.last['zones'] as List).expand(
          (z) => (z as Map)['options'] as List,
        );
        expect(
          options.any((o) => (o as Map)['merchant_id'] == 'place-40.002'),
          isTrue,
        );
        expect(refreshes, 3);
      }
    });
  }
}

class _MovingLocation extends LocationService {
  double lat = 40;
  @override
  Future<({double lat, double lng})> getOneShot({bool ask = true}) async =>
      (lat: lat, lng: -100.0);
  @override
  Future<LocationPermission> currentPermission() async =>
      LocationPermission.always;
}

class _AreaSearch extends MerchantSearchProvider {
  _AreaSearch(this.kind);
  final String kind;
  int calls = 0;
  @override
  Future<NearbySearchResult> nearbyCovered({
    required double lat,
    required double lng,
    required int radiusMi,
    Set<String>? categoryIds,
  }) async {
    calls++;
    return NearbySearchResult(
      centerLat: lat,
      centerLng: lng,
      coveredM: kind == 'dense' ? 42 : 1000,
      partial: kind == 'partial-empty',
      merchants: kind == 'capped'
          ? [
              for (var y = -4; y < 4; y++)
                for (var x = -4; x < 4; x++)
                  NearbyMerchant(
                    id: '$x:$y',
                    name: 'Store $x:$y',
                    placeType: 'store',
                    lat: lat + y * 0.0008,
                    lng: lng + x * 0.0008,
                    distanceMi:
                        distanceMeters(
                          lat,
                          lng,
                          lat + y * 0.0008,
                          lng + x * 0.0008,
                        ) /
                        1609.34,
                  ),
            ]
          : kind == 'dense'
          ? [
              NearbyMerchant(
                id: 'place-$lat',
                name: 'Store',
                lat: lat,
                lng: lng,
                distanceMi: 0,
                placeType: 'store',
              ),
            ]
          : [],
    );
  }
}
