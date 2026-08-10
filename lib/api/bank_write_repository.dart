import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../models/reward_category.dart';
import 'bank_fdx_mapper.dart';
import 'brand_resolver.dart';
import 'card_repository.dart';
import 'database_helper.dart';
import 'reward_category_mapper.dart';
import 'types.dart';
import '../util/logger.dart';

/// Owns the write side of the Sophtron pipeline: connection rows,
/// institution cache, the per-institution atomic rebuild used by
/// `BankSyncEngine`, manual-card merging, wipe paths, and the small
/// catalog of Sophtron-specific static helpers (stable ids, name
/// normalization, last-four parsing, etc.).
///
/// Reads live here too when they're scoped to Sophtron concepts
/// (`queryBankConnections`, `getConnection`,
/// `lookupInstitutionName`). The general card-listing read is
/// `CardRepository.queryAllCards` instead.
class BankWriteRepository {
  BankWriteRepository(this._dbHelper);
  final DatabaseHelper _dbHelper;

  // ───────────── Connections ─────────────

  Future<void> upsertConnection({
    required String userId,
    required String userInstitutionId,
    String? memberId,
    String? institutionId,
    String? institutionName,
    String? institutionLogo,
  }) async {
    final db = await _dbHelper.database;
    // INSERT OR IGNORE stamps `created_at` (column default) the first time we
    // see this link and is a no-op on every sync after; the UPDATE then
    // refreshes ONLY the institution metadata.
    //
    // The previous `ConflictAlgorithm.replace` was a DELETE+INSERT, so every
    // sync silently reset the columns not listed here — `created_at` back to
    // CURRENT_TIMESTAMP, and `last_synced_at` / `last_sync_status` /
    // `last_sync_error` back to NULL. The engine re-reads those mid-sync, so the
    // reset quietly defeated three things: the abandoned-link retirement (its
    // ">2h old" gate saw a perpetually-fresh `created_at`), never-synced
    // detection (`last_synced_at` always looked NULL), and the broken-bank
    // circuit breaker (`last_sync_status` always looked blank).
    await db.insert('bank_connections', {
      'user_institution_id': userInstitutionId,
      'user_id': userId,
      'member_id': memberId,
      'institution_id': institutionId,
      'institution_name': institutionName,
      'institution_logo': institutionLogo,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.update(
      'bank_connections',
      {
        'member_id': memberId,
        'institution_id': institutionId,
        'institution_name': institutionName,
        'institution_logo': institutionLogo,
      },
      where: 'user_institution_id = ? AND user_id = ?',
      whereArgs: [userInstitutionId, userId],
    );
  }

  Future<List<BankConnectionRow>> queryBankConnections(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'bank_connections',
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    return rows.map(BankConnectionRow.fromRow).toList(growable: false);
  }

  Future<BankConnectionRow?> getConnection({
    required String userId,
    required String userInstitutionId,
  }) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'bank_connections',
      where: 'user_institution_id = ? AND user_id = ?',
      whereArgs: [userInstitutionId, userId],
      limit: 1,
    );
    return rows.isEmpty ? null : BankConnectionRow.fromRow(rows.first);
  }

  Future<void> setConnectionLastSyncedAt(
    String userInstitutionId,
    DateTime when,
  ) async {
    final db = await _dbHelper.database;
    await db.update(
      'bank_connections',
      {'last_synced_at': when.toIso8601String()},
      where: 'user_institution_id = ?',
      whereArgs: [userInstitutionId],
    );
  }

  Future<void> setConnectionSyncStatus(
    String userInstitutionId, {
    required String status,
    String? error,
  }) async {
    final db = await _dbHelper.database;
    await db.update(
      'bank_connections',
      {
        'last_sync_status': status,
        'last_sync_error': status == 'ok' ? null : error,
      },
      where: 'user_institution_id = ?',
      whereArgs: [userInstitutionId],
    );
  }

  // ───────────── Institution cache ─────────────

