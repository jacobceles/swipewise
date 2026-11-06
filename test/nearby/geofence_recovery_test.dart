import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_crashlytics_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/app_check_service.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/reward_category_mapper.dart';
import 'package:swipewise/models/reward_category.dart';
import 'package:swipewise/nearby/geofence_manager.dart';
import 'package:swipewise/nearby/google_places_provider.dart';
import 'package:swipewise/nearby/location_service.dart';
import 'package:swipewise/nearby/merchant_search_provider.dart';
import 'package:swipewise/nearby/place_roots.dart';
import 'package:swipewise/nearby/tile_cache.dart';

// Offline composition: real Dart discovery/cache/ranking/registration policy;
// synthetic SDK/HTTP inputs and a mocked native registerSet acknowledgement.
// This does not exercise headless startup, GMS, attestation or notifications.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const channel = MethodChannel('com.appsoflife/geofence');
  const proxyUrl = 'https://example.invalid/places/nearby';
  const userId = 'local:recovery-fixture';
  final repo = DataRepository();
  final crashlytics = _CrashlyticsHost();
  final registrations = <Map<Object?, Object?>>[];
  final traces = <String>[];
  late Database db;
  late GeolocatorPlatform originalLocation;
  late _Fixes fixes;
  late Completer<void> registrationCalled;
  Completer<int>? nativeResult;
  var refreshRequests = 0;
  var unregisterCalls = 0;

  setUpAll(() async {
    TestFirebaseCoreHostApi.setUp(_CoreHost());
    TestFirebaseCrashlyticsHostApi.setUp(crashlytics);
    await Firebase.initializeApp();
    // No remote service: use only the versioned classifier bundled in this tree.
    await initCategoryRegistry();
    await initBrandRegistry();
    expect(categoryForPlaceType('restaurant'), RewardCategory.dining);
  });
  tearDownAll(() {
    TestFirebaseCrashlyticsHostApi.setUp(null);
    TestFirebaseCoreHostApi.setUp(null);
  });
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: DatabaseHelper.configureForTesting,
        onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
      ),
    );
    DatabaseHelper.setTestDatabaseFactory(() async => db);
    await _seedWallet(db, userId);
    originalLocation = GeolocatorPlatform.instance;
    fixes = _Fixes();
    GeolocatorPlatform.instance = fixes;
    crashlytics.errors.clear();
    registrations.clear();
    traces.clear();
    registrationCalled = Completer<void>();
    nativeResult = null;
    refreshRequests = 0;
    unregisterCalls = 0;
    AppCheckService.getTokenForTest = () async => 'accepted';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'accountEpoch':
              return 7;
            case 'recoveryGeneration':
              return 11;
            case 'registerSet':
              final args = call.arguments as Map<Object?, Object?>;
              registrations.add(args);
              if (!registrationCalled.isCompleted) {
                registrationCalled.complete();
              }
              return nativeResult == null
                  ? (args['zones'] as List).length
                  : await nativeResult!.future;
            case 'requestRefresh':
              refreshRequests++;
              return null;
            case 'unregisterAll':
              unregisterCalls++;
              fail('A failed enabled registration must keep the last fences');
            case 'walkinLog':
              traces.add(call.arguments as String);
              return null;
            default:
              fail('Unexpected geofence call: ${call.method}');
          }
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    GeolocatorPlatform.instance = originalLocation;
    AppCheckService.resetForTest();
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  GeofenceManager manager(http.Client client) => GeofenceManager(
    cache: TileCache(),
    search: GooglePlacesProvider(
      repo: repo,
      client: client,
      proxyUrl: proxyUrl,
      apiKey: '',
    ),
    location: LocationService(),
    repo: repo,
  );
  Future<bool> run(
    GeofenceManager manager, {
    Set<String>? categories = const {'dining'},
  }) => manager.ensureRegistered(
    userId: userId,
    enabled: true,
    radiusMi: 1,
    dwellByCategory: const {},
    categoryIds: categories,
    trigger: 'background',
  );
  Future<String?> successStamp() =>
      repo.getSetting(userId, 'geofence_last_register');
  Future<void> expectCurrentRegistration(DateTime started) async {
    final payload = registrations.single;
    expect(payload['user_id'], userId);
    expect(payload['account_epoch'], 7);
    expect(payload['recovery_generation'], 11);
    final zone = (payload['zones'] as List).single as Map;
    expect(zone['geofence_id'], 'm_synthetic-dining');
    final option = (zone['options'] as List).single as Map;
    expect(option['merchant_id'], 'synthetic-dining');
    expect(option['name'], 'Synthetic Dining');
    expect(option['place_type'], 'restaurant');
    expect(option['best_card_name'], 'Synthetic Dining Card');
    expect(option['best_rate'], 3);
    expect(option['best_currency'], 'USD');
    final boundary = payload['boundary'] as Map;
    expect(boundary['lat'], 40);
    expect(boundary['lng'], -100);
    expect(boundary['radius_m'], greaterThan(1000));
    expect(refreshRequests, 0);
    final stamp = (await successStamp())!.split(',');
    expect(stamp.take(2), ['40.000', '-100.000']);
    final at = DateTime.parse(stamp[2]);
    expect(at.isBefore(started), isFalse);
    expect(at.isAfter(DateTime.now().toUtc()), isFalse);
  }

  test(
    'parallel proxy 401s share refresh, parse merchants and await native success',
    () async {
      final started = DateTime.now().toUtc();
      final batches =
          (includedTypesForRoots(defaultEnabledPlaceRootIds).length / 50)
              .ceil();
      expect(
        batches,
        greaterThan(1),
        reason: 'Must exercise parallel requests',
      );
      final refresh = Completer<String?>();
      final refreshStarted = Completer<void>();
      var normalCalls = 0;
      var refreshCalls = 0;
      AppCheckService.getTokenForTest = () async {
        normalCalls++;
        return 'rejected';
      };
      AppCheckService.getTokenForceRefreshForTest = () {
        refreshCalls++;
        if (!refreshStarted.isCompleted) refreshStarted.complete();
        return refresh.future;
      };
      final tokens = <String?>[];
      final client = MockClient((request) async {
        expect(request.url.toString(), proxyUrl);
        expect(request.headers, isNot(contains('X-Goog-Api-Key')));
        final token = request.headers['X-Firebase-AppCheck'];
        tokens.add(token);
        return token == 'accepted'
            ? http.Response(_merchantBody, 200)
            : http.Response('app check failed', 401);
      });
      nativeResult = Completer<int>();
      final result = run(manager(client), categories: null);
      await refreshStarted.future.timeout(const Duration(seconds: 10));
      // This DB read also lets every parallel 401 reach the held SDK operation.
      expect(await successStamp(), isNull);
      expect(tokens, List.filled(batches, 'rejected'));
      expect(registrations, isEmpty);
      refresh.complete('accepted');
      await registrationCalled.future.timeout(const Duration(seconds: 10));
      expect(
        await successStamp(),
        isNull,
        reason: 'Native has not acknowledged add',
      );
      nativeResult!.complete(1);

      expect(await result, isTrue);
      expect(normalCalls, 1);
      expect(refreshCalls, 1);
      expect(tokens, [
        ...List.filled(batches, 'rejected'),
        ...List.filled(batches, 'accepted'),
      ]);
      final cached = await TileCache().read(
        lat: 40,
        lng: -100,
        queryKey: nearbyQueryKey(null, 1),
      );
      expect(cached!.merchants.single.id, 'synthetic-dining');
      await expectCurrentRegistration(started);
      expect(crashlytics.errors, isEmpty);
    },
  );

  test(
    'native add failure leaves success unstamped and cached retry recovers',
    () async {
      final started = DateTime.now().toUtc();
      var requests = 0;
      final subject = manager(
        MockClient((request) async {
          requests++;
          expect(request.url.toString(), proxyUrl);
          expect(request.headers['X-Firebase-AppCheck'], 'accepted');
          expect(request.headers, isNot(contains('X-Goog-Api-Key')));
          return http.Response(_merchantBody, 200);
        }),
      );
      nativeResult = Completer<int>();
      final rejected = run(subject);
      await registrationCalled.future.timeout(const Duration(seconds: 10));
      final attemptedPayload = registrations.single;
      final zone = (attemptedPayload['zones'] as List).single as Map;
      final option = (zone['options'] as List).single as Map;
      expect(option['merchant_id'], 'synthetic-dining');
      expect(option['best_card_name'], 'Synthetic Dining Card');
      expect(option['best_rate'], 3);
      final cached = await TileCache().read(
        lat: 40,
        lng: -100,
        queryKey: nearbyQueryKey({'dining'}, 1),
      );
      expect(cached!.merchants.single.id, 'synthetic-dining');
      expect(requests, 1);
      expect(await successStamp(), isNull);
      expect(unregisterCalls, 0);

      nativeResult!.completeError(PlatformException(code: 'ADD_FAILED'));
      expect(await rejected.timeout(const Duration(seconds: 10)), isFalse);
      expect(await successStamp(), isNull);
      expect(unregisterCalls, 0);
      expect(crashlytics.errors.single.reason, 'geofence_register_failed');
      expect(crashlytics.errors.single.exception, contains('ADD_FAILED'));

      registrations.clear();
      registrationCalled = Completer<void>();
      nativeResult = Completer<int>();
      final recovered = run(subject);
      await registrationCalled.future.timeout(const Duration(seconds: 10));
      expect(await successStamp(), isNull);
      expect(registrations.single, attemptedPayload);
      nativeResult!.complete(1);
      expect(await recovered.timeout(const Duration(seconds: 10)), isTrue);
      expect(
        requests,
        1,
        reason: 'Retry reuses the successfully fetched cache',
      );
      expect(unregisterCalls, 0);
      await expectCurrentRegistration(started);
    },
  );

  for (final failure in ['repeated-401', 'null-token', 'sdk-timeout']) {
    test(
      '$failure is bounded, cannot stamp success and can later recover',
      () async {
        final started = DateTime.now().toUtc();
        var recovered = false;
        var normalCalls = 0;
        var refreshCalls = 0;
        AppCheckService.getTokenForTest = () async {
          normalCalls++;
          return recovered
              ? 'accepted'
              : failure == 'null-token'
              ? null
              : 'rejected';
        };
        AppCheckService.getTokenForceRefreshForTest = () async {
          refreshCalls++;
          // SDK timeout input here; the actual 5 s bound/late completion is
          // exercised with virtual time in app_check_service_test.dart.
          if (failure == 'sdk-timeout') {
            throw TimeoutException('synthetic SDK timeout');
          }
          return failure == 'null-token' ? null : 'still rejected';
        };
        final tokens = <String?>[];
        final subject = manager(
          MockClient((request) async {
            expect(request.url.toString(), proxyUrl);
            expect(request.headers, isNot(contains('X-Goog-Api-Key')));
            tokens.add(request.headers['X-Firebase-AppCheck']);
            return recovered
                ? http.Response(_merchantBody, 200)
                : http.Response('app check failed', 401);
          }),
        );
        expect(await run(subject), isFalse);
        expect(
          tokens,
          failure == 'null-token'
              ? [null, null]
              : failure == 'sdk-timeout'
              ? ['rejected', null]
              : ['rejected', 'still rejected'],
        );
        expect(normalCalls, 1);
        expect(refreshCalls, 1);
        expect(registrations, isEmpty);
        expect(await successStamp(), isNull);
        expect((await repo.getCircuitBreaker('google_places')).failureCount, 1);
        expect(crashlytics.errors.single.reason, 'geofence_register_failed');

        recovered = true;
        expect(await run(subject), isTrue);
        expect(tokens, hasLength(3));
        expect(normalCalls, 2);
        expect(refreshCalls, 1);
        expect(await repo.getCircuitBreaker('google_places'), (
          failureCount: 0,
          openedUntil: null,
        ));
        await expectCurrentRegistration(started);
      },
    );
  }

  test('discovery failure classes use types, never exception messages', () {
    for (final (error, expected) in <(Object, String)>[
      (PlacesNetworkTransient('secret'), 'network_transient'),
      (
        MerchantSearchUnavailable(
          retryAfter: Duration.zero,
          lastError: 'secret',
        ),
        'cooldown',
      ),
      (MissingPlacesApiKey(), 'missing_config'),
      (PlacesUpstreamError('401 secret'), 'upstream'),
      (StateError('timeout secret'), 'unknown'),
    ]) {
      expect(GeofenceManager.discoveryFailureClass(error), expected);
    }
  });

  test(
    'stale fallback reports typed failure and recovers with fresh coverage',
    () async {
      var online = true;
      final subject = manager(
        MockClient((_) async {
          if (!online) throw const SocketException('synthetic-secret-value');
          return http.Response(_merchantBody, 200);
        }),
      );
      // Populate through the real provider and TileCache, then age relative to
      // now so this remains stale as the suite ages.
      final cached = await subject.search.nearbyCovered(
        lat: 40,
        lng: -100,
        radiusMi: 1,
        categoryIds: {'dining'},
      );
      await subject.cache.write(
        lat: 40,
        lng: -100,
        result: cached,
        queryKey: nearbyQueryKey({'dining'}, 1),
      );
      await db.update('merchant_search_cache', {
        'fetched_at': DateTime.now()
            .subtract(const Duration(days: 8))
            .millisecondsSinceEpoch,
      });
      online = false;
      nativeResult = Completer<int>();
      final degraded = run(subject);
      await registrationCalled.future.timeout(const Duration(seconds: 10));
      expect(await successStamp(), isNull);
      expect(refreshRequests, 0);
      expect(traces.where((s) => s.contains('discovery_failure=')), [
        'geofence: discovery_failure=network_transient',
      ]);
      expect(traces.join(), isNot(contains('synthetic-secret-value')));
      nativeResult!.complete(1);
      expect(await degraded.timeout(const Duration(seconds: 10)), isTrue);
      expect(refreshRequests, 1);
      expect(traces, contains(contains('source=stale_cache')));
      expect(traces, contains(contains('covered=0m')));
      expect(traces, contains(contains('needs_refresh=true')));
      expect(await successStamp(), isNotNull);

      online = true;
      registrations.clear();
      registrationCalled = Completer<void>();
      nativeResult = Completer<int>();
      final recovered = run(subject);
      await registrationCalled.future.timeout(const Duration(seconds: 10));
      nativeResult!.complete(1);
      expect(await recovered.timeout(const Duration(seconds: 10)), isTrue);
      expect(refreshRequests, 1);
      expect(traces, contains(contains('source=search')));
      expect(traces, contains(contains('needs_refresh=false')));
      expect((registrations.single['zones'] as List), hasLength(1));
      expect(
        traces.where((s) => s.contains('discovery_failure=')),
        hasLength(1),
      );
    },
  );

  test(
    'offline registration retries after network recovery without opening breaker',
    () async {
      final started = DateTime.now().toUtc();
      var online = false;
      var requests = 0;
      final subject = manager(
        MockClient((_) async {
          requests++;
          if (!online) throw const SocketException('synthetic offline');
          return http.Response(_merchantBody, 200);
        }),
      );
      expect(await run(subject), isFalse);
      expect(traces.where((s) => s.contains('discovery_failure=')), [
        'geofence: discovery_failure=network_transient',
      ]);
      expect(registrations, isEmpty);
      expect(await successStamp(), isNull);
      expect(await repo.getCircuitBreaker('google_places'), (
        failureCount: 0,
        openedUntil: null,
      ));
      expect(
        crashlytics.errors,
        isEmpty,
        reason: 'Transient network is not a fault',
      );
      online = true;
      expect(await run(subject), isTrue);
      expect(requests, 2);
      await expectCurrentRegistration(started);
    },
  );

  for (final stale in [false, true]) {
    for (final retrySucceeds in [false, true]) {
      test(
        '${stale ? 'stale' : 'absent'} fix retry success=$retrySucceeds correlates with registration',
        () async {
          final started = DateTime.now().toUtc();
          fixes.failMedium = true;
          fixes.failHigh = !retrySucceeds;
          // Relative to now: this must stay stale as the test suite ages.
          fixes.lastKnown = stale
              ? _position(
                  lat: 39.696,
                  lng: -119.441,
                  at: DateTime.now().subtract(const Duration(minutes: 20)),
                )
              : null;
          var requests = 0;
          final subject = manager(
            MockClient((request) async {
              requests++;
              final circle =
                  (jsonDecode(request.body)
                          as Map)['locationRestriction']['circle']
                      as Map;
              expect(circle['center'], {'latitude': 40.0, 'longitude': -100.0});
              return http.Response(_merchantBody, 200);
            }),
          );
          expect(await run(subject), retrySucceeds);
          expect(fixes.requested.map((s) => s.accuracy), [
            LocationAccuracy.medium,
            LocationAccuracy.high,
          ]);
          expect(fixes.requested.map((s) => s.timeLimit), [
            const Duration(seconds: 10),
            const Duration(seconds: 30),
          ]);
          expect(requests, retrySucceeds ? 1 : 0);
          expect(
            crashlytics.errors.where(
              (e) => e.reason == 'location_fallback_stale',
            ),
            hasLength(1),
          );
          if (!retrySucceeds) {
            expect(registrations, isEmpty);
            expect(await successStamp(), isNull);
            expect(
              crashlytics.errors.where(
                (e) => e.reason == 'geofence_register_failed',
              ),
              hasLength(1),
            );
            fixes.failHigh = false;
            expect(await run(subject), isTrue);
            expect(fixes.requested, hasLength(4));
            expect(requests, 1);
          }
          await expectCurrentRegistration(started);
        },
      );
    }
  }
}

