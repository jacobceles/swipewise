import 'reward_category.dart';

// Models for data surfaced from the new sync tables (perks, recurring
// payments, pending transactions, transaction score, monthly aggregates).

class CardPerk {
  final String id;
  final String? cardId;
  final String? title;
  final String? status;
  final String? dateRedeemed;
  final double? redeemedAmount;
  final String? description;
  // `kind` mirrors the seed's perk type: typically `CreditPerk` (statement
  // credit) or `BenefitPerk` (insurance/protection).
  final String? kind;
  final String? frequency;
  final double? valueEstimate;
  final double? calendarMaxYearAmount;
  final String? howToEarn;
  final String? imageUri;
  final String? redemptionUrl;
  final String? expirationDate;

  const CardPerk({
    required this.id,
    this.cardId,
    this.title,
    this.status,
    this.dateRedeemed,
    this.redeemedAmount,
    this.description,
    this.kind,
    this.frequency,
    this.valueEstimate,
    this.calendarMaxYearAmount,
    this.howToEarn,
    this.imageUri,
    this.redemptionUrl,
    this.expirationDate,
  });

  factory CardPerk.fromRow(Map<String, dynamic> row) {
    return CardPerk(
      id: row['id'] as String,
      cardId: row['card_id'] as String?,
      title: row['title'] as String?,
      status: row['status'] as String?,
      dateRedeemed: row['date_redeemed'] as String?,
      redeemedAmount: (row['redeemed_amount'] as num?)?.toDouble(),
      description: row['description'] as String?,
      kind: row['kind'] as String?,
      frequency: row['frequency'] as String?,
      valueEstimate: (row['value_estimate'] as num?)?.toDouble(),
      calendarMaxYearAmount: (row['calendar_max_year_amount'] as num?)
          ?.toDouble(),
      howToEarn: row['how_to_earn'] as String?,
      imageUri: row['image_uri'] as String?,
      redemptionUrl: row['redemption_url'] as String?,
      expirationDate: row['expiration_date'] as String?,
    );
  }

  bool get isCredit => kind == 'CreditPerk' || kind == 'UserCreditPerk';
  bool get isBenefit => kind == 'BenefitPerk' || kind == 'UserBenefitPerk';
  bool get isExpired => status == 'EXPIRED';

  /// Whether this perk has been consumed FOR THE CURRENT PERIOD. A
  /// `$50 annual hotel credit` redeemed in Sep 2025 is "Used" through the
  /// rest of 2025, but "Available" again in 2026. Without a frequency hint
  /// we fall back to a 1-year window.
  bool get isUsed {
    final hasRedemption =
        dateRedeemed != null ||
        status == 'REDEEMED' ||
        status == 'USED' ||
        status == 'COMPLETED';
    if (!hasRedemption) return false;
    final dt = dateRedeemed == null ? null : DateTime.tryParse(dateRedeemed!);
    if (dt == null) {
      return status == 'REDEEMED' || status == 'USED' || status == 'COMPLETED';
    }
    final now = DateTime.now();
    switch (frequency?.toLowerCase()) {
      case 'monthly':
        return dt.year == now.year && dt.month == now.month;
      case 'annual':
      case 'yearly':
        return dt.year == now.year;
      case 'every four years':
        return now.difference(dt).inDays < 365 * 4;
      default:
        return now.difference(dt).inDays < 365;
    }
  }

  bool get isAvailable => !isUsed && !isExpired;
}

class RecurringPayment {
  final String id;
  final String? merchant;
  final String? category;
  final double? amount;
  final String? currency;
  final String? frequency;
  final DateTime? nextPaymentDate;

  /// Card this charge is billed to — the `card_id` of the most recent
  /// occurrence in the group. Null when the transactions carried no card.
  final String? chargedCardId;

  const RecurringPayment({
    required this.id,
    this.merchant,
    this.category,
    this.amount,
    this.currency,
    this.frequency,
    this.nextPaymentDate,
    this.chargedCardId,
  });
}

class RecurringPaymentsSummary {
  final List<RecurringPayment> items;
  final double monthlyTotal;
  final double paidThisMonth;

