import 'package:sqflite/sqflite.dart';

import '../models/card.dart';
import '../models/insights.dart';
import '../models/transaction.dart' as model;
import 'bank_fdx_mapper.dart';
import 'brand_resolver.dart';
import 'card_repository.dart';
import 'catalog_repository.dart';
import 'database_helper.dart';
import 'engine_ranker.dart';
import 'bank_write_repository.dart';
import 'sync_state_repository.dart';
import 'transaction_repository.dart';
import 'types.dart';

/// Composition root. Holds long-lived instances of the per-concern
/// repositories and exposes them as fields ([cards], [transactions],
/// [rewards], [bank], [syncState]) for new code that wants the
/// focused API.
///
/// Existing callers can keep using the forwarding methods on this class
/// — they delegate to the focused repos without behavior change. The
/// audit (§A1) called for the split; the facade keeps the migration
/// reviewable instead of forcing every screen to update in the same PR.
///
/// **Singleton (A4)**: a single instance is shared across foreground,
/// the WorkManager dispatcher, and the geofence-reregister isolate via
/// the cached factory constructor. The underlying `DatabaseHelper` is
/// already singleton, so the previous "fresh DataRepository per
/// instantiation" pattern was functionally fine — but a single instance
/// makes future stateful additions (request-level caches, prepared
/// statements) safe by default.
class DataRepository {
  factory DataRepository() => _instance;

  DataRepository._internal()
    : _dbHelper = DatabaseHelper(),
      cards = CardRepository(DatabaseHelper()),
      transactions = TransactionRepository(DatabaseHelper()),
      catalog = CatalogRepository(DatabaseHelper()),
      bank = BankWriteRepository(DatabaseHelper()),
      syncState = SyncStateRepository(DatabaseHelper());

  static final DataRepository _instance = DataRepository._internal();

  final DatabaseHelper _dbHelper;

  /// Card surface (queries, overrides, perks, orphan recovery).
  final CardRepository cards;

  /// Transactions read surface (paged list, drilldown,
  /// recurring detection, merchant summary).
  final TransactionRepository transactions;

  /// Catalog surface: the global catalog tables, user `card_links`,
  /// `rotating_activations`, and the engine-backed ranking. Card
  /// recommendations resolve here.
  final CatalogRepository catalog;

  /// Bank write surface (connections, institution cache, atomic
  /// per-institution rebuild, wipes).
  final BankWriteRepository bank;

  /// Cross-isolate sync mutex, run history, and per-service circuit
  /// breaker state.
  final SyncStateRepository syncState;

  // ────────────────── Forwarding facade (caller compat) ──────────────────
  //
  // Each method below is a thin delegate to its owner repo. New code
  // should prefer the field-based API (`repo.cards.queryAllCards(...)`)
  // — the forwards exist so the screens and providers don't all need
  // to update in one PR.

