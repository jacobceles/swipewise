// Debug instrumentation entrypoint, never the shipping main.dart. Inputs only:
// the real repository, classifier, cache, manager and native policies do the work.
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/reward_category_mapper.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/models/reward_category.dart';
import 'package:swipewise/nearby/geofence_manager.dart';
import 'package:swipewise/nearby/location_service.dart';
import 'package:swipewise/nearby/merchant.dart';
import 'package:swipewise/nearby/merchant_search_provider.dart';
import 'package:swipewise/nearby/tile_cache.dart';

const _channel = MethodChannel('swipewise/qualification-fixture');
const _user = 'local:qualification-user-v1';
const _merchant = 'qualification-restaurant-v1';
const _lat = 39.237148;
const _lon = -123.176090;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = DataRepository();
  final settings = SettingsRepository(repo);
  final cache = TileCache();
  final search = _NoRemoteSearch();
  final manager = GeofenceManager(
    cache: cache,
    search: search,
    location: LocationService(),
    repo: repo,
  );
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'run') throw UnsupportedError('fixture command');
    final action = call.arguments as String;
    if (action == 'seed-muted') {
      final db = await DatabaseHelper().database;
      if ((await db.query('users')).isNotEmpty) {
        throw StateError('fresh disposable sandbox required');
      }
      // Identity bootstrap mirrors the app's local/free identity, not Firebase.
      await db.insert('users', {
        'id': _user,
        'identifier': 'Qualification only',
      });
      await repo.catalog.replaceCatalog(
        pointSystems: [
          {
            'point_system_id': 'qualification-cash',
            'display_name': 'Qualification cash',
            'baseline_cent_value': 1.0,
            'currency': 'USD',
            'unit': 'cash',
          },
        ],
        cardProducts: [
          for (final (id, name) in [
            ('qualification-dining-v1', 'Qualification Dining'),
            ('qualification-base-v1', 'Qualification Base'),
          ])
            {
              'card_product_id': id,
              'issuer': 'Qualification',
              'display_name': name,
              'catalog_version': 'qualification-v1',
              'country': 'US',
              'currency': 'USD',
            },
        ],
        rewardRules: [
          for (final (id, kind, category, rate) in [
            ('qualification-dining-v1', 'category', 'dining', 3.0),
            ('qualification-dining-v1', 'baseline', null, 1.0),
            ('qualification-base-v1', 'baseline', null, 2.0),
          ])
            {
              'rule_id': '$id-$kind',
              'card_product_id': id,
              'kind': kind,
              'category': category,
              'rate': rate,
              'point_system_id': 'qualification-cash',
            },
        ],
        exclusions: [],
      );
      for (final (id, name) in [
        ('qualification-dining-v1', 'Qualification Dining'),
        ('qualification-base-v1', 'Qualification Base'),
      ]) {
        await repo.addManualCard(
          userId: _user,
          productId: id,
          issuer: 'Qualification',
          name: name,
          network: null,
          imageUrl: null,
        );
      }
      await initBrandRegistry();
      await initCategoryRegistry();
      await settings.setOnboardingSeen(_user);
      await settings.setSetupPending(_user, false);
      await settings.setNearbyEnabled(_user, true);
      await settings.setNearbyPlaceTypeIds(_user, {'restaurant'});
      await repo.muteMerchant(_merchant, 'Qualification Restaurant');
      // TileCache.write stamps now. A fixed fetched_at would become a time bomb.
      await cache.write(
        lat: _lat,
        lng: _lon,
        queryKey: nearbyQueryKey({'restaurant'}, 10),
        result: NearbySearchResult(
          centerLat: _lat,
          centerLng: _lon,
          coveredM: 2000,
          merchants: const [
            NearbyMerchant(
              id: _merchant,
              name: 'Qualification Restaurant',
              placeType: 'restaurant',
              businessStatus: 'OPERATIONAL',
              lat: _lat,
              lng: _lon,
              distanceMi: 0,
            ),
          ],
        ),
      );
    } else if (action == 'unmute-register') {
      // Public disable/unmute/enable flow, not deleting native visit/attempt state.
      await manager.ensureRegistered(
        userId: _user,
        enabled: false,
        radiusMi: 10,
        dwellByCategory: await settings.getDwellSecondsByCategory(_user),
      );
      await repo.unmuteMerchant(_merchant);
    } else {
      throw UnsupportedError('fixture command');
    }
    final dwell = await settings.getDwellSecondsByCategory(_user);
    final ranked = await repo.queryBestCardByCategory(_user);
    final pick = ranked.byCategory[RewardCategory.dining];
    await _channel.invokeMethod<void>('record', {
      'action': action,
      'wallet_count': (await repo.queryAllCards(_user)).length,
      'dwell_seconds': dwell['Dining'],
      'card_name': pick?.name,
      'rate': pick?.rate,
      'currency': pick?.currency,
      'muted': (await repo.queryMutedMerchantIds()).contains(_merchant),
      'cache_current_complete':
          (await cache.read(
            lat: _lat,
            lng: _lon,
            queryKey: nearbyQueryKey({'restaurant'}, 10),
          )) !=
          null,
      'remote_search_calls': search.calls,
      'remote_catalog_disabled': true,
    });
    final registered = await manager.ensureRegistered(
      userId: _user,
      enabled: await settings.getNearbyEnabled(_user),
      radiusMi: await settings.getNearbyRadiusMi(_user),
      dwellByCategory: dwell,
      categoryIds: await settings.getNearbyPlaceTypeIds(_user),
      trigger: 'qualification',
    );
    if (!registered || search.calls != 0) {
      throw StateError('normal cache registration failed');
    }
    return true;
  });
  await _channel.invokeMethod<void>('ready');
}

class _NoRemoteSearch extends MerchantSearchProvider {
  int calls = 0;
  @override
  Future<NearbySearchResult> nearbyCovered({
    required double lat,
    required double lng,
    required int radiusMi,
    Set<String>? categoryIds,
  }) async {
    calls++;
    throw StateError('fixture must use its current complete cache');
  }
}
