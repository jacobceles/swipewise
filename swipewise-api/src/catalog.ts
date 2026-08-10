// Pure catalog-shaping logic shared by the Worker (runtime slicing) and the
// tests. No Workers or Node APIs here so it can be unit-tested directly.
//
// A "slice" is a catalog narrowed to a subset of cards but kept in the exact
// same shape as the full build — same version headers, same five arrays — so
// the app's CatalogLoader can hydrate a slice with the identical code path it
// uses for the whole catalog.

export interface Catalog {
  catalogVersion: string;
  dataVersion: number;
  schemaVersion: number;
  point_systems: Array<Record<string, unknown> & { point_system_id: string }>;
  card_products: Array<Record<string, unknown> & { card_product_id: string }>;
  reward_rules: Array<
    Record<string, unknown> & {
      rule_id: string;
      card_product_id: string;
      point_system_id: string;
    }
  >;
  reward_rule_exclusions: Array<Record<string, unknown> & { rule_id: string }>;
  product_perks: Array<Record<string, unknown> & { card_product_id: string }>;
}

/** The issuer key embedded in a `card_product_id` (`chase.freedom-flex` -> `chase`). */
export function bankOf(cardProductId: string): string {
  const dot = cardProductId.indexOf('.');
  return dot === -1 ? cardProductId : cardProductId.slice(0, dot);
}

/**
 * Narrow `catalog` to exactly `cardIds`, dropping every row that doesn't belong
 * to one of them. Point systems are kept only when a surviving rule references
 * them, so a slice never ships dangling FKs or unused valuations.
 */
export function sliceByCards(catalog: Catalog, cardIds: Iterable<string>): Catalog {
  const ids = new Set(cardIds);

  const card_products = catalog.card_products.filter((c) => ids.has(c.card_product_id));
  const reward_rules = catalog.reward_rules.filter((r) => ids.has(r.card_product_id));
  const product_perks = catalog.product_perks.filter((p) => ids.has(p.card_product_id));

  const ruleIds = new Set(reward_rules.map((r) => r.rule_id));
  const reward_rule_exclusions = catalog.reward_rule_exclusions.filter((e) =>
    ruleIds.has(e.rule_id),
  );

  const usedPointSystems = new Set(reward_rules.map((r) => r.point_system_id));
  const point_systems = catalog.point_systems.filter((p) =>
    usedPointSystems.has(p.point_system_id),
  );

  return {
    catalogVersion: catalog.catalogVersion,
    dataVersion: catalog.dataVersion,
    schemaVersion: catalog.schemaVersion,
    point_systems,
    card_products,
    reward_rules,
    reward_rule_exclusions,
    product_perks,
  };
}

/** All cards whose `card_product_id` is prefixed with `bank` (case-insensitive). */
export function sliceByBank(catalog: Catalog, bank: string): Catalog {
  const want = bank.toLowerCase();
  const ids = catalog.card_products
    .map((c) => c.card_product_id)
    .filter((id) => bankOf(id).toLowerCase() === want);
  return sliceByCards(catalog, ids);
}

/** A single card by id (a one-element [sliceByCards]). */
export function sliceByCard(catalog: Catalog, cardId: string): Catalog {
  return sliceByCards(catalog, [cardId]);
}

/**
 * A lightweight index of the catalog: versions, banks with counts, and the
 * card id/name list. Cheap for the app to poll and decide what to fetch.
 */
export function manifestSummary(catalog: Catalog) {
  const counts = new Map<string, number>();
  for (const c of catalog.card_products) {
    const b = bankOf(c.card_product_id);
    counts.set(b, (counts.get(b) ?? 0) + 1);
  }
  return {
    catalogVersion: catalog.catalogVersion,
    dataVersion: catalog.dataVersion,
    schemaVersion: catalog.schemaVersion,
    banks: [...counts]
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([bank, card_count]) => ({ bank, card_count })),
    cards: catalog.card_products
      .map((c) => ({
        card_product_id: c.card_product_id,
        display_name: (c.display_name as string | undefined) ?? null,
      }))
      .sort((a, b) => a.card_product_id.localeCompare(b.card_product_id)),
  };
}
