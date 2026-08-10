import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../util/logger.dart';

/// Our wrapper vocabulary for reward categories. Decouples the
/// recommender from free-form merchant strings — every transaction's
/// merchant label is mapped into one of these buckets via `classifyLabel`,
/// and the catalog's `reward_rules.category` references the same vocabulary
/// (the app owns this enum; the catalog only references its names).
///
/// `other` is the catch-all destination for anything we can't slot into
/// a named category. The "Other" tile on the Categories grid surfaces
/// the user's best catch-all card (typically a flat-rate card).
enum RewardCategory {
  dining,
  coffee,
  grocery,
  onlineGrocery,
  gas,
  evCharging,
  travel,
  hotels,
  airlines,
  carRentals,
  drugStores,
  streaming,
  entertainment,
  movieTheaters,
  onlineShopping,
  wholesale,
  transit,
  departmentStores,
  phoneAndInternet,
  officeSupply,
  homeImprovement,
  fitness,
  utilities,
  rent,
  advertising,
  apparel,
  shipping,
  electronics,
  sportingGoods,
  pets,
  medical,
  other;

  String get label {
    switch (this) {
      case RewardCategory.dining:
        return 'Dining';
      case RewardCategory.coffee:
        return 'Coffee';
      case RewardCategory.grocery:
        return 'Grocery';
      case RewardCategory.onlineGrocery:
        return 'Online Grocery';
      case RewardCategory.gas:
        return 'Gas';
      case RewardCategory.evCharging:
        return 'EV Charging';
      case RewardCategory.travel:
        return 'Travel';
      case RewardCategory.hotels:
        return 'Hotels';
      case RewardCategory.airlines:
        return 'Airlines';
      case RewardCategory.carRentals:
        return 'Car Rentals';
      case RewardCategory.drugStores:
        return 'Drug Stores';
      case RewardCategory.streaming:
        return 'Streaming';
      case RewardCategory.entertainment:
        return 'Entertainment';
      case RewardCategory.movieTheaters:
        return 'Movie Theaters';
      case RewardCategory.onlineShopping:
        return 'Online Shopping';
      case RewardCategory.wholesale:
        return 'Wholesale';
      case RewardCategory.transit:
        return 'Transit';
      case RewardCategory.departmentStores:
        return 'Department Stores';
      case RewardCategory.phoneAndInternet:
        return 'Phone & Internet';
      case RewardCategory.officeSupply:
        return 'Office Supply';
      case RewardCategory.homeImprovement:
        return 'Home Improvement';
      case RewardCategory.fitness:
        return 'Fitness';
      case RewardCategory.utilities:
        return 'Utilities';
      case RewardCategory.rent:
        return 'Rent';
      case RewardCategory.advertising:
        return 'Advertising';
      case RewardCategory.apparel:
        return 'Apparel';
      case RewardCategory.shipping:
        return 'Shipping';
      case RewardCategory.electronics:
        return 'Electronics';
      case RewardCategory.sportingGoods:
        return 'Sporting Goods';
      case RewardCategory.pets:
        return 'Pets';
      case RewardCategory.medical:
        return 'Medical';
      case RewardCategory.other:
        return 'Other';
    }
  }

