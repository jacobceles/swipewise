import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/sync/wallet_snapshot.dart';

/// Pins what a wallet backup carries — and, more importantly, what it refuses
/// to carry in either direction.
///
/// A backup is the one feature that both leaves the device and overwrites it,
/// so the interesting assertions are the negative ones: transactions never
/// leave, device-local settings never travel, and a payload arriving off the
/// network cannot assert facts about this device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const userId = 'uid-owner';

  setUp(() async {
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
    await db.insert('users', {'id': userId, 'identifier': 'Owner'});
  });

  tearDown(() async {
    final db = await DatabaseHelper().database;
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<void> seedCard(String id, {String name = 'Sapphire'}) async {
    final db = await DatabaseHelper().database;
    await db.insert('cards', {
      'id': id,
      'user_id': userId,
      'source': 'manual',
      'name': name,
    });
  }

  test('capture takes the wallet but never the transactions', () async {
    final db = await DatabaseHelper().database;
    await seedCard('card-1');
    await db.insert('transactions', {
      'id': 'txn-1',
      'user_id': userId,
      'card_id': 'card-1',
      'amount': 42.0,
      'name': 'COFFEE',
      'posted_at': '2026-01-01T00:00:00Z',
    });

    final snapshot = await WalletBackupRepository().capture(userId);

    expect(snapshot.cards, hasLength(1));
    expect(
      jsonEncode(snapshot.toJson()),
      isNot(contains('txn-1')),
      reason:
          'transactions must never leave the device — moving spend history '
          'server-side is the thing the privacy position rules out',
    );
  });

  test('capture strips user_id so a backup is not welded to one id', () async {
    await seedCard('card-1');
    final snapshot = await WalletBackupRepository().capture(userId);
    expect(snapshot.cards.single.containsKey('user_id'), isFalse);
  });

  test('capture carries only allowlisted settings', () async {
    final db = await DatabaseHelper().database;
    for (final entry in {
      'default_screen': 'cards', // syncable — a real preference
      'permissions_asked': 'true', // device-local
      'onboarding_seen': 'true', // device-local
      'backup_enabled': 'true', // must never travel
      'popular_banks_cache': '[]', // a cache
    }.entries) {
      await db.insert('settings', {
        'user_id': userId,
        'key': entry.key,
        'value': entry.value,
      });
    }

    final snapshot = await WalletBackupRepository().capture(userId);

    expect(snapshot.settings, {'default_screen': 'cards'});
    expect(
      snapshot.settings.keys,
      everyElement(isIn(SettingsRepository.syncableSettingsKeys)),
    );
  });

  test('apply restores the wallet under the local user id', () async {
    final repo = WalletBackupRepository();
    await seedCard('card-1', name: 'Sapphire');
    final db = await DatabaseHelper().database;
    await db.insert('card_overrides', {
      'card_id': 'card-1',
      'user_id': userId,
      'custom_name': 'Travel card',
    });
    await db.insert('card_links', {
      'user_id': userId,
      'card_id': 'card-1',
      'card_product_id': 'chase-sapphire',
      'source': 'manual',
    });

    // Round-trip through JSON, the way the service would hand it back.
    final snapshot = WalletSnapshot.fromJson(
      jsonDecode(jsonEncode((await repo.capture(userId)).toJson()))
          as Map<String, Object?>,
    );

    // A fresh device: same account, nothing local.
    for (final t in ['cards', 'card_overrides', 'card_links']) {
      await db.delete(t);
    }
    expect(await repo.isWalletEmpty(userId), isTrue);

    await repo.apply(snapshot, userId: userId);

    final cards = await db.query('cards');
    expect(cards.single['name'], 'Sapphire');
    expect(cards.single['user_id'], userId);
    expect(
      (await db.query('card_overrides')).single['custom_name'],
      'Travel card',
    );
    expect(
      (await db.query('card_links')).single['card_product_id'],
      'chase-sapphire',
    );
  });

  test('apply refuses settings a backup has no business asserting', () async {
    final repo = WalletBackupRepository();
    final snapshot = WalletSnapshot(
      schemaVersion: WalletSnapshot.currentSchemaVersion,
      capturedAt: DateTime.utc(2026),
      cards: const [],
      cardOverrides: const [],
      cardLinks: const [],
      // The payload comes off the network, so treat it as hostile: a stale or
      // tampered backup must not be able to claim this device has already
      // asked for permissions or finished onboarding.
      settings: const {
        'default_screen': 'cards',
        'permissions_asked': 'true',
        'onboarding_seen': 'true',
        'backup_enabled': 'true',
      },
    );

    await repo.apply(snapshot, userId: userId);

    final db = await DatabaseHelper().database;
    final stored = {
      for (final row in await db.query('settings'))
        row['key'] as String: row['value'],
    };
    expect(stored, {'default_screen': 'cards'});
  });

  test('apply drops columns this build has never heard of', () async {
    final repo = WalletBackupRepository();
    final snapshot = WalletSnapshot(
      schemaVersion: WalletSnapshot.currentSchemaVersion,
      capturedAt: DateTime.utc(2026),
      cards: const [
        {
          'id': 'card-1',
          'source': 'manual',
          'name': 'Sapphire',
          // Written by a newer build; unfiltered this would throw and take the
          // whole restore down with it.
          'a_column_from_the_future': 'boom',
        },
      ],
      cardOverrides: const [],
      cardLinks: const [],
      settings: const {},
    );

    await repo.apply(snapshot, userId: userId);

    final db = await DatabaseHelper().database;
    expect((await db.query('cards')).single['name'], 'Sapphire');
  });

  test('apply leaves transactions alone', () async {
    final db = await DatabaseHelper().database;
    await seedCard('card-1');
    await db.insert('transactions', {
      'id': 'txn-1',
      'user_id': userId,
      'card_id': 'card-1',
      'amount': 42.0,
      'name': 'COFFEE',
      'posted_at': '2026-01-01T00:00:00Z',
    });

    await WalletBackupRepository().apply(
      WalletSnapshot(
        schemaVersion: WalletSnapshot.currentSchemaVersion,
        capturedAt: DateTime.utc(2026),
        cards: const [
          {'id': 'card-2', 'source': 'manual', 'name': 'Freedom'},
        ],
        cardOverrides: const [],
        cardLinks: const [],
        settings: const {},
      ),
      userId: userId,
    );

    expect(
      await db.query('transactions'),
      hasLength(1),
      reason:
          'replacing cards must not cascade into spend history — there is '
          'deliberately no foreign key from transactions to cards',
    );
  });

  test('isWalletEmpty is what gates automatic restore', () async {
    final repo = WalletBackupRepository();
    expect(await repo.isWalletEmpty(userId), isTrue);
    await seedCard('card-1');
    expect(await repo.isWalletEmpty(userId), isFalse);
  });
}