  // ── transactions ──

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
  }) => transactions.queryTransactions(
    userId,
    q: q,
    page: page,
    pageSize: pageSize,
    cardNames: cardNames,
    categories: categories,
    startDate: startDate,
    endDate: endDate,
    spendOnly: spendOnly,
    merchantExact: merchantExact,
  );

  Future<List<({String month, double total})>> queryMonthlyTrend(
    String userId, {
    int months = 6,
    List<String> cardIds = const [],
    DateTime? startDate,
    DateTime? endDate,
  }) => transactions.queryMonthlyTrend(
    userId,
    months: months,
    cardIds: cardIds,
    startDate: startDate,
    endDate: endDate,
  );

  Future<List<String>> distinctCategories(String userId) =>
      transactions.distinctCategories(userId);

  Future<Map<String, String?>> categoryIconMap() =>
      transactions.categoryIconMap();

  Future<RecurringPaymentsSummary> queryRecurringPayments(String userId) =>
      transactions.queryRecurringPayments(userId);

  Future<String?> dominantAccountCurrency(String userId) =>
      transactions.dominantAccountCurrency(userId);

  Future<MerchantSummary?> queryMerchantSummary(
    String userId,
    String merchant, {
    DateTime? startDate,
    DateTime? endDate,
  }) => transactions.queryMerchantSummary(
    userId,
    merchant,
    startDate: startDate,
    endDate: endDate,
  );

  Future<CategoryDrilldown> queryCategoryDrilldown(
    String userId,
    String category, {
    DateTime? startDate,
    DateTime? endDate,
  }) => transactions.queryCategoryDrilldown(
    userId,
    category,
    startDate: startDate,
    endDate: endDate,
  );

  // ── cards ──

  Future<List<CardSummary>> queryAllCards(String userId) =>
      cards.queryAllCards(userId);

  Future<int> deleteManualCard(String userId, String cardId) =>
      cards.deleteManualCard(userId, cardId);

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
  }) => cards.addManualCard(
    userId: userId,
    productId: productId,
    issuer: issuer,
    name: name,
    network: network,
    imageUrl: imageUrl,
    lastFour: lastFour,
    creditLimit: creditLimit,
    dueDay: dueDay,
    institutionLogo: institutionLogo,
  );

  Future<int> setCustomName(String userId, String cardId, String? customName) =>
      cards.setCustomName(userId, cardId, customName);

  Future<int> setDueDay(String userId, String cardId, int? dueDay) =>
      cards.setDueDay(userId, cardId, dueDay);

  Future<int> setReminderPrefs(
    String userId,
    String cardId, {
    required bool? enabled,
    required int? leadDays,
  }) => cards.setReminderPrefs(
    userId,
    cardId,
    enabled: enabled,
    leadDays: leadDays,
  );

  Future<int> setProductIdentification(
    String userId,
    String cardId,
    String? productId, {
    String source = 'user',
  }) =>
      cards.setProductIdentification(userId, cardId, productId, source: source);

  Future<void> updateManualCreditLimit(
    String userId,
    String cardId, {
    required double? limit,
    required String name,
    String? lastFour,
    String? provider,
    String? accountType,
  }) => cards.updateManualCreditLimit(
    userId,
    cardId,
    limit: limit,
    name: name,
    lastFour: lastFour,
    provider: provider,
    accountType: accountType,
  );

  Future<List<Map<String, dynamic>>> queryCardsByInstitutionId({
    required String userId,
    required String institutionId,
  }) => cards.queryCardsByInstitutionId(
    userId: userId,
    institutionId: institutionId,
  );

  Future<List<OrphanTransactionGroup>> findOrphanTransactionGroupsForLastFour({
    required String userId,
    required String lastFour,
  }) => cards.findOrphanTransactionGroupsForLastFour(
    userId: userId,
    lastFour: lastFour,
  );

  Future<int> mergeOrphanTransactionsToCard({
    required String userId,
    required String orphanCardId,
    required String newCardId,
  }) => cards.mergeOrphanTransactionsToCard(
    userId: userId,
    orphanCardId: orphanCardId,
    newCardId: newCardId,
  );

  // ── rewards (engine-backed) ──
  //
  // Best-card lookups resolve through the catalog RewardEngine. Kept as
  // methods (not provider-only) so non-Riverpod callers — the geofence
  // background isolate and the Nearby providers — get the same answer.

  Future<EngineRanker?> _buildRanker(
    String userId,
    List<String> cardPreferenceOrder, {
    bool isForeign = false,
  }) async {
    final snapshot = await catalog.loadSnapshot();
    if (snapshot.isEmpty) return null;
    final links = await catalog.linkedCards(userId);
    if (links.isEmpty) return null;
    return EngineRanker(
      snapshot: snapshot,
      linkedCards: links,
      when: DateTime.now(),
      activationsByCard: await catalog.activations(userId),
      cardPreferenceOrder: cardPreferenceOrder,
      isForeign: isForeign,
    );
  }

  Future<BestCardLookup> queryBestCardByCategory(
    String userId, {
    List<String> cardPreferenceOrder = const [],
  }) async {
    final ranker = await _buildRanker(userId, cardPreferenceOrder);
    return ranker?.bestCardByCategory() ?? BestCardLookup.empty;
  }

  Future<CardPick?> queryBestCatchAllCard(
    String userId, {
    List<String> cardPreferenceOrder = const [],
  }) async {
    final ranker = await _buildRanker(userId, cardPreferenceOrder);
    return ranker?.bestCatchAllCard();
  }

  BrandResolver loadBrandResolver() => BrandResolver.fromDefaultRegistry();

  // ── catalog: rotating activations (Track B / B6) ──

  Future<Map<String, Set<(int, int)>>> rotatingActivations(String userId) =>
      catalog.activations(userId);

  Future<void> setRotatingActivation({
    required String userId,
    required String cardId,
    required int year,
    required int quarter,
    required bool activated,
  }) => catalog.setActivation(
    userId: userId,
    cardId: cardId,
    year: year,
    quarter: quarter,
    activated: activated,
  );

  Future<DateTime?> getEarliestTransactionDate(String userId) =>
      transactions.getEarliestTransactionDate(userId);

  // ── bank writes ──

  Future<void> upsertConnection({
    required String userId,
    required String userInstitutionId,
    String? memberId,
    String? institutionId,
    String? institutionName,
    String? institutionLogo,
  }) => bank.upsertConnection(
    userId: userId,
    userInstitutionId: userInstitutionId,
    memberId: memberId,
    institutionId: institutionId,
    institutionName: institutionName,
    institutionLogo: institutionLogo,
  );

  Future<List<BankConnectionRow>> queryBankConnections(String userId) =>
      bank.queryBankConnections(userId);

  Future<BankConnectionRow?> getConnection({
    required String userId,
    required String userInstitutionId,
  }) =>
      bank.getConnection(userId: userId, userInstitutionId: userInstitutionId);

  Future<void> setConnectionLastSyncedAt(
    String userInstitutionId,
    DateTime when,
  ) => bank.setConnectionLastSyncedAt(userInstitutionId, when);

  Future<void> setConnectionSyncStatus(
    String userInstitutionId, {
    required String status,
    String? error,
  }) => bank.setConnectionSyncStatus(
    userInstitutionId,
    status: status,
    error: error,
  );

  Future<void> upsertInstitutionCache({
    required String institutionId,
    required String name,
    String? logo,
  }) => bank.upsertInstitutionCache(
    institutionId: institutionId,
    name: name,
    logo: logo,
  );

  Future<String?> lookupInstitutionName(String institutionId) =>
      bank.lookupInstitutionName(institutionId);

  Future<void> deleteMemberData({
    required String userId,
    required String userInstitutionId,
  }) => bank.deleteMemberData(
    userId: userId,
    userInstitutionId: userInstitutionId,
  );

  Future<int> deleteOrphanCardsByInstitution({
    required String userId,
    required String institutionId,
  }) => bank.deleteOrphanCardsByInstitution(
    userId: userId,
    institutionId: institutionId,
  );

  Future<int> mergeManualCardsWithBank({
    required String userId,
    required String institutionName,
  }) => bank.mergeManualCardsWithBank(
    userId: userId,
    institutionName: institutionName,
  );

  Future<void> pruneDebitBankData(String userId) =>
      bank.pruneDebitBankData(userId);

  Future<void> replaceBankData(String userId) => bank.replaceBankData(userId);

  Future<({int cardCount, int txCount})> rebuildInstitution({
    required String userId,
    required String institutionId,
    required String? institutionName,
    required String? institutionLogo,
    required List<BankAccount> accounts,
    required Map<String, List<BankTransaction>> txsByAccountId,
    BrandResolver? brandResolver,
  }) => bank.rebuildInstitution(
    userId: userId,
    institutionId: institutionId,
    institutionName: institutionName,
    institutionLogo: institutionLogo,
    accounts: accounts,
    txsByAccountId: txsByAccountId,
    brandResolver: brandResolver,
  );

  Future<void> dropMissingInstitutions({
    required String userId,
    required Set<String> keepInstitutionIds,
    required Set<String> keepMemberIds,
  }) => bank.dropMissingInstitutions(
    userId: userId,
    keepInstitutionIds: keepInstitutionIds,
    keepMemberIds: keepMemberIds,
  );

  // ── sync state / runs / circuit breaker ──

  static Duration get syncLockTtl => SyncStateRepository.syncLockTtl;
  static Duration get syncLockLiveness => SyncStateRepository.syncLockLiveness;

  Future<int?> acquireSyncLock(
    String userId, {
    required String holder,
    DateTime? now,
  }) => syncState.acquireSyncLock(userId, holder: holder, now: now);

  Future<void> heartbeatSyncLock(
    String userId, {
    required int acquiredAtToken,
    DateTime? now,
  }) => syncState.heartbeatSyncLock(
    userId,
    acquiredAtToken: acquiredAtToken,
    now: now,
  );

  Future<({String holder, int acquiredAt, int heartbeatAt, bool isStale})?>
  readSyncLock(String userId, {DateTime? now}) =>
      syncState.readSyncLock(userId, now: now);

  Future<void> releaseSyncLock(String userId, {int? acquiredAtToken}) =>
      syncState.releaseSyncLock(userId, acquiredAtToken: acquiredAtToken);

  Future<String> startSyncRun({
    required String userId,
    required String trigger,
  }) => syncState.startSyncRun(userId: userId, trigger: trigger);

  Future<void> finishSyncRun({
    required String runId,
    required int memberCount,
    required int cardCount,
    required int txCount,
    required int errorCount,
    required String outcome,
    Map<String, dynamic>? membersJson,
  }) => syncState.finishSyncRun(
    runId: runId,
    memberCount: memberCount,
    cardCount: cardCount,
    txCount: txCount,
    errorCount: errorCount,
    outcome: outcome,
    membersJson: membersJson,
  );

  // ── First-sync gate on `users` ──
  //
  // The engine's orphan-Member cleanup is unsafe on a fresh / post-
  // reinstall install (the empty local DB makes every Sophtron Member
  // look orphaned). These two helpers gate that pass: callers read
  // `isFirstSyncCompleted` before invoking the engine, and stamp
  // `markFirstSyncCompleted` once a successful run lands.

  /// True when this user has completed at least one successful sync
  /// (any non-empty outcome). Reads `users.first_sync_completed_at`.
  Future<bool> isFirstSyncCompleted(String userId) async {
    final db = await DatabaseHelper().database;
    final rows = await db.query(
      'users',
      columns: ['first_sync_completed_at'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final ts = rows.first['first_sync_completed_at'] as String?;
    return ts != null && ts.isNotEmpty;
  }

  /// Stamps `users.first_sync_completed_at` with [at]. Idempotent —
  /// callers should still gate on `isFirstSyncCompleted` first to
  /// avoid overwriting an earlier stamp on every sync.
  Future<void> markFirstSyncCompleted({
    required String userId,
    required DateTime at,
  }) async {
    final db = await DatabaseHelper().database;
    await db.update(
      'users',
      {'first_sync_completed_at': at.toIso8601String()},
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  Future<({int failureCount, int? openedUntil})> getCircuitBreaker(
    String service,
  ) => syncState.getCircuitBreaker(service);

  Future<({int failureCount, int? openedUntil})> recordCircuitBreakerFailure(
    String service, {
    required int threshold,
    required Duration cooldown,
    DateTime? now,
  }) => syncState.recordCircuitBreakerFailure(
    service,
    threshold: threshold,
    cooldown: cooldown,
    now: now,
  );

  Future<void> resetCircuitBreaker(String service) =>
      syncState.resetCircuitBreaker(service);

  // ────────────────── Muted merchants ──────────────────
  //
  // Device-level per-store mute for dwell notifications. Writes happen only
  // here (Dart); the native dwell receiver reads the same `muted_merchants`
  // table as a belt-and-braces guard. Keyed by the Google place id.

  Future<void> muteMerchant(String merchantId, String name) async {
    final db = await DatabaseHelper().database;
    await db.insert('muted_merchants', {
      'merchant_id': merchantId,
      'name': name,
      'muted_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> unmuteMerchant(String merchantId) async {
    final db = await DatabaseHelper().database;
    await db.delete(
      'muted_merchants',
      where: 'merchant_id = ?',
      whereArgs: [merchantId],
    );
  }

  Future<Set<String>> queryMutedMerchantIds() async {
    final db = await DatabaseHelper().database;
    final rows = await db.query('muted_merchants', columns: ['merchant_id']);
    return rows.map((r) => r['merchant_id'] as String).toSet();
  }

  /// Ordered newest-first for the Muted Stores management screen.
  Future<List<Map<String, Object?>>> queryMutedMerchants() async {
    final db = await DatabaseHelper().database;
    return db.query('muted_merchants', orderBy: 'muted_at DESC');
  }

  // ────────────────── Stays here ──────────────────
  //
  // Small kv-store accessors used by the SettingsRepository. They live
  // on DataRepository (rather than a SettingsStore subclass) because
  // SettingsRepository owns the typed accessors; we just need the raw
  // get/set passthrough here.

  Future<String?> getSetting(String userId, String key) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'user_id = ? AND key = ?',
      whereArgs: [userId, key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String userId, String key, String value) async {
    final db = await _dbHelper.database;
    await db.insert('settings', {
      'user_id': userId,
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Returns the counts of rows in various tables for diagnostic purposes.
  Future<Map<String, int>> queryDataDiagnostics(String userId) async {
    final db = await _dbHelper.database;
    final tables = {
      'transactions': 'user_id = ?',
      'cards': 'user_id = ?',
      'card_links': 'user_id = ?',
      'categories': null,
    };

    final out = <String, int>{};
    for (final entry in tables.entries) {
      final where = entry.value;
      final res = await db.rawQuery(
        'SELECT COUNT(*) as n FROM ${entry.key}${where != null ? " WHERE $where" : ""}',
        where != null ? [userId] : null,
      );
      out[entry.key] = Sqflite.firstIntValue(res) ?? 0;
    }
    return out;
  }

  // ────────────────── Static helper forwards ──────────────────
  //
  // The original `DataRepository.foo(...)` static call sites keep
  // working. Use the focused-repo static directly in new code (e.g.
  // `BankWriteRepository.stableCardId(...)`).

  static String stableCardId({
    required String institutionId,
    required String? lastFour,
    required String? accountSlug,
  }) => BankWriteRepository.stableCardId(
    institutionId: institutionId,
    lastFour: lastFour,
    accountSlug: accountSlug,
  );

  static String accountSlug({
    required String? rawAccountName,
    required String? rawAccountId,
  }) => BankWriteRepository.slugForAccount(
    rawAccountName: rawAccountName,
    rawAccountId: rawAccountId,
  );

  static String bankDisplayName({
    required String? rawAccountName,
    required String? institutionName,
  }) => BankWriteRepository.bankDisplayName(
    rawAccountName: rawAccountName,
    institutionName: institutionName,
  );

  static String transactionStableId({
    required String stableCardId,
    required String? date,
    required double? amount,
    required String? description,
  }) => BankWriteRepository.transactionStableId(
    stableCardId: stableCardId,
    date: date,
    amount: amount,
    description: description,
  );

  static String rewriteTransactionIdPrefix({
    required String existingTxId,
    required String oldStableCardId,
    required String newStableCardId,
  }) => BankWriteRepository.rewriteTransactionIdPrefix(
    existingTxId: existingTxId,
    oldStableCardId: oldStableCardId,
    newStableCardId: newStableCardId,
  );

  static String? institutionIdFromStableId(String cardId) =>
      BankWriteRepository.institutionIdFromStableId(cardId);

  static String? lastFourFromAccountNumber(String? raw) =>
      BankWriteRepository.lastFourFromAccountNumber(raw);

  static String? smartCase(String? raw) => BankWriteRepository.smartCase(raw);

  static bool isAmbiguousCardName(String name) =>
      CardRepository.isAmbiguousCardName(name);
}
