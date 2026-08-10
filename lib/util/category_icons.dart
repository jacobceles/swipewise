import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class CategoryColors {
  const CategoryColors({required this.iconColor, required this.bgColor});
  final Color iconColor;
  final Color bgColor;
}

/// Resolves a lucide icon for a category label / icon_id pair that come from
/// the bundled reward seed or Sophtron's free-form category strings. The map
/// is intentionally narrow - anything we haven't classified renders as the
/// generic `circle-ellipsis`. Callers that need an exact icon for a known
/// `RewardCategory` enum should consult that enum directly.
IconData iconForCategory(String? label, {String? iconId}) {
  final id = (iconId ?? '').toLowerCase();
  if (id.isNotEmpty) {
    final byId = _byIconId[id];
    if (byId != null) return byId;
  }
  final l = (label ?? '').toLowerCase();
  if (l.contains('dining') || l.contains('food') || l.contains('restaurant')) {
    return LucideIcons.utensils;
  }
  if (l.contains('coffee')) return LucideIcons.coffee;
  if (l.contains('grocer')) return LucideIcons.shoppingCart;
  if (l.contains('shop')) return LucideIcons.shoppingBag;
  if (l.contains('travel') || l.contains('flight') || l.contains('airline')) {
    return LucideIcons.plane;
  }
  if (l.contains('hotel') || l.contains('lodg')) return LucideIcons.hotel;
  if (l.contains('gas') || l.contains('fuel')) return LucideIcons.fuel;
  if (l.contains('rideshare') || l.contains('uber') || l.contains('lyft')) {
    return LucideIcons.car;
  }
  if (l.contains('transit') || l.contains('transport')) {
    return LucideIcons.trainFront;
  }
  if (l.contains('streaming') ||
      l.contains('subscription') ||
      l.contains('tv')) {
    return LucideIcons.tv;
  }
  if (l.contains('entertainment') ||
      l.contains('movie') ||
      l.contains('music')) {
    return LucideIcons.film;
  }
  if (l.contains('utilit') || l.contains('bill')) return LucideIcons.receipt;
  if (l.contains('health') || l.contains('medical')) {
    return LucideIcons.stethoscope;
  }
  if (l.contains('pharm') || l.contains('drug')) return LucideIcons.pill;
  if (l.contains('fitness') || l.contains('gym')) return LucideIcons.dumbbell;
  if (l.contains('home') || l.contains('improvement')) {
    return LucideIcons.hammer;
  }
  if (l.contains('online') || l.contains('amazon')) return LucideIcons.package;
  if (l.contains('department') || l.contains('wholesale')) {
    return LucideIcons.store;
  }
  return LucideIcons.circleEllipsis;
}

