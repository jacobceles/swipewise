import 'google_place_type_map.dart';

/// Maps a Google Places `primaryType` string (or a category name fallback)
/// to the display label that [classifyLooseLabel] understands.
///
/// Primary lookup is [kGooglePlaceTypeToLabel] (keyed by `primaryType`).
/// Name-based heuristics serve as a fallback for cases where `primaryType`
/// is absent or not in the map (e.g. an unusual place category).
class CategoryLabelResolver {
  static String? labelFor({String? categoryId, String? categoryName}) {
    if (categoryId != null) {
      final byType = kGooglePlaceTypeToLabel[categoryId];
      if (byType != null) return byType;
    }
    final lower = (categoryName ?? '').toLowerCase();
    if (lower.isEmpty) return null;
    if (lower.contains('coffee') || lower.contains('café')) return 'Coffee';
    if (lower.contains('grocery') || lower.contains('supermarket')) {
      return 'Grocery';
    }
    if (lower.contains('gas') || lower.contains('fuel')) return 'Gas';
    if (lower.contains('pharmacy') || lower.contains('drug')) {
      return 'Drug Stores';
    }
    if (lower.contains('hotel') ||
        lower.contains('motel') ||
        lower.contains('resort') ||
        lower.contains('lodging') ||
        lower.contains('inn')) {
      return 'Travel';
    }
    if (lower.contains('restaurant') ||
        lower.contains('food') ||
        lower.contains('dining') ||
        lower.contains('joint')) {
      return 'Dining';
    }
    if (lower.contains('shop') ||
        lower.contains('store') ||
        lower.contains('retail') ||
        lower.contains('market')) {
      return 'Shopping';
    }
    return categoryName;
  }
}
