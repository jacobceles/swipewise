import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/nearby/geofence_manager.dart';
import 'package:swipewise/nearby/location_service.dart';
import 'package:swipewise/nearby/merchant.dart';
import 'package:swipewise/nearby/merchant_search_provider.dart';
import 'package:swipewise/nearby/tile_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final (cached, stale) in [(false, false), (true, false), (true, true)]) {
    test(
      '${cached ? 'persisted cache' : 'search'} transit excluded, stale=$stale',
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
        await db.insert('cards', {
          'id': 'card',
          'user_id': 'local:guest',
          'source': 'manual',
          'name': 'Card',
        });
        final result = NearbySearchResult(
          centerLat: 39.74,
          centerLng: -104.99,
          coveredM: 1000,
          merchants: [
            for (final type in [
              'bus_stop',
              'bus_station',
              'transit_station',
              'atm',
              'store',
            ])
              NearbyMerchant(
                id: type,
                name: type,
                placeType: type,
                lat: 39.74,
                lng: -104.99,
                distanceMi: 0,
              ),
          ],
        );
        final cache = TileCache();
        if (cached) await cache.write(lat: 39.74, lng: -104.99, result: result);
        Map<Object?, Object?>? payload;
        const channel = MethodChannel('com.appsoflife/geofence');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'accountEpoch') return 7;
              if (call.method == 'registerSet') {
                payload = call.arguments as Map<Object?, Object?>;
                if (stale) throw PlatformException(code: 'STALE_ACCOUNT');
                return (payload!['zones'] as List).length;
              }
              return null;
            });
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          await db.close();
          DatabaseHelper.setTestDatabaseFactory(null);
        });
        final search = _Search(result);
        expect(
          await GeofenceManager(
            cache: cache,
            search: search,
            location: _Location(),
            repo: DataRepository(),
          ).ensureRegistered(
            userId: 'local:guest',
            enabled: true,
            radiusMi: 1,
            dwellByCategory: const {},
          ),
          isTrue,
        );
        expect(search.calls, cached ? 0 : 1);
        expect(payload!['user_id'], 'local:guest');
        expect(payload!['account_epoch'], 7);
        expect(
          await DataRepository().getSetting(
            'local:guest',
            'geofence_last_register',
          ),
          stale ? isNull : isNotNull,
        );
        final options = (payload!['zones'] as List).expand(
          (z) => (z as Map)['options'] as List,
        );
        expect(options.map((o) => (o as Map)['place_type']), ['store']);
        // Filtering is walk-in-only: cached search results still contain transit.
        expect(
          (await cache.read(lat: 39.74, lng: -104.99))!.merchants,
          hasLength(5),
        );
      },
    );
  }
}

class _Location extends LocationService {
  @override
  Future<({double lat, double lng})> getOneShot({bool ask = true}) async =>
      (lat: 39.74, lng: -104.99);
  @override
  Future<LocationPermission> currentPermission() async =>
      LocationPermission.always;
}

class _Search extends MerchantSearchProvider {
  _Search(this.result);
  final NearbySearchResult result;
  int calls = 0;
  @override
  Future<NearbySearchResult> nearbyCovered({
    required double lat,
    required double lng,
    required int radiusMi,
    Set<String>? categoryIds,
  }) async {
    calls++;
    return result;
  }
}