CategoryColors colorsForCategory(String? label, {String? iconId}) {
  final l = ((iconId?.isNotEmpty == true ? iconId : null) ?? label ?? '')
      .toLowerCase();

  // Dining / Food & Drink (Brown)
  if (l.contains('dining') || l.contains('food') || l.contains('restaurant')) {
    return const CategoryColors(
      iconColor: Color(0xFFFF9F60),
      bgColor: Color(0xFF3E2723),
    );
  }
  // Coffee (Tan)
  if (l.contains('coffee') || l.contains('starbucks')) {
    return const CategoryColors(
      iconColor: Color(0xFFD7CCC8),
      bgColor: Color(0xFF4E342E),
    );
  }
  // Grocery / Supermarkets (Green)
  if (l.contains('grocery') ||
      l.contains('grocer') ||
      l.contains('whole foods') ||
      l.contains('supermarket')) {
    return const CategoryColors(
      iconColor: Color(0xFF4ADE80),
      bgColor: Color(0xFF064E3B),
    );
  }
  // Wholesale (Teal/Cyan)
  if (l.contains('wholesale') ||
      l.contains('warehouse') ||
      l.contains('costco') ||
      l.contains('sam\'s club')) {
    return const CategoryColors(
      iconColor: Color(0xFF2DD4BF),
      bgColor: Color(0xFF134E4A),
    );
  }
  // Gas / Automotive (Orange)
  if (l.contains('gas') || l.contains('fuel') || l.contains('shell')) {
    return const CategoryColors(
      iconColor: Color(0xFFFB923C),
      bgColor: Color(0xFF431407),
    );
  }
  // Shopping / Online / Amazon (Blue)
  if (l.contains('amazon') ||
      l.contains('online') ||
      l.contains('shop') ||
      l.contains('department')) {
    return const CategoryColors(
      iconColor: Color(0xFF60A5FA),
      bgColor: Color(0xFF1E3A8A),
    );
  }
  // Travel / Airlines / Hotels (Indigo)
  if (l.contains('travel') ||
      l.contains('flight') ||
      l.contains('airline') ||
      l.contains('hotel') ||
      l.contains('lodg')) {
    return const CategoryColors(
      iconColor: Color(0xFF818CF8),
      bgColor: Color(0xFF312E81),
    );
  }
  // Rideshare / Transit (Purple)
  if (l.contains('uber') ||
      l.contains('lyft') ||
      l.contains('rideshare') ||
      l.contains('transit') ||
      l.contains('transport')) {
    return const CategoryColors(
      iconColor: Color(0xFFA78BFA),
      bgColor: Color(0xFF4C1D95),
    );
  }
  // Entertainment / Streaming / Netflix (Red)
  if (l.contains('netflix') ||
      l.contains('streaming') ||
      l.contains('tv') ||
      l.contains('entertainment') ||
      l.contains('target')) {
    return const CategoryColors(
      iconColor: Color(0xFFF87171),
      bgColor: Color(0xFF7F1D1D),
    );
  }
  // Drug Stores (Pink)
  if (l.contains('drug') ||
      l.contains('pharm') ||
      l.contains('pill') ||
      l.contains('health') ||
      l.contains('medical')) {
    return const CategoryColors(
      iconColor: Color(0xFFF472B6),
      bgColor: Color(0xFF831843),
    );
  }
  // Recreation / Fitness (Lime)
  if (l.contains('recreation') ||
      l.contains('fitness') ||
      l.contains('gym') ||
      l.contains('yoga')) {
    return const CategoryColors(
      iconColor: Color(0xFFA3E635),
      bgColor: Color(0xFF365314),
    );
  }
  // Services (Slate/Muted)
  if (l.contains('service') ||
      l.contains('utilit') ||
      l.contains('bill') ||
      l.contains('phone') ||
      l.contains('internet')) {
    return const CategoryColors(
      iconColor: Color(0xFF94A3B8),
      bgColor: Color(0xFF1E293B),
    );
  }

  // Fallback (Muted Gray)
  return const CategoryColors(
    iconColor: Color(0xFFA1A1AA), // zinc-400
    bgColor: Color(0xFF27272A), // zinc-800
  );
}

const Map<String, IconData> _byIconId = {
  'dining': LucideIcons.utensils,
  'restaurant': LucideIcons.utensils,
  'food': LucideIcons.utensils,
  'coffee': LucideIcons.coffee,
  'grocery': LucideIcons.shoppingCart,
  'groceries': LucideIcons.shoppingCart,
  'shopping': LucideIcons.shoppingBag,
  'travel': LucideIcons.plane,
  'flight': LucideIcons.plane,
  'airline': LucideIcons.plane,
  'hotel': LucideIcons.hotel,
  'gas': LucideIcons.fuel,
  'fuel': LucideIcons.fuel,
  'transit': LucideIcons.trainFront,
  'rideshare': LucideIcons.car,
  'entertainment': LucideIcons.film,
  'streaming': LucideIcons.tv,
  'utilities': LucideIcons.receipt,
  'health': LucideIcons.stethoscope,
  'pharmacy': LucideIcons.pill,
  'drug': LucideIcons.pill,
  'fitness': LucideIcons.dumbbell,
  'home': LucideIcons.hammer,
  'online': LucideIcons.package,
  'department': LucideIcons.store,
  'wholesale': LucideIcons.store,
};
