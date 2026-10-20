import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/backup_provider.dart';
import 'package:swipewise/sync/wallet_backup_client.dart';
import 'package:swipewise/sync/wallet_snapshot.dart';

/// Automatic backup uploads only on a change, and never replaces a backup
/// another phone wrote when that would remove cards this phone lacks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const userId = 'u1';
  final settings = SettingsRepository(DataRepository());
  late _FakeClient client;

  setUp(() async {
    client = _FakeClient();
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
    await db.insert('users', {'id': userId, 'identifier': 'u1@test'});
  });

  tearDown(() async {
    await (await DatabaseHelper().database).close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  Future<void> addCard(String id) async {
    final db = await DatabaseHelper().database;
    await db.insert('cards', {
      'id': id,
      'user_id': userId,
      'source': 'manual',
      'name': id,
    });
  }

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_SignedIn.new),
        walletBackupClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<AutoBackupOutcome> run(ProviderContainer c) =>
      c.read(walletBackupControllerProvider).maybeAutoBackup();

  test('does nothing while backup is off', () async {
    await addCard('a');
    expect(await run(container()), AutoBackupOutcome.off);
    expect(client.pulls + client.pushes, 0);
  });

  test('uploads a change once, then sends nothing until the next', () async {
    await settings.setBackupEnabled(userId, true);
    await addCard('a');
    final c = container();
    expect(await run(c), AutoBackupOutcome.uploaded);
    expect(client.pushes, 1);

    expect(await run(c), AutoBackupOutcome.unchanged);
    expect(client.pulls, 1);
    expect(client.pushes, 1);

    await addCard('b');
    expect(await run(c), AutoBackupOutcome.uploaded);
    expect(client.stored!.cards.map((r) => r['id']), ['a', 'b']);
  });

  test('a card deleted here replaces the backup this phone wrote', () async {
    await settings.setBackupEnabled(userId, true);
    await addCard('a');
    await addCard('b');
    final c = container();
    await run(c);
    final db = await DatabaseHelper().database;
    await db.delete('cards', where: 'id = ?', whereArgs: ['b']);

    expect(await run(c), AutoBackupOutcome.uploaded);
    expect(client.stored!.cards.map((r) => r['id']), ['a']);
  });

  test('holds back, and says how many, when another phone added cards '
      'this one lacks', () async {
    await settings.setBackupEnabled(userId, true);
    await addCard('a');
    final c = container();
    await run(c);
    client.stored = _snapshot(['a', 'from-other-phone']);
    await addCard('c');

    expect(await run(c), AutoBackupOutcome.held);
    expect(client.pushes, 1);
    expect(await c.read(backupHeldCardsProvider.future), 1);

    // "Back up now" is the user choosing this phone's copy.
    await c.read(walletBackupControllerProvider).backUpNow();
    expect(await c.read(backupHeldCardsProvider.future), 0);
    expect(client.stored!.cards.map((r) => r['id']), ['a', 'c']);
  });

  test('a new phone with a backup it never wrote holds back too', () async {
    await settings.setBackupEnabled(userId, true);
    client.stored = _snapshot(['x', 'y']);
    await addCard('x');

    expect(await run(container()), AutoBackupOutcome.held);
    expect(client.pushes, 0);
  });

  test(
    'a backup written elsewhere but fully on this phone is replaced',
    () async {
      await settings.setBackupEnabled(userId, true);
      client.stored = _snapshot(['x']);
      await addCard('x');
      await addCard('y');

      expect(await run(container()), AutoBackupOutcome.uploaded);
    },
  );

  test(
    'restoring counts as in step: no upload, deletions then replace',
    () async {
      await settings.setBackupEnabled(userId, true);
      client.stored = _snapshot(['x', 'y']);
      final c = container();
      await c.read(walletBackupControllerProvider).restoreNow();
      final db = await DatabaseHelper().database;
      await db.delete('cards', where: 'id = ?', whereArgs: ['y']);

      expect(await run(c), AutoBackupOutcome.uploaded);
      expect(client.stored!.cards.map((r) => r['id']), ['x']);
    },
  );

  test('the fingerprint ignores capturedAt and survives the service', () {
    final a = _snapshot(['x']);
    final roundTrip = WalletSnapshot.fromJson(
      jsonDecode(jsonEncode(a.toJson())) as Map<String, Object?>,
    );
    final later = WalletSnapshot(
      schemaVersion: a.schemaVersion,
      capturedAt: a.capturedAt.add(const Duration(days: 1)),
      cards: a.cards,
      cardOverrides: a.cardOverrides,
      cardLinks: a.cardLinks,
      settings: a.settings,
    );
    expect(roundTrip.fingerprint, a.fingerprint);
    expect(later.fingerprint, a.fingerprint);
    expect(_snapshot(['y']).fingerprint, isNot(a.fingerprint));
  });
}

WalletSnapshot _snapshot(List<String> ids) => WalletSnapshot(
  schemaVersion: WalletSnapshot.currentSchemaVersion,
  capturedAt: DateTime.utc(2026),
  cards: [
    for (final id in ids) {'id': id, 'source': 'manual', 'name': id},
  ],
  cardOverrides: const [],
  cardLinks: const [],
  settings: const {},
);

class _FakeClient extends WalletBackupClient {
  WalletSnapshot? stored;
  int pulls = 0;
  int pushes = 0;

  @override
  Future<BackupStatus> push(WalletSnapshot snapshot) async {
    pushes++;
    // What the service hands back later: the JSON it was sent.
    stored = WalletSnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>,
    );
    return BackupStatus.ok;
  }

  @override
  Future<BackupResult> pull() async {
    pulls++;
    final s = stored;
    return s == null
        ? const BackupResult(BackupStatus.empty)
        : BackupResult(BackupStatus.ok, s);
  }
}

class _SignedIn extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoggedIn: true, userId: 'u1');
}
