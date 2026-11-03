import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/settings_repository.dart';

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

  test(
    'legacy uniform 60s default automatically upgrades to 30s',
    () async {
      final settings = SettingsRepository(DataRepository());
      await settings.setDwellSecondsByCategory('timing-user', {
        for (final k in SettingsRepository.defaultDwellSeconds.keys) k: 60,
      });
      final upgraded = await settings.getDwellSecondsByCategory('timing-user');
      expect(upgraded.values.toSet(), {30});
    },
  );
}
