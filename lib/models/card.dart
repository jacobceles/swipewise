/// UI-facing snapshot of one card, assembled from `cards` + `card_overrides`
/// + the latest balance row + the per-card transaction aggregate.
///
/// Has value equality (`==`/`hashCode`) so list-equality short-circuits in
/// Riverpod consumers: the cards provider re-fires on sync invalidation,
/// but if nothing actually changed the downstream `select`/`where` paths
/// don't rebuild.
class CardSummary {
  final String cardId;
  final String source;
  final String? provider;
  final String name;
  // User-set rename override. When non-null, the UI shows `customName`
  // instead of `name`. Sync never writes this column, so it survives every
  // Sophtron upsert. Set via the universal rename / identify card flow.
  final String? customName;
  // Explicit catalog product the user picked in the Identify Card flow.
  // When set, the catalog binder attaches rewards/perks to this exact
  // product instead of fuzzy-matching, and the Identify banner is hidden.
  // `identificationSource` records how the binding was made — today only
  // `'user'` is written but the column exists so the catalog rewrite
  // can flip on `'heuristic'` / `'bin'` without a schema change.
  final String? productIdentification;
  final String? identificationSource;
  final String? lastFour;
  // Sophtron's stable per-catalog-entry institution ID. NULL for manual
  // cards. Used by the Cards screen as the group key (every card on the
  // same institution renders under one bank section) and by the
  // reconciliation flow at link time to detect orphan transactions that
  // should be re-attached.
  final String? institutionId;
  // Card network (Visa / Mastercard / Amex / Discover) when Sophtron
  // returns it. Used by some UI affordances (e.g. routing card-art
  // fallbacks when the catalog has no image).
  final String? network;
  final int txCount;
  final double balance;
  final double? creditLimit;
  // Aggregator-reported headroom. Null when no financial_account row exists
  // (manual cards, or the aggregator couldn't pull a limit from the issuer).
  final double? creditAvailable;
  final String? imageUrl;
  final String? institutionLogo;

  /// User-entered payment due day-of-month (1-31). Null = not set, which is
  /// the normal default: banks do not supply a due date over FDX.
  final int? dueDay;

  /// Per-card reminder opt-out. Null = inherit the global toggle.
  final bool? reminderEnabled;

  /// Per-card lead time in days. Null = inherit the Settings default.
  final int? reminderLeadDays;
  // Most recent posted/created date for any tx on this card. Null if the card
  // has never had a transaction.
  final DateTime? lastUsedAt;
  // The aggregator's `accountType` (e.g. "Credit_Card", "Checking", "Investment").
  // Cards-screen rollups filter to credit only — summing checking assets
  // with credit-card debt is semantically wrong.
  final String? accountType;

  CardSummary({
    required this.cardId,
    required this.source,
    this.provider,
    required this.name,
    this.customName,
    this.productIdentification,
    this.identificationSource,
    this.lastFour,
    this.institutionId,
    this.network,
    required this.txCount,
    required this.balance,
    this.creditLimit,
    this.creditAvailable,
    this.imageUrl,
    this.institutionLogo,
    this.dueDay,
    this.reminderEnabled,
    this.reminderLeadDays,
    this.lastUsedAt,
    this.accountType,
  });

  /// Name to show in the UI. Honors the user's universal rename override
  /// when set; falls back to the synced/canonical name otherwise. The
  /// final fallback ("Card · ••1234" / "Card") guards against the
  /// aggregator returning empty-but-not-null names.
  String get displayName {
    final cn = customName?.trim();
    if (cn != null && cn.isNotEmpty) return cn;
    final n = name.trim();
    if (n.isNotEmpty) return n;
    if (lastFour != null && lastFour!.isNotEmpty) return 'Card · ••$lastFour';
    return 'Card';
  }

  /// True when this card has been explicitly identified by the user via
  /// the Identify Card flow. Rewards/perks attach by catalog product id
  /// rather than by fuzzy name match.
  bool get isExplicitlyIdentified => productIdentification != null;

  /// Credit-card detection that tolerates aggregator casing drift
  /// (Sophtron has shipped both `Credit_Card` and `CREDIT_CARD` across
  /// schema versions).
  bool get isCreditCard {
    final t = accountType;
    if (t == null) return false;
    return _kCreditAccountTypes.contains(t.toLowerCase());
  }

  /// True only when we have an explicit non-credit `accountType` (Checking,
  /// Savings, Money Market, etc.). Manual cards leave `accountType` null
  /// and aren't deposit accounts by intent, so the "Include Debit Accounts"
  /// toggle uses this — not `!isCreditCard` — to decide what to hide.
  bool get isDepositAccount {
    final t = accountType;
    if (t == null) return false;
    return !_kCreditAccountTypes.contains(t.toLowerCase());
  }

  /// Raw utilization. May exceed 1.0 when the card is over-limit (legit
  /// case under over-limit fees). UI clamps for the meter but reads the
  /// raw value via [isOverLimit] to surface the warning treatment.
  double? get utilization {
    final lim = creditLimit;
    if (lim == null || lim <= 0) return null;
    return balance / lim;
  }

  bool get isOverLimit {
    final u = utilization;
    return u != null && u > 1.0;
  }

  /// True when [lastUsedAt] is older than [thresholdDays] (default 90).
  /// Cards with no tx at all are not considered dormant — they're new.
  /// `now` is injectable so tests can pin the clock.
  bool isDormant({int thresholdDays = 90, DateTime? now}) {
    final last = lastUsedAt;
    if (last == null) return false;
    final n = now ?? DateTime.now();
    return n.difference(last).inDays >= thresholdDays;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CardSummary) return false;
    return cardId == other.cardId &&
        source == other.source &&
        provider == other.provider &&
        name == other.name &&
        customName == other.customName &&
        productIdentification == other.productIdentification &&
        identificationSource == other.identificationSource &&
        lastFour == other.lastFour &&
        institutionId == other.institutionId &&
        network == other.network &&
        txCount == other.txCount &&
        balance == other.balance &&
        creditLimit == other.creditLimit &&
        creditAvailable == other.creditAvailable &&
        imageUrl == other.imageUrl &&
        institutionLogo == other.institutionLogo &&
        lastUsedAt == other.lastUsedAt &&
        accountType == other.accountType;
  }

  @override
  int get hashCode => Object.hashAll([
    cardId,
    source,
    provider,
    name,
    customName,
    productIdentification,
    identificationSource,
    lastFour,
    institutionId,
    network,
    txCount,
    balance,
    creditLimit,
    creditAvailable,
    imageUrl,
    institutionLogo,
    lastUsedAt,
    accountType,
  ]);
}

const Set<String> _kCreditAccountTypes = {
  'credit_card',
  'creditcard',
  'credit',
};
