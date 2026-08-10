import 'package:sqflite/sqflite.dart';

import '../models/card.dart';
import '../util/logger.dart';
import 'database_helper.dart';
import 'bank_write_repository.dart';
import 'types.dart';

enum ManualCardAddStatus { added, alreadyInWallet }

class ManualCardAddResult {
  const ManualCardAddResult.added(String this.cardId)
    : status = ManualCardAddStatus.added;
  const ManualCardAddResult.alreadyInWallet()
    : status = ManualCardAddStatus.alreadyInWallet,
      cardId = null;

  final ManualCardAddStatus status;
  final String? cardId;
}

/// Owns the user-facing card surface: the `cards` row aggregation, the
/// `card_overrides` upsert path, perks, and the orphan-recovery reads
/// the reconciliation sheet drives.
///
/// SQL stays here; the BankWriteRepository owns the Sophtron-write
/// path (different concern — that one wipes/rebuilds at sync time). The
/// two cross-call via static helpers (`BankWriteRepository
/// .institutionIdFromStableId`, etc.) so the orphan-detection logic
/// doesn't need to know how the stable id is shaped.
class CardRepository {
  CardRepository(this._dbHelper);
  final DatabaseHelper _dbHelper;

  // Sentinels for the override upsert: passing them means "don't change
  // this column," distinguishing from `null` which means "clear it."
  // Compared by `identical` so any other instance still acts as a real
  // write.
  static const Object _keepExistingString = Object();
  static const Object _keepExistingNum = Object();
  static const Object _keepExistingInt = Object();

  /// Exposed for callers (sync engine, providers) that need to use the
  /// sentinels via `CardRepository.keepExisting*`.
  static const Object keepExistingString = _keepExistingString;
  static const Object keepExistingNum = _keepExistingNum;
  static const Object keepExistingInt = _keepExistingInt;

