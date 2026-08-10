import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/providers/entitlement_provider.dart';
import 'package:swipewise/providers/auth_provider.dart';

/// The free tier has no accounts: identity is a UUID minted on the device at
/// first launch. Everything the user owns hangs off it via
/// `FOREIGN KEY (user_id) REFERENCES users(id)`, so if this id is ever
/// regenerated the whole wallet is orphaned in place — no crash, no error, the
/// cards simply stop being there. Stability is the entire contract.
///
/// These run under the default (free) build config; `BuildConfig.isPro` is
/// false unless `--dart-define=SWIPEWISE_PRO=true` is passed, which is
/// asserted below so the suite can't quietly stop testing what it claims to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    // One in-memory DB shared across every `database` call in a test, so
    // "relaunch the app" can be modelled as a fresh ProviderContainer over
    // the same storage.
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

  /// Models an app launch. Mounting `authProvider` makes `AuthNotifier.build`
  /// fire `checkStatus` exactly as it does in the real app; awaiting the same
  /// call is how the test observes completion. Pumping instead would not work
  /// — sqflite-ffi answers from another isolate, so draining the event loop
  /// proves nothing about whether the query came back.
  Future<ProviderContainer> launch() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(authProvider.notifier).checkStatus();
    // Let `build`'s own microtask land too, so it can't run against a closed
    // database after teardown.
    await pumpEventQueue();
    return container;
  }

  test('these tests describe a user without Pro', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(proEntitlementProvider), isFalse);
  });

  test('first launch mints a local identity and signs the user in', () async {
    final container = await launch();

    final state = container.read(authProvider);
    expect(state.isLoggedIn, isTrue);
    expect(state.userId, startsWith(kLocalUserIdPrefix));
    expect(await db.query('users'), hasLength(1));
  });

  test('the identity survives a relaunch and is never regenerated', () async {
    final first = await launch();
    final original = first.read(authProvider).userId;

    // Relaunch: new container, new notifier, same on-disk database.
    final second = await launch();

    expect(second.read(authProvider).userId, original);
    expect(
      await db.query('users'),
      hasLength(1),
      reason: 'a second users row would split the wallet in two',
    );
  });

  test('repeated checks do not mint a second identity', () async {
    final container = await launch();
    final original = container.read(authProvider).userId;

    await container.read(authProvider.notifier).checkStatus();
    await container.read(authProvider.notifier).checkStatus();

    expect(container.read(authProvider).userId, original);
    expect(await db.query('users'), hasLength(1));
  });

  test('an existing account is left alone', () async {
    await db.insert('users', {
      'id': 'uid-from-firebase',
      'identifier': 'Ada',
      'email': 'ada@example.com',
    });

    final container = await launch();

    expect(container.read(authProvider).userId, 'uid-from-firebase');
    expect(await db.query('users'), hasLength(1));
  });

  test('the local id is a v4 UUID, so two devices never collide', () async {
    final container = await launch();

    final uuid = container
        .read(authProvider)
        .userId!
        .substring(kLocalUserIdPrefix.length);
    expect(
      uuid,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
}
