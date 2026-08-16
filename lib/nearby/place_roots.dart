import 'package:flutter/material.dart';

/// A logical grouping of Google Places API place types shown to the user
/// as a toggleable category in Nearby Stores settings.
class PlaceRoot {
  final String id;
  final String label;
  final String description;
  final IconData icon;
  final bool defaultEnabled;

  /// Google Places API `includedTypes` values for this group.
  final List<String> includedTypes;

  const PlaceRoot({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
    required this.defaultEnabled,
    required this.includedTypes,
  });
}

/// ⚠️ **These lists look short on purpose — do not "complete" them.**
///
/// Google's place types are hierarchical and a place carries its parents in `types[]`, which
/// `includedTypes` matches against — not just `primaryType`. So `'restaurant'` already returns
/// pizzerias, delis and coffee shops, and `'lodging'` already returns hotels, motels and hostels.
/// Listing the children changes nothing except the bill.
///
/// That bill is a **step function**: the API caps `includedTypes` at 50, so the app fans out into
/// `ceil(types / 50)` billed Nearby requests per tile. The default set was **146 types = 3
/// requests**; it is now **75 = 2**. A trim that doesn't cross a multiple of 50 saves exactly
/// nothing, which is why this was measured rather than eyeballed.
///
/// Measured 2026-08-15, one query per type in two deliberately different markets (midtown
/// Manhattan and suburban Plano TX), keeping a type only when some sampled place of that type
/// carried **no** retained parent. 64 of the 71 dropped types were confirmed redundant in *both*
/// markets with zero contradictions; the other 7 (ferry terminals, opera houses, subway stations —
/// absent from suburban Texas) were confirmed in Manhattan alone. Spot-checked the ones that would
/// hurt most if wrong: every sampled supermarket, grocery and convenience store carried
/// `food_store`; every hotel carried `lodging`; every train and subway station carried
/// `transit_station`.
///
/// It is a *sample*, not a proof. If merchants of some kind stop appearing in Nearby, this is the
/// first place to look — re-add that specific type rather than reverting the trim.
///
/// The four roots that are off by default were left untouched: they were never in the measured
/// set, and enabling them all pushes the total back over 100 (i.e. back to 3 requests).
const kPlaceRoots = <PlaceRoot>[
  PlaceRoot(
    id: 'grocery',
    label: 'Grocery & Convenience',
    description: 'Supermarkets, warehouse stores & convenience stores',
    icon: Icons.local_grocery_store,
    defaultEnabled: true,
    includedTypes: [
      'warehouse_store',
      'discount_store',
      'liquor_store',
      'food_store',
      'market',
    ],
  ),
  PlaceRoot(
    id: 'gas',
    label: 'Gas Stations',
    description: 'Gas stations & EV charging',
    icon: Icons.local_gas_station,
    defaultEnabled: true,
    includedTypes: [
      'gas_station',
      'electric_vehicle_charging_station',
    ],
  ),
  PlaceRoot(
    id: 'dining',
    label: 'Dining',
    description: 'Restaurants, cafes, bars & food delivery',
    icon: Icons.restaurant,
    defaultEnabled: true,
    includedTypes: [
      'restaurant',
      'cafe',
      'bar',
      'coffee_roastery',
      'coffee_stand',
      'food_court',
      'catering_service',
      'meal_delivery',
      'brewery',
      'winery',
      'night_club',
      'juice_shop',
      'tea_house',
    ],
  ),
  PlaceRoot(
    id: 'retail',
    label: 'Retail',
    description: 'Clothing, electronics, home goods & malls',
    icon: Icons.shopping_bag,
    defaultEnabled: true,
    includedTypes: [
      'clothing_store',
      'shoe_store',
      'electronics_store',
      'jewelry_store',
      'book_store',
      'home_goods_store',
      'hardware_store',
      'sporting_goods_store',
      'department_store',
      'shopping_mall',
      'gift_shop',
      'cell_phone_store',
      'cosmetics_store',
      'pet_store',
      'toy_store',
      'florist',
      'wholesaler',
    ],
  ),
  PlaceRoot(
    id: 'beauty',
    label: 'Beauty & Wellness',
    description: 'Salons, spas & personal care',
    icon: Icons.spa,
    defaultEnabled: true,
    includedTypes: [
      'beauty_salon',
      'hair_salon',
      'spa',
      'massage',
      'barber_shop',
      'tanning_studio',
      'wellness_center',
    ],
  ),
  PlaceRoot(
    id: 'automotive',
    label: 'Automotive',
    description: 'Car dealers, repair shops & car washes',
    icon: Icons.directions_car,
    defaultEnabled: true,
    includedTypes: [
      'car_dealer',
      'car_repair',
      'car_wash',
    ],
  ),
  PlaceRoot(
    id: 'travel',
    label: 'Travel',
    description: 'Airports, hotels & transit',
    icon: Icons.flight,
    defaultEnabled: true,
    includedTypes: [
      'airport',
      'lodging',
      'transit_station',
      'car_rental',
    ],
  ),
  PlaceRoot(
    id: 'arts',
    label: 'Arts & Entertainment',
    description: 'Museums, theaters, galleries & nightlife',
    icon: Icons.theater_comedy,
    defaultEnabled: true,
    includedTypes: [
      'museum',
      'art_gallery',
      'movie_theater',
      'performing_arts_theater',
      'live_music_venue',
      'comedy_club',
      'amusement_park',
      'amusement_center',
      'aquarium',
      'casino',
      'zoo',
    ],
  ),
  PlaceRoot(
    id: 'sports',
    label: 'Sports & Recreation',
    description: 'Gyms, stadiums, courts & recreation',
    icon: Icons.sports,
    defaultEnabled: true,
    includedTypes: [
      'gym',
      'sports_complex',
      'sports_club',
      'golf_course',
      'swimming_pool',
      'tennis_court',
      'arena',
      'ski_resort',
    ],
  ),
  PlaceRoot(
    id: 'event',
    // Disabled by default: none of these types resolve via categoryForPlaceType
    // (categories.json googlePlaceTypes) and none carry a display label, so
    // fencing here yields uncategorised, raw-type-labelled notifications with no
    // reward benefit. A wedding venue / banquet hall also rarely codes as any
    // rewardable MCC (place type ≠ MCC). Opt-in only until rules/coverage exist.
    label: 'Events',
    description: 'Convention centers, venues & halls',
    icon: Icons.event,
    defaultEnabled: false,
    includedTypes: [
      'event_venue',
      'convention_center',
      'wedding_venue',
      'banquet_hall',
    ],
  ),
  PlaceRoot(
    id: 'business',
    label: 'Financial',
    description: 'Banks, ATMs & post offices',
    icon: Icons.account_balance,
    defaultEnabled: true,
    includedTypes: [
      'bank',
      'atm',
      'post_office',
    ],
  ),
  PlaceRoot(
    id: 'drugstore',
    label: 'Drug Stores',
    description: 'Pharmacies & drug stores',
    icon: Icons.local_pharmacy,
    defaultEnabled: true,
    includedTypes: [
      'pharmacy',
      'drugstore',
    ],
  ),
  PlaceRoot(
    id: 'health',
    label: 'Health',
    description: 'Hospitals, doctors, dentists & clinics',
    icon: Icons.local_hospital,
    defaultEnabled: false,
    includedTypes: [
      'hospital',
      'general_hospital',
      'doctor',
      'dentist',
      'dental_clinic',
      'medical_clinic',
      'medical_center',
      'chiropractor',
    ],
  ),
  PlaceRoot(
    id: 'outdoors',
    label: 'Outdoors',
    description: 'Parks, nature, beaches & attractions',
    icon: Icons.park,
    defaultEnabled: false,
    includedTypes: [
      'park',
      'city_park',
      'national_park',
      'state_park',
      'tourist_attraction',
      'beach',
      'hiking_area',
      'botanical_garden',
      'wildlife_park',
      'wildlife_refuge',
      'marina',
      'vineyard',
    ],
  ),
  PlaceRoot(
    id: 'community',
    label: 'Community',
    description: 'Places of worship & civic buildings',
    icon: Icons.people,
    defaultEnabled: false,
    includedTypes: [
      'church',
      'mosque',
      'hindu_temple',
      'buddhist_temple',
      'synagogue',
      'shinto_shrine',
      'city_hall',
    ],
  ),
];

