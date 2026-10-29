import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
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
}
