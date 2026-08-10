// Publish CLI: take the FREE catalog bundle at ./catalog/free.json, mirror its
// card art into R2, rewrite each image_url to the Worker's /cards URL, and upload
// only what changed. Optionally ALSO publishes the PAID (full) bundle when
// PAID_CATALOG_FILE points at a full catalog.json — the SAME image rewrite is
// applied, so BOTH R2 bundles point at the Worker. The backend engine drives this (its
// `make publish` / CI) from one build, so free + paid can't drift.
//
//   1. the backend engine copies free.json (a projection of the full catalog) here;
//      brands.json + categories.json are read from the app's canonical
//      assets/vocab/. PAID_CATALOG_FILE (optional) points at the full catalog.
//   2. npm run publish:catalog
//
// What it does:
//   - downloads any card image not already cached in ./cards
//   - rewrites free.json image_url -> ${IMAGE_BASE_URL}/cards/<id>.<ext>
//     (the Worker's card route — the bucket is private, so no r2.dev URL)
//   - applies the SAME rewrite to the paid bundle (→ /paid.json) when
//     PAID_CATALOG_FILE is set; the committed free.json source stays untouched
//     (raw crawled URLs — that's the GitHub-CDN copy), only ./dist is rewritten
//   - sha-diffs free.json (→ /catalog.json) [+ paid.json] + brands.json +
//     categories.json + every image against the R2 manifest and PUTs only
//     changed objects, then updates it
//
// Config comes from .env locally or the environment in CI (see .env.example);
// R2 identifiers never appear in code and are scrubbed from error output, so a
// public CI log can't leak them. Re-running an unchanged catalog = zero writes.

import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { R2, type R2Config } from './lib/r2';
import { archiveCatalog } from './lib/archive';
import { cardsBeforeAssets, describeBytes, sniffImageExt } from './lib/art';
import { diffObjects, isRollback, sha256, type PublishManifest } from './lib/manifest';
import { META_CATALOG_VERSION, META_DATA_VERSION, R2_BRANDS_KEY, R2_CATALOG_KEY, R2_CATEGORIES_KEY, R2_MANIFEST_KEY, R2_PAID_KEY, cardKey } from '../src/layout';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const CATALOG_DIR = join(ROOT, 'catalog');
const CATALOG_FILE = join(CATALOG_DIR, 'free.json');
// brands.json + categories.json are the app-owned canonical vocab (single source); swipewise-api
// lives inside the app repo, so they're read intra-repo from assets/vocab/ — never copied/committed here.
const BRANDS_FILE = join(ROOT, '..', 'assets', 'vocab', 'brands.json');
const CATEGORIES_FILE = join(ROOT, '..', 'assets', 'vocab', 'categories.json');
const CARDS_DIR = join(ROOT, 'cards');
// Records the upstream image_url each cached art file came from, so a changed
// source URL triggers a re-fetch instead of serving the stale cached copy (A3-F4).
const SOURCES_FILE = join(CARDS_DIR, '.sources.json');
const DIST_DIR = join(ROOT, 'dist');

const IMAGE_TYPES: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  gif: 'image/gif',
  svg: 'image/svg+xml',
};

interface Card {
  card_product_id: string;
  image_url?: string;
}