  /// Long-lived `institution_id → (name, logo)` cache. Updated on every
  /// successful member resolution. Never wiped, so orphan transactions
  /// keep their bank label after the live connection is removed.
  Future<void> upsertInstitutionCache({
    required String institutionId,
    required String name,
    String? logo,
  }) async {
    final db = await _dbHelper.database;
    final existing = await db.query(
      'institutions_cache',
      where: 'institution_id = ?',
      whereArgs: [institutionId],
      limit: 1,
    );
    final keepLogo = (logo == null || logo.isEmpty) && existing.isNotEmpty
        ? existing.first['logo'] as String?
        : logo;
    await db.insert('institutions_cache', {
      'institution_id': institutionId,
      'name': name,
      'logo': keepLogo,
      'last_seen_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> lookupInstitutionName(String institutionId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'institutions_cache',
      columns: ['name'],
      where: 'institution_id = ?',
      whereArgs: [institutionId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['name'] as String?;
  }

  // ───────────── Wipes ─────────────

  /// Member-scoped wipe used by Disconnect. Removes the connection +
  /// any Sophtron cards/transactions/financial_accounts tied to this
  /// member's institution. Manual cards untouched.
  Future<void> deleteMemberData({
    required String userId,
    required String userInstitutionId,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'bank_connections',
        columns: ['institution_id'],
        where: 'user_institution_id = ? AND user_id = ?',
        whereArgs: [userInstitutionId, userId],
        limit: 1,
      );
      final instId = rows.isEmpty
          ? null
          : (rows.first['institution_id'] as String?);
      if (instId != null) {
        await _wipeCardsByInstitutionId(txn, userId, instId);
      }
      await txn.delete(
        'bank_connections',
        where: 'user_institution_id = ? AND user_id = ?',
        whereArgs: [userInstitutionId, userId],
      );
    });
  }

  /// Powers the orphan-section "Remove cards" CTA — same wipe shape as
  /// [deleteMemberData] but keyed by institution_id and without
  /// the Sophtron API call.
  Future<int> deleteOrphanCardsByInstitution({
    required String userId,
    required String institutionId,
  }) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      return _wipeCardsByInstitutionId(txn, userId, institutionId);
    });
  }

  /// Shared body of the institution-scoped wipe. Returns the number of
  /// transactions deleted.
  ///
  /// Deliberately does NOT touch `card_overrides`. The design intent at
  /// [DatabaseHelper] is that overrides — the user's saved credit limit,
  /// Identify-Card pick, and custom rename — survive every sync-side
  /// wipe and re-attach the moment a card with the same stable id is
  /// re-inserted (the per-institution rebuild path is the main consumer
  /// of this and *will* re-insert the cards in the same transaction).
  /// Wiping overrides here would lose user-entered state on every sync
  /// of the institution, which is exactly the bug we're keeping shut.
  ///
  /// Dead `card_overrides` rows (the user disconnects the bank
  /// permanently and never re-adds) accumulate as a tiny per-card leak.
  /// Acceptable for now: the row is ~5 columns of text, the override is
  /// ready to re-attach if the user changes their mind, and explicit
  /// cleanup belongs to a dedicated "forget this card" path, not the
  /// sync's blanket wipe.
  ///
  /// [demoteManualOrigin] (only passed by [dropMissingInstitutions], the
  /// automatic "Sophtron stopped returning this connection" path) spares
  /// `originated_manual` cards — a manual card the user added, later
  /// merged into this bank link — by flipping them back to
  /// `source = 'manual'` (and `institution_id` to that issuer's
  /// [CardRepository.manualInstitutionId], so it groups into the same
  /// "Issuer (Manual)" Cards-screen section a fresh manual add would)
  /// instead of deleting them, and by excluding them from the transaction
  /// wipe below. The card `id` is left unchanged, so
  /// `card_overrides`, `card_links`, and `transactions` (none of which FK
  /// on `cards.id`) all stay attached with no migration needed. If the
  /// same bank+card links again later, [rebuildInstitution]'s
  /// `ConflictAlgorithm.replace` insert naturally flips it back to
  /// `source = 'bank'` with fresh data. Explicit user removal
  /// ([deleteMemberData] Disconnect, [deleteOrphanCardsByInstitution]
  /// "Remove cards") deliberately does NOT demote — the user asked for
  /// the card gone.
  Future<int> _wipeCardsByInstitutionId(
    Transaction txn,
    String userId,
    String institutionId, {
    bool deleteTransactions = true,
    bool demoteManualOrigin = false,
  }) async {
    final prefix = 'bank:$institutionId:';
    if (demoteManualOrigin) {
      // Per-row (not a blanket UPDATE): each demoted card needs its own
      // provider's `manualInstitutionId` so it lands in that issuer's
      // "<Issuer> (Manual)" Cards-screen section — the same grouping a
      // fresh manual add gets — instead of the flat legacy "Manual" bucket.
      final toDemote = await txn.query(
        'cards',
        columns: ['id', 'provider'],
        where:
            "user_id = ? AND source = 'bank' AND id LIKE ? "
            "AND originated_manual = 1",
        whereArgs: [userId, '$prefix%'],
      );
      for (final row in toDemote) {
        await txn.update(
          'cards',
          {
            'source': 'manual',
            'institution_id': CardRepository.manualInstitutionId(
              (row['provider'] as String?) ?? '',
            ),
          },
          where: 'user_id = ? AND id = ?',
          whereArgs: [userId, row['id']],
        );
      }
    }
    // [rebuildInstitution] passes deleteTransactions:false and instead does a
    // *date-bounded*, per-card transaction delete (freezing rows older than
    // what the latest scrape returned) so history isn't truncated to the
    // issuer window each sync. Other callers (full institution removal) wipe
    // everything except rows just demoted to manual above. Safe to
    // delete/replace cards without losing transactions: `transactions.card_id`
    // has no FK, so the card replace never cascades.
    final txDeleted = deleteTransactions
        ? await txn.rawDelete(
            "DELETE FROM transactions WHERE user_id = ? AND card_id LIKE ? "
            "AND card_id NOT IN "
            "(SELECT id FROM cards WHERE user_id = ? AND source = 'manual' "
            "AND originated_manual = 1)",
            [userId, '$prefix%', userId],
          )
        : 0;
    await txn.rawDelete(
      "DELETE FROM financial_accounts WHERE user_id = ? "
      "AND linked_card_id LIKE ?",
      [userId, '$prefix%'],
    );
    await txn.rawDelete(
      "DELETE FROM cards WHERE user_id = ? AND source = 'bank' "
      "AND id LIKE ?",
      [userId, '$prefix%'],
    );
    return txDeleted;
  }

  /// After a Sophtron sync, collapses any `source='manual'` rows the
  /// user added before linking that match the same physical card
  /// (provider + last_four). Moves any override row to the Sophtron id,
  /// migrates the manual `card_links` catalog binding onto it (unless the
  /// bank card already has its own), flags the bank card as
  /// `originated_manual` (read by [dropMissingInstitutions]), then deletes
  /// the manual row.
  Future<int> mergeManualCardsWithBank({
    required String userId,
    required String institutionName,
  }) async {
    final db = await _dbHelper.database;
    final cleanProvider = smartCase(institutionName);
    if (cleanProvider == null || cleanProvider.isEmpty) return 0;
    var merged = 0;
    await db.transaction((txn) async {
      final manualRows = await txn.query(
        'cards',
        where:
            "user_id = ? AND source = 'manual' AND provider = ? "
            "AND last_four IS NOT NULL",
        whereArgs: [userId, cleanProvider],
      );
      for (final m in manualRows) {
        final lf = m['last_four'] as String?;
        if (lf == null || lf.isEmpty) continue;
        final bankMatches = await txn.query(
          'cards',
          where:
              "user_id = ? AND source = 'bank' AND provider = ? "
              "AND last_four = ?",
          whereArgs: [userId, cleanProvider, lf],
          limit: 1,
        );
        if (bankMatches.isEmpty) continue;
        final bankCardId = bankMatches.first['id'] as String;
        final manualCardId = m['id'] as String;
        await txn.rawInsert(
          '''
          INSERT OR IGNORE INTO card_overrides
            (card_id, user_id, manual_credit_limit, custom_name,
             product_identification, identification_source, due_day, updated_at)
          SELECT ?, user_id, manual_credit_limit, custom_name,
                 product_identification, identification_source, due_day, updated_at
          FROM card_overrides
          WHERE card_id = ? AND user_id = ?
          ''',
          [bankCardId, manualCardId, userId],
        );
        await txn.delete(
          'card_overrides',
          where: 'card_id = ? AND user_id = ?',
          whereArgs: [manualCardId, userId],
        );
        // Move the catalog product binding over unless the bank card
        // already resolved its own (e.g. a BIN-based auto-identification
        // that raced the merge) — that binding is left as the more
        // authoritative one, and the manual link is just dropped.
        final bankHasLink = await txn.query(
          'card_links',
          columns: ['card_id'],
          where: 'user_id = ? AND card_id = ?',
          whereArgs: [userId, bankCardId],
          limit: 1,
        );
        if (bankHasLink.isEmpty) {
          await txn.update(
            'card_links',
            {'card_id': bankCardId},
            where: 'user_id = ? AND card_id = ?',
            whereArgs: [userId, manualCardId],
          );
        } else {
          await txn.delete(
            'card_links',
            where: 'user_id = ? AND card_id = ?',
            whereArgs: [userId, manualCardId],
          );
        }
        await txn.update(
          'cards',
          {'originated_manual': 1},
          where: 'id = ? AND user_id = ?',
          whereArgs: [bankCardId, userId],
        );
        await txn.delete(
          'cards',
          where: 'id = ? AND user_id = ?',
          whereArgs: [manualCardId, userId],
        );
        merged++;
      }
    });
    return merged;
  }

  /// Local-only prune of Sophtron-sourced deposit data. Invoked when the
  /// user flips "Include debit accounts" OFF so the UI reflects the
  /// change without waiting for the next sync round-trip.
  Future<void> pruneDebitBankData(String userId) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final debitCards = await txn.query(
        'cards',
        columns: ['id'],
        where:
            "user_id = ? AND source = 'bank' "
            "AND account_type IS NOT NULL "
            "AND account_type != 'Credit_Card'",
        whereArgs: [userId],
      );
      if (debitCards.isEmpty) return;
      final ids = debitCards.map((c) => c['id'] as String).toList();
      final placeholders = List.filled(ids.length, '?').join(',');
      await txn.rawDelete(
        'DELETE FROM transactions WHERE user_id = ? AND card_id IN ($placeholders)',
        [userId, ...ids],
      );
      await txn.rawDelete(
        'DELETE FROM financial_accounts WHERE user_id = ? '
        'AND linked_card_id IN ($placeholders)',
        [userId, ...ids],
      );
      await txn.rawDelete(
        'DELETE FROM cards WHERE user_id = ? AND id IN ($placeholders)',
        [userId, ...ids],
      );
    });
  }

  /// Global reset of Sophtron-sourced data. Retained for the logout /
  /// disconnect-all path. Sync no longer uses it — see
  /// [rebuildInstitution] for the per-institution staging that
  /// replaces the pre-fanout wipe.
  Future<void> replaceBankData(String userId) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      await txn.rawDelete(
        "DELETE FROM transactions WHERE user_id = ? AND card_id LIKE 'bank:%'",
        [userId],
      );
      await txn.rawDelete(
        "DELETE FROM financial_accounts WHERE user_id = ? AND linked_card_id LIKE 'bank:%'",
        [userId],
      );
      await txn.delete(
        'cards',
        where: "user_id = ? AND source = 'bank'",
        whereArgs: [userId],
      );
      await txn.delete(
        'bank_connections',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
    });
  }

  /// Connections younger than this aren't eligible to be dropped by
  /// [dropMissingInstitutions], even if they're absent from the
  /// supplied `keepInstitutionIds`. Closes the race between
  /// `add_bank_v2_screen` inserting a connection row at link time and
  /// Sophtron's `getMembersV2` reflecting the new MemberID in the
  /// customer's members list (eventual consistency, observed up to a few
  /// minutes after `createMember` succeeds). Without the grace window,
  /// a sync that ran in this race interval would wipe the freshly-added
  /// bank wholesale.
  static const Duration dropMissingGracePeriod = Duration(minutes: 10);

  /// Drops `bank_connections` rows whose `institution_id` isn't in
  /// the supplied set, along with their cards/transactions. Called at
  /// the end of a successful sync to clean up banks the user removed
  /// server-side.
  ///
  /// Connections younger than [dropMissingGracePeriod] are skipped —
  /// they might be a just-linked bank whose MemberID hasn't yet
  /// propagated to Sophtron's customer/members view. They become
  /// eligible on the next sync after they age out; if still missing
  /// then, they're genuinely gone server-side.
  Future<void> dropMissingInstitutions({
    required String userId,
    required Set<String> keepInstitutionIds,
    required Set<String> keepMemberIds,
    DateTime? now,
  }) async {
    final db = await _dbHelper.database;
    final cutoffMs = (now ?? DateTime.now())
        .subtract(dropMissingGracePeriod)
        .millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'bank_connections',
        columns: ['user_institution_id', 'institution_id', 'created_at'],
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      for (final r in rows) {
        final mid = r['user_institution_id'] as String?;
        final iid = r['institution_id'] as String?;
        if (mid == null) continue;

        // Skip rows still inside the grace window. `created_at` is
        // populated by `CURRENT_TIMESTAMP`; parse to ms-epoch and
        // compare. Unparsable / null timestamps are treated as "too
        // young to drop" — better to leak a stale row than wipe a real
        // freshly-linked one.
        final createdRaw = r['created_at'] as String?;
        if (createdRaw == null) continue;
        final created = DateTime.tryParse(createdRaw);
        if (created != null && created.millisecondsSinceEpoch > cutoffMs) {
          continue;
        }

        // If the member ID is in keepMemberIds, keep the connection.
        if (keepMemberIds.contains(mid)) {
          continue;
        }

        // Otherwise, this member is no longer present on Sophtron.
        // Delete the connection locally.
        await txn.delete(
          'bank_connections',
          where: 'user_institution_id = ? AND user_id = ?',
          whereArgs: [mid, userId],
        );

        // Wipe cards and transactions only if the institution itself has no other active connection being kept.
        // `demoteManualOrigin: true` — this path is Sophtron no longer
        // returning the connection, not the user asking to remove it, so a
        // card that started manual and got merged into this link falls
        // back to `source='manual'` instead of disappearing.
        if (iid != null && !keepInstitutionIds.contains(iid)) {
          await _wipeCardsByInstitutionId(
            txn,
            userId,
            iid,
            demoteManualOrigin: true,
          );
        }
      }
    });
  }

  // ───────────── Per-institution atomic rebuild ─────────────

  /// Per-institution transactional rebuild. Wipes every existing row
  /// belonging to [institutionId], then writes the supplied accounts and
  /// per-account transaction lists, all inside a single SQLite transaction.
  /// A failure rolls back this institution only; other banks remain untouched.
  ///
  /// Consumes neutral [BankAccount] / [BankTransaction] records produced by
  /// [BankFdxMapper] — this method has no FDX field-name knowledge, so a future
  /// aggregator swap only touches the mapper. `institutionId` is supplied by the
  /// caller (from the connection row), not read from the account payload.
  Future<({int cardCount, int txCount})> rebuildInstitution({
    required String userId,
    required String institutionId,
    required String? institutionName,
    required String? institutionLogo,
    required List<BankAccount> accounts,
    required Map<String, List<BankTransaction>> txsByAccountId,
    BrandResolver? brandResolver,
  }) async {
    final db = await _dbHelper.database;
    final displayBank = smartCase(institutionName);
    var cardCount = 0;
    var txCount = 0;
    await db.transaction((txn) async {
      // Snapshot the existing card ids BEFORE the wipe below — it deletes the
      // rows we need to recognise a renamed account against. Keyed by last four,
      // and only where that key is unambiguous (see _existingCardIdForRename).
      final priorIdByLastFour = await _cardIdsByLastFour(
        txn,
        userId: userId,
        institutionId: institutionId,
      );

      // Wipe cards + accounts wholesale (replaced below), but NOT transactions:
      // those are deleted per-card and date-bounded inside the loop so the
      // archive of rows older than this scrape's returned window is preserved.
      await _wipeCardsByInstitutionId(
        txn,
        userId,
        institutionId,
        deleteTransactions: false,
      );
      final batch = txn.batch();
      for (final acct in accounts) {
        final type = acct.accountType;
        if (type == null) continue;
        final aid = acct.accountId;
        if (aid.isEmpty) continue;

        final lastFour = lastFourFromAccountNumber(acct.accountNumberDisplay);
        final rawAccountName = acct.nickname;
        final cardName = bankDisplayName(
          rawAccountName: rawAccountName,
          institutionName: institutionName,
        );
        final accountSlug = slugForAccount(
          rawAccountName: rawAccountName,
          rawAccountId: aid,
        );
        final derivedId = stableCardId(
          institutionId: institutionId,
          lastFour: lastFour,
          accountSlug: accountSlug,
        );
        // An issuer renaming an account must NOT mint a second card. `accountSlug`
        // is derived from the Sophtron AccountName, so when Discover relabelled
        // "Discover it Card" -> "Discover Card" the id changed from
        // `bank:<inst>:2501:discoveritcard` to `…:discovercard`: the rebuild wrote the
        // new row, the old row's transactions stayed behind under the old id, and the
        // orphan-recovery read resurrected them as a SECOND card in the wallet.
        // Re-key onto the existing card when this institution already has exactly one
        // card with the same last four. Exactly-one is the safety condition — two real
        // cards can share a last four at one issuer, and merging those would be worse
        // than the duplicate.
        final stableId =
            await _reuseRenamedCardId(
              txn,
              userId: userId,
              priorIdByLastFour: priorIdByLastFour,
              lastFour: lastFour,
              derivedId: derivedId,
            ) ??
            derivedId;

        batch.insert('cards', {
          'id': stableId,
          'user_id': userId,
          'source': 'bank',
          'provider': displayBank,
          'name': cardName,
          'last_four': lastFour,
          'account_slug': accountSlug,
          'institution_id': institutionId,
          // FDX V3 doesn't return card network or a sub-type.
          'network': null,
          'image_url': null,
          'institution_logo': institutionLogo,
          'account_type': type,
          'sub_type': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        cardCount++;

        final balance = acct.currentBalance;
        final available = acct.availableBalance;
        // FDX V3 credit cards return no credit limit; derive headroom when
        // both balance and available are present, else null (manual override
        // fills it in the UI).
        final limit =
            (type == 'Credit_Card' && balance != null && available != null)
            ? balance.abs() + available
            : null;
        batch.insert('financial_accounts', {
          'id': stableId,
          'user_id': userId,
          'linked_card_id': stableId,
          'bank_name': institutionName,
          'mask': lastFour,
          'balance_available': available,
          'balance_current': balance,
          'balance_limit': limit,
          'raw_json': jsonEncode(acct.raw),
          'synced_at': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        final accountCurrency = acct.currency;
        final txs = txsByAccountId[aid] ?? const <BankTransaction>[];
        // Date-bounded rebuild: delete only this card's transactions at or
        // newer than the oldest row this scrape returned, then re-insert the
        // returned set below. Rows older than the returned window are frozen
        // (a permanent local archive), so history isn't lost when the issuer
        // serves a shorter window or a light refresh runs. If the scrape
        // returned nothing for this card, delete nothing (preserve archive).
        DateTime? minPosted;
        for (final t in txs) {
          final p = t.postedAt;
          if (p != null && (minPosted == null || p.isBefore(minPosted))) {
            minPosted = p;
          }
        }
        if (minPosted != null) {
          await txn.rawDelete(
            "DELETE FROM transactions WHERE user_id = ? AND card_id = ? "
            "AND posted_at >= ?",
            [userId, stableId, minPosted.toIso8601String()],
          );
        }
        for (final t in txs) {
          final amount = t.amount?.abs();
          final description = t.description;
          final date = t.date?.toIso8601String();
          final stableTxId = transactionStableId(
            stableCardId: stableId,
            date: date,
            amount: amount,
            description: description,
          );
          // Bank-supplied FDX category is authoritative; the classifier only
          // tags brand_id and fills category when the bank left it empty.
          // FDX has no separate merchant field — classify off description.
          String? category = t.category;
          final isDebit = t.type == 'DEBIT';
          String? brandId;
          // Canonical bucket for the engine + category insights. Always set
          // for debits via the classifier, independent of the bank's display
          // `category`, and stored as the enum `.name` so it matches the
          // catalog's `reward_rules.category`.
          String? rewardCategory;
          if (isDebit && description != null && description.isNotEmpty) {
            final hit = classifyLabel(description);
            var resolved = hit.category;
            // Cascade rung: when the merchant description doesn't classify,
            // fall back to the bank's own free-text category (e.g.
            // "Food & Drink" → dining) by running it through the same
            // keyword pass. The bank category is a *hint*, not a dependency:
            // if it's absent or unrecognized we keep `other`.
            if (resolved == RewardCategory.other &&
                t.category != null &&
                t.category!.isNotEmpty) {
              final bankHit = classifyLabel(t.category!);
              if (bankHit.category != RewardCategory.other) {
                resolved = bankHit.category;
              }
            }
            rewardCategory = resolved.name;
            if ((category == null || category.isEmpty) &&
                resolved != RewardCategory.other) {
              category = resolved.label;
            }
            brandId = hit.brandId ?? brandResolver?.resolve(description);
          }
          batch.insert('transactions', {
            'id': stableTxId,
            'user_id': userId,
            'posted_at': t.postedAt?.toIso8601String(),
            'created_at': date,
            'name': description,
            // No FDX merchant field; display falls back to name/description.
            'merchant': description,
            'category': category,
            'reward_category': rewardCategory,
            'category_id': null,
            'brand_id': brandId,
            'type': t.type,
            'amount': amount,
            // FDX transactions carry no currency; use the account's.
            'currency': accountCurrency,
            'rewards_earned': null,
            'reward_multiplier': null,
            'card': cardName,
            'card_id': stableId,
            'card_last_four': lastFour,
            'status': t.status ?? 'POSTED',
            'raw_json': jsonEncode(t.raw),
            'last_seen_at': DateTime.now().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          txCount++;
        }
      }
      await batch.commit(noResult: true);
    });
    return (cardCount: cardCount, txCount: txCount);
  }

  // ───────────── Static helpers ─────────────

  /// Deterministic card identifier.
  /// `bank:<institutionId>:<lastFour>:<accountSlug>` — accountSlug
  /// disambiguates the joint-card / shared-last-four case.
  /// `last_four -> card id` for this institution's CURRENT cards, keeping only
  /// unambiguous keys.
  ///
  /// Must be called BEFORE the wholesale card wipe in [rebuildInstitution] —
  /// after it, the rows this reads are already gone. A last four shared by two
  /// cards at one issuer is dropped from the map: merging distinct cards would
  /// destroy real data, which is strictly worse than the duplicate this fixes.
  Future<Map<String, String>> _cardIdsByLastFour(
    Transaction txn, {
    required String userId,
    required String institutionId,
  }) async {
    final rows = await txn.query(
      'cards',
      columns: ['id', 'last_four'],
      where: 'user_id = ? AND institution_id = ?',
      whereArgs: [userId, institutionId],
    );
    final byLastFour = <String, List<String>>{};
    for (final r in rows) {
      final last = r['last_four'] as String?;
      if (last == null || last.isEmpty) continue;
      byLastFour.putIfAbsent(last, () => []).add(r['id'] as String);
    }
    return {
      for (final e in byLastFour.entries)
        if (e.value.length == 1) e.key: e.value.single,
    };
  }

  /// The surviving id for a card whose account the issuer renamed, or null when
  /// there is nothing to re-key (no prior card, ambiguous last four, or the id
  /// is unchanged — the normal path).
  ///
  /// `accountSlug` is derived from the Sophtron AccountName, so a relabel changes
  /// `stableCardId` and the rebuild would write a SECOND card while the old one's
  /// transactions stayed behind — which the orphan-recovery read then resurrects
  /// as a duplicate wallet entry. Observed live: Discover renaming
  /// "Discover it Card" to "Discover Card".
  ///
  /// Also re-points the old rows so history follows the surviving id.
  Future<String?> _reuseRenamedCardId(
    Transaction txn, {
    required String userId,
    required Map<String, String> priorIdByLastFour,
    required String? lastFour,
    required String derivedId,
  }) async {
    if (lastFour == null || lastFour.isEmpty) return null;
    final existingId = priorIdByLastFour[lastFour];
    if (existingId == null || existingId == derivedId) return null;
    Log.i(
      'bank-write',
      'account renamed: re-keying $derivedId onto existing $existingId',
    );
    // Only `transactions` needs re-pointing. `financial_accounts` is wiped and
    // re-inserted wholesale by this same rebuild (and keys the card as
    // `linked_card_id`, not `card_id`), so it lands on the merged id by itself.
    await txn.update(
      'transactions',
      {'card_id': existingId},
      where: 'user_id = ? AND card_id = ?',
      whereArgs: [userId, derivedId],
    );
    return existingId;
  }

  static String stableCardId({
    required String institutionId,
    required String? lastFour,
    required String? accountSlug,
  }) {
    final last = (lastFour == null || lastFour.isEmpty) ? '----' : lastFour;
    final slug = (accountSlug == null || accountSlug.isEmpty)
        ? 'na'
        : accountSlug;
    return 'bank:$institutionId:$last:$slug';
  }

  /// Slugifies a Sophtron AccountName / AccountID into an opaque-but-
  /// stable token suitable for use inside [stableCardId].
  static String slugForAccount({
    required String? rawAccountName,
    required String? rawAccountId,
  }) {
    String? clean(String? s) {
      if (s == null) return null;
      final t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
      if (t.isEmpty) return null;
      return t.length > 16 ? t.substring(0, 16) : t;
    }

    return clean(rawAccountName) ?? clean(rawAccountId) ?? 'na';
  }

  /// Display name for a Sophtron account. Fallback when AccountName is
  /// missing is "{Bank} Card" rather than the raw "Credit_Card" type.
  static String bankDisplayName({
    required String? rawAccountName,
    required String? institutionName,
  }) {
    final trimmed = rawAccountName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return smartCase(trimmed)!;
    }
    final bank = smartCase(institutionName);
    return '${(bank == null || bank.isEmpty) ? 'Bank' : bank} Card';
  }

  /// Stable composite transaction id. Normalized description hash +
  /// integer-cents amount so re-syncs collapse correctly.
  static String transactionStableId({
    required String stableCardId,
    required String? date,
    required double? amount,
    required String? description,
  }) {
    final d = (date ?? '').trim();
    final cents = (amount == null)
        ? '0'
        : (amount.abs() * 100).round().toString();
    final norm = (description ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final descHash = sha1
        .convert(utf8.encode(norm))
        .toString()
        .substring(0, 10);
    return '$stableCardId:$d:$cents:$descHash';
  }

  /// Recomputes the leading `stableCardId` segment of a transaction id
  /// so merged orphans encode their new owner.
  static String rewriteTransactionIdPrefix({
    required String existingTxId,
    required String oldStableCardId,
    required String newStableCardId,
  }) {
    if (!existingTxId.startsWith('$oldStableCardId:')) return existingTxId;
    return '$newStableCardId${existingTxId.substring(oldStableCardId.length)}';
  }

  /// Extracts the `institution_id` segment from a Sophtron stable card
  /// id of the shape `bank:<institution_id>:<last_four>:<slug>`.
  static String? institutionIdFromStableId(String cardId) {
    if (!cardId.startsWith('bank:')) return null;
    final parts = cardId.split(':');
    if (parts.length < 3) return null;
    final id = parts[1].trim();
    if (id.isEmpty) return null;
    return id;
  }

  /// Strips Sophtron's account-number formatting down to the trailing
  /// four digits. Public so the sync engine can compute stable IDs the
  /// same way the persistence layer does.
  static String? lastFourFromAccountNumber(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return digits.length <= 4 ? digits : digits.substring(digits.length - 4);
  }

  /// Title-cases an ALL-CAPS string ("DISCOVER IT CARD" → "Discover It
  /// Card", "US BANK" → "US Bank"). Mixed-case inputs pass through
  /// untouched. Words ≤2 letters stay uppercase to preserve common
  /// acronyms.
  static String? smartCase(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return s;
    if (s != s.toUpperCase()) return s;
    return s
        .split(RegExp(r'\s+'))
        .map((w) {
          if (w.isEmpty) return w;
          if (w.length <= 2) return w;
          return w[0].toUpperCase() + w.substring(1).toLowerCase();
        })
        .join(' ');
  }
}