Future<void> _seedWallet(Database db, String userId) async {
  await db.insert('users', {'id': userId, 'identifier': 'Synthetic User'});
  await db.insert('point_systems', {
    'point_system_id': 'usd',
    'display_name': 'Synthetic cash',
    'baseline_cent_value': 1,
    'unit': 'cash',
  });
  for (final (id, name, baseRate) in [
    ('dining-card', 'Synthetic Dining Card', 1),
    ('flat-card', 'Synthetic Flat Card', 2),
  ]) {
    await db.insert('card_products', {
      'card_product_id': id,
      'display_name': name,
      'issuer': 'Synthetic Issuer',
      'catalog_version': 'recovery-fixture-v1',
      'country': 'US',
    });
    await db.insert('cards', {
      'id': id,
      'user_id': userId,
      'name': name,
      'source': 'manual',
    });
    await db.insert('card_links', {
      'user_id': userId,
      'card_id': id,
      'card_product_id': id,
      'source': 'manual',
    });
    await db.insert('reward_rules', {
      'rule_id': '$id-base',
      'card_product_id': id,
      'kind': 'baseline',
      'rate': baseRate,
      'point_system_id': 'usd',
    });
  }
  await db.insert('reward_rules', {
    'rule_id': 'dining-bonus',
    'card_product_id': 'dining-card',
    'kind': 'category',
    'category': 'dining',
    'rate': 3,
    'point_system_id': 'usd',
  });
}

