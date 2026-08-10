/// Static list of US issuers shown on the empty-query state of the Add
/// Bank institution picker. Tapping a tile fires the same v2 institution
/// search the picker uses and advances to the credentials form with the
/// top result - so we don't hardcode Sophtron `InstitutionID` values
/// (their 53K-entry catalog has multiple subtenants per issuer and IDs
/// aren't stable contracts).
///
/// Logos come from Sophtron via a parallel prefetch the picker fires on
/// mount - same source the search results use, so brand marks stay in
/// sync with whatever Sophtron ships and we don't have to babysit
/// per-bank CDN URLs.
///
/// Order matters: shown left-to-right, top-to-bottom in a 2-column grid.
class PopularBank {
  const PopularBank({required this.displayName, required this.searchQuery});

  /// Label shown under the tile.
  final String displayName;

  /// Sent to `client.searchInstitutions(query: ...)` on tap. Pick the
  /// shortest / most canonical name - Sophtron sorts by length-then-name
  /// on the picker side too, so the top result is usually the consumer
  /// mainstream entry, not an obscure subtenant.
  final String searchQuery;
}

const List<PopularBank> kPopularBanks = [
  PopularBank(displayName: 'Chase', searchQuery: 'Chase'),
  PopularBank(displayName: 'American Express', searchQuery: 'American Express'),
  PopularBank(displayName: 'Citi', searchQuery: 'Citi'),
  PopularBank(displayName: 'Capital One', searchQuery: 'Capital One'),
  PopularBank(displayName: 'Discover', searchQuery: 'Discover'),
  PopularBank(displayName: 'Bank of America', searchQuery: 'Bank of America'),
  PopularBank(displayName: 'Wells Fargo', searchQuery: 'Wells Fargo'),
  PopularBank(displayName: 'US Bank', searchQuery: 'US Bank'),
];