/// Place types this app no longer *searches* for, because Google returns them anyway as
/// subtypes of a type in [kPlaceRoots] — verified by sampling (see the note above).
///
/// They are still very much alive downstream: a pizzeria arrives with
/// `primaryType: pizza_restaurant`, so `categories.json` must keep mapping it to a reward
/// category and `kGooglePlaceTypeToLabel` must keep a display label for it. This set is what
/// lets the vocab tests tell "reachable as a subtype" apart from "genuinely unreachable", so
/// a NEW categorised type that nothing can return still fails the guard.
const kTypesReachedViaParentType = <String>{
  'amphitheatre',
  'art_museum',
  'asian_grocery_store',
  'auto_parts_store',
  'bagel_shop',
  'bakery',
  'bar_and_grill',
  'bed_and_breakfast',
  'beer_garden',
  'bicycle_store',
  'bistro',
  'bowling_alley',
  'brewpub',
  'brunch_restaurant',
  'buffet_restaurant',
  'bus_station',
  'bus_stop',
  'butcher_shop',
  'candy_store',
  'cocktail_bar',
  'coffee_shop',
  'concert_hall',
  'convenience_store',
  'deli',
  'dessert_restaurant',
  'dessert_shop',
  'diner',
  'discount_supermarket',
  'donut_shop',
  'extended_stay_hotel',
  'farmers_market',
  'fast_food_restaurant',
  'ferry_terminal',
  'fine_dining_restaurant',
  'fitness_center',
  'furniture_store',
  'gastropub',
  'grocery_store',
  'health_food_store',
  'history_museum',
  'home_improvement_store',
  'hostel',
  'hotel',
  'hypermarket',
  'ice_cream_shop',
  'ice_skating_rink',
  'international_airport',
  'lounge_bar',
  'massage_spa',
  'meal_takeaway',
  'motel',
  'nail_salon',
  'opera_house',
  'pastry_shop',
  'pizza_restaurant',
  'planetarium',
  'pub',
  'resort_hotel',
  'sandwich_shop',
  'snack_bar',
  'sports_bar',
  'sportswear_store',
  'stadium',
  'steak_house',
  'subway_station',
  'supermarket',
  'thrift_store',
  'tire_shop',
  'train_station',
  'wine_bar',
  'yoga_studio',
};

/// IDs of roots enabled by default — used when no user setting exists.
Set<String> get defaultEnabledPlaceRootIds =>
    kPlaceRoots.where((r) => r.defaultEnabled).map((r) => r.id).toSet();

/// Merged `includedTypes` for the given root IDs.
List<String> includedTypesForRoots(Set<String> rootIds) {
  final types = <String>[];
  for (final root in kPlaceRoots) {
    if (rootIds.contains(root.id)) {
      types.addAll(root.includedTypes);
    }
  }
  return types;
}
