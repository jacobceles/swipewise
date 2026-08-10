/// The single place that knows the aggregator's FDX (V3) JSON field names.
///
/// Sophtron's V3 endpoints return FDX-shaped data; a future move to the
/// Universal Connect Widget would feed the *same* FDX shape. By isolating all
/// field-name knowledge here and emitting neutral [BankAccount] /
/// [BankTransaction] records, the rest of the app (write repo, DB, ranking,
/// UI) never learns which source produced the data — swapping aggregators is a
/// one-file rewrite.
///
/// Forward-compatible by design: every read is null-safe, unknown/extra keys
/// are ignored (never fatal), and the full source object is kept in [raw] so a
/// field the aggregator *adds* later survives untouched and can be back-filled
/// from `raw_json` without a re-sync.
library;

/// Neutral account record — only the fields the app consumes today. The full
/// FDX `depositAccount` object is preserved in [raw].
class BankAccount {
  const BankAccount({
    required this.accountId,
    required this.raw,
    this.accountNumberDisplay,
    this.accountType,
    this.nickname,
    this.currentBalance,
    this.availableBalance,
    this.currency,
    this.institutionId,
  });

  final String accountId;
  final String? accountNumberDisplay;
  final String? accountType;
  final String? nickname;
  final double? currentBalance;
  final double? availableBalance;
  final String? currency;

  /// From the account's `fiAttributes`. We normally key institution off the
  /// connection row; this is kept for a defensive cross-check / logging.
  final String? institutionId;

  /// Full FDX `depositAccount` object, persisted to `financial_accounts.raw_json`.
  final Map<String, dynamic> raw;
}

/// Neutral transaction record — only the fields the app consumes today. The
/// full FDX `depositTransaction` object is preserved in [raw].
class BankTransaction {
  const BankTransaction({
    required this.raw,
    this.transactionId,
    this.amount,
    this.type,
    this.status,
    this.date,
    this.postedAt,
    this.description,
    this.memo,
    this.category,
  });

  final String? transactionId;

  /// Unsigned magnitude as returned by FDX; callers `.abs()` defensively.
  final double? amount;
  final String? type; // DEBIT | CREDIT
  final String? status; // POSTED | PENDING
  /// Transaction date (FDX `transactionTimestamp`) — used for the stable id.
  final DateTime? date;

  /// Posted date (FDX `postedTimestamp`).
  final DateTime? postedAt;
  final String? description;
  final String? memo;

  /// Bank-supplied category (FDX `category`, e.g. "Food & Drink"). Retained by
  /// Sophtron V3, so transaction categorization is unchanged from V2.
  final String? category;

  final Map<String, dynamic> raw;
}

class BankFdxMapper {
  /// Maps one element of the FDX accounts list. Each element wraps the account
  /// in a `depositAccount` node (credit cards included). Returns null when the
  /// entry is malformed or has no usable account id.
  static BankAccount? account(dynamic entry) {
    final node = _unwrap(entry, 'depositAccount');
    if (node == null) return null;
    final accountId = node['accountId']?.toString();
    if (accountId == null || accountId.isEmpty) return null;
    return BankAccount(
      accountId: accountId,
      accountNumberDisplay:
          node['accountNumberDisplay']?.toString() ??
          node['accountNumber']?.toString(),
      accountType: node['accountType']?.toString(),
      nickname: node['nickname']?.toString(),
      currentBalance: _double(node['currentBalance']),
      availableBalance: _double(node['availableBalance']),
      currency: node['currency']?.toString(),
      institutionId: _fiAttr(node['fiAttributes'], 'institution_id'),
      raw: node,
    );
  }

  /// Maps one element of the FDX transactions list. Each element wraps the
  /// transaction in a `depositTransaction` node. Returns null when malformed.
  static BankTransaction? transaction(dynamic entry) {
    final node = _unwrap(entry, 'depositTransaction');
    if (node == null) return null;
    return BankTransaction(
      transactionId: node['transactionId']?.toString(),
      amount: _double(node['amount']),
      type: node['transactionType']?.toString(),
      status: node['status']?.toString(),
      date: _isoDate(node['transactionTimestamp'] ?? node['postedTimestamp']),
      postedAt: _isoDate(node['postedTimestamp']),
      description: node['description']?.toString(),
      memo: node['memo']?.toString(),
      category: node['category']?.toString(),
      raw: node,
    );
  }

  // ---- internals ----

  /// FDX wraps each list entry in a single-key node (`depositAccount` /
  /// `depositTransaction`). Unwrap it; tolerate a bare object too (so a future
  /// shape change degrades gracefully rather than dropping everything).
  static Map<String, dynamic>? _unwrap(dynamic entry, String key) {
    if (entry is! Map) return null;
    final inner = entry[key];
    if (inner is Map) return Map<String, dynamic>.from(inner);
    // Fallback: some shapes may return the account object directly.
    if (entry.containsKey('accountId') || entry.containsKey('transactionId')) {
      return Map<String, dynamic>.from(entry);
    }
    return null;
  }

  /// `fiAttributes` is a list of `{Name, Value}` pairs. Match name
  /// case-insensitively so casing drift (`institution_id` vs `Institution_Id`)
  /// doesn't break us.
  static String? _fiAttr(dynamic fiAttributes, String name) {
    if (fiAttributes is! List) return null;
    final target = name.toLowerCase();
    for (final a in fiAttributes) {
      if (a is Map &&
          a['Name']?.toString().toLowerCase() == target &&
          a['Value'] != null) {
        return a['Value'].toString();
      }
    }
    return null;
  }

  static double? _double(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static DateTime? _isoDate(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString());
  }
}