class _Fixes extends GeolocatorPlatform {
  bool failMedium = false;
  bool failHigh = false;
  Position? lastKnown;
  final requested = <LocationSettings>[];

  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.always;
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => lastKnown;
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    final settings = locationSettings!;
    requested.add(settings);
    if (settings.accuracy == LocationAccuracy.medium ? failMedium : failHigh) {
      throw TimeoutException('synthetic GPS timeout');
    }
    return _position(at: DateTime.now());
  }
}

Position _position({
  double lat = 40,
  double lng = -100,
  required DateTime at,
}) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: at,
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

class _CoreHost extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    final apps = await super.initializeCore();
    apps.single.pluginConstants['plugins.flutter.io/firebase_crashlytics'] = {
      'isCrashlyticsCollectionEnabled': false,
    };
    return apps;
  }
}

class _CrashlyticsHost implements TestFirebaseCrashlyticsHostApi {
  final errors = <RecordErrorRequest>[];
  @override
  Future<void> recordError(RecordErrorRequest request) async =>
      errors.add(request);
  @override
  Future<void> setCustomKey(String key, String value) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _merchantBody = '''{"places":[{
  "id":"synthetic-dining", "displayName":{"text":"Synthetic Dining"},
  "primaryType":"restaurant", "location":{"latitude":40,"longitude":-100},
  "businessStatus":"OPERATIONAL"
}]}''';