  IconData get icon {
    switch (this) {
      case RewardCategory.dining:
        return LucideIcons.utensils;
      case RewardCategory.coffee:
        return LucideIcons.coffee;
      case RewardCategory.grocery:
        return LucideIcons.shoppingCart;
      case RewardCategory.onlineGrocery:
        return LucideIcons.shoppingBasket;
      case RewardCategory.gas:
        return LucideIcons.fuel;
      case RewardCategory.evCharging:
        return LucideIcons.batteryCharging;
      case RewardCategory.travel:
        return LucideIcons.plane;
      case RewardCategory.hotels:
        return LucideIcons.hotel;
      case RewardCategory.airlines:
        return LucideIcons.planeTakeoff;
      case RewardCategory.carRentals:
        return LucideIcons.car;
      case RewardCategory.drugStores:
        return LucideIcons.pill;
      case RewardCategory.streaming:
        return LucideIcons.tv;
      case RewardCategory.entertainment:
        return LucideIcons.film;
      case RewardCategory.movieTheaters:
        return LucideIcons.clapperboard;
      case RewardCategory.onlineShopping:
        return LucideIcons.package;
      case RewardCategory.wholesale:
        return LucideIcons.warehouse;
      case RewardCategory.transit:
        return LucideIcons.trainFront;
      case RewardCategory.departmentStores:
        return LucideIcons.store;
      case RewardCategory.phoneAndInternet:
        return LucideIcons.smartphone;
      case RewardCategory.officeSupply:
        return LucideIcons.paperclip;
      case RewardCategory.homeImprovement:
        return LucideIcons.hammer;
      case RewardCategory.fitness:
        return LucideIcons.dumbbell;
      case RewardCategory.utilities:
        return LucideIcons.plug;
      case RewardCategory.rent:
        return LucideIcons.house;
      case RewardCategory.advertising:
        return LucideIcons.megaphone;
      case RewardCategory.apparel:
        return LucideIcons.shirt;
      case RewardCategory.shipping:
        return LucideIcons.truck;
      case RewardCategory.electronics:
        return LucideIcons.monitor;
      case RewardCategory.sportingGoods:
        return LucideIcons.bike;
      case RewardCategory.pets:
        return LucideIcons.pawPrint;
      case RewardCategory.medical:
        return LucideIcons.stethoscope;
      case RewardCategory.other:
        return LucideIcons.creditCard;
    }
  }

  /// Travel sub-categories: `travel` is their superset. Issuers define a
  /// "travel" bonus to cover hotels, airlines, car rentals, and commuter
  /// transit, so a general `travel` reward rule also applies at these
  /// merchants. The reward engine uses this to let a `travel` rule compete at a
  /// hotel/airline/car-rental/transit lookup (richest rate wins).
  bool get isTravelSubcategory =>
      this == RewardCategory.hotels ||
      this == RewardCategory.airlines ||
      this == RewardCategory.carRentals ||
      this == RewardCategory.transit;

  /// Gas superset: an EV charging station and a gas station are distinct
  /// merchants (distinct Google Place types), but issuers overwhelmingly define
  /// a "gas" bonus to also cover EV charging, so a general `gas` rule competes
  /// at an `evCharging` lookup — mirroring `travel`/`transit`. A rule may carve
  /// it out (`excludedCategories`) when the terms exclude EV, and a card with a
  /// dedicated EV rate ships its own `evCharging` rule (richest rate wins).
  bool get isGasSubcategory => this == RewardCategory.evCharging;

  /// Entertainment superset: issuers define a broad "entertainment" bonus
  /// (Capital One Savor, US Bank Cash+) that covers movie theaters, so a
  /// general `entertainment` rule competes at a `movieTheaters` lookup —
  /// mirroring `travel`/`gas`. A rule may carve it out (`excludedCategories`)
  /// when the terms exclude movie theaters — Chase Freedom Flex's rotating
  /// "Select Live Entertainment" 5% excludes them — so the general rate
  /// doesn't leak onto a movie ticket.
  bool get isEntertainmentSubcategory => this == RewardCategory.movieTheaters;

  /// Round-trips an enum name from SQLite. Falls back to `other` so any
  /// historically-stored string (or a future-added value the running
  /// build doesn't know about) doesn't crash.
  ///
  /// O(1) via the precomputed [_byName] map; the prior linear scan ran
  /// on every ranker row and was ~2M iterations at 100k transactions
  /// × 19 values.
  static RewardCategory fromName(String s) {
    final match = _byName[s];
    if (match != null) return match;
    // Unknown/future category id — fall back to `other`, but breadcrumb it so a
    // vocab that outran this build (see categories.json `vocabVersion`) is
    // diagnosable instead of failing silently. Deduped per distinct value:
    // this runs on every ranker row, so a whole sync of one unknown id must
    // not spam the log.
    if (_warnedUnknownNames.add(s)) {
      Log.w(
        'categories',
        'unknown RewardCategory "$s" → other '
            '(vocab may be newer than this build)',
      );
    }
    return RewardCategory.other;
  }
}

final Map<String, RewardCategory> _byName = {
  for (final v in RewardCategory.values) v.name: v,
};

/// Distinct unknown names already breadcrumbed by [RewardCategory.fromName], so
/// the fallback log fires once per value rather than once per ranker row.
final Set<String> _warnedUnknownNames = <String>{};
