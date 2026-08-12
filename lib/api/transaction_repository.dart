import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../models/insights.dart';
import '../models/transaction.dart' as model;
import 'database_helper.dart';
import 'types.dart';

/// Owns the transactions-table read surface — paged list
/// rollups, monthly trend, category drilldown, merchant summary, and the
/// detected-recurring-payment summary.
///
/// Writes from sync live in [BankWriteRepository] (the
/// `upsertTransactions` + `rebuildInstitution` paths).
/// This class is read-only by design — keep it that way and any future
/// alternate data source (Plaid, manual import) routes through its own
/// write repo.
class TransactionRepository {
  TransactionRepository(this._dbHelper);
  final DatabaseHelper _dbHelper;

  /// Oldest stored transaction `posted_at` for the user, or null when empty.
  /// `posted_at` is an ISO-8601 string, so lexicographic MIN == chronological.
  /// Used to floor the date pickers (no on-demand remote backfill exists).
  Future<DateTime?> getEarliestTransactionDate(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      'SELECT MIN(posted_at) AS earliest FROM transactions '
      'WHERE user_id = ? AND posted_at IS NOT NULL',
      [userId],
    );
    final v = rows.isNotEmpty ? rows.first['earliest'] as String? : null;
    return (v == null || v.isEmpty) ? null : DateTime.tryParse(v);
  }

  Future<model.TransactionResponse> queryTransactions(
    String userId, {
    String q = '',
    int page = 1,
    int pageSize = 50,
    List<String>? cardNames,
    List<String>? categories,
    DateTime? startDate,
    DateTime? endDate,
    bool spendOnly = false,
    String? merchantExact,
  }) async {
    final db = await _dbHelper.database;
    // LEFT JOIN cards + card_overrides so the displayed card name
    // follows renames immediately. Filter by the same COALESCE so the
    // card-chip filter matches what the user sees, not the snapshot.
    const cardDisplayExpr =
        "COALESCE(card_overrides.custom_name, cards.name, transactions.card)";
    const fromJoin = '''
      transactions
      LEFT JOIN cards
        ON cards.id = transactions.card_id
       AND cards.user_id = transactions.user_id
      LEFT JOIN card_overrides
        ON card_overrides.card_id = cards.id
       AND card_overrides.user_id = cards.user_id
    ''';

    String where =
        'transactions.user_id = ? AND transactions.posted_at IS NOT NULL';
    List<dynamic> whereArgs = [userId];

    // Spend view (breakdown drilldown): show only debits, so the list
    // matches the spend-only totals above it. Excludes credit-card
    // payments and refunds (both CREDIT). The full history leaves this
    // off so the ledger still shows every transaction.
    if (spendOnly) {
      where += " AND transactions.type = 'DEBIT'";
    }

    if (q.isNotEmpty) {
      where +=
          ' AND (transactions.name LIKE ? OR transactions.merchant LIKE ? '
          'OR transactions.category LIKE ? OR $cardDisplayExpr LIKE ?)';
      final like = '%$q%';
      whereArgs.addAll([like, like, like, like]);
    }

    // Exact-merchant match for the merchant-detail drilldown. Mirrors the
    // predicate `queryMerchantSummary` uses so the history list and the stat
    // tiles count the same rows — the prior `q: merchant` LIKE + client-side
    // filter could over-match other merchants and disagree with the tiles.
    if (merchantExact != null) {
      where +=
          ' AND (transactions.merchant = ? '
          'OR (transactions.merchant IS NULL AND transactions.name = ?))';
      whereArgs.addAll([merchantExact, merchantExact]);
    }

    if (cardNames != null && cardNames.isNotEmpty) {
      final placeholders = List.filled(cardNames.length, '?').join(',');
      where += ' AND $cardDisplayExpr IN ($placeholders)';
      whereArgs.addAll(cardNames);
    }

    if (categories != null && categories.isNotEmpty) {
      final real = categories.where((c) => c != 'Uncategorized').toList();
      final wantsUncategorized = categories.contains('Uncategorized');
      final clauses = <String>[];
      if (real.isNotEmpty) {
        final placeholders = List.filled(real.length, '?').join(',');
        clauses.add('transactions.category IN ($placeholders)');
        whereArgs.addAll(real);
      }
      if (wantsUncategorized) {
        clauses.add('transactions.category IS NULL');
      }
      where += ' AND (${clauses.join(' OR ')})';
    }

    if (startDate != null) {
      where += ' AND transactions.posted_at >= ?';
      whereArgs.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      where += ' AND transactions.posted_at <= ?';
      whereArgs.add(endDate.toIso8601String());
    }

    final totalRows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM $fromJoin WHERE $where',
      whereArgs,
    );
    final total = Sqflite.firstIntValue(totalRows) ?? 0;

    final rows = await db.rawQuery(
      '''
      SELECT
        transactions.id            AS id,
        transactions.posted_at     AS posted_at,
        transactions.name          AS name,
        transactions.merchant      AS merchant,
        transactions.category      AS category,
        transactions.category_id   AS category_id,
        transactions.type          AS type,
        transactions.amount        AS amount,
        transactions.currency      AS currency,
        transactions.rewards_earned AS rewards_earned,
        transactions.reward_multiplier AS reward_multiplier,
        transactions.card          AS card,
        transactions.card_id       AS card_id,
        transactions.card_last_four AS card_last_four,
        transactions.status        AS status,
        $cardDisplayExpr           AS card_display
      FROM $fromJoin
      WHERE $where
      ORDER BY transactions.posted_at DESC
      LIMIT ? OFFSET ?
      ''',
      [...whereArgs, pageSize, (page - 1) * pageSize],
    );

    return model.TransactionResponse(
      transactions: rows.map((r) => model.Transaction.fromJson(r)).toList(),
      page: page,
      pages: (total / pageSize).ceil(),
      total: total,
    );
  }

  Future<List<({String month, double total})>> queryMonthlyTrend(
    String userId, {
    int months = 6,
    List<String> cardIds = const [],
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await _dbHelper.database;
    final now = DateTime.now();
    final defaultFirst = DateTime(now.year, now.month - (months - 1), 1);
    final firstMonth = startDate != null
        ? DateTime(startDate.year, startDate.month, 1)
        : defaultFirst;
    final lastMonth = endDate != null
        ? DateTime(endDate.year, endDate.month, 1)
        : DateTime(now.year, now.month, 1);
    final spanMonths =
        (lastMonth.year - firstMonth.year) * 12 +
        (lastMonth.month - firstMonth.month) +
        1;

    String filter = ' AND posted_at >= ?';
    final params = <dynamic>[userId, firstMonth.toIso8601String()];
    if (endDate != null) {
      filter += ' AND posted_at <= ?';
      params.add(endDate.toIso8601String());
    }
    if (cardIds.isNotEmpty) {
      final placeholders = List.filled(cardIds.length, '?').join(',');
      filter += ' AND card_id IN ($placeholders)';
      params.addAll(cardIds);
    }

    final rows = await db.rawQuery('''
      SELECT strftime('%Y-%m', posted_at) as month, SUM(ABS(amount)) as total
      FROM transactions
      WHERE user_id = ? AND type = 'DEBIT'$filter
      GROUP BY month ORDER BY month
    ''', params);

    final byMonth = {
      for (var r in rows)
        r['month'] as String: (r['total'] as num?)?.toDouble() ?? 0.0,
    };

    return List.generate(spanMonths, (i) {
      final d = DateTime(firstMonth.year, firstMonth.month + i, 1);
      final mm = d.month.toString().padLeft(2, '0');
      final key = '${d.year}-$mm';
      return (month: key, total: byMonth[key] ?? 0.0);
    });
  }

  /// Categories the user has at least one transaction in. Drives the
  /// Transactions filter sheet.
  Future<List<String>> distinctCategories(String userId) async {
    final db = await _dbHelper.database;
    final txRows = await db.rawQuery(
      '''
      SELECT DISTINCT category FROM transactions
      WHERE user_id = ? AND category IS NOT NULL AND category != ''
    ''',
      [userId],
    );
    final sorted = [for (final r in txRows) r['category'] as String]..sort();
    return sorted;
  }

  /// Returns a `name → iconId` map for the user's category vocabulary.
  Future<Map<String, String?>> categoryIconMap() async {
    final db = await _dbHelper.database;
    final rows = await db.query('categories', columns: ['name', 'icon_id']);
    return {
      for (final r in rows)
        ((r['name'] as String?) ?? '').toLowerCase(): r['icon_id'] as String?,
    };
  }

  /// The user's home currency — the most common non-empty transaction currency
  /// (each account tags its transactions with its own currency). Drives
  /// home-country inference for foreign-travel mode (N7). Null before any
  /// currency-tagged transactions exist.
  Future<String?> dominantAccountCurrency(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT currency FROM transactions
      WHERE user_id = ? AND currency IS NOT NULL AND currency != ''
      GROUP BY currency
      ORDER BY COUNT(*) DESC
      LIMIT 1
      ''',
      [userId],
    );
    return rows.isEmpty ? null : rows.first['currency'] as String?;
  }

  Future<RecurringPaymentsSummary> queryRecurringPayments(String userId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      '''
      SELECT
        COALESCE(merchant, name) as merchant_name,
        MAX(category) as category,
        currency,
        COUNT(*) as count,
        MIN(COALESCE(posted_at, created_at)) as first_seen,
        MAX(COALESCE(posted_at, created_at)) as last_seen,
        AVG(amount) as avg_amount,
        MIN(amount) as min_amount,
        MAX(amount) as max_amount,
        (SELECT t2.card_id FROM transactions t2
         WHERE t2.user_id = transactions.user_id
           AND t2.type = 'DEBIT' AND t2.amount > 0
           AND COALESCE(t2.merchant, t2.name) = COALESCE(transactions.merchant, transactions.name)
         ORDER BY COALESCE(t2.posted_at, t2.created_at) DESC
         LIMIT 1) as charged_card_id
      FROM transactions
      WHERE user_id = ? AND type = 'DEBIT' AND amount > 0
      GROUP BY merchant_name
      HAVING count >= 3
    ''',
      [userId],
    );

    final now = DateTime.now();
    final List<RecurringPayment> items = [];
    double monthlyTotal = 0;

    for (var row in rows) {
      final merchant = row['merchant_name'] as String;
      final category = row['category'] as String?;
      final lastSeenStr = row['last_seen'] as String;
      final lastSeen = DateTime.tryParse(lastSeenStr) ?? DateTime(1970);
      final count = row['count'] as int;
      final firstSeenStr = row['first_seen'] as String;
      final firstSeen = DateTime.tryParse(firstSeenStr) ?? DateTime(1970);
      final avgAmount = (row['avg_amount'] as num).toDouble();
      final minAmount = (row['min_amount'] as num).toDouble();
      final maxAmount = (row['max_amount'] as num).toDouble();
      final currency = row['currency'] as String? ?? 'USD';
      final chargedCardId = row['charged_card_id'] as String?;

      if (avgAmount <= 0) continue;
      final spread = (maxAmount - minAmount) / avgAmount;
      if (spread > 0.25) continue;

      final daysTotal = lastSeen.difference(firstSeen).inDays;
      final avgGap = count > 1 ? daysTotal / (count - 1) : 30.0;

      final String freq;
      final double monthlyContribution;
      final int activeCutoffDays;

      if (avgGap <= 10) {
        freq = 'WEEKLY';
        monthlyContribution = avgAmount * 4.33;
        activeCutoffDays = 14;
      } else if (avgGap <= 45) {
        freq = 'MONTHLY';
        monthlyContribution = avgAmount;
        activeCutoffDays = 50;
      } else if (avgGap <= 100) {
        freq = 'QUARTERLY';
        monthlyContribution = avgAmount / 3;
        activeCutoffDays = 110;
      } else {
        freq = 'ANNUAL';
        monthlyContribution = avgAmount / 12;
        activeCutoffDays = 400;
      }

      if (now.difference(lastSeen).inDays > activeCutoffDays) continue;

      // SHA1 over the merchant string: stable across process restarts.
      final stableId = sha1
          .convert(utf8.encode(merchant))
          .toString()
          .substring(0, 16);
      items.add(
        RecurringPayment(
          id: 'detected-$stableId',
          merchant: merchant,
          category: category,
          amount: avgAmount,
          currency: currency,
          frequency: freq,
          nextPaymentDate: lastSeen.add(Duration(days: avgGap.round())),
          chargedCardId: chargedCardId,
        ),
      );

      monthlyTotal += monthlyContribution;
    }

    items.sort((a, b) => (b.amount ?? 0).compareTo(a.amount ?? 0));

    final monthStart = DateTime(now.year, now.month, 1).toIso8601String();
    final merchantNames = items
        .map((i) => i.merchant)
        .whereType<String>()
        .toList();
    double paid = 0;
    if (merchantNames.isNotEmpty) {
      final placeholders = List.filled(merchantNames.length, '?').join(',');
      final paidRow = await db.rawQuery(
        '''
        SELECT SUM(amount) AS total FROM transactions
        WHERE user_id = ? AND type = 'DEBIT'
          AND COALESCE(posted_at, created_at) >= ?
          AND COALESCE(merchant, name) IN ($placeholders)
      ''',
        [userId, monthStart, ...merchantNames],
      );
      paid = (paidRow.first['total'] as num?)?.toDouble() ?? 0.0;
    }

    return RecurringPaymentsSummary(
      items: items,
      monthlyTotal: monthlyTotal,
      paidThisMonth: paid,
    );
  }

  Future<MerchantSummary?> queryMerchantSummary(
    String userId,
    String merchant, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await _dbHelper.database;
    // Optional date scope so the merchant drilldown matches whatever range is
    // active on the transactions list. Filter on posted_at to mirror the list
    // query; null bounds = all-time.
    String dateFilter = '';
    final dateArgs = <dynamic>[];
    if (startDate != null) {
      dateFilter += ' AND posted_at >= ?';
      dateArgs.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      dateFilter += ' AND posted_at <= ?';
      dateArgs.add(endDate.toIso8601String());
    }
    final aggRow = await db.rawQuery(
      '''
      SELECT
        SUM(CASE WHEN type = 'DEBIT' THEN amount ELSE 0 END) AS total_spent,
        SUM(CASE WHEN type = 'DEBIT' THEN 1 ELSE 0 END) AS visits,
        MAX(COALESCE(posted_at, created_at)) AS last_visit,
        category AS category
      FROM transactions
      WHERE user_id = ? AND (merchant = ? OR (merchant IS NULL AND name = ?))$dateFilter
      ''',
      [userId, merchant, merchant, ...dateArgs],
    );
    if (aggRow.isEmpty) return null;
    final visits = (aggRow.first['visits'] as num?)?.toInt() ?? 0;
    if (visits == 0) return null;
    final total = (aggRow.first['total_spent'] as num?)?.toDouble() ?? 0.0;
    final lastVisitRaw = aggRow.first['last_visit'] as String?;
    final category = aggRow.first['category'] as String?;

    final mostUsedRow = await db.rawQuery(
      '''
      SELECT card, COUNT(*) AS uses FROM transactions
      WHERE user_id = ? AND (merchant = ? OR (merchant IS NULL AND name = ?))$dateFilter
        AND card IS NOT NULL
      GROUP BY card ORDER BY uses DESC LIMIT 1
      ''',
      [userId, merchant, merchant, ...dateArgs],
    );
    final mostUsed = mostUsedRow.isNotEmpty
        ? mostUsedRow.first['card'] as String?
        : null;

    return MerchantSummary(
      merchant: merchant,
      category: category,
      totalSpent: total,
      visitCount: visits,
      lastVisit: lastVisitRaw == null ? null : DateTime.tryParse(lastVisitRaw),
      avgPerVisit: visits == 0 ? 0 : total / visits,
      mostUsedCard: mostUsed,
    );
  }

  Future<CategoryDrilldown> queryCategoryDrilldown(
    String userId,
    String category, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await _dbHelper.database;
    final isUncategorized = category == 'Uncategorized';
    final categoryClause = isUncategorized
        ? 'category IS NULL'
        : 'category = ?';
    String filter = '';
    final args = <dynamic>[userId];
    if (!isUncategorized) args.add(category);
    if (startDate != null) {
      filter += ' AND COALESCE(posted_at, created_at) >= ?';
      args.add(startDate.toIso8601String());
    }
    if (endDate != null) {
      filter += ' AND COALESCE(posted_at, created_at) <= ?';
      args.add(endDate.toIso8601String());
    }

    final aggRow = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN type = 'DEBIT' THEN amount ELSE 0 END) AS total_spent,
        SUM(CASE WHEN type = 'DEBIT' THEN 1 ELSE 0 END) AS tx_count
      FROM transactions
      WHERE user_id = ? AND $categoryClause $filter
      ''', args);
    final spent = (aggRow.first['total_spent'] as num?)?.toDouble() ?? 0.0;
    final txCount = (aggRow.first['tx_count'] as num?)?.toInt() ?? 0;

    final totalRow = await db.rawQuery(
      '''
      SELECT SUM(amount) AS total FROM transactions
      WHERE user_id = ? AND type = 'DEBIT'
        ${startDate != null ? 'AND COALESCE(posted_at, created_at) >= ?' : ''}
        ${endDate != null ? 'AND COALESCE(posted_at, created_at) <= ?' : ''}
      ''',
      [
        userId,
        if (startDate != null) startDate.toIso8601String(),
        if (endDate != null) endDate.toIso8601String(),
      ],
    );
    final periodTotal = (totalRow.first['total'] as num?)?.toDouble() ?? 0.0;
    final shareOfTotal = periodTotal == 0 ? 0.0 : (spent / periodTotal);

    final mostUsedRow = await db.rawQuery('''
      SELECT card, COUNT(*) AS uses FROM transactions
      WHERE user_id = ? AND $categoryClause AND card IS NOT NULL $filter
      GROUP BY card ORDER BY uses DESC LIMIT 1
      ''', args);
    final mostUsed = mostUsedRow.isNotEmpty
        ? mostUsedRow.first['card'] as String?
        : null;
    final mostUsedShare = mostUsedRow.isNotEmpty && txCount > 0
        ? (mostUsedRow.first['uses'] as num).toDouble() / txCount
        : 0.0;

    return CategoryDrilldown(
      totalSpent: spent,
      txCount: txCount,
      shareOfTotal: shareOfTotal,
      mostUsedCard: mostUsed,
      mostUsedShare: mostUsedShare,
    );
  }
}
