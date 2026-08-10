import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/nearby/google_places_provider.dart';

/// Guards the security property of the Places proxy rollout.
///
/// The Places key used to ship inside the APK, guarded by GCP's Android
/// application restriction — a restriction measured on 2026-08-10 to be worth
/// nothing, because forging `X-Android-Package` / `X-Android-Cert` from a laptop
/// returns 200 with real data. The fix is to move the key into a Worker secret
/// and have the app call the Worker instead.
///
/// During the rollout both paths exist, chosen by the compile-time
/// `PLACES_PROXY_URL` dart-define. A const cannot be varied within one test
/// process, so rather than skip whichever branch is not compiled in — a skipped
/// test reads exactly like a passing one — these assert the invariant that must
/// hold in **either** mode:
///
///   the destination host and the outgoing headers must always agree.
///
/// Direct → the key goes to Google and nowhere else.
/// Proxied → the key is not sent at all, because it is not in the binary to send.
///
/// Run the other branch with:
///   flutter test --dart-define=PLACES_PROXY_URL=https://example.invalid/places/nearby
///
/// With neither define set — a bare `flutter test` — there is no configured
/// route at all, and the only correct behaviour is to refuse loudly. That is
/// asserted too, so this file is meaningful in all three states rather than
/// quietly vacuous in the default one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const proxyUrl = String.fromEnvironment('PLACES_PROXY_URL');
  const apiKey = String.fromEnvironment('GOOGLE_PLACES_KEY');
  final viaProxy = proxyUrl.isNotEmpty;

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
      ),
    );
    DatabaseHelper.setTestDatabaseFactory(() async => db);
  });

  tearDown(() async {
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  /// Captures the single outbound request `nearby()` makes.
  Future<http.Request> captureRequest() async {
    late http.Request seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'places': []}), 200);
    });
    await GooglePlacesProvider(
      repo: DataRepository(),
      client: client,
    ).nearby(lat: 40.748, lng: -73.986, radiusMi: 1, categoryIds: const {});
    return seen;
  }

  test('an unconfigured build refuses loudly instead of failing at the network',
      () async {
    if (viaProxy || apiKey.isNotEmpty) return;
    await expectLater(
      captureRequest(),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('neither GOOGLE_PLACES_KEY nor PLACES_PROXY_URL'),
        ),
      ),
    );
  });

  test('the destination host and the credential headers always agree', () async {
    if (!viaProxy && apiKey.isEmpty) return;
    final req = await captureRequest();
    final sentToProxy = req.url.toString() == proxyUrl;

    expect(
      sentToProxy,
      viaProxy,
      reason: 'PLACES_PROXY_URL decides the destination; it was '
          '"${req.url}" with proxy configured = $viaProxy',
    );

    if (sentToProxy) {
      // The whole point of the proxy: the key is not in the binary, so it
      // cannot be sent. If this ever fails, the key is shipping again.
      expect(req.headers.containsKey('X-Goog-Api-Key'), isFalse);
      expect(req.headers.containsKey('X-Android-Package'), isFalse);
      expect(req.headers.containsKey('X-Android-Cert'), isFalse);
    } else {
      expect(req.headers['X-Goog-Api-Key'], apiKey);
    }
  });

  test('the request body is Google-shaped in both modes', () async {
    // The Worker forwards the body verbatim and pins its own field mask, so the
    // app must speak Google's schema either way. If this diverges, the proxy
    // silently returns results for the wrong location.
    if (!viaProxy && apiKey.isEmpty) return;
    final body = jsonDecode((await captureRequest()).body) as Map;
    final circle =
        (body['locationRestriction'] as Map)['circle'] as Map;
    final center = circle['center'] as Map;

    expect(body.containsKey('includedTypes'), isTrue);
    expect(center['latitude'], closeTo(40.748, 0.01));
    expect(center['longitude'], closeTo(-73.986, 0.01));
  });

  test('the field mask is never sent to the proxy', () async {
    // The Worker pins the mask because it determines the billing SKU, and a
    // client must not be able to widen it. Sending our own would either be
    // ignored (confusing) or, if the Worker ever forwarded it, billable.
    if (!viaProxy && apiKey.isEmpty) return;
    final req = await captureRequest();
    if (viaProxy) {
      expect(req.headers.containsKey('X-Goog-FieldMask'), isFalse);
    } else {
      expect(req.headers['X-Goog-FieldMask'], contains('places.id'));
    }
  });
}
