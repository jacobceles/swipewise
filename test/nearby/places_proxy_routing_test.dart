import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/app_check_service.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/nearby/google_places_provider.dart';
import 'package:swipewise/nearby/merchant_search_provider.dart';

/// Both routing modes must run under a bare `flutter test`: credentials may
/// go only to Google, never to the proxy (even if both are configured).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: DatabaseHelper.configureForTesting,
        onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        version: 1,
      ),
    );
    DatabaseHelper.setTestDatabaseFactory(() async => db);
  });
  tearDown(() async {
    AppCheckService.resetForTest();
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<http.Request> captureRequest(String proxyUrl, String apiKey) async {
    late http.Request seen;
    await GooglePlacesProvider(
      repo: DataRepository(),
      proxyUrl: proxyUrl,
      apiKey: apiKey,
      client: MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode({'places': []}), 200);
      }),
    ).nearby(lat: 40.748, lng: -73.986, radiusMi: 1, categoryIds: const {});
    return seen;
  }

  test('an unconfigured build refuses loudly without a network call', () async {
    await expectLater(
      captureRequest('', ''),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('neither GOOGLE_PLACES_KEY nor PLACES_PROXY_URL'),
        ),
      ),
    );
  });

  for (final proxyUrl in ['', 'https://example.invalid/places/nearby']) {
    final viaProxy = proxyUrl.isNotEmpty;
    group(viaProxy ? 'proxy' : 'direct', () {
      test('destination and credential headers agree', () async {
        final req = await captureRequest(proxyUrl, 'test-key');
        expect(
          req.url.toString(),
          viaProxy
              ? proxyUrl
              : 'https://places.googleapis.com/v1/places:searchNearby',
        );
        if (viaProxy) {
          expect(req.headers, isNot(contains('X-Goog-Api-Key')));
          expect(req.headers, isNot(contains('X-Android-Package')));
          expect(req.headers, isNot(contains('X-Android-Cert')));
        } else {
          expect(req.headers['X-Goog-Api-Key'], 'test-key');
        }
      });

      test('request body is Google-shaped', () async {
        final body =
            jsonDecode((await captureRequest(proxyUrl, 'test-key')).body)
                as Map;
        final circle = (body['locationRestriction'] as Map)['circle'] as Map;
        final center = circle['center'] as Map;
        expect(body, contains('includedTypes'));
        expect(center['latitude'], closeTo(40.748, 0.01));
        expect(center['longitude'], closeTo(-73.986, 0.01));
      });

      test(
        'a dropped connection is transient and leaves the breaker alone',
        () async {
          final repo = DataRepository();
          final client = MockClient(
            (req) async => throw http.ClientException(
              'Software caused connection abort',
              req.url,
            ),
          );
          await expectLater(
            GooglePlacesProvider(
              repo: repo,
              client: client,
              proxyUrl: proxyUrl,
              apiKey: 'test-key',
            ).nearby(
              lat: 40.748,
              lng: -73.986,
              radiusMi: 1,
              categoryIds: const {},
            ),
            throwsA(isA<PlacesNetworkTransient>()),
          );
          expect(
            (await repo.getCircuitBreaker('google_places')).failureCount,
            0,
          );
        },
      );

      test('only Google receives the field mask', () async {
        final req = await captureRequest(proxyUrl, 'test-key');
        if (viaProxy) {
          expect(req.headers, isNot(contains('X-Goog-FieldMask')));
        } else {
          expect(req.headers['X-Goog-FieldMask'], contains('places.id'));
        }
      });

      if (viaProxy) {
        test('401 triggers a retry with force-refreshed App Check token', () async {
          final repo = DataRepository();
          var calls = 0;
          final seenTokens = <String?>[];
          var refreshCalls = 0;
          AppCheckService.getTokenForTest = () async => 'initial-token';
          AppCheckService.getTokenForceRefreshForTest = () async {
            refreshCalls++;
            return 'refreshed-token';
          };
          addTearDown(AppCheckService.resetForTest);

          final provider = GooglePlacesProvider(
            repo: repo,
            proxyUrl: proxyUrl,
            apiKey: '',
            client: MockClient((req) async {
              calls++;
              seenTokens.add(req.headers['X-Firebase-AppCheck']);
              if (calls == 1) {
                return http.Response('Unauthorized', 401);
              }
              return http.Response(jsonEncode({'places': []}), 200);
            }),
          );

          final result = await provider.nearby(
            lat: 40.748,
            lng: -73.986,
            radiusMi: 1,
            categoryIds: const {'grocery'},
          );

          expect(calls, 2);
          expect(refreshCalls, 1);
          expect(seenTokens, ['initial-token', 'refreshed-token']);
          expect(result, isEmpty);
        });

        test('401 retry failure throws PlacesUpstreamError', () async {
          final repo = DataRepository();
          var calls = 0;
          AppCheckService.getTokenForTest = () async => 'initial-token';
          AppCheckService.getTokenForceRefreshForTest = () async => 'refreshed-token';
          addTearDown(AppCheckService.resetForTest);

          final provider = GooglePlacesProvider(
            repo: repo,
            proxyUrl: proxyUrl,
            apiKey: '',
            client: MockClient((req) async {
              calls++;
              return http.Response('Unauthorized', 401);
            }),
          );

          await expectLater(
            provider.nearby(
              lat: 40.748,
              lng: -73.986,
              radiusMi: 1,
              categoryIds: const {'grocery'},
            ),
            throwsA(isA<PlacesUpstreamError>()),
          );
          expect(calls, 2);
        });
      }
    });
  }

  for (final (status, body) in [
    (400, 'bad request'),
    (500, 'upstream failed'),
    (200, 'not JSON'),
    (200, '[]'),
  ]) {
    test(
      '$status / $body feeds the breaker, which prevents a fourth request',
      () async {
        final repo = DataRepository();
        var calls = 0;
        final provider = GooglePlacesProvider(
          repo: repo,
          proxyUrl: '',
          apiKey: 'test-key',
          client: MockClient((_) async {
            calls++;
            return http.Response(body, status);
          }),
        );
        for (var attempt = 1; attempt <= 3; attempt++) {
          await expectLater(
            provider.nearby(
              lat: 1,
              lng: 2,
              radiusMi: 1,
              categoryIds: const {'grocery'},
            ),
            throwsA(isA<PlacesUpstreamError>()),
          );
          expect(
            (await repo.getCircuitBreaker('google_places')).failureCount,
            attempt,
          );
        }
        await expectLater(
          provider.nearby(
            lat: 1,
            lng: 2,
            radiusMi: 1,
            categoryIds: const {'grocery'},
          ),
          throwsA(isA<MerchantSearchUnavailable>()),
        );
        expect(calls, 3);
      },
    );
  }

  test(
    'persisted cooldown survives provider reconstruction, expires and resets',
    () async {
      final repo = DataRepository();
      var failedCalls = 0;
      final failing = GooglePlacesProvider(
        repo: repo,
        proxyUrl: '',
        apiKey: 'test-key',
        client: MockClient((_) async {
          failedCalls++;
          return http.Response('upstream failed', 500);
        }),
      );
      final before = DateTime.now();
      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          failing.nearby(lat: 1, lng: 2, radiusMi: 1, categoryIds: {'grocery'}),
          throwsA(isA<PlacesUpstreamError>()),
        );
      }
      final opened = await repo.getCircuitBreaker('google_places');
      expect(opened.failureCount, 3);
      expect(
        opened.openedUntil,
        inInclusiveRange(
          before.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
          DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
        ),
      );
      final persisted = await db.query('api_circuit_breakers');
      var recoveredCalls = 0;
      final reconstructed = GooglePlacesProvider(
        repo: DataRepository(),
        proxyUrl: '',
        apiKey: 'test-key',
        client: MockClient((_) async {
          recoveredCalls++;
          return http.Response(_merchantBody, 200);
        }),
      );
      DatabaseHelper.resetForTesting();
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          reconstructed.nearby(
            lat: 1,
            lng: 2,
            radiusMi: 1,
            categoryIds: {'grocery'},
          ),
          throwsA(
            isA<MerchantSearchUnavailable>().having(
              (e) => e.retryAfter,
              'remaining cooldown',
              allOf(
                greaterThan(Duration.zero),
                lessThanOrEqualTo(const Duration(minutes: 5)),
              ),
            ),
          ),
        );
      }
      expect(recoveredCalls, 0);
      expect(await db.query('api_circuit_breakers'), persisted);

      // Advance only this synthetic persisted deadline, not wall time or policy.
      await db.update(
        'api_circuit_breakers',
        {
          'opened_until': DateTime.now()
              .subtract(const Duration(seconds: 1))
              .millisecondsSinceEpoch,
        },
        where: 'service = ?',
        whereArgs: ['google_places'],
      );
      final merchants = await reconstructed.nearby(
        lat: 1,
        lng: 2,
        radiusMi: 1,
        categoryIds: {'grocery'},
      );
      expect(merchants.single.id, 'synthetic-grocery');
      expect(recoveredCalls, 1);
      expect(await repo.getCircuitBreaker('google_places'), (
        failureCount: 0,
        openedUntil: null,
      ));
      expect(await db.query('api_circuit_breakers'), isEmpty);
      await expectLater(
        failing.nearby(lat: 1, lng: 2, radiusMi: 1, categoryIds: {'grocery'}),
        throwsA(isA<PlacesUpstreamError>()),
      );
      expect(failedCalls, 4);
      expect(await repo.getCircuitBreaker('google_places'), (
        failureCount: 1,
        openedUntil: null,
      ));
    },
  );

  test(
    'transient failure preserves prior failures; reconstructed provider recovers',
    () async {
      final repo = DataRepository();
      for (var i = 0; i < 2; i++) {
        await repo.recordCircuitBreakerFailure(
          'google_places',
          threshold: 3,
          cooldown: const Duration(minutes: 5),
        );
      }
      final persisted = await db.query('api_circuit_breakers');
      final offline = GooglePlacesProvider(
        repo: repo,
        proxyUrl: '',
        apiKey: 'test-key',
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await expectLater(
        offline.nearby(lat: 1, lng: 2, radiusMi: 1, categoryIds: {'grocery'}),
        throwsA(isA<PlacesNetworkTransient>()),
      );
      expect(await db.query('api_circuit_breakers'), persisted);
      var calls = 0;
      final online = GooglePlacesProvider(
        repo: DataRepository(),
        proxyUrl: '',
        apiKey: 'test-key',
        client: MockClient((_) async {
          calls++;
          return http.Response(_merchantBody, 200);
        }),
      );
      final merchants = await online.nearby(
        lat: 1,
        lng: 2,
        radiusMi: 1,
        categoryIds: {'grocery'},
      );
      expect(merchants.single.name, 'Synthetic Grocery');
      expect(calls, 1);
      expect(await repo.getCircuitBreaker('google_places'), (
        failureCount: 0,
        openedUntil: null,
      ));
    },
  );

  for (final error in [
    TimeoutException('timeout'),
    const SocketException('offline'),
    http.ClientException('connection reset'),
  ]) {
    test(
      '$error remains off-breaker and the next request can recover',
      () async {
        final repo = DataRepository();
        var calls = 0;
        final provider = GooglePlacesProvider(
          repo: repo,
          proxyUrl: '',
          apiKey: 'test-key',
          client: MockClient((_) async {
            if (++calls <= 3) throw error;
            return http.Response(_merchantBody, 200);
          }),
        );
        for (var attempt = 0; attempt < 3; attempt++) {
          await expectLater(
            provider.nearby(
              lat: 1,
              lng: 2,
              radiusMi: 1,
              categoryIds: const {'grocery'},
            ),
            throwsA(isA<PlacesNetworkTransient>()),
          );
        }
        final breaker = await repo.getCircuitBreaker('google_places');
        expect(breaker.failureCount, 0);
        expect(breaker.openedUntil, isNull);
        final merchants = await provider.nearby(
          lat: 1,
          lng: 2,
          radiusMi: 1,
          categoryIds: const {'grocery'},
        );
        expect(merchants.single.id, 'synthetic-grocery');
        expect(merchants.single.placeType, 'grocery_store');
        expect(calls, 4);
      },
    );
  }
}

const _merchantBody = '''{"places":[{
  "id":"synthetic-grocery",
  "displayName":{"text":"Synthetic Grocery"},
  "primaryType":"grocery_store",
  "location":{"latitude":1,"longitude":2},
  "businessStatus":"OPERATIONAL"
}]}''';
