// Typed records returned by the per-concern repositories. Replaces the
// `Map<String, dynamic>` lingua franca that used to flow between the
// repo layer and provider/UI consumers — a renamed column would have
// silently returned `null` at the read site instead of producing a
// compile error. Each record validates the shape at the SQL boundary
// and exposes a typed surface to everyone else.

class CashFlow {
  const CashFlow({
    required this.spent,
    required this.credited,
    required this.spentCount,
  });
  final double spent;
  final double credited;
  final int spentCount;

  double get net => spent - credited;
}

class CategoryDrilldown {
  const CategoryDrilldown({
    required this.totalSpent,
    required this.txCount,
    required this.shareOfTotal,
    required this.mostUsedCard,
    required this.mostUsedShare,
  });
  final double totalSpent;
  final int txCount;
  final double shareOfTotal;
  final String? mostUsedCard;
  final double mostUsedShare;
}

/// One row from `bank_connections`. Used by the Cards-screen
/// broken-connection treatment and by the reconnect flow.
class BankConnectionRow {
  const BankConnectionRow({
    required this.userInstitutionId,
    required this.userId,
    this.memberId,
    this.institutionId,
    this.institutionName,
    this.institutionLogo,
    this.lastSyncedAt,
    this.lastSyncStatus,
    this.lastSyncError,
    this.createdAt,
  });

  factory BankConnectionRow.fromRow(Map<String, Object?> r) {
    return BankConnectionRow(
      userInstitutionId: r['user_institution_id'] as String,
      userId: r['user_id'] as String,
      memberId: r['member_id'] as String?,
      institutionId: r['institution_id'] as String?,
      institutionName: r['institution_name'] as String?,
      institutionLogo: r['institution_logo'] as String?,
      lastSyncedAt: r['last_synced_at'] as String?,
      lastSyncStatus: r['last_sync_status'] as String?,
      lastSyncError: r['last_sync_error'] as String?,
      createdAt: r['created_at'] as String?,
    );
  }

  final String userInstitutionId;
  final String userId;
  final String? memberId;
  final String? institutionId;
  final String? institutionName;
  final String? institutionLogo;
  final String? lastSyncedAt;
  final String? lastSyncStatus;
  final String? lastSyncError;
  final String? createdAt;

  bool get isBroken => lastSyncStatus == 'failed';
}

/// One card earn rule in the legacy `wallet_rewards` row shape — now
/// produced by [CatalogRepository.rewardsForCard] from the catalog's
/// `reward_rules` so the card-detail Rewards tab renders unchanged after the
/// catalog cutover. `categoryName` is the enum `name` form (so it's stable
/// across UI label changes).
class WalletRewardRow {
  const WalletRewardRow({
    required this.ruleId,
    required this.label,
    required this.categoryName,
    required this.brandId,
    required this.isBaseline,
    required this.amount,
    required this.currency,
    required this.iconId,
    this.earnConstraint,
  });

  factory WalletRewardRow.fromRow(Map<String, Object?> r) {
    return WalletRewardRow(
      ruleId: r['rule_id'] as String,
      label: r['label'] as String,
      categoryName: r['category'] as String,
      brandId: r['brand_id'] as String?,
      isBaseline: (r['is_baseline'] as num?)?.toInt() == 1,
      amount: (r['amount'] as num?)?.toDouble(),
      currency: r['currency'] as String?,
      iconId: (r['icon_id'] as num?)?.toInt(),
    );
  }

  final String ruleId;
  final String label;
  final String categoryName;
  final String? brandId;
  final bool isBaseline;
  final double? amount;
  final String? currency;
  final int? iconId;

  /// Caveat for a "top N spend categories" earn — the bonus reaches only N of
  /// the card's eligible categories, so the Rewards tab shows it as inline
  /// subtext under the rate. Null for an ordinary unconditional earn.
  final String? earnConstraint;
}

/// Orphan transaction group surfaced by reconciliation. Used by the
/// reconciliation sheet to offer "re-attach to this card."
class OrphanTransactionGroup {
  const OrphanTransactionGroup({
    required this.orphanCardId,
    required this.institutionId,
    required this.institutionName,
    required this.txCount,
    required this.earliest,
    required this.latest,
  });

  final String orphanCardId;
  final String? institutionId;
  final String? institutionName;
  final int txCount;
  final String? earliest;
  final String? latest;
}

/// Per-card best-card pick + reason. Returned by the simpler "best card
/// at this category" lookups.
class CardPick {
  const CardPick({required this.id, required this.name, required this.rate});
  final String id;
  final String name;
  final double rate;
}
