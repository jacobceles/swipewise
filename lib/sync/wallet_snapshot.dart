import 'package:sqflite/sqflite.dart';

import '../api/database_helper.dart';
import '../api/settings_repository.dart';

/// The portable half of a wallet: what a user would expect to find waiting on
/// a new phone.
///
/// Four tables, and deliberately only four. **Transactions are not here and
/// must never be** — moving spend history server-side would contradict the
/// on-device privacy position the app is built and marketed on, and turn a
/// recommendation app into a financial data processor. Nor are
/// `bank_connections`: a bank link is bound to aggregator credentials that
/// cannot follow a device, so a restored phone re-links rather than pretending
/// the connection came along.
///
/// What is here is the wallet as the user thinks of it — which cards they
/// carry, what they renamed and tuned, which catalog product each maps to, and
/// their preferences.
class WalletSnapshot {
  const WalletSnapshot({
    required this.schemaVersion,
    required this.capturedAt,
    required this.cards,
    required this.cardOverrides,
    required this.cardLinks,
    required this.settings,
    this.mutedMerchants = const [],
  });

  /// Bumped when the shape changes incompatibly. The service stores it
  /// alongside the payload so a newer app can recognise an older backup
  /// instead of misreading it.
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final DateTime capturedAt;
  final List<Map<String, Object?>> cards;
  final List<Map<String, Object?>> cardOverrides;
  final List<Map<String, Object?>> cardLinks;
  final Map<String, String> settings;

  /// Stores the user silenced for arrival alerts.
  ///
  /// The odd one out: `muted_merchants` has no `user_id`, because the native
  /// geofence receivers read it with no user context. It is carried anyway —
  /// from the user's side it is a preference sitting in Profile next to ones
  /// that already travel, and a new phone that starts alerting for every store
  /// they had silenced reads as a bug, not as a scoping decision.
  final List<Map<String, Object?>> mutedMerchants;

