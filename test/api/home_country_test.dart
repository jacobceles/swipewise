import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// Travel mode's home country without bank data: the wallet's cards decide
/// before the phone's region does.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUp(() {
    binding.platformDispatcher.localeTestValue = const Locale('en', 'GB');
    DatabaseHelper.setTestDatabaseFactory(
      () => databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      ),
    );
  });

  tearDown(() async {
    binding.platformDispatcher.clearLocaleTestValue();
    await (await DatabaseHelper().database).close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<void> wallet(Map<String, String?> productCountry) async {
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});
    for (final e in productCountry.entries) {
      await db.insert('card_products', {
        'card_product_id': e.key,
        'issuer': 'x',
        'display_name': e.key,
        'catalog_version': 't',
        'country': e.value,
      });
      await db.insert('cards', {
        'id': 'c-${e.key}',
        'user_id': 'u1',
        'source': 'manual',
        'name': e.key,
      });
      await db.insert('card_links', {
        'user_id': 'u1',
        'card_id': 'c-${e.key}',
        'card_product_id': e.key,
        'source': 'user_confirmed',
      });
    }
  }

  test('an all-Canadian wallet makes Canada home', () async {
    await wallet({'td.cash': 'CA', 'rbc.avion': 'CA'});
    expect(await DataRepository().homeCountry('u1'), 'CA');
  });

  test('a card with no country counts as American', () async {
    await wallet({'chase.freedom': null, 'citi.double': 'US'});
    expect(await DataRepository().homeCountry('u1'), 'US');
  });

  test('a mixed wallet falls back to the phone region', () async {
    await wallet({'td.cash': 'CA', 'chase.freedom': 'US'});
    expect(await DataRepository().homeCountry('u1'), 'GB');
  });

  test('an empty wallet falls back to the phone region', () async {
    await wallet({});
    expect(await DataRepository().homeCountry('u1'), 'GB');
  });

  test('bank currency takes precedence over wallet and phone', () async {
    await wallet({'chase.freedom': 'US'});
    final db = await DatabaseHelper().database;
    await db.insert('transactions', {
      'id': 't1',
      'user_id': 'u1',
      'currency': 'CAD',
      'amount': 10,
    });
    expect(await DataRepository().homeCountry('u1'), 'CA');
  });
}