async function main(): Promise<void> {
  loadEnv(join(ROOT, '.env'));
  const cfg = readConfig();

  if (!existsSync(CATALOG_FILE)) {
    fail(`No free bundle at ${CATALOG_FILE}\nRun the backend engine's \`make publish\` to copy free.json here, then re-run.`);
  }

  const catalog = JSON.parse(readFileSync(CATALOG_FILE, 'utf8')) as {
    card_products: Card[];
    catalogVersion: string;
    dataVersion: number;
    schemaVersion: number;
  };
  const cards = catalog.card_products ?? [];
  assertSaneBundle(catalog, cards);
  console.log(`Catalog ${catalog.catalogVersion} (dataVersion ${catalog.dataVersion}): ${cards.length} cards\n`);

  console.log('=== 1/4  Download card art ===');
  await downloadArt(cards, cfg.imageBaseUrl);

  console.log('\n=== 2/4  Rewrite image URLs -> Worker ===');
  const published = rewriteUrls(cards, cfg.imageBaseUrl);
  // Minified (no pretty-print): the app parses this on every cold start and
  // stores it on device, so ~18% off the payload is a free win. The committed
  // catalog/free.json source stays pretty for readable git diffs — only the
  // published/dist bytes are minified.
  const catalogJson = JSON.stringify(catalog);
  // The PAID bundle (full catalog) gets the SAME rewrite, so both R2 copies point
  // at the Worker. It's supplied out-of-band via PAID_CATALOG_FILE and never
  // committed here — null when not publishing paid (free-only run).
  const paidJson = buildPaidJson(cards, catalog);
  // Write the rewritten free bundle to ./dist for inspection; never mutate the
  // committed catalog/free.json source.
  mkdirSync(DIST_DIR, { recursive: true });
  writeFileSync(join(DIST_DIR, 'free.json'), catalogJson);
  if (paidJson) writeFileSync(join(DIST_DIR, 'paid.json'), paidJson);

  console.log('\n=== 3/4  Diff against R2 manifest ===');
  const r2 = new R2(cfg);
  const remote = await readManifest(r2);

  // Monotonicity guard (A3-F8): catalogVersion is a YYYY.MM.DD date passed at build
  // time, so it sorts as a string. Publishing from a STALE checkout would sha-diff
  // as "changed" and silently DOWNGRADE the live catalog — and the smoke gate, which
  // only checks the live API matches what was just published, would stay green.
  // Refuse an older catalogVersion over a newer live one; ALLOW_ROLLBACK=1 overrides
  // (intentional rollback), matching the ALLOW_PARTIAL / ALLOW_STALE_PAID style.
  if (isRollback(catalog.catalogVersion, remote.catalogVersion) && process.env.ALLOW_ROLLBACK !== '1') {
    fail(
      `refusing to publish: local catalogVersion ${catalog.catalogVersion} is older than the live ` +
        `${remote.catalogVersion} — publishing would downgrade the catalog (stale checkout?). ` +
        `Set ALLOW_ROLLBACK=1 to override.`,
    );
  }

  // dataVersion is a content hash (see the backend engine's build.py), not a counter:
  // it carries no ordering, so "is this newer?" is answered by the sha-diff below
  // (publish iff an object's bytes changed), never by comparing dataVersion values.

  const local: Record<string, string> = { [R2_CATALOG_KEY]: sha256(catalogJson) };
  if (existsSync(BRANDS_FILE)) local[R2_BRANDS_KEY] = sha256(readFileSync(BRANDS_FILE));
  if (existsSync(CATEGORIES_FILE)) local[R2_CATEGORIES_KEY] = sha256(readFileSync(CATEGORIES_FILE));
  if (paidJson) local[R2_PAID_KEY] = sha256(paidJson);
  // Free-only run while a paid bundle already exists in R2 (paid tier is live):
  // advancing /catalog.json here would leave /paid.json behind, so paying users
  // get staler data than free ones (A3-F3). That's a data-integrity skew — refuse
  // to publish rather than ship it, matching the backend engine's gate style
  // (ALLOW_PARTIAL / ALLOW_REGRESSION). Escape hatch for a knowing operator (e.g.
  // an urgent free-only hotfix): ALLOW_STALE_PAID=1, which carries the old paid
  // sha forward so it isn't flagged orphaned. Before the paid tier launches there
  // is no paid object, so this never fires on today's normal free-only publishes.
  else if (remote.objects[R2_PAID_KEY]) {
    if (process.env.ALLOW_STALE_PAID !== '1') {
      fail(
        `refusing to publish: a paid bundle exists in R2 but this run has no PAID_CATALOG_FILE,\n` +
          `so /paid.json would serve stale data behind /catalog.json. Re-run with PAID_CATALOG_FILE\n` +
          `to publish both in lockstep, or set ALLOW_STALE_PAID=1 to publish free-only anyway.`,
      );
    }
    local[R2_PAID_KEY] = remote.objects[R2_PAID_KEY];
    console.warn('  ⚠️  ALLOW_STALE_PAID=1 — publishing free-only; /paid.json will serve stale data.');
  }
  for (const [id, { ext, sha }] of published) {
    local[cardKey(id, ext)] = sha;
  }

  const diff = diffObjects(local, remote.objects);
  // --force re-uploads every local object regardless of the manifest. The manifest is
  // only a fast-path cache of "what's in R2"; if it ever gets AHEAD of the actual object
  // (a past run recorded a sha but the PUT never landed), the normal diff reports "0
  // changed" forever and the stale object can never be re-pushed. --force is the escape
  // hatch; the post-upload verify below stops the desync from being written in the first place.
  const force = process.argv.slice(2).includes('--force');
  // Upload cards/* before assets/* (A3-F1): the catalog references art via
  // `?v=<sha8>` immutable URLs, so if the catalog lands first a client can fetch
  // it and pull the OLD art bytes — which the edge then caches immutably under
  // the new URL. Publishing art first closes that window.
  const toUpload = cardsBeforeAssets(force ? Object.keys(local) : diff.changed);
  console.log(
    `  ${toUpload.length} to upload, ${diff.unchanged.length} unchanged, ${diff.removed.length} orphaned` +
      (force ? '  [--force: re-uploading all]' : ''),
  );
  for (const k of diff.removed) console.log(`  orphan (left in R2): ${k}`);

  if (toUpload.length === 0 && remote.dataVersion === catalog.dataVersion) {
    console.log('\nNothing to publish — R2 already up to date.');
    return;
  }

  console.log('\n=== 4/4  Upload to R2 ===');
  for (const key of toUpload) {
    const meta: Record<string, string> =
      key === R2_CATALOG_KEY || key === R2_PAID_KEY
        ? { [META_CATALOG_VERSION]: catalog.catalogVersion, [META_DATA_VERSION]: String(catalog.dataVersion) }
        : {};
    await r2.put(key, bodyFor(key, catalogJson, paidJson), contentTypeFor(key), meta);
    console.log(`  PUT ${key}`);

    // Archive every published FREE catalog under a permanent, versioned key
    // (never the paid bundle — only the free/public catalog needs this today).
    // A re-publish of the same catalogVersion must not clobber the archived copy.
    if (key === R2_CATALOG_KEY) {
      const archiveResult = await archiveCatalog(r2, catalog.catalogVersion, catalogJson);
      console.log(
        archiveResult.archived
          ? `  PUT ${archiveResult.key} (archive)`
          : `  archive ${archiveResult.key} already exists — skip`,
      );
    }
  }

  // Read-back verify for the JSON vocab/catalog objects (text, so a sha compare is exact):
  // confirm each landed before writing the manifest, so the manifest can never claim a
  // sha the object doesn't have — the desync that once wedged publish into a permanent no-op.
  const VERIFY_KEYS = [R2_CATALOG_KEY, R2_PAID_KEY, R2_BRANDS_KEY, R2_CATEGORIES_KEY];
  for (const key of toUpload) {
    if (!VERIFY_KEYS.includes(key)) continue;
    const got = await r2.getText(key);
    if (got === null || sha256(got) !== local[key]) {
      fail(`Post-upload verify FAILED for ${key}: R2 object sha != local. Manifest NOT written — re-run \`... --force\`.`);
    }
  }

  const manifest: PublishManifest = {
    catalogVersion: catalog.catalogVersion,
    dataVersion: catalog.dataVersion,
    schemaVersion: catalog.schemaVersion,
    updatedAt: new Date().toISOString(),
    objects: local,
  };
  await r2.put(R2_MANIFEST_KEY, `${JSON.stringify(manifest, null, 2)}\n`, 'application/json');
  console.log(`  PUT ${R2_MANIFEST_KEY}`);
  console.log(`\nDone — ${diff.changed.length} object(s) uploaded.`);
}