  const RecurringPaymentsSummary({
    required this.items,
    required this.monthlyTotal,
    required this.paidThisMonth,
  });

  int get activeCount => items.length;
}

class MerchantSummary {
  final String merchant;
  final String? category;
  final double totalSpent;
  final int visitCount;
  final DateTime? lastVisit;
  final double avgPerVisit;
  final String? mostUsedCard;

  const MerchantSummary({
    required this.merchant,
    this.category,
    required this.totalSpent,
    required this.visitCount,
    this.lastVisit,
    required this.avgPerVisit,
    this.mostUsedCard,
  });
}

class CategoryRewardRanking {
  final String cardId;
  final String? cardName;
  final String? lastFour;
  final String? cardImage;
  final double rate;
  final String? currency;
  final double earnedRecently;
  final bool isBest;

  const CategoryRewardRanking({
    required this.cardId,
    this.cardName,
    this.lastFour,
    this.cardImage,
    required this.rate,
    this.currency,
    required this.earnedRecently,
    required this.isBest,
  });
}

/// One brand-specific bonus row inside the reward ranking sheet's
/// "Brand bonuses" section. Distinct from [CategoryRewardRanking]:
///   - `brand` is non-null (e.g. "Whole Foods Market") whereas the
///     general ranking has no brand context.
///   - `generalBest` is the best general rate the user gets in this
///     same category, used to render the "vs Nx general" caption.
///   - `isMatchedBrand` lights up the row when the sheet was opened
///     in response to the user being at this specific merchant.
class BrandBonusRow {
  final String cardId;
  final String? cardName;
  final String? lastFour;
  final String? cardImage;
  final String brand;
  final double rate;
  final String? currency;
  final double generalBest;
  final bool isMatchedBrand;

  const BrandBonusRow({
    required this.cardId,
    this.cardName,
    this.lastFour,
    this.cardImage,
    required this.brand,
    required this.rate,
    this.currency,
    required this.generalBest,
    required this.isMatchedBrand,
  });
}

class RewardRankingResult {
  final List<CategoryRewardRanking> general;
  final List<BrandBonusRow> brandBonuses;

  const RewardRankingResult({
    required this.general,
    required this.brandBonuses,
  });

  static const empty = RewardRankingResult(general: [], brandBonuses: []);

  bool get isEmpty => general.isEmpty && brandBonuses.isEmpty;
}

/// Result of [queryBestCardByCategory]: separate maps so callers can
/// pick the right answer based on what they have.
///   - `byCategory` - keyed by [RewardCategory], holds the best general
///     card (rows where `bonus_brand IS NULL`) per bucket.
///   - `byBrand` - keyed by lowercased brand string, holds the
///     brand-specific bonus card.
class BestCardLookup {
  final Map<RewardCategory, BestCardEntry> byCategory;
  final Map<String, BestCardEntry> byBrand;

  const BestCardLookup({required this.byCategory, required this.byBrand});

  static const empty = BestCardLookup(byCategory: {}, byBrand: {});
}

class BestCardEntry {
  final String id;
  final String name;
  final double rate;
  final RewardCategory category;
  final String? brand;

  const BestCardEntry({
    required this.id,
    required this.name,
    required this.rate,
    required this.category,
    this.brand,
  });
}

/// One row of the Advisor "Brands" tab: a registered merchant resolved to the
/// user's best card. `isBonus` is true when that card beats the user's baseline
/// (a brand / rotating / category / promo rule won) — this drives the
/// wins-on-top vs. collapsed-baseline-tail split. `currency` ('USD' | 'POINTS'
/// | 'MILES') lets the tile render "5%" vs "5x".
class BrandPick {
  final String brandId;
  final String displayName;
  final String cardId;
  final String cardName;
  final double rate;
  final String currency;
  final RewardCategory category;
  final bool isBonus;

  const BrandPick({
    required this.brandId,
    required this.displayName,
    required this.cardId,
    required this.cardName,
    required this.rate,
    required this.currency,
    required this.category,
    required this.isBonus,
  });
}
