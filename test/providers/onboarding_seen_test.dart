import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/settings_provider.dart';

/// 2026-10-19: the first launch after an upgrade lost a race for the database,
/// and the launch gate showed the welcome screen to a signed-in user. The flag
/// read now retries; a database that never opens is an error, not "new user".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late int opens;
  late int failFirst;

  setUp(() {
    opens = 0;
    DatabaseHelper.setTestDatabaseFactory(() async {
      opens++;
      if (opens <= failFirst) throw Exception('database_closed');
      return databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await DatabaseHelper.bootstrapSchema(db);
            await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});
            await db.insert('settings', {
              'user_id': 'u1',
              'key': 'onboarding_seen',
              'value': 'true',
            });
          },
        ),
      );
    });
  });

  tearDown(() async {
    if (opens > failFirst) await (await DatabaseHelper().database).close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  ProviderContainer container() =>
      ProviderContainer(overrides: [authProvider.overrideWith(_SignedIn.new)]);

  test(
    'a failed first open is retried: an onboarded user stays onboarded',
    () async {
      failFirst = 1;
      final c = container();
      addTearDown(c.dispose);
      expect(await c.read(onboardingSeenProvider.future), isTrue);
      expect(opens, 2);
    },
  );

  test('a database that never opens is an error, not a new user', () async {
    failFirst = 99;
    final c = container();
    addTearDown(c.dispose);
    final sub = c.listen(onboardingSeenProvider, (_, _) {});
    addTearDown(sub.close);
    // What the launch gate renders: an error (→ "Try again"), never `false`
    // (→ the welcome screen). Riverpod retries a failed provider, so the
    // state is watched rather than awaiting `.future`.
    var state = c.read(onboardingSeenProvider);
    for (var i = 0; i < 100 && !state.hasError; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      state = c.read(onboardingSeenProvider);
    }
    expect(state.hasError, isTrue);
    expect(state.value, isNot(isFalse));
  });
}

class _SignedIn extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoggedIn: true, userId: 'u1');
}