// ─────────────── steps ───────────────

/**
 * Download each card's art into ./cards. Re-fetches when the upstream
 * `image_url` changed since we cached it (A3-F4) — a source map beside the art
 * records the URL each cached file came from — and validates the downloaded
 * bytes are a real image before caching, so an issuer CDN's HTML block page
 * can't become "card art" (A3-F5). The extension is taken from the bytes, not
 * the URL, so a format change (png→webp) is handled correctly.
 */
async function downloadArt(cards: Card[], imageBaseUrl: string): Promise<void> {
  mkdirSync(CARDS_DIR, { recursive: true });
  const sources = readSources();
  let ok = 0;
  const failed: string[] = [];

  for (const card of cards) {
    const id = card.card_product_id;
    const url = card.image_url ?? '';
    const cached = cachedExt(id);

    // Cached and the upstream URL hasn't changed → trust the prior (validated) copy.
    if (cached && sources.get(id) === url) {
      ok++;
      continue;
    }
    if (!url || url.startsWith(imageBaseUrl) || url.startsWith('data:')) {
      if (cached) ok++; // keep whatever art we already have
      else console.log(`  skip  ${id} (no downloadable image)`);
      continue;
    }

    try {
      const res = await fetch(url, { headers: { 'user-agent': 'Mozilla/5.0' } });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const bytes = new Uint8Array(await res.arrayBuffer());
      const ext = sniffImageExt(bytes);
      if (!ext) {
        throw new Error(`not a recognised image (starts ${describeBytes(bytes)}) — refusing to cache`);
      }
      removeCachedArt(id); // drop any stale copy (covers a format change)
      writeFileSync(join(CARDS_DIR, `${id}.${ext}`), bytes);
      sources.set(id, url);
      console.log(`  ok    ${id}.${ext}${cached ? ' (refreshed)' : ''}`);
      ok++;
    } catch (e) {
      console.log(`  FAIL  ${id}: ${e instanceof Error ? e.message : e}`);
      failed.push(id);
    }
  }
  writeSources(sources);
  console.log(`  ${ok} ready, ${failed.length} failed`);
}

