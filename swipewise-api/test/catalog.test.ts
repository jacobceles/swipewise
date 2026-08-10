import { describe, expect, it } from 'vitest';

import {
  type Catalog,
  bankOf,
  manifestSummary,
  sliceByBank,
  sliceByCard,
  sliceByCards,
} from '../src/catalog';

const catalog: Catalog = {
  catalogVersion: '2026.06.18',
  dataVersion: 2,
  schemaVersion: 1,
  point_systems: [
    { point_system_id: 'usd', display_name: 'Cash back', baseline_cent_value: 1.0 },
    { point_system_id: 'chase.ur', display_name: 'Ultimate Rewards', baseline_cent_value: 1.25 },
    { point_system_id: 'discover.miles', display_name: 'Miles', baseline_cent_value: 1.0 },
  ],
  card_products: [
    { card_product_id: 'chase.freedom-flex', display_name: 'Freedom Flex' },
    { card_product_id: 'chase.sapphire-preferred', display_name: 'Sapphire Preferred' },
    { card_product_id: 'discover.it-card', display_name: 'Discover it' },
  ],
  reward_rules: [
    { rule_id: 'r1', card_product_id: 'chase.freedom-flex', point_system_id: 'usd' },
    { rule_id: 'r2', card_product_id: 'chase.sapphire-preferred', point_system_id: 'chase.ur' },
    { rule_id: 'r3', card_product_id: 'discover.it-card', point_system_id: 'discover.miles' },
  ],
  reward_rule_exclusions: [
    { rule_id: 'r1', brand: 'costco' },
    { rule_id: 'r3', brand: 'walmart' },
  ],
  product_perks: [
    { card_product_id: 'chase.sapphire-preferred', perk_id: 'p1', title: 'Trip protection' },
    { card_product_id: 'discover.it-card', perk_id: 'p2', title: 'FICO score' },
  ],
};

describe('bankOf', () => {
  it('takes the prefix before the first dot', () => {
    expect(bankOf('chase.freedom-flex')).toBe('chase');
    expect(bankOf('discover.it-card')).toBe('discover');
    expect(bankOf('nodots')).toBe('nodots');
  });
});

describe('sliceByBank', () => {
  const chase = sliceByBank(catalog, 'chase');

  it('keeps only that issuer’s cards, rules, exclusions and perks', () => {
    expect(chase.card_products.map((c) => c.card_product_id)).toEqual([
      'chase.freedom-flex',
      'chase.sapphire-preferred',
    ]);
    expect(chase.reward_rules.map((r) => r.rule_id)).toEqual(['r1', 'r2']);
    expect(chase.reward_rule_exclusions.map((e) => e.rule_id)).toEqual(['r1']);
    expect(chase.product_perks.map((p) => p.card_product_id)).toEqual(['chase.sapphire-preferred']);
  });

  it('keeps only point systems referenced by surviving rules', () => {
    expect(chase.point_systems.map((p) => p.point_system_id).sort()).toEqual(['chase.ur', 'usd']);
  });

  it('preserves the version headers', () => {
    expect(chase.catalogVersion).toBe('2026.06.18');
    expect(chase.dataVersion).toBe(2);
    expect(chase.schemaVersion).toBe(1);
  });

  it('is case-insensitive', () => {
    expect(sliceByBank(catalog, 'CHASE').card_products).toHaveLength(2);
  });
});

describe('sliceByCard / sliceByCards', () => {
  it('returns exactly one card and its dependencies', () => {
    const slice = sliceByCard(catalog, 'discover.it-card');
    expect(slice.card_products).toHaveLength(1);
    expect(slice.reward_rules.map((r) => r.rule_id)).toEqual(['r3']);
    expect(slice.reward_rule_exclusions.map((e) => e.rule_id)).toEqual(['r3']);
    expect(slice.point_systems.map((p) => p.point_system_id)).toEqual(['discover.miles']);
  });

  it('resolves an arbitrary cross-issuer set', () => {
    const slice = sliceByCards(catalog, ['chase.freedom-flex', 'discover.it-card']);
    expect(slice.card_products.map((c) => c.card_product_id)).toEqual([
      'chase.freedom-flex',
      'discover.it-card',
    ]);
    expect(slice.point_systems.map((p) => p.point_system_id).sort()).toEqual([
      'discover.miles',
      'usd',
    ]);
  });

  it('returns an empty-but-shaped slice for unknown ids', () => {
    const slice = sliceByCards(catalog, ['nope.nothing']);
    expect(slice.card_products).toHaveLength(0);
    expect(slice.point_systems).toHaveLength(0);
    expect(slice.dataVersion).toBe(2);
  });
});

describe('manifestSummary', () => {
  const m = manifestSummary(catalog);

  it('counts cards per bank', () => {
    expect(m.banks).toEqual([
      { bank: 'chase', card_count: 2 },
      { bank: 'discover', card_count: 1 },
    ]);
  });

  it('lists every card sorted by id and carries versions', () => {
    expect(m.cards).toHaveLength(3);
    expect(m.cards[0]!.card_product_id).toBe('chase.freedom-flex');
    expect(m.dataVersion).toBe(2);
  });
});