  /// Nothing worth restoring. Used to decide that a pulled backup should not
  /// overwrite a populated device with emptiness.
  bool get isEmpty =>
      cards.isEmpty &&
      cardOverrides.isEmpty &&
      cardLinks.isEmpty &&
      settings.isEmpty &&
      mutedMerchants.isEmpty;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'cards': cards,
    'cardOverrides': cardOverrides,
    'cardLinks': cardLinks,
    'settings': settings,
    'mutedMerchants': mutedMerchants,
  };

  factory WalletSnapshot.fromJson(Map<String, Object?> json) {
    List<Map<String, Object?>> rows(String key) => ((json[key] as List?) ?? [])
        .whereType<Map>()
        .map((r) => r.map((k, v) => MapEntry(k.toString(), v)))
        .toList();

    return WalletSnapshot(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
      capturedAt:
          DateTime.tryParse(json['capturedAt'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      cards: rows('cards'),
      cardOverrides: rows('cardOverrides'),
      cardLinks: rows('cardLinks'),
      // Absent in backups written before muted stores were carried. Defaults
      // to empty, so an older snapshot restores without them rather than
      // failing — additive, which is why schemaVersion does not move.
      mutedMerchants: rows('mutedMerchants'),
      settings: ((json['settings'] as Map?) ?? {}).map(
        (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
      ),
    );
  }
}

/// Reads and writes [WalletSnapshot]s against the local database.
class WalletBackupRepository {
  WalletBackupRepository([DatabaseHelper? helper])
    : _dbHelper = helper ?? DatabaseHelper();

  final DatabaseHelper _dbHelper;

  /// `user_id` is stripped on capture and re-stamped on apply, so a snapshot
  /// is not welded to the id it was taken under.
  static const _ownerColumn = 'user_id';

  /// Whether there is anything on this device worth protecting.
  ///
  /// Drives the one automatic decision this feature makes: a backup is pulled
  /// down on launch only onto an empty wallet. Any other combination is left
  /// to the user, because overwriting cards they can see is not a choice code
  /// should make for them.
  Future<bool> isWalletEmpty(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM cards WHERE user_id = ?',
      [userId],
    );
    return (rows.single['n'] as int) == 0;
  }

  Future<WalletSnapshot> capture(String userId) async {
    final db = await _dbHelper.database;

    Future<List<Map<String, Object?>>> table(String name) async {
      final rows = await db.query(
        name,
        where: '$_ownerColumn = ?',
        whereArgs: [userId],
      );
      return rows
          .map((r) => {...r}..remove(_ownerColumn))
          .toList(growable: false);
    }

    final settingRows = await db.query(
      'settings',
      columns: ['key', 'value'],
      where: '$_ownerColumn = ?',
      whereArgs: [userId],
    );

    // No `user_id` to filter on — the table is device-global by design, so the
    // whole thing is the user's mute list.
    final muted = await db.query('muted_merchants');

    return WalletSnapshot(
      schemaVersion: WalletSnapshot.currentSchemaVersion,
      capturedAt: DateTime.now().toUtc(),
      cards: await table('cards'),
      cardOverrides: await table('card_overrides'),
      cardLinks: await table('card_links'),
      mutedMerchants: muted.map((r) => {...r}).toList(growable: false),
      settings: {
        for (final row in settingRows)
          if (SettingsRepository.syncableSettingsKeys.contains(row['key']))
            row['key'] as String: (row['value'] as String?) ?? '',
      },
    );
  }

  /// Replaces this user's wallet with [snapshot], in one transaction.
  ///
  /// Destructive by design — it is the "restore" half of a restore, and every
  /// caller either found the wallet empty or asked the user first.
  ///
  /// Transactions are left alone. They have no foreign key to `cards`
  /// (deleting a bank link deliberately preserves spend history), so replacing
  /// the card rows cannot cascade into them.
  Future<void> apply(WalletSnapshot snapshot, {required String userId}) async {
    final db = await _dbHelper.database;

    // Columns the *local* schema actually has. A backup written by a newer
    // build can carry a column this one has never heard of, and an unfiltered
    // insert would throw on it — so drift degrades to a dropped field rather
    // than a failed restore.
    Future<Set<String>> columnsOf(String table) async {
      final info = await db.rawQuery('PRAGMA table_info($table)');
      return info.map((c) => c['name'] as String).toSet();
    }

    final cardCols = await columnsOf('cards');
    final overrideCols = await columnsOf('card_overrides');
    final linkCols = await columnsOf('card_links');
    final mutedCols = await columnsOf('muted_merchants');

    await db.transaction((txn) async {
      for (final table in ['cards', 'card_overrides', 'card_links']) {
        await txn.delete(
          table,
          where: '$_ownerColumn = ?',
          whereArgs: [userId],
        );
      }

      // `scoped` false for the one table with no `user_id` to stamp.
      Future<void> insertAll(
        String table,
        List<Map<String, Object?>> rows,
        Set<String> allowed, {
        bool scoped = true,
      }) async {
        for (final row in rows) {
          final clean = <String, Object?>{if (scoped) _ownerColumn: userId};
          for (final entry in row.entries) {
            if (entry.key == _ownerColumn) continue;
            if (!allowed.contains(entry.key)) continue;
            clean[entry.key] = entry.value;
          }
          if (clean.isEmpty) continue;
          await txn.insert(
            table,
            clean,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

      await insertAll('cards', snapshot.cards, cardCols);
      await insertAll('card_overrides', snapshot.cardOverrides, overrideCols);
      await insertAll('card_links', snapshot.cardLinks, linkCols);

      // Device-global, so the delete is unfiltered — there is no user whose
      // mutes these are, only this device's. Replaced wholesale like the rest.
      await txn.delete('muted_merchants');
      await insertAll(
        'muted_merchants',
        snapshot.mutedMerchants,
        mutedCols,
        scoped: false,
      );

      // Filtered again on the way in. The payload arrives over the network,
      // so it is untrusted input: without this, a stale or tampered backup
      // could set `permissions_asked` or `onboarding_seen` — device-local
      // facts a backup has no business asserting.
      for (final entry in snapshot.settings.entries) {
        if (!SettingsRepository.syncableSettingsKeys.contains(entry.key)) {
          continue;
        }
        await txn.insert('settings', {
          _ownerColumn: userId,
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}