interface Published {
  ext: string;
  sha: string;
}

/**
 * Point each card with cached art at the Worker's card route, cache-busted with
 * `?v=<sha8>`. Driven by what's on disk, so it's stable across re-runs; when an
 * image's bytes change, its `?v` changes, so clients fetch the new art even
 * though the Worker serves card art `immutable`. Returns id -> {ext, sha} (the
 * sha is reused for the upload manifest, so each image is read once).
 */
function rewriteUrls(cards: Card[], imageBaseUrl: string): Map<string, Published> {
  const onDisk = new Map<string, string>(); // card_product_id -> ext
  for (const f of readdirSync(CARDS_DIR)) {
    const dot = f.lastIndexOf('.');
    const ext = dot > 0 ? f.slice(dot + 1).toLowerCase() : '';
    if (ext in IMAGE_TYPES) onDisk.set(f.slice(0, dot), f.slice(dot + 1)); // skip .sources.json
  }

  const published = new Map<string, Published>();
  const missing: string[] = [];
  for (const card of cards) {
    const id = card.card_product_id;
    const ext = onDisk.get(id);
    if (!ext) {
      missing.push(id);
      continue;
    }
    const sha = sha256(readFileSync(join(CARDS_DIR, `${id}.${ext}`)));
    card.image_url = `${imageBaseUrl}/cards/${id}.${ext}?v=${sha.slice(0, 8)}`;
    published.set(id, { ext, sha });
  }
  console.log(`  ${published.size} -> Worker, ${missing.length} without art (left unchanged)`);
  return published;
}

/** Refuse to publish an empty, unversioned free bundle (an empty or malformed build). */
function assertSaneBundle(catalog: { catalogVersion?: string; dataVersion?: number; schemaVersion?: number }, cards: Card[]): void {
  if (cards.length === 0) {
    fail('refusing to publish: free.json has 0 card_products — empty or malformed build');
  }
  if (!catalog.catalogVersion || typeof catalog.dataVersion !== 'number' || typeof catalog.schemaVersion !== 'number') {
    fail('refusing to publish: free.json is missing catalogVersion / dataVersion / schemaVersion');
  }
}

/**
 * Build the rewritten PAID bundle when PAID_CATALOG_FILE is set, else null. Reuses
 * the URLs already written onto the free cards (same card ids, same art), so the
 * `/cards/<id>.<ext>?v=<sha8>` scheme has ONE source — no second rewrite to drift.
 * The source file (a full catalog handed in by the backend engine) is never mutated.
 */
function buildPaidJson(freeCards: Card[], free: { dataVersion: number }): string | null {
  const file = process.env.PAID_CATALOG_FILE;
  if (!file) return null;
  const path = resolve(file);
  if (!existsSync(path)) fail(`PAID_CATALOG_FILE set but no file at ${path}`);

  const paid = JSON.parse(readFileSync(path, 'utf8')) as { card_products?: Card[]; dataVersion?: number };
  // free is a projection of the same build, so paid must be a superset at the same
  // dataVersion — otherwise PAID_CATALOG_FILE is stale or from a different build.
  if (paid.dataVersion !== free.dataVersion) {
    fail(`refusing to publish: paid dataVersion ${paid.dataVersion} != free dataVersion ${free.dataVersion} — mismatched builds (stale PAID_CATALOG_FILE?)`);
  }
  const paidIds = new Set((paid.card_products ?? []).map((c) => c.card_product_id));
  const missingInPaid = freeCards.filter((c) => !paidIds.has(c.card_product_id)).map((c) => c.card_product_id);
  if (missingInPaid.length) {
    fail(`refusing to publish: paid bundle is missing ${missingInPaid.length} card(s) present in free (e.g. ${missingInPaid[0]}) — free must be a projection of paid`);
  }
  const urlById = new Map(freeCards.filter((c) => c.image_url).map((c) => [c.card_product_id, c.image_url!]));
  let rewritten = 0;
  for (const card of paid.card_products ?? []) {
    const url = urlById.get(card.card_product_id);
    if (url) {
      card.image_url = url;
      rewritten++;
    }
  }
  console.log(`  paid bundle: ${paid.card_products?.length ?? 0} cards, ${rewritten} image_url -> Worker`);
  return JSON.stringify(paid); // minified, matching the free bundle (API3)
}

