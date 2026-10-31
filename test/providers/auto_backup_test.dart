import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/backup_provider.dart';
import 'package:swipewise/providers/settings_provider.dart';
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

  ProviderContainer container({bool signedIn = true, bool supported = true}) {
    client.signedIn = signedIn;
    final c = ProviderContainer(
      overrides: [
        authProvider.overrideWith(signedIn ? _SignedIn.new : _SignedOut.new),
        backupSupportedProvider.overrideWithValue(supported),
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

  for (final failedPull in [true, false]) {
    test(
      'failed ${failedPull ? 'pull' : 'push'} does not record a new fingerprint',
      () async {
        await settings.setBackupEnabled(userId, true);
        await addCard('a');
        final c = container();
        expect(await run(c), AutoBackupOutcome.uploaded);
        final known = await settings.getBackupFingerprint(userId);
        final uploadedAt = await settings.getLastBackupAt(userId);
        await addCard('b');
        if (failedPull) {
          client.pullStatus = BackupStatus.failed;
        } else {
          client.pushStatus = BackupStatus.failed;
        }
        expect(await run(c), AutoBackupOutcome.failed);
        expect(client.pushes, failedPull ? 1 : 2);
        expect(await settings.getBackupFingerprint(userId), known);
        expect(await settings.getLastBackupAt(userId), uploadedAt);
        client.pullStatus = null;
        client.pushStatus = BackupStatus.ok;
        expect(
          await run(c),
          AutoBackupOutcome.uploaded,
          reason: 'failure must remain retryable',
        );
      },
    );
  }

  test(
    'signed-out client cannot upload even with a stale enabled setting',
    () async {
      await settings.setBackupEnabled(userId, true);
      await addCard('a');
      expect(await run(container(signedIn: false)), AutoBackupOutcome.failed);
      expect(client.pushes, 0);
      expect(await settings.getBackupFingerprint(userId), isNull);
    },
  );

  test(
    'auto restore populates an empty wallet, enables backup, and records fingerprint',
    () async {
      await addCard('a');
      await addCard('b');
      client.stored = await WalletBackupRepository().capture(userId);
      final db = await DatabaseHelper().database;
      await db.delete('cards', where: 'user_id = ?', whereArgs: [userId]);
      final c = container();
      expect(
        await c.read(walletBackupControllerProvider).maybeAutoRestore(),
        RestoreOutcome.restored,
      );
      expect((await db.query('cards')).map((r) => r['id']), ['a', 'b']);
      expect(await settings.getBackupEnabled(userId), isTrue);
      expect(
        await settings.getBackupFingerprint(userId),
        client.stored!.fingerprint,
      );
      expect(await settings.getLastBackupAt(userId), isNull);
      expect(client.pushes, 0);
      expect(await run(c), AutoBackupOutcome.unchanged);
      expect(
        await c.read(walletBackupControllerProvider).maybeAutoRestore(),
        RestoreOutcome.nothingToRestore,
      );
      expect(client.pulls, 1);
    },
  );

  test('auto restore never overwrites a nonempty wallet', () async {
    await addCard('local');
    client.stored = _snapshot(['remote']);
    final c = container();
    expect(
      await c.read(walletBackupControllerProvider).maybeAutoRestore(),
      RestoreOutcome.nothingToRestore,
    );
    expect(client.pulls, 0);
    expect(
      (await (await DatabaseHelper().database).query('cards')).single['id'],
      'local',
    );
  });

  test(
    'restore refreshes already-loaded wallet preferences without restarting',
    () async {
      await addCard('x');
      await settings.setDefaultScreen(userId, DefaultScreen.cards);
      await settings.setDefaultAdvisorView(userId, AdvisorView.categories);
      await settings.setNearbyRadiusMi(userId, 25);
      await settings.setCardPreferenceOrder(userId, ['x']);
      client.stored = await WalletBackupRepository().capture(userId);
      final db = await DatabaseHelper().database;
      await db.delete('cards', where: 'user_id = ?', whereArgs: [userId]);
      await db.delete('settings', where: 'user_id = ?', whereArgs: [userId]);

      final c = container();
      final subscriptions = [
        c.listen(defaultScreenProvider, (_, _) {}),
        c.listen(advisorViewProvider, (_, _) {}),
        c.listen(nearbyRadiusProvider, (_, _) {}),
        c.listen(cardPreferenceOrderProvider, (_, _) {}),
      ];
      addTearDown(() {
        for (final sub in subscriptions) {
          sub.close();
        }
      });
      await c.read(cardPreferenceOrderProvider.future);
      await c.pump();
      await settings.getNearbyRadiusMi(userId);
      expect(c.read(defaultScreenProvider), DefaultScreen.transactions);
      expect(c.read(advisorViewProvider), AdvisorView.stores);
      expect(c.read(nearbyRadiusProvider), 10);

      expect(
        await c.read(walletBackupControllerProvider).restoreNow(),
        RestoreOutcome.restored,
      );
      await c.pump();
      expect(await c.read(cardPreferenceOrderProvider.future), ['x']);
      await settings.getNearbyRadiusMi(userId);
      await c.pump();
      expect(c.read(defaultScreenProvider), DefaultScreen.cards);
      expect(c.read(advisorViewProvider), AdvisorView.categories);
      expect(c.read(nearbyRadiusProvider), 25);
    },
  );

  test(
    'a retired owner cannot restore cards or replace the guest mute list',
    () async {
      final db = await DatabaseHelper().database;
      await db.delete('users');
      await db.insert('users', {'id': 'local:guest', 'identifier': 'You'});
      await db.insert('muted_merchants', {
        'merchant_id': 'guest-mute',
        'name': 'Guest store',
        'muted_at': DateTime.now().millisecondsSinceEpoch,
      });
      await WalletBackupRepository().apply(_snapshot(['old']), userId: userId);
      expect(await db.query('cards'), isEmpty);
      expect(
        (await db.query('muted_merchants')).single['merchant_id'],
        'guest-mute',
      );
    },
  );

  for (final signedIn in [false, true]) {
    test(
      'auto restore requires ${signedIn ? 'a configured service' : 'sign-in'}',
      () async {
        client.stored = _snapshot(['remote']);
        final c = container(signedIn: signedIn, supported: !signedIn);
        expect(
          await c.read(walletBackupControllerProvider).maybeAutoRestore(),
          RestoreOutcome.unavailable,
        );
        expect(client.pulls, 0);
      },
    );
  }

  for (final (status, outcome) in [
    (BackupStatus.empty, RestoreOutcome.nothingToRestore),
    (BackupStatus.failed, RestoreOutcome.failed),
    (BackupStatus.unavailable, RestoreOutcome.unavailable),
  ]) {
    test('auto restore handles $status without changing local state', () async {
      client.pullStatus = status;
      final c = container();
      expect(
        await c.read(walletBackupControllerProvider).maybeAutoRestore(),
        outcome,
      );
      expect(await (await DatabaseHelper().database).query('cards'), isEmpty);
      expect(await settings.getBackupEnabled(userId), isFalse);
      expect(await settings.getBackupFingerprint(userId), isNull);
      expect(client.pushes, 0);
    });
  }
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
  bool signedIn = true;
  BackupStatus? pullStatus;
  BackupStatus pushStatus = BackupStatus.ok;
  WalletSnapshot? stored;
  int pulls = 0;
  int pushes = 0;

  @override
  Future<BackupStatus> push(WalletSnapshot snapshot) async {
    pushes++;
    if (!signedIn) return BackupStatus.unavailable;
    if (pushStatus != BackupStatus.ok) return pushStatus;
    // What the service hands back later: the JSON it was sent.
    stored = WalletSnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>,
    );
    return BackupStatus.ok;
  }

  @override
  Future<BackupResult> pull() async {
    pulls++;
    if (!signedIn) return const BackupResult(BackupStatus.unavailable);
    if (pullStatus != null) return BackupResult(pullStatus!);
    final s = stored;
    return s == null
        ? const BackupResult(BackupStatus.empty)
        : BackupResult(BackupStatus.ok, s);
  }
}

class _SignedIn extends AuthNotifier {
  @override
  AuthState build() =>
      AuthState(isLoggedIn: true, userId: 'u1', email: 'u1@example.com');
}

class _SignedOut extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoggedIn: true, userId: 'u1');
}
