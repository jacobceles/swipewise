import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Every table keyed on `user_id` — i.e. everything that belongs to one
/// identity rather than to the device or the catalog.
///
/// Lives beside the schema because it has to move with it:
/// [DatabaseHelper.reassignUserId] rewrites exactly these tables, so a
/// user-scoped table missing from this list would be silently orphaned the
/// first time a free user upgrades to Pro. `test/api/user_rekey_test.dart`
/// derives the same set from `PRAGMA table_info` and fails if they diverge,
/// so adding a table without updating this list breaks the build rather than
/// someone's wallet.
const List<String> kUserScopedTables = [
  'cards',
  'transactions',
  'card_overrides',
  'settings',
  'financial_accounts',
  'bank_connections',
  'sync_state',
  'sync_runs',
  'card_links',
  'rotating_activations',
];

/// Owns the sqflite handle and both schema paths: the `_onCreate` pass for
/// fresh installs and the `_onUpgrade` migration chain for existing ones.
///
/// The app is in internal testing, so testers carry live databases across
/// updates. A schema change is no longer just an `_onCreate` edit: bump
/// `version`, add an `if (oldVersion < N)` block to `_onUpgrade` that migrates
/// the existing schema in place (`ALTER TABLE` / new `CREATE TABLE`), and keep
/// `_onCreate` updated to the same end state so fresh installs land where
/// upgraders do. Test the upgrade path from the prior version, not just create.
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;
  static Future<Database> Function()? _testInit;

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  /// Test-only hook: override how the underlying database is opened.
  /// Pass a function that opens an in-memory or temp-file DB and runs
  /// `_onCreate` on it, then call `setTestDatabaseFactory(null)` in tearDown
  /// to restore production behavior. Setting this also busts the cached
  /// `_database`.
  static void setTestDatabaseFactory(Future<Database> Function()? init) {
    _testInit = init;
    _database = null;
  }

  /// Test-only: schema bootstrap that callers can invoke on a freshly opened
  /// DB to mirror the production CREATE statements without going through
  /// `path_provider`.
  static Future<void> bootstrapSchema(Database db) =>
      _instance._onCreate(db, 1);

  /// Test-only: runs the real `_onUpgrade` migration chain against an
  /// already-open DB, so the upgrade path (not just `_onCreate`) is
  /// exercised from a prior schema version.
  static Future<void> runUpgrade(Database db, int fromVersion, int toVersion) =>
      _instance._onUpgrade(db, fromVersion, toVersion);

  /// Test-only: drops the cached connection so the next `database` getter
  /// reopens. Use after `setTestDatabaseFactory(null)` if you want to force
  /// a re-init in the same process.
  static void resetForTesting() {
    _database = null;
  }

  /// Test-only: runs the real `_onConfigure` pragmas against an already-open
  /// DB. `setTestDatabaseFactory` opens its own connection and so never calls
  /// them, which left the whole of [_onConfigure] untested.
  static Future<void> configureForTesting(Database db) =>
      _instance._onConfigure(db);

  Future<Database> get database async {
    if (_database != null) return _database!;
    final init = _testInit;
    _database = await (init != null ? init() : _initDatabase());
    return _database!;
  }

  /// Backoff between open attempts. Three attempts total.
  static const List<Duration> _kOpenRetryDelays = [
    Duration(milliseconds: 500),
    Duration(seconds: 2),
  ];

  /// True for SQLITE_BUSY, primary or extended. Android reports extended codes,
  /// so `BUSY_SNAPSHOT`/`BUSY_TIMEOUT` arrive as 517/773 — mask to the low byte.
  static bool _isBusy(DatabaseException e) {
    final int? code = e.getResultCode();
    return code != null && (code & 0xFF) == 5;
  }

  /// Opens the database, retrying a transient SQLITE_BUSY rather than dying.
  ///
  /// sqflite only wraps the version check in `BEGIN EXCLUSIVE` when the stored
  /// schema version differs from [version], so this races on exactly one
  /// launch: the first after an install or an upgrade. That is also when
  /// `ReregisterWorker` is most likely mid-write on its own connection, which
  /// is how 1.0.2+10 crashed in the field despite `busy_timeout`.
  ///
  /// The pragma only covers waits *inside* SQLite; when it expires the open
  /// still throws, and this is the startup path (`AuthNotifier.checkStatus`),
  /// so an uncaught throw takes the app down before first frame. Retrying the
  /// whole open is what makes losing the race survivable.
  Future<Database> _initDatabase() async {
    final String path = join(await getDatabasesPath(), 'swipewise.db');
    for (int attempt = 0; ; attempt++) {
      try {
        return await openDatabase(
          path,
          version: 16,
          onConfigure: _onConfigure,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
          // Internal testers can side-load an older build over a newer DB. sqflite's
          // default onDowngrade throws (hard crash on open); delete-and-recreate is
          // safe here because every local table is re-derivable — the catalog
          // rehydrates from the API/bundled fallback and bank data re-syncs.
          onDowngrade: onDatabaseDowngradeDelete,
        );
      } on DatabaseException catch (e) {
        if (attempt >= _kOpenRetryDelays.length || !_isBusy(e)) rethrow;
        await Future<void>.delayed(_kOpenRetryDelays[attempt]);
      }
    }
  }

  /// Device-level per-store mute list for dwell notifications. A row here
  /// suppresses geofence registration (Dart, in `GeofenceManager`) and, as a
  /// belt-and-braces guard for fences registered before the mute, the native
  /// dwell post. Keyed by the Google place id. Not user-scoped — the native
  /// receivers read it without a user context, exactly like the cooldown
  /// tables. Mute/unmute writes happen only in Dart; native only reads.
  /// Disposable diagnostic trail: one row per fired dwell timer, saying which of
  /// `DwellCheckReceiver`'s seven exits it took. Written only by the native
  /// `DwellOutcomeStore`, and only in debug builds — Dart just owns the schema.
  ///
  /// **Temporary.** Its ancestor `debug_trail` went in at v6 and was dropped at
  /// v8 once it had proven the pipeline; this one gets the same ending once the
  /// silent drops are attributed. Keep in step with `DwellOutcomeStore.CREATE_SQL`.
  static const String _createDwellOutcomesSql = '''
    CREATE TABLE IF NOT EXISTS dwell_outcomes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      at INTEGER NOT NULL,
      geofence_id TEXT NOT NULL,
      merchant_name TEXT,
      outcome TEXT NOT NULL,
      distance_m REAL,
      accuracy_m REAL,
      allowed_m REAL
    )
  ''';

  static const String _createMutedMerchantsSql = '''
    CREATE TABLE IF NOT EXISTS muted_merchants (
      merchant_id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      muted_at INTEGER NOT NULL
    )
  ''';

  /// Migrates an existing tester's database forward. Each `if (oldVersion < N)`
  /// block brings the schema from version N-1 to N and runs in order, so a
  /// tester two versions behind replays every block between their version and
  /// the current one. Rules:
  ///   • Never edit or remove a block that has shipped — add a new one and bump
  ///     `version` in `_initDatabase`.
  ///   • Mirror every change into `_onCreate` so fresh installs reach the same
  ///     end state.
  ///   • `onConfigure` (foreign_keys = ON) already ran before this.
  ///
  /// Example for the next schema change (bump `version` to 2 alongside it):
  ///   if (oldVersion < 2) {
  ///     await db.execute('ALTER TABLE cards ADD COLUMN nickname TEXT');
  ///   }
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v2: the catalog-driven RewardEngine replaces the bundled reward seed.
    // Create the catalog tables (point_systems/card_products/reward_rules/
    // reward_rule_exclusions/product_perks are global; card_links/
    // rotating_activations are user-side) and drop the now-dead seed tables —
    // `wallet_rewards` (rewards) and `card_perks` (perks, now `product_perks`).
    if (oldVersion < 2) {
      await _createCatalogTables(db);
      await db.execute('DROP TABLE IF EXISTS wallet_rewards');
      await db.execute('DROP TABLE IF EXISTS card_perks');
    }
    // v3: migrated to Google Places and Firebase Auth. Clear the tile cache
    // (stale place IDs), the old place-type root-id setting, and the users table
    // (forces Google Sign-In re-login; user-scoped rows cascade-delete).
    //
    // Each statement guards against partial schemas (e.g. migration tests that
    // only create a minimal subset of tables).
    if (oldVersion < 3) {
      final tableNames = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name'] as String).toSet();
      if (tableNames.contains('merchant_tile_cache')) {
        await db.execute('DELETE FROM merchant_tile_cache');
      }
      if (tableNames.contains('settings')) {
        await db.execute(
          "DELETE FROM settings WHERE key = 'nearby_fsq_root_ids'",
        );
      }
      if (tableNames.contains('users')) {
        await db.execute('DELETE FROM users');
      }
    }
    // v4: `reward_rules.earn_constraint` — a display caveat for "top N spend categories"
    // earns (the bonus reaches only N of the listed categories), shown as inline subtext on
    // the Rewards tab. Guarded: a v1→v4 upgrade already gets the column from
    // `_createCatalogTables` (run in the v2 block above), so only add it when absent.
    if (oldVersion < 4) {
      final ruleCols = (await db.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      if (!ruleCols.contains('earn_constraint')) {
        await db.execute(
          'ALTER TABLE reward_rules ADD COLUMN earn_constraint TEXT',
        );
      }
    }
    // v5: `reward_rules.excluded_categories` — JSON array of RewardCategory names a rule
    // does NOT extend to via the travel-superset match (Citi Costco's "travel" excludes
    // transit). Guarded like v4: a fresh v<5 install already gets the column from
    // `_createCatalogTables`, so only add it when absent.
    if (oldVersion < 5) {
      final ruleCols = (await db.rawQuery(
        'PRAGMA table_info(reward_rules)',
      )).map((r) => r['name'] as String).toSet();
      if (!ruleCols.contains('excluded_categories')) {
        await db.execute(
          'ALTER TABLE reward_rules ADD COLUMN excluded_categories TEXT',
        );
      }
    }
    // v6: `debug_trail` was a disposable breadcrumb log; dropped in v8 below.
    // v7: `muted_merchants` — device-level per-store mute list for dwell
    // notifications (see [_createMutedMerchantsSql]).
    if (oldVersion < 7) {
      await db.execute(_createMutedMerchantsSql);
    }
    // v8: drop the disposable `debug_trail` — the geofence/dwell pipeline is
    // proven, so the breadcrumb rig is gone. `IF EXISTS` covers testers who
    // upgrade from before v6 and so never had the table.
    if (oldVersion < 8) {
      await db.execute('DROP TABLE IF EXISTS debug_trail');
    }
    // v9: carry Google Places `businessStatus` onto cached tiles so the
    // "Temporarily closed" badge survives a cache hit (N15). Guarded against a
    // partial schema (migration tests may not create the cache table) — the
    // cache is disposable, so a miss here just means the column arrives on the
    // next fresh install / cache rebuild.
    if (oldVersion < 9) {
      final tableNames = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name'] as String).toSet();
      if (tableNames.contains('merchant_tile_cache')) {
        await db.execute(
          'ALTER TABLE merchant_tile_cache ADD COLUMN business_status TEXT',
        );
      }
    }
    // v10: manual card linking stores the optional payment due day from the
    // add-card flow. It is intentionally an override: bank-synced due dates
    // remain owned by the sync payload when that support lands.
    if (oldVersion < 10) {
      final overrideCols = (await db.rawQuery(
        'PRAGMA table_info(card_overrides)',
      )).map((r) => r['name'] as String).toSet();
      if (overrideCols.isNotEmpty && !overrideCols.contains('due_day')) {
        await db.execute(
          'ALTER TABLE card_overrides ADD COLUMN due_day INTEGER',
        );
      }
    }
    // v11: `cards.originated_manual` marks a `source='bank'` row that was
    // originally a manual card merged into a live bank link (see
    // `mergeManualCardsWithBank`). Read by `dropMissingInstitutions` so a
    // server-side-detected connection loss demotes the card back to
    // `source='manual'` instead of deleting it outright.
    if (oldVersion < 11) {
      final tableNames = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name'] as String).toSet();
      if (tableNames.contains('cards')) {
        final cardCols = (await db.rawQuery(
          'PRAGMA table_info(cards)',
        )).map((r) => r['name'] as String).toSet();
        if (!cardCols.contains('originated_manual')) {
          await db.execute(
            'ALTER TABLE cards ADD COLUMN originated_manual INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
    }

    // v12 — one-shot repair for the account-rename card split.
    //
    // `cards.id` is `bank:<institution>:<lastFour>:<accountSlug>`, and the slug
    // comes from the issuer's account NAME. So when Discover relabelled
    // "Discover it Card" to "Discover Card", the id changed: the rebuild wrote
    // the new card, the old id's transactions stayed behind with no `cards` row,
    // and the orphan-recovery read resurrected them as a DUPLICATE wallet card.
    //
    // `BankWriteRepository` now re-keys on rename, but that only prevents NEW
    // splits — it cannot heal one that already happened, because the stale id no
    // longer matches any incoming account. Hence this repair.
    //
    // Only unambiguous cases are touched: the orphan is adopted only when the
    // same institution + last four resolves to exactly ONE surviving card. Two
    // real cards can share a last four at one issuer, and merging those would
    // destroy data — worse than the duplicate being fixed.
    if (oldVersion < 12) {
      await _repairRenamedCardSplits(db);
    }

    // v13 — per-card payment-reminder overrides. The wireframe puts the
    // "Remind me before it's due" toggle and the "How far ahead" choice on the
    // CARD sheet, not only in Settings, so each card can opt out or use its own
    // lead time while Settings supplies the default. NULL = inherit.
    if (oldVersion < 13) {
      final overrideCols = (await db.rawQuery(
        'PRAGMA table_info(card_overrides)',
      )).map((r) => r['name'] as String).toSet();
      if (overrideCols.isNotEmpty) {
        if (!overrideCols.contains('reminder_enabled')) {
          await db.execute(
            'ALTER TABLE card_overrides ADD COLUMN reminder_enabled INTEGER',
          );
        }
        if (!overrideCols.contains('reminder_lead_days')) {
          await db.execute(
            'ALTER TABLE card_overrides ADD COLUMN reminder_lead_days INTEGER',
          );
        }
      }
    }

    // v14 — country + currency on the catalog, for Canada. Both are additive and
    // NULL-means-US/USD, so an old bundle keeps importing unchanged; the columns
    // simply stay empty until a catalog that carries them arrives.
    if (oldVersion < 14) {
      final productCols = (await db.rawQuery(
        'PRAGMA table_info(card_products)',
      )).map((r) => r['name'] as String).toSet();
      if (productCols.isNotEmpty) {
        if (!productCols.contains('country')) {
          await db.execute('ALTER TABLE card_products ADD COLUMN country TEXT');
        }
        if (!productCols.contains('currency')) {
          await db.execute('ALTER TABLE card_products ADD COLUMN currency TEXT');
        }
      }
      final psCols = (await db.rawQuery(
        'PRAGMA table_info(point_systems)',
      )).map((r) => r['name'] as String).toSet();
      if (psCols.isNotEmpty && !psCols.contains('currency')) {
        await db.execute('ALTER TABLE point_systems ADD COLUMN currency TEXT');
      }
    }

    // v16 — force one catalog re-hydrate so `foreign_tx_fee_pct` picks up the
    // negative "unknown" sentinel. Existing rows hold 0.0 for every card whose
    // fee was never captured, which reads as "charges nothing" and is the bug
    // being fixed; nothing rewrites them until the catalog's dataVersion moves,
    // which could be weeks. Clearing the loaded-version marker makes the next
    // launch re-import from the bundle it already has. Catalog data is derived,
    // so this costs one import and no user data.
    if (oldVersion < 16) {
      // Guarded like every other block here: migration tests (and a v1 DB)
      // reach this with only a subset of tables created.
      final hasSettings =
          (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='settings'",
          )).isNotEmpty;
      if (hasSettings) {
        await db.delete(
          'settings',
          where: 'key = ?',
          whereArgs: ['catalog_data_version'],
        );
      }
    }

    // v15 — dwell_outcomes, the temporary diagnostic trail. Additive and
    // debug-write-only, so nothing reads it in a release build; it exists so a
    // dwell timer that fires and posts nothing can say which of the six silent
    // paths ate it. Drop it (and the native writer) once that's answered.
    if (oldVersion < 15) {
      await db.execute(_createDwellOutcomesSql);
    }
  }

  /// Re-points transactions stranded under a card id that no longer exists onto
  /// the surviving card for the same institution + last four. See the v12 note.
  static Future<void> _repairRenamedCardSplits(Database db) async {
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name'] as String).toSet();
    if (!tables.contains('cards') || !tables.contains('transactions')) return;

    final orphans = await db.rawQuery('''
      SELECT DISTINCT t.user_id AS user_id, t.card_id AS card_id
      FROM transactions t
      LEFT JOIN cards c ON c.id = t.card_id AND c.user_id = t.user_id
      WHERE c.id IS NULL AND t.card_id LIKE 'bank:%'
    ''');

    for (final row in orphans) {
      final orphanId = row['card_id'] as String?;
      final userId = row['user_id'] as String?;
      if (orphanId == null || userId == null) continue;
      // bank:<institution>:<lastFour>:<slug>
      final parts = orphanId.split(':');
      if (parts.length < 4) continue;
      final institutionId = parts[1];
      final lastFour = parts[2];
      if (lastFour.isEmpty || lastFour == '----') continue;

      final matches = await db.query(
        'cards',
        columns: ['id'],
        where: 'user_id = ? AND institution_id = ? AND last_four = ?',
        whereArgs: [userId, institutionId, lastFour],
      );
      if (matches.length != 1) continue; // absent or ambiguous — leave it alone
      final survivingId = matches.first['id'] as String;
      if (survivingId == orphanId) continue;

      await db.update(
        'transactions',
        {'card_id': survivingId},
        where: 'user_id = ? AND card_id = ?',
        whereArgs: [userId, orphanId],
      );
      // The stale link would otherwise keep pointing at a card that no longer
      // exists; the surviving card has its own row.
      if (tables.contains('card_links')) {
        await db.delete(
          'card_links',
          where: 'user_id = ? AND card_id = ?',
          whereArgs: [userId, orphanId],
        );
      }
    }
  }

  /// sqflite defaults `PRAGMA foreign_keys` OFF. Without this, every
  /// `FOREIGN KEY ... ON DELETE CASCADE` we declare is decorative.
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    // Two isolates open this same file: the UI engine, and the background
    // engine `ReregisterWorker` spins up to re-register geofences. Each gets
    // its own sqflite connection, so they genuinely contend. Without a busy
    // timeout the loser fails its open-time `BEGIN EXCLUSIVE` the instant the
    // other holds the lock — SQLITE_BUSY out of `_initDatabase`, which is
    // fatal because it surfaces during `AuthNotifier.checkStatus` at startup.
    //
    // 10s, not the 5s that shipped in 1.0.2+10 — that build still crashed in
    // the field. The holder is not necessarily a short write: `ReregisterWorker`
    // budgets its isolate two minutes (`ReregisterWorker.kt`) and writes the
    // tile cache between Places calls. [_initDatabase] retries on top of this
    // for the tail that still loses.
    //
    // Both of these are rawQuery, not execute: they report the value they set,
    // and Android's `execute` is `execSQL`, which rejects any statement that
    // returns rows ("Queries can be performed using ... query or rawQuery
    // methods only"). `foreign_keys` above returns nothing, so it stays execute.
    await db.rawQuery('PRAGMA busy_timeout = 10000');
    // WAL so a reader isn't blocked by the writer at all. This does NOT cover
    // the crash above: the open-time version check takes an EXCLUSIVE *write*
    // lock, and WAL leaves writer-writer contention exactly as it was.
    await db.rawQuery('PRAGMA journal_mode = WAL');
  }

  /// Moves every row owned by [from] onto [to] in one transaction, then
  /// retires the old `users` row. No-op when the ids match or [from] doesn't
  /// exist.
  ///
  /// This is the free → Pro upgrade path. A free user's identity is a
  /// device-local UUID (see `AuthNotifier`); when they sign in, the wallet
  /// they already built has to follow them onto the Firebase UID. Inserting a
  /// second `users` row instead would strand it — `AuthNotifier.checkStatus`
  /// reads `users` with `limit: 1` and would pick between the two arbitrarily.
  ///
  /// The ordering is dictated by `PRAGMA foreign_keys = ON` (see
  /// [_onConfigure]): every table in [kUserScopedTables] references
  /// `users(id)` and SQLite enforces that immediately, so the destination row
  /// must exist *before* anything is repointed at it and the source row can
  /// only be deleted *after*.
  ///
  /// Throws — inside the transaction, so nothing partial lands — if [to]
  /// already holds rows that collide with [from] on a primary key. That is a
  /// merge, not a re-key, and there is no sane silent answer to it.
  Future<void> reassignUserId({
    required String from,
    required String to,
  }) async {
    if (from == to) return;
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'users',
        where: 'id = ?',
        whereArgs: [from],
        limit: 1,
      );
      if (rows.isEmpty) return;
      await txn.insert('users', {...rows.first, 'id': to});
      for (final table in kUserScopedTables) {
        await txn.update(
          table,
          {'user_id': to},
          where: 'user_id = ?',
          whereArgs: [from],
        );
      }
      await txn.delete('users', where: 'id = ?', whereArgs: [from]);
    });
  }

  Future _onCreate(Database db, int version) async {
    // Single-row users table. `id` and `identifier` both hold the display
    // name the user entered at first launch — Sophtron HMAC creds live in
    // `--dart-define` (SophtronConfig), not here.
    //
    // `email` is the recovery key: re-entering the same email on a fresh
    // install yields the same `bank_customer_id` (because both
    // are derived from `sha256(email.toLowerCase().trimmed + APP_SALT)`),
    // which Sophtron uses to retrieve the existing Customer. That's how
    // a reinstall (or a second device) gets the user's prior banks back
    // without any backup-side machinery. See [SophtronConfig.deriveCustomerUniqueId].
    //
    // `first_sync_completed_at` gates the orphan-Member cleanup pass in
    // the sync engine: on a fresh-install / post-reinstall sync the
    // local DB is empty so every Sophtron Member would look like an
    // orphan; skipping cleanup until at least one successful sync has
    // landed prevents recovery from accidentally wiping banks at
    // Sophtron.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        identifier TEXT NOT NULL,
        email TEXT,
        bank_customer_id TEXT,
        first_sync_completed_at TEXT,
        auth_time INTEGER
      )
    ''');

    // ────── cards ──────
    //
    // `id` shape: `bank:<institution_id>:<last_four>:<account_slug>` for
    // Sophtron rows, free-form for manual cards. `account_slug` is the
    // sanitized AccountName (or first 8 of AccountID when name is missing)
    // and disambiguates the joint-card case where two cards from the same
    // bank share `last_four`. See `stableCardId` in
    // `card_repository.dart`.
    //
    // No FK from `card_overrides` to `cards` on purpose: overrides survive
    // every sync-side wipe path — `rebuildInstitution`,
    // `dropMissingInstitutions`, `replaceBankData`, and
    // explicit disconnect — and re-attach the moment a card with the
    // same deterministic id reappears. The `id` shape above is stable
    // across re-links of the same physical card, so the user's saved
    // credit limit, Identify-Card pick, and custom rename hold through
    // every flow that wasn't an outright bank disconnect by the user.
    //
    // `originated_manual` is set on a `source='bank'` row when
    // `mergeManualCardsWithBank` collapses a manual card into it. It's the
    // breadcrumb `dropMissingInstitutions` reads to demote the row back to
    // `source='manual'` (rather than delete it) when Sophtron stops
    // returning the connection server-side — see [BankWriteRepository].
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cards (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        source TEXT NOT NULL,
        provider TEXT,
        name TEXT NOT NULL,
        last_four TEXT,
        account_slug TEXT,
        institution_id TEXT,
        network TEXT,
        image_url TEXT,
        institution_logo TEXT,
        account_type TEXT,
        sub_type TEXT,
        originated_manual INTEGER NOT NULL DEFAULT 0,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cards_user ON cards(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cards_institution ON cards(institution_id)',
    );

    // ────── transactions ──────
    //
    // `id` is a stable composite built from (card_id, posted_date, abs_amount
    // in cents, normalized_description_hash). Normalization (description
    // lowercased + whitespace collapsed; amount in integer cents) so a
    // re-sync that emits a re-cased description or sign-flipped amount
    // doesn't double-insert. See `transactionStableId` in
    // `transaction_repository.dart`.
    //
    // Foreign key to users cascades (logout wipes everything); NOT cascading
    // from cards (deleting a bank link preserves spend history).
    //
    // `brand_id` is a free-form text column referring to a logical brand
    // slug in the in-code registry (`reward_category_mapper.dart`). No FK:
    // the registry is the single source of truth, never empty, and only
    // produces slugs the registry itself defines, so a FK would only ever
    // catch our own ordering bugs (which it did, repeatedly). Display
    // names + categories for the slug come from `brandDisplayNameFor()`
    // and `brandDefaultCategory()` at read time.
    //
    // Two category columns, deliberately separate:
    //   `category`        — display only. The bank's free-text label
    //                       ("Food & Drink"), falling back to the
    //                       classifier's human label when the bank gives
    //                       none. Never parsed back into an enum.
    //   `reward_category` — canonical `RewardCategory.name` ('onlineGrocery'),
    //                       set by the classifier for every debit. This is
    //                       the engine / insights input; it matches the
    //                       catalog's `reward_rules.category` (the enum `.name`).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transactions (
        id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        posted_at TEXT,
        created_at TEXT,
        name TEXT,
        merchant TEXT,
        category TEXT,
        reward_category TEXT,
        category_id TEXT,
        brand_id TEXT,
        type TEXT,
        amount REAL,
        currency TEXT,
        rewards_earned REAL,
        reward_multiplier REAL,
        card TEXT,
        card_id TEXT,
        card_last_four TEXT,
        status TEXT DEFAULT 'POSTED',
        raw_json TEXT,
        first_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
        last_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id, user_id),
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tx_user_posted ON transactions(user_id, posted_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tx_card ON transactions(card_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tx_category_id ON transactions(category_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tx_brand ON transactions(brand_id)',
    );

    // Long-lived snapshot of every Sophtron institution we've seen via
    // sync (`institution_id` -> name + logo). Never wiped, so orphan
    // transactions whose `bank_connections` row was deleted (manual
    // disconnect, or a different-catalog reconnect) can still render
    // their bank label and logo. Updated on every successful member
    // resolution.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS institutions_cache (
        institution_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        logo TEXT,
        last_seen_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // User-set overrides keyed by the same stable card id `cards.id` uses.
    // Survives `replaceBankData` (which only wipes `cards`) so renames,
    // identifications, and manual credit limits re-attach automatically
    // when the next sync recreates the card row with the same id.
    //
    // `product_identification` replaces a prior provider-specific product-id
    // column. The catalog-rewrite §3 swap-in will reuse this column, paired with
    // `identification_source` ('user' / 'heuristic' / 'bin') to track how
    // the binding was made.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS card_overrides (
        card_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        manual_credit_limit REAL,
        custom_name TEXT,
        product_identification TEXT,
        identification_source TEXT,
        due_day INTEGER,
        -- Per-card reminder overrides (N12). NULL = inherit the global setting:
        -- `reminder_enabled` NULL means "follow the master toggle", and
        -- `reminder_lead_days` NULL means "use the default lead time". Storing
        -- them here (not on `cards`) keeps them safe from the sync rebuild,
        -- which replaces `cards` wholesale.
        reminder_enabled INTEGER,
        reminder_lead_days INTEGER,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (card_id, user_id),
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_card_overrides_user ON card_overrides(user_id)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        user_id TEXT NOT NULL,
        key TEXT NOT NULL,
        value TEXT,
        PRIMARY KEY (user_id, key),
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        icon_id TEXT,
        synced_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Per-card balance snapshot from the aggregator. Columns cover only what
    // we consume today; the full FDX payload is kept in `raw_json` so a future
    // field (e.g. rewards, if an aggregator ever returns them) can be lit up by
    // adding a column + back-filling from raw_json — no re-sync, no breakage.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS financial_accounts (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        linked_card_id TEXT,
        bank_name TEXT,
        mask TEXT,
        balance_available REAL,
        balance_current REAL,
        balance_limit REAL,
        raw_json TEXT,
        synced_at TEXT DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
        FOREIGN KEY (linked_card_id) REFERENCES cards (id) ON DELETE CASCADE
      )
    ''');

    // Nearby stores: cached Google Places merchants per ~1km grid cell.
    // `last_accessed_at` tracks read recency for the LRU eviction policy
    // (`TileCache.evictTo(maxCells:)`).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS merchant_tile_cache (
        cell_id TEXT NOT NULL,
        merchant_id TEXT NOT NULL,
        name TEXT NOT NULL,
        category TEXT,
        foursquare_category_id TEXT,
        business_status TEXT,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        fetched_at INTEGER NOT NULL,
        last_accessed_at INTEGER NOT NULL,
        PRIMARY KEY (cell_id, merchant_id)
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tile_cache_fetched ON merchant_tile_cache(fetched_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tile_cache_accessed ON merchant_tile_cache(last_accessed_at)',
    );

    // Currently-registered merchant geofences. Receiver reads merchant from here on dwell.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS active_geofences (
        geofence_id TEXT PRIMARY KEY,
        merchant_id TEXT NOT NULL,
        name TEXT NOT NULL,
        category TEXT,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        radius_m INTEGER NOT NULL,
        dwell_seconds INTEGER NOT NULL,
        registered_at INTEGER NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_active_geofences_merchant ON active_geofences(merchant_id)',
    );

    // Single-row table holding the boundary tripwire geofence.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS boundary_geofence (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        geofence_id TEXT NOT NULL,
        center_lat REAL NOT NULL,
        center_lng REAL NOT NULL,
        radius_m INTEGER NOT NULL,
        registered_at INTEGER NOT NULL
      )
    ''');

    // Per-merchant cooldown (e.g. don't re-notify the same Kohl's for 6h).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS merchant_notification_cooldown (
        merchant_id TEXT PRIMARY KEY,
        last_notified_at INTEGER NOT NULL
      )
    ''');

    // Per-category cooldown (e.g. one Retail notification while walking
    // through a strip mall — don't fire for every store inside it).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS category_notification_cooldown (
        category TEXT PRIMARY KEY,
        last_notified_at INTEGER NOT NULL
      )
    ''');

    // Device-level per-store mute list for dwell notifications.
    await db.execute(_createMutedMerchantsSql);

    // Temporary diagnostic trail for dwell notifications (see the SQL above).
    await db.execute(_createDwellOutcomesSql);

    // One row per bank Member (link) we resolve from Sophtron v2. Drives
    // the per-link transaction sync. `user_institution_id` holds the
    // Sophtron v2 MemberID despite the older-sounding column name.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bank_connections (
        user_institution_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        member_id TEXT,
        institution_id TEXT,
        institution_name TEXT,
        institution_logo TEXT,
        last_synced_at TEXT,
        last_sync_status TEXT,
        last_sync_error TEXT,
        created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (user_institution_id, user_id),
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    // ────── sync_state ──────
    //
    // Cross-isolate advisory lock. Foreground `SyncRepository.acquire()`
    // and the WorkManager dispatcher both gate on this row before calling
    // `BankSyncEngine.run()`. The holder bumps `heartbeat_at` as it makes
    // progress; a lock whose heartbeat has gone stale (older than the
    // liveness window) is treated as dead and stealable, so a crashed run
    // can't strand the table while a healthy long run is never stolen.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        user_id TEXT PRIMARY KEY,
        acquired_at INTEGER NOT NULL,
        heartbeat_at INTEGER NOT NULL,
        holder TEXT NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    // ────── sync_runs ──────
    //
    // Per-run timing + outcome. Powers diagnostics ("why did sync take
    // 90s?") that the progress-event stream can't answer after the fact.
    // Pruned via an LRU sweep so the table doesn't grow unbounded.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_runs (
        run_id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        trigger TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        member_count INTEGER,
        card_count INTEGER,
        tx_count INTEGER,
        error_count INTEGER,
        outcome TEXT,
        members_json TEXT,
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_runs_user_started ON sync_runs(user_id, started_at DESC)',
    );

    // ────── api_circuit_breakers ──────
    //
    // Cross-isolate breaker state for external APIs (Google Places, Sophtron, etc.).
    // Replaces the per-isolate `static` fields that diverged between
    // foreground and the geofence-reregister entry. `opened_until` is
    // a future ms-epoch; null means closed.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS api_circuit_breakers (
        service TEXT PRIMARY KEY,
        failure_count INTEGER NOT NULL DEFAULT 0,
        opened_until INTEGER,
        last_failure_at INTEGER
      )
    ''');

    await _createCatalogTables(db);
  }

  /// The catalog-driven RewardEngine schema (Track B), shared by `_onCreate`
  /// (fresh installs) and the v2 `_onUpgrade` block (existing testers).
  ///
  /// The first four tables are the **catalog**: global, read-mostly, hydrated
  /// from the bundled `catalog-v{version}.json` by `CatalogLoader`. They carry
  /// no user FK — they're the same for everyone and survive user-scoped wipes.
  /// `card_links` / `rotating_activations` are the **user-side** bindings.
  ///
  /// Creation order matters: `onConfigure` turns `foreign_keys` ON, so a
  /// referenced table must exist before its referencer — point_systems and
  /// card_products before reward_rules, reward_rules before its exclusions.
  ///
  /// Like `card_overrides`, `card_links`/`rotating_activations` carry **no FK
  /// on `card_id`** so they survive `replaceBankData` and re-attach when a card
  /// with the same stable id reappears; the binding outlives a re-link.
  Future<void> _createCatalogTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS point_systems (
        point_system_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        baseline_cent_value REAL NOT NULL,
        valuation_source TEXT,
        valuation_updated_at TEXT,
        -- Which currency `baseline_cent_value` is denominated in. NULL = USD.
        -- Values are NOT converted between currencies — see the ranking note in
        -- reward_engine.dart.
        currency TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS card_products (
        card_product_id TEXT PRIMARY KEY,
        issuer TEXT NOT NULL,
        display_name TEXT NOT NULL,
        network TEXT,
        annual_fee_usd REAL,
        -- NOT NULL, so "never captured" is carried as a NEGATIVE sentinel
        -- written by CatalogLoader rather than NULL — this table has two FK
        -- dependents and dropping NOT NULL would mean a rebuild. 0.0 means the
        -- card genuinely charges nothing; < 0 means unknown. No real fee is
        -- negative. See CatalogLoader._markUnknownFxFee.
        foreign_tx_fee_pct REAL NOT NULL DEFAULT 0.0,
        image_url TEXT,
        catalog_version TEXT NOT NULL,
        retired_at TEXT,
        -- NULL means US/USD: catalogs published before Canada carried neither
        -- column, and every card in them was American.
        country TEXT,
        currency TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS reward_rules (
        rule_id TEXT PRIMARY KEY,
        card_product_id TEXT NOT NULL REFERENCES card_products(card_product_id),
        kind TEXT NOT NULL,
        category TEXT,
        brand TEXT,
        rate REAL NOT NULL,
        point_system_id TEXT NOT NULL REFERENCES point_systems(point_system_id),
        valid_from TEXT,
        valid_to TEXT,
        rotation_year INTEGER,
        rotation_quarter INTEGER,
        requires_activation INTEGER NOT NULL DEFAULT 0,
        cap_spend_amount_usd REAL,
        cap_period TEXT,
        cap_group TEXT,
        notes TEXT,
        earn_constraint TEXT,
        excluded_categories TEXT
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rules_product ON reward_rules(card_product_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rules_category ON reward_rules(category)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rules_brand ON reward_rules(brand)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_rules_rotation ON reward_rules(rotation_year, rotation_quarter)',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS reward_rule_exclusions (
        rule_id TEXT NOT NULL REFERENCES reward_rules(rule_id),
        brand TEXT NOT NULL,
        PRIMARY KEY (rule_id, brand)
      )
    ''');

    // Card benefits/credits (travel insurance, purchase protection, lounge &
    // statement credits, …) attached to a product. Global catalog data, like
    // reward_rules; the user's card inherits them via card_links. Replaces the
    // old user-scoped, seed-populated `card_perks` table.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS product_perks (
        card_product_id TEXT NOT NULL REFERENCES card_products(card_product_id),
        perk_id TEXT NOT NULL,
        kind TEXT,
        title TEXT,
        description TEXT,
        frequency TEXT,
        value_estimate REAL,
        calendar_max_year_amount REAL,
        how_to_earn TEXT,
        image_uri TEXT,
        redemption_url TEXT,
        PRIMARY KEY (card_product_id, perk_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS card_links (
        user_id TEXT NOT NULL,
        card_id TEXT NOT NULL,
        card_product_id TEXT NOT NULL,
        source TEXT NOT NULL,
        confidence REAL,
        linked_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (user_id, card_id),
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS rotating_activations (
        user_id TEXT NOT NULL,
        card_id TEXT NOT NULL,
        rotation_year INTEGER NOT NULL,
        rotation_quarter INTEGER NOT NULL,
        activated_at TEXT,
        PRIMARY KEY (user_id, card_id, rotation_year, rotation_quarter),
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');
  }
}