async function readManifest(r2: R2): Promise<PublishManifest> {
  const raw = await r2.getText(R2_MANIFEST_KEY);
  if (!raw) return { catalogVersion: '', dataVersion: 0, schemaVersion: 0, updatedAt: '', objects: {} };
  return JSON.parse(raw) as PublishManifest;
}

// ─────────────── helpers ───────────────

function cachedExt(id: string): string | null {
  for (const ext of Object.keys(IMAGE_TYPES)) {
    if (existsSync(join(CARDS_DIR, `${id}.${ext}`))) return ext;
  }
  return null;
}

/** Delete every cached art file for an id (all known image extensions). */
function removeCachedArt(id: string): void {
  for (const ext of Object.keys(IMAGE_TYPES)) {
    const p = join(CARDS_DIR, `${id}.${ext}`);
    if (existsSync(p)) unlinkSync(p);
  }
}

/** id -> upstream image_url the cached art was fetched from (A3-F4). */
function readSources(): Map<string, string> {
  if (!existsSync(SOURCES_FILE)) return new Map();
  try {
    return new Map(Object.entries(JSON.parse(readFileSync(SOURCES_FILE, 'utf8')) as Record<string, string>));
  } catch {
    return new Map(); // corrupt sidecar → treat as empty, everything re-fetches
  }
}

function writeSources(sources: Map<string, string>): void {
  const obj = Object.fromEntries([...sources.entries()].sort());
  writeFileSync(SOURCES_FILE, `${JSON.stringify(obj, null, 2)}\n`);
}

function contentTypeFor(key: string): string {
  if (key.endsWith('.json')) return 'application/json';
  const ext = key.slice(key.lastIndexOf('.') + 1).toLowerCase();
  return IMAGE_TYPES[ext] ?? 'application/octet-stream';
}

function bodyFor(key: string, catalogJson: string, paidJson: string | null): Uint8Array | string {
  if (key === R2_CATALOG_KEY) return catalogJson;
  if (key === R2_PAID_KEY) return paidJson!; // only diffed in when paidJson was built
  if (key === R2_BRANDS_KEY) return readFileSync(BRANDS_FILE);
  if (key === R2_CATEGORIES_KEY) return readFileSync(CATEGORIES_FILE);
  return readFileSync(join(ROOT, key)); // cards/<id>.<ext>
}

interface Config extends R2Config {
  imageBaseUrl: string;
}

function readConfig(): Config {
  const need = (k: string): string => {
    const v = process.env[k];
    if (!v) fail(`Missing ${k} — copy .env.example to .env and fill it in.`);
    return v!;
  };
  const cfg: Config = {
    accountId: need('R2_ACCOUNT_ID'),
    accessKeyId: need('R2_ACCESS_KEY_ID'),
    secretAccessKey: need('R2_SECRET_ACCESS_KEY'),
    bucket: need('R2_BUCKET'),
    imageBaseUrl: need('IMAGE_BASE_URL').replace(/\/+$/, ''),
  };
  // CI logs are public — scrub these from any error before it's printed.
  REDACT.push(cfg.accountId, cfg.accessKeyId, cfg.secretAccessKey, cfg.bucket, cfg.imageBaseUrl);
  return cfg;
}

/** Tiny .env loader (KEY=value), so the CLI works without extra node flags. */
function loadEnv(path: string): void {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    const key = m?.[1];
    if (!key) continue;
    let val = m[2] ?? '';
    if (/^(".*"|'.*')$/.test(val)) val = val.slice(1, -1);
    if (!(key in process.env)) process.env[key] = val;
  }
}

/** Values to redact from error output (R2 account id / keys / bucket). */
const REDACT: string[] = [];
function scrub(s: string): string {
  let out = s;
  for (const secret of REDACT) if (secret) out = out.split(secret).join('***');
  return out;
}

function fail(message: string): never {
  console.error(`\nERROR: ${scrub(message)}`);
  process.exit(1);
}

main().catch((e) => fail(e instanceof Error ? e.stack ?? e.message : String(e)));