  Future<List<CardSummary>> queryAllCards(String userId) async {
    final db = await _dbHelper.database;

    // Live balances/limits per linked card. Sophtron may omit limits
    // (Discover often does) — falls back to local derivation.
    final faRows = await db.query(
      'financial_accounts',
      where: 'user_id = ? AND linked_card_id IS NOT NULL',
      whereArgs: [userId],
    );
    final faByCardId = {
      for (final r in faRows) r['linked_card_id'] as String: r,
    };

    // LEFT JOIN `card_overrides` so the user's manual limit / rename /
    // identification flow through.
    final cardRows = await db.rawQuery(
      '''
      SELECT
        cards.*,
        card_overrides.manual_credit_limit       AS o_manual_credit_limit,
        card_overrides.custom_name               AS o_custom_name,
        card_overrides.product_identification    AS o_product_identification,
        card_overrides.identification_source     AS o_identification_source,
        card_overrides.due_day                   AS o_due_day,
        card_overrides.reminder_enabled          AS o_reminder_enabled,
        card_overrides.reminder_lead_days        AS o_reminder_lead_days
      FROM cards
      LEFT JOIN card_overrides
        ON card_overrides.card_id = cards.id
       AND card_overrides.user_id = cards.user_id
      WHERE cards.user_id = ?
      ''',
      [userId],
    );

    // Per-card transaction aggregation, keyed by stable `card_id`.
    final derivedRows = await db.rawQuery(
      '''
      SELECT
        transactions.card_id AS card_id,
        COUNT(*) AS tx_count,
        SUM(CASE WHEN type = 'DEBIT' THEN amount ELSE 0 END) -
        SUM(CASE WHEN type = 'CREDIT' THEN amount ELSE 0 END) AS balance,
        MAX(COALESCE(posted_at, created_at)) AS last_used_at,
        MAX(transactions.card) AS last_card_name,
        MAX(transactions.card_last_four) AS last_card_last_four
      FROM transactions
      WHERE transactions.user_id = ? AND transactions.card_id IS NOT NULL
      GROUP BY transactions.card_id
      ''',
      [userId],
    );

    final derivedByCardId = {
      for (var d in derivedRows) d['card_id'] as String: d,
    };

    // Long-lived institution cache: keeps orphan transactions labelled
    // with their bank name even after the live connection is removed.
    final cacheRows = await db.query(
      'institutions_cache',
      columns: ['institution_id', 'name', 'logo'],
    );
    final institutionsCache = {
      for (final r in cacheRows)
        r['institution_id'] as String: (
          name: r['name'] as String,
          logo: r['logo'] as String?,
        ),
    };

    final consumed = <String>{};
    final result = <CardSummary>[];

    for (var m in cardRows) {
      final cardId = m['id'] as String;
      final d = derivedByCardId[cardId];
      if (d != null) consumed.add(cardId);
      final img = m['image_url'] as String?;
      if (img != null) {
        Log.d('repo', 'UI loading image for ${m['name']}: $img');
      }
      final fa = faByCardId[cardId];
      final manualCreditLimit = (m['o_manual_credit_limit'] as num?)
          ?.toDouble();
      final localBalance = (d?['balance'] as num?)?.toDouble() ?? 0.0;
      final liveLimit = (fa?['balance_limit'] as num?)?.toDouble();
      final liveCurrent = (fa?['balance_current'] as num?)?.toDouble();
      final liveAvailable = (fa?['balance_available'] as num?)?.toDouble();
      final lastUsedRaw = d?['last_used_at'] as String?;
      // User-entered manual limit takes precedence; drop the live
      // available headroom too when manual is in effect so the cards
      // screen derives `available = limit - balance` consistently.
      final usingManualLimit = manualCreditLimit != null;
      final effectiveLimit = manualCreditLimit ?? liveLimit;
      final effectiveAvailable = usingManualLimit ? null : liveAvailable;
      result.add(
        CardSummary(
          cardId: cardId,
          source: m['source'] as String,
          provider: m['provider'] as String?,
          name: m['name'] as String,
          customName: m['o_custom_name'] as String?,
          productIdentification: m['o_product_identification'] as String?,
          identificationSource: m['o_identification_source'] as String?,
          lastFour: m['last_four'] as String?,
          institutionId: m['institution_id'] as String?,
          network: m['network'] as String?,
          creditLimit: effectiveLimit,
          creditAvailable: effectiveAvailable,
          txCount: (d?['tx_count'] as int?) ?? 0,
          balance: liveCurrent ?? localBalance,
          imageUrl: img,
          institutionLogo: m['institution_logo'] as String?,
          dueDay: (m['o_due_day'] as num?)?.toInt(),
          reminderEnabled: m['o_reminder_enabled'] == null
              ? null
              : (m['o_reminder_enabled'] as num) != 0,
          reminderLeadDays: (m['o_reminder_lead_days'] as num?)?.toInt(),
          lastUsedAt: lastUsedRaw == null
              ? null
              : DateTime.tryParse(lastUsedRaw),
          accountType: m['account_type'] as String?,
        ),
      );
    }

    for (final entry in derivedByCardId.entries) {
      final cardId = entry.key;
      if (consumed.contains(cardId)) continue;
      final d = entry.value;
      // Orphan transactions: their `card_id` no longer points to any
      // row in `cards`. Surface them as a synthetic group so the user
      // can still see + clean them up via the orphan bank section.
      final orphanInstitutionId = BankWriteRepository.institutionIdFromStableId(
        cardId,
      );
      final cached = orphanInstitutionId == null
          ? null
          : institutionsCache[orphanInstitutionId];
      Log.w(
        'repo',
        'orphan card from tx: card_id=$cardId '
            'institution_id=$orphanInstitutionId tx_count=${d['tx_count']}',
      );
      final fa = faByCardId[cardId];
      final liveLimit = (fa?['balance_limit'] as num?)?.toDouble();
      final liveCurrent = (fa?['balance_current'] as num?)?.toDouble();
      final liveAvailable = (fa?['balance_available'] as num?)?.toDouble();
      final lastUsedRaw = d['last_used_at'] as String?;
      result.add(
        CardSummary(
          cardId: cardId,
          source: 'reward-seed',
          provider: cached?.name ?? 'Previous link',
          name: (d['last_card_name'] as String?) ?? 'Card',
          lastFour: d['last_card_last_four'] as String?,
          institutionId: orphanInstitutionId,
          txCount: d['tx_count'] as int,
          balance: liveCurrent ?? (d['balance'] as num?)?.toDouble() ?? 0.0,
          creditLimit: liveLimit,
          creditAvailable: liveAvailable,
          imageUrl: null,
          institutionLogo: cached?.logo,
          lastUsedAt: lastUsedRaw == null
              ? null
              : DateTime.tryParse(lastUsedRaw),
          accountType: 'Credit_Card',
        ),
      );
    }

    result.sort((a, b) => b.balance.compareTo(a.balance));
    return result;
  }

