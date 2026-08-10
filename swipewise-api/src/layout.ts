// The R2 object layout, shared by the Worker (which reads these keys) and the
// publish CLI (which writes them) so the two can never drift.
//
// Bucket: swipewise-assets — fully PRIVATE. Everything is reached through the
// Worker's R2 binding; nothing is served from a public r2.dev URL.
//   assets/catalog.json     the FREE bundle (rewards slice) — served at /catalog.json
//   assets/paid.json        the PAID bundle (full catalog + enrichment) — gated
//   assets/brands.json      the brand vocabulary
//   assets/categories.json  the category vocabulary (matchers + place types)
//   assets/manifest.json    publish state: sha256 per object (diff source)
//   cards/<id>.<ext>        card art, served by the Worker at /cards/<id>.<ext>
//   archive/<version>.json  permanent per-version copy of the FREE catalog, one
//                           object per catalogVersion, never overwritten (not
//                           served by the Worker — publish CLI only)
//
// The free/paid split (Path B) is a column projection done in the backend engine:
// assets/catalog.json is the rewards columns the app reads;
// assets/paid.json is the full record incl. enrichment. Both are published by the
// publish CLI (scripts/publish.ts) with the same card-art rewrite, driven by
// the backend engine. The public route stays /catalog.json (the app's hardcoded path), it
// just serves the free bundle; /paid.json is gated.

export const R2_CATALOG_KEY = 'assets/catalog.json';
export const R2_PAID_KEY = 'assets/paid.json';
export const R2_BRANDS_KEY = 'assets/brands.json';
export const R2_CATEGORIES_KEY = 'assets/categories.json';
export const R2_MANIFEST_KEY = 'assets/manifest.json';

export function cardKey(cardProductId: string, ext: string): string {
  return `cards/${cardProductId}.${ext}`;
}

/** archive/<catalogVersion>.json — one permanent copy per published catalogVersion. */
export function archiveKey(catalogVersion: string): string {
  return `archive/${catalogVersion}.json`;
}

// Custom-metadata keys on assets/catalog.json (the catalog versions /healthz reports).
// MUST be lower-case: publish.ts writes them via the S3 API (`x-amz-meta-<key>`), and
// R2 canonicalises S3 user-metadata names to lower-case, so the Worker binding reads
// them back lower-cased. A camelCase key here writes fine but reads back `undefined`
// in the Worker (→ /healthz dataVersion: null → smoke fails). Shared so the publish
// writer and the Worker reader can't drift.
export const META_CATALOG_VERSION = 'catalogversion';
export const META_DATA_VERSION = 'dataversion';
