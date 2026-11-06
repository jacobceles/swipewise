import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/settings_provider.dart';

class _TimingUser extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoggedIn: true, userId: 'timing-user');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUp(() async {
    DatabaseHelper.setTestDatabaseFactory(
      () => databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
          version: 1,
        ),
      ),
    );
    await (await DatabaseHelper().database).insert('users', {
      'id': 'timing-user',
      'identifier': 'Test',
    });
  });

  tearDown(() async {
    await (await DatabaseHelper().database).close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  test(
    'ten-second waits round-trip without minute rounding or changing defaults',
    () async {
      final settings = SettingsRepository(DataRepository());
      expect(
        await settings.getDwellSecondsByCategory('timing-user'),
        SettingsRepository.defaultDwellSeconds,
      );
      expect(SettingsRepository.defaultDwellSeconds['Gas'], 10);
      await settings.setDwellSecondsByCategory('timing-user', {
        'Dining': 10,
        'Coffee': 20,
        'Gas': 90,
      });
      final restored = await settings.getDwellSecondsByCategory('timing-user');
      expect(restored['Dining'], 10);
      expect(restored['Coffee'], 20);
      expect(restored['Gas'], 90);
      expect(restored['Shopping'], 30);
    },
  );

  for (final seconds in [30, 60]) {
    for (final json in [true, false]) {
      test(
        'preserves uniform $seconds seconds in ${json ? 'JSON' : 'CSV'}',
        () async {
          final repo = DataRepository();
          final settings = SettingsRepository(repo);
          final values = {
            for (final k in SettingsRepository.defaultDwellSeconds.keys)
              k: seconds,
          };
          if (json) {
            await settings.setDwellSecondsByCategory('timing-user', values);
          } else {
            await repo.setSetting(
              'timing-user',
              'nearby_dwell_by_category',
              values.entries.map((e) => '${e.key}:${e.value}').join(','),
            );
          }
          // A uniform value can be a deliberate customization, not an old default.
          expect(
            await settings.getDwellSecondsByCategory('timing-user'),
            values,
          );
        },
      );
    }
  }

  for (final raw in [
    '{"Dining":40,"Coffee":"bad"}',
    'Dining:40,Coffee:bad',
    '{broken',
  ]) {
    test('partial or malformed value falls back per category: $raw', () async {
      final repo = DataRepository();
      await repo.setSetting('timing-user', 'nearby_dwell_by_category', raw);
      final result = await SettingsRepository(
        repo,
      ).getDwellSecondsByCategory('timing-user');
      expect(result['Gas'], 10);
      expect(result['Coffee'], 30);
      expect(result['Dining'], raw == '{broken' ? 30 : 40);
    });
  }

  test('Reset persists per-kind defaults for the signed-in user', () async {
    final settings = SettingsRepository(DataRepository());
    await settings.setDwellSecondsByCategory('timing-user', {
      for (final kind in SettingsRepository.defaultDwellSeconds.keys) kind: 60,
    });
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith(_TimingUser.new)],
    );
    addTearDown(container.dispose);
    final loaded = Completer<void>();
    container.listen(nearbyDwellProvider, (_, next) {
      if (next['Gas'] == 60 && !loaded.isCompleted) loaded.complete();
    });
    await loaded.future;
    await container.read(nearbyDwellProvider.notifier).resetToDefault();
    expect(
      container.read(nearbyDwellProvider),
      SettingsRepository.defaultDwellSeconds,
    );
    expect(
      await settings.getDwellSecondsByCategory('timing-user'),
      SettingsRepository.defaultDwellSeconds,
    );
  });
}
