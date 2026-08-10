import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import type { Catalog } from '../src/catalog';

// Schema-shape sanity guard for the committed free bundle. This is the one object
// the Worker serves AND the app ships in-APK as its offline fallback, so a schema
// regression from the backend engine (a dropped column, a dangling foreign key, a
// silent schemaVersion bump, a duplicate id) breaks the app. Catching it here, in
// the repo that owns the published artifact, fails a bad bundle before it ships.
//
// This is the API-side half of the cross-repo contract test: it validates the
// bundle's internal shape and referential integrity without needing the app. The
// column-parity-against-the-app half still requires a shared-tree test (see ROADMAP).
//
// Deliberately structural, not census: counts (181 cards, 933 rules) change on every
// rebuild and are NOT asserted. schemaVersion IS pinned — a bump must be a conscious
// edit here, coordinated with the app's schemaVersion gate.

const catalog = JSON.parse(
  readFileSync(new URL('../catalog/free.json', import.meta.url), 'utf8'),
) as Catalog;

const isStr = (v: unknown): boolean => typeof v === 'string' && v.length > 0;
const isNum = (v: unknown): boolean => typeof v === 'number' && Number.isFinite(v);

const ARRAYS = [
  'card_products',
  'reward_rules',
  'reward_rule_exclusions',
  'product_perks',
  'point_systems',
] as const;

describe('free.json — version headers', () => {
  it('carries the three version fields with the right types', () => {
    expect(catalog.catalogVersion).toMatch(/^\d{4}\.\d{2}\.\d{2}$/);
    expect(isNum(catalog.dataVersion)).toBe(true);
  });

  it('pins schemaVersion to 1 (a bump must be edited here + coordinated with the app)', () => {
    expect(catalog.schemaVersion).toBe(1);
  });
});

describe('free.json — the five arrays', () => {
  it('are all present and non-empty', () => {
    for (const key of ARRAYS) {
      expect(Array.isArray(catalog[key]), key).toBe(true);
      expect(catalog[key].length, key).toBeGreaterThan(0);
    }
  });
});

describe('free.json — required columns', () => {
  it('card_products carry an id + the fields the app/free-tier depend on', () => {
    for (const c of catalog.card_products) {
      expect(isStr(c.card_product_id)).toBe(true);
      expect(isStr(c.display_name), c.card_product_id).toBe(true);
      expect(isStr(c.issuer), c.card_product_id).toBe(true);
      // annual_fee_usd + foreign_tx_fee_pct are the FREE-bundle tiering fields
      // (kept free by design, B3-S3); a regression dropping them changes rankings.
      expect('annual_fee_usd' in c, c.card_product_id).toBe(true);
      expect('foreign_tx_fee_pct' in c, c.card_product_id).toBe(true);
    }
  });

  it('reward_rules carry both foreign keys, a numeric rate, and a kind', () => {
    for (const r of catalog.reward_rules) {
      expect(isStr(r.rule_id)).toBe(true);
      expect(isStr(r.card_product_id), r.rule_id).toBe(true);
      expect(isStr(r.point_system_id), r.rule_id).toBe(true);
      expect(isNum(r.rate), r.rule_id).toBe(true);
      expect(isStr(r.kind), r.rule_id).toBe(true);
    }
  });

  it('point_systems carry an id + the baseline valuation the ranker multiplies by', () => {
    for (const p of catalog.point_systems) {
      expect(isStr(p.point_system_id)).toBe(true);
      expect(isNum(p.baseline_cent_value), p.point_system_id).toBe(true);
    }
  });

  it('product_perks carry a perk id + a card foreign key', () => {
    for (const p of catalog.product_perks) {
      expect(isStr(p.perk_id)).toBe(true);
      expect(isStr(p.card_product_id), String(p.perk_id)).toBe(true);
    }
  });

  it('reward_rule_exclusions carry a rule foreign key', () => {
    for (const e of catalog.reward_rule_exclusions) {
      expect(isStr(e.rule_id)).toBe(true);
    }
  });
});

describe('free.json — referential integrity', () => {
  const cardIds = new Set(catalog.card_products.map((c) => c.card_product_id));
  const ruleIds = new Set(catalog.reward_rules.map((r) => r.rule_id));
  const psIds = new Set(catalog.point_systems.map((p) => p.point_system_id));

  it('has no duplicate card or rule ids (A1-F14: a dropped dup silently vanishes a card)', () => {
    expect(cardIds.size, 'card_product_id').toBe(catalog.card_products.length);
    expect(ruleIds.size, 'rule_id').toBe(catalog.reward_rules.length);
  });

  it('every reward_rule points at an existing card and point system', () => {
    for (const r of catalog.reward_rules) {
      expect(cardIds.has(r.card_product_id), `rule ${r.rule_id} -> card ${r.card_product_id}`).toBe(
        true,
      );
      expect(psIds.has(r.point_system_id), `rule ${r.rule_id} -> ps ${r.point_system_id}`).toBe(
        true,
      );
    }
  });

  it('every perk points at an existing card', () => {
    for (const p of catalog.product_perks) {
      expect(cardIds.has(p.card_product_id), `perk ${p.perk_id}`).toBe(true);
    }
  });

  it('every exclusion points at an existing rule', () => {
    for (const e of catalog.reward_rule_exclusions) {
      expect(ruleIds.has(e.rule_id), `exclusion -> rule ${e.rule_id}`).toBe(true);
    }
  });
});