  Future<int> deleteManualCard(String userId, String cardId) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'cards',
      where: 'user_id = ? AND id = ? AND source = ?',
      whereArgs: [userId, cardId, 'manual'],
    );
  }

  /// Creates a catalog-backed manual card and its reward-engine link in one
  /// transaction. A product can appear once in a wallet; adding it again
  /// returns [ManualCardAddStatus.alreadyInWallet] for the result screen.
  ///
  /// [institutionLogo] is the picked institution's logo (Sophtron search /
  /// popular-banks result), stored on the card row purely for display — the
  /// Cards screen groups manual cards under a synthetic
  /// [manualInstitutionId] per issuer (e.g. "Chase (Manual)"), separate from
  /// any live bank connection for the same issuer, and shows this logo in
  /// that group's header.
  Future<ManualCardAddResult> addManualCard({
    required String userId,
    required String productId,
    required String issuer,
    required String name,
    required String? network,
    required String? imageUrl,
    String? lastFour,
    double? creditLimit,
    int? dueDay,
    String? institutionLogo,
  }) async {
    final db = await _dbHelper.database;
    final cardId = 'manual:$productId';
    return db.transaction((txn) async {
      final existingLink = await txn.query(
        'card_links',
        columns: ['card_id'],
        where: 'user_id = ? AND card_product_id = ?',
        whereArgs: [userId, productId],
        limit: 1,
      );
      if (existingLink.isNotEmpty) {
        return const ManualCardAddResult.alreadyInWallet();
      }

      final existingCard = await txn.query(
        'cards',
        columns: ['id'],
        where: 'user_id = ? AND id = ?',
        whereArgs: [userId, cardId],
        limit: 1,
      );
      if (existingCard.isNotEmpty) {
        return const ManualCardAddResult.alreadyInWallet();
      }

      await txn.insert('cards', {
        'id': cardId,
        'user_id': userId,
        'source': 'manual',
        'provider': issuer,
        'name': name,
        'last_four': lastFour,
        'network': network,
        'image_url': imageUrl,
        'institution_id': manualInstitutionId(issuer),
        'institution_logo': institutionLogo,
        'account_type': 'Credit_Card',
      });
      await txn.insert('card_overrides', {
        'card_id': cardId,
        'user_id': userId,
        'manual_credit_limit': creditLimit,
        'due_day': dueDay,
        'updated_at': DateTime.now().toIso8601String(),
      });
      await txn.insert('card_links', {
        'user_id': userId,
        'card_id': cardId,
        'card_product_id': productId,
        'source': 'manual',
      });
      return ManualCardAddResult.added(cardId);
    });
  }

  /// Universal rename. `null` clears the override and reverts to the
  /// canonical synced name.
  Future<int> setCustomName(
    String userId,
    String cardId,
    String? customName,
  ) async {
    final trimmed = customName?.trim();
    final normalized = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    return _upsertCardOverride(
      userId: userId,
      cardId: cardId,
      customName: normalized,
      manualCreditLimit: _keepExistingNum,
      dueDay: _keepExistingInt,
      productIdentification: _keepExistingString,
      identificationSource: _keepExistingString,
    );
  }

  /// Sets (or clears, with `null`) the payment due day-of-month for **any**
  /// card, bank-linked or manual.
  ///
  /// Banks don't expose a due date over FDX, so this is the only source. It
  /// lives in `card_overrides` rather than `cards` precisely so a sync can't
  /// clobber it — the per-institution rebuild replaces `cards` wholesale.
  Future<int> setDueDay(String userId, String cardId, int? dueDay) {
    final normalized = (dueDay != null && dueDay >= 1 && dueDay <= 31)
        ? dueDay
        : null;
    return _upsertCardOverride(
      userId: userId,
      cardId: cardId,
      customName: _keepExistingString,
      manualCreditLimit: _keepExistingNum,
      dueDay: normalized,
      productIdentification: _keepExistingString,
      identificationSource: _keepExistingString,
    );
  }

  /// Per-card payment-reminder overrides. `null` on either clears it back to
  /// inheriting the global Settings value — the wireframe puts the toggle and
  /// the "how far ahead" choice on the card sheet, with Settings as the default.
  Future<int> setReminderPrefs(
    String userId,
    String cardId, {
    required bool? enabled,
    required int? leadDays,
  }) {
    final days = (leadDays != null && leadDays >= 0 && leadDays <= 31)
        ? leadDays
        : null;
    return _upsertCardOverride(
      userId: userId,
      cardId: cardId,
      customName: _keepExistingString,
      manualCreditLimit: _keepExistingNum,
      dueDay: _keepExistingInt,
      productIdentification: _keepExistingString,
      identificationSource: _keepExistingString,
      reminderEnabled: enabled == null ? null : (enabled ? 1 : 0),
      reminderLeadDays: days,
    );
  }

  /// Binds a card to an exact catalog product. `null` clears (re-identify
  /// flow). [source] tags how the binding was made.
  Future<int> setProductIdentification(
    String userId,
    String cardId,
    String? productId, {
    String source = 'user',
  }) async {
    return _upsertCardOverride(
      userId: userId,
      cardId: cardId,
      productIdentification: productId,
      identificationSource: productId == null ? null : source,
      manualCreditLimit: _keepExistingNum,
      dueDay: _keepExistingInt,
      customName: _keepExistingString,
    );
  }

  Future<int> _upsertCardOverride({
    required String userId,
    required String cardId,
    required Object? manualCreditLimit,
    required Object? dueDay,
    required Object? customName,
    required Object? productIdentification,
    required Object? identificationSource,
    Object? reminderEnabled = _keepExistingInt,
    Object? reminderLeadDays = _keepExistingInt,
  }) async {
    final db = await _dbHelper.database;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'card_overrides',
        where: 'user_id = ? AND card_id = ?',
        whereArgs: [userId, cardId],
        limit: 1,
      );
      Object? resolve(Object? incoming, Object? sentinel, String column) {
        if (identical(incoming, sentinel)) {
          return existing.isEmpty ? null : existing.first[column];
        }
        return incoming;
      }

      final row = <String, Object?>{
        'card_id': cardId,
        'user_id': userId,
        'manual_credit_limit': resolve(
          manualCreditLimit,
          _keepExistingNum,
          'manual_credit_limit',
        ),
        'due_day': resolve(dueDay, _keepExistingInt, 'due_day'),
        'reminder_enabled': resolve(
          reminderEnabled,
          _keepExistingInt,
          'reminder_enabled',
        ),
        'reminder_lead_days': resolve(
          reminderLeadDays,
          _keepExistingInt,
          'reminder_lead_days',
        ),
        'custom_name': resolve(customName, _keepExistingString, 'custom_name'),
        'product_identification': resolve(
          productIdentification,
          _keepExistingString,
          'product_identification',
        ),
        'identification_source': resolve(
          identificationSource,
          _keepExistingString,
          'identification_source',
        ),
        'updated_at': DateTime.now().toIso8601String(),
      };
      final hasContent =
          row['manual_credit_limit'] != null ||
          row['due_day'] != null ||
          row['reminder_enabled'] != null ||
          row['reminder_lead_days'] != null ||
          row['custom_name'] != null ||
          row['product_identification'] != null;
      if (!hasContent) {
        return txn.delete(
          'card_overrides',
          where: 'user_id = ? AND card_id = ?',
          whereArgs: [userId, cardId],
        );
      }
      return txn.insert(
        'card_overrides',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Sets the user-entered credit limit, creating the cards row first if
  /// it doesn't exist (orphan case).
  Future<void> updateManualCreditLimit(
    String userId,
    String cardId, {
    required double? limit,
    required String name,
    String? lastFour,
    String? provider,
    String? accountType,
  }) async {
    final db = await _dbHelper.database;
    final existing = await db.query(
      'cards',
      columns: ['id'],
      where: 'user_id = ? AND id = ?',
      whereArgs: [userId, cardId],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('cards', {
        'id': cardId,
        'user_id': userId,
        'source': 'manual',
        'provider': provider,
        'name': name,
        'last_four': lastFour,
        'account_type': accountType,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final rows = await _upsertCardOverride(
      userId: userId,
      cardId: cardId,
      manualCreditLimit: limit,
      dueDay: _keepExistingInt,
      customName: _keepExistingString,
      productIdentification: _keepExistingString,
      identificationSource: _keepExistingString,
    );
    final after = await db.rawQuery(
      '''
      SELECT cards.id, cards.name, cards.last_four, cards.source,
             card_overrides.manual_credit_limit
      FROM cards
      LEFT JOIN card_overrides
        ON card_overrides.card_id = cards.id
       AND card_overrides.user_id = cards.user_id
      WHERE cards.user_id = ? AND cards.id = ?
      ''',
      [userId, cardId],
    );
    Log.i(
      'repo',
      'limit-edit: cardId=$cardId limit=$limit overrideRows=$rows '
          'readback=${after.isEmpty ? 'MISSING' : after.first}',
    );
  }

  /// Returns the just-synced cards for a given `institution_id`. Used by
  /// the reconciliation drain — we need the new `last_four` (only known
  /// after sync finishes) to look for matching orphans.
  Future<List<Map<String, dynamic>>> queryCardsByInstitutionId({
    required String userId,
    required String institutionId,
  }) async {
    final db = await _dbHelper.database;
    return db.query(
      'cards',
      where: "user_id = ? AND source = 'bank' AND institution_id = ?",
      whereArgs: [userId, institutionId],
    );
  }

  /// Looks up orphan transaction groups for the just-linked card's last
  /// four. Each result is one orphan card_id (previous link via a
  /// different Sophtron catalog entry, or any other disconnected card)
  /// the reconciliation flow may offer to re-attach.
  ///
  /// Pattern: `bank:%:LF:%`. Stable Sophtron card ids are shaped
  /// `bank:<institutionId>:<lastFour>:<accountSlug>`, so anchoring the
  /// LIKE to the `:LF:` segment between two colons rules out the false
  /// positive that the earlier `%:LF%` allowed — a slug ending in the
  /// same digits (or another bank's institutionId tail) would have
  /// matched. Real-world risk was low but the wider pattern was strictly
  /// looser than needed.
  Future<List<OrphanTransactionGroup>> findOrphanTransactionGroupsForLastFour({
    required String userId,
    required String lastFour,
  }) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT transactions.card_id AS card_id,
             COUNT(*) AS tx_count,
             MIN(COALESCE(posted_at, created_at)) AS earliest,
             MAX(COALESCE(posted_at, created_at)) AS latest
      FROM transactions
      WHERE user_id = ?
        AND card_id LIKE ?
        AND card_id NOT IN (SELECT id FROM cards WHERE user_id = ?)
      GROUP BY transactions.card_id
      ''',
      [userId, 'bank:%:$lastFour:%', userId],
    );
    final results = <OrphanTransactionGroup>[];
    for (final r in rows) {
      final orphanCardId = r['card_id'] as String;
      final instId = BankWriteRepository.institutionIdFromStableId(
        orphanCardId,
      );
      String? instName;
      if (instId != null) {
        final cache = await db.query(
          'institutions_cache',
          columns: ['name'],
          where: 'institution_id = ?',
          whereArgs: [instId],
          limit: 1,
        );
        if (cache.isNotEmpty) instName = cache.first['name'] as String?;
      }
      results.add(
        OrphanTransactionGroup(
          orphanCardId: orphanCardId,
          institutionId: instId,
          institutionName: instName,
          txCount: r['tx_count'] as int,
          earliest: r['earliest'] as String?,
          latest: r['latest'] as String?,
        ),
      );
    }
    return results;
  }

  /// Re-attaches all transactions from an orphan `card_id` to a current
  /// `card_id`. Also rewrites each row's `id` so the leading
  /// stableCardId segment reflects the new owner (the invariant
  /// "transactions.id always encodes its current card_id prefix" must
  /// hold). On PK collision, drops the orphan side rather than violate.
  Future<int> mergeOrphanTransactionsToCard({
    required String userId,
    required String orphanCardId,
    required String newCardId,
  }) async {
    final db = await _dbHelper.database;
    return db.transaction((txn) async {
      final orphanRows = await txn.query(
        'transactions',
        columns: ['id'],
        where: 'user_id = ? AND card_id = ?',
        whereArgs: [userId, orphanCardId],
      );
      var rewritten = 0;
      for (final r in orphanRows) {
        final oldId = r['id'] as String;
        final newId = BankWriteRepository.rewriteTransactionIdPrefix(
          existingTxId: oldId,
          oldStableCardId: orphanCardId,
          newStableCardId: newCardId,
        );
        if (newId == oldId) {
          await txn.update(
            'transactions',
            {'card_id': newCardId},
            where: 'user_id = ? AND id = ?',
            whereArgs: [userId, oldId],
          );
          rewritten++;
          continue;
        }
        final clash = await txn.query(
          'transactions',
          columns: ['id'],
          where: 'user_id = ? AND id = ?',
          whereArgs: [userId, newId],
          limit: 1,
        );
        if (clash.isNotEmpty) {
          await txn.delete(
            'transactions',
            where: 'user_id = ? AND id = ?',
            whereArgs: [userId, oldId],
          );
          continue;
        }
        await txn.update(
          'transactions',
          {'id': newId, 'card_id': newCardId},
          where: 'user_id = ? AND id = ?',
          whereArgs: [userId, oldId],
        );
        rewritten++;
      }
      return rewritten;
    });
  }

  // ───────────── Static helpers (display fallbacks) ─────────────

  /// Synthetic `cards.institution_id` for manual cards, one per issuer
  /// (e.g. `manual:chase`). Never collides with a real Sophtron
  /// `institution_id` (opaque hex/uuid-shaped), so the Cards screen groups
  /// every manual card for an issuer together under its own "Issuer
  /// (Manual)" section — distinct from a live bank connection for the same
  /// issuer, never merged into it.
  static String manualInstitutionId(String issuer) {
    final slug = issuer
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'manual:${slug.isEmpty ? 'unknown' : slug}';
  }

  /// Returns true for the generic strings some banks emit instead of a
  /// real product name. Bound to the Identify-card banner.
  ///
  /// Trimmed + lowercased exact-match against the curated set below.
  /// Deliberately NOT fuzzy — we'd rather under-trigger the banner than
  /// hide it from a real product name we happen not to recognize. Add to
  /// the set as new generics are observed in the wild.
  static bool isAmbiguousCardName(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return true;
    return _ambiguousExact.contains(n);
  }

  static const Set<String> _ambiguousExact = {
    // Originally-flagged generics from the audit.
    'credit card',
    'card',
    'visa',
    'mastercard',
    'debit card',
    'checking',
    'savings',
    // Additions flagged in the matching audit follow-through.
    'account',
    'bank card',
    'rewards card',
    'cash card',
    'checking account',
    'savings account',
    'personal',
    'personal account',
    'personal checking',
    'personal savings',
    'business',
    'business account',
    'business checking',
    'main',
    'primary',
    'primary checking',
  };
}
