import '../models/reward_category.dart';

class NearbyMerchant {
  final String id;
  final String name;
  final String? category;

  /// Google Places `primaryType` string (e.g. `'restaurant'`). Stored in the
  /// `foursquare_category_id` DB column — column name kept to avoid a
  /// complex SQLite ALTER TABLE.
  final String? placeType;

  final double lat;
  final double lng;
  final double distanceMi;

  /// Google Places `businessStatus` (`OPERATIONAL` / `CLOSED_TEMPORARILY`).
  /// `CLOSED_PERMANENTLY` is filtered upstream, so only these two (or null when
  /// the API omitted it) ever reach here. Free field, already in the mask.
  final String? businessStatus;

  const NearbyMerchant({
    required this.id,
    required this.name,
    this.category,
    this.placeType,
    required this.lat,
    required this.lng,
    required this.distanceMi,
    this.businessStatus,
  });

  bool get isTemporarilyClosed => businessStatus == 'CLOSED_TEMPORARILY';
}

/// Merchant enriched with the user's best card for that merchant's
/// category - and, if the merchant name matches a `bonus_brand` the
/// user has a card for, the brand-specific bonus instead.
class NearbyMerchantWithReward {
  final NearbyMerchant merchant;
  final String? bestCardName;
  final double? bestRate;
  final String? bestCardImage;

  /// The free-form label the resolver tagged this merchant with
  /// ("Grocery", "Dining"). Kept around for display in the row.
  final String? resolvedLabel;

  /// Our enum bucket - drives the bottom-sheet category lookup.
  final RewardCategory? resolvedCategory;

  /// Non-null when the merchant name matched a brand bonus the user
  /// has. The bottom sheet should open with this brand highlighted.
  final String? matchedBrand;

  const NearbyMerchantWithReward({
    required this.merchant,
    this.bestCardName,
    this.bestRate,
    this.bestCardImage,
    this.resolvedLabel,
    this.resolvedCategory,
    this.matchedBrand,
  });

  String get name => merchant.name;
  String? get category => merchant.category;
  double get distanceMi => merchant.distanceMi;
  bool get isTemporarilyClosed => merchant.isTemporarilyClosed;
}
