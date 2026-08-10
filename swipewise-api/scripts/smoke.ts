// Post-publish / post-deploy smoke gate for the catalog read API (the Worker).
//
// Hits the LIVE Worker and fails CI if it isn't serving a coherent catalog —
// the missing check that turns a broken publish (stale/empty R2) or a deploy
// that killed an endpoint into a red build instead of a silently-degraded app.
//
// Checks (retried briefly to absorb edge/R2 propagation right after a publish):
//   GET /healthz      → 200, status "ok", numeric dataVersion
//   GET /catalog.json → 200, non-empty card_products, body.dataVersion matches
//                       /healthz (internal coherence)
// When EXPECTED_FREE (a built free.json) or EXPECTED_DATA_VERSION is given, both
// must ALSO equal that dataVersion — i.e. "the live API serves the build we just
// published", not merely "some catalog". Without it the run is liveness-only
// (post-deploy: the Worker code changed, the data didn't).
//
// Env:
//   WORKER_BASE_URL       required — Worker origin (the backend engine's CI passes
//                         IMAGE_BASE_URL, which is the Worker URL)
//   EXPECTED_FREE         optional — path to the just-built free.json
//   EXPECTED_DATA_VERSION optional — the just-built dataVersion (overrides EXPECTED_FREE)
//
// WORKER_BASE_URL is scrubbed from all failure output (it's a secret in the
// backend engine's CI), mirroring publish.ts's redaction.

import { existsSync, readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

const ATTEMPTS = 5;
const DELAY_MS = 3000;

const REDACT: string[] = [];
function scrub(s: string): string {
  let out = s;
  for (const secret of REDACT) if (secret) out = out.split(secret).join('***');
  return out;
}

function fail(message: string): never {
  console.error(`\nSMOKE FAIL: ${scrub(message)}`);
  process.exit(1);
}

/** The dataVersion the live API must serve, or null for a liveness-only run. */
function expectedDataVersion(): number | null {
  const direct = process.env.EXPECTED_DATA_VERSION;
  if (direct) {
    const n = Number(direct);
    if (!Number.isFinite(n)) fail(`EXPECTED_DATA_VERSION is not a number: ${direct}`);
    return n;
  }
  const file = process.env.EXPECTED_FREE;
  if (!file) return null;
  if (!existsSync(file)) fail(`EXPECTED_FREE set but no file at ${file}`);
  const built = JSON.parse(readFileSync(file, 'utf8')) as { dataVersion?: unknown };
  if (typeof built.dataVersion !== 'number') fail(`${file} has no numeric dataVersion`);
  return built.dataVersion;
}

interface Health {
  status?: string;
  dataVersion?: unknown;
}
interface Free {
  card_products?: unknown;
  dataVersion?: unknown;
}

async function getJson(url: string): Promise<{ status: number; json: unknown }> {
  const res = await fetch(url, { headers: { 'cache-control': 'no-cache' } });
  // Read the body even on a non-200 so the message can quote it; tolerate non-JSON.
  const text = await res.text();
  let json: unknown = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* leave null — surfaced as a shape failure below */
  }
  return { status: res.status, json };
}

async function check(base: string, expected: number | null): Promise<void> {
  // 1) /healthz — authoritative served version (reads R2 head, uncached).
  const health = await getJson(`${base}/healthz`);
  if (health.status !== 200) throw new Error(`/healthz returned ${health.status}`);
  const h = (health.json ?? {}) as Health;
  if (h.status !== 'ok') throw new Error(`/healthz status is "${h.status}" (catalog not published?)`);
  if (typeof h.dataVersion !== 'number') {
    throw new Error(`/healthz dataVersion is not numeric: ${JSON.stringify(h.dataVersion)}`);
  }
  if (expected !== null && h.dataVersion !== expected) {
    throw new Error(`/healthz serves dataVersion ${h.dataVersion}, expected ${expected} (publish didn't land / serving stale)`);
  }

  // 2) /catalog.json — non-empty + coherent with /healthz. Cache-bust to dodge
  //    any edge cache from its max-age=60.
  const cat = await getJson(`${base}/catalog.json?_smoke=${h.dataVersion}`);
  if (cat.status !== 200) throw new Error(`/catalog.json returned ${cat.status}`);
  const c = (cat.json ?? {}) as Free;
  if (!Array.isArray(c.card_products) || c.card_products.length === 0) {
    throw new Error('/catalog.json has no card_products (empty/malformed)');
  }
  if (c.dataVersion !== h.dataVersion) {
    throw new Error(`/catalog.json dataVersion ${c.dataVersion} != /healthz ${h.dataVersion}`);
  }
}

async function main(): Promise<void> {
  const base = (process.env.WORKER_BASE_URL ?? '').replace(/\/+$/, '');
  if (!base) fail('WORKER_BASE_URL is required');
  REDACT.push(base);
  const expected = expectedDataVersion();

  console.log(`Smoke-testing the live Worker${expected !== null ? ` (expecting dataVersion ${expected})` : ''}…`);
  let lastErr = '';
  for (let i = 1; i <= ATTEMPTS; i++) {
    try {
      await check(base, expected);
      console.log(`OK — /healthz + /catalog.json serve a coherent catalog${expected !== null ? ` at dataVersion ${expected}` : ''}.`);
      return;
    } catch (e) {
      lastErr = e instanceof Error ? e.message : String(e);
      if (i < ATTEMPTS) {
        console.log(`  attempt ${i}/${ATTEMPTS} not ready (${scrub(lastErr)}); retrying in ${DELAY_MS / 1000}s…`);
        await sleep(DELAY_MS);
      }
    }
  }
  fail(`live API never served the expected catalog after ${ATTEMPTS} attempts: ${lastErr}`);
}

main().catch((e) => fail(e instanceof Error ? (e.stack ?? e.message) : String(e)));
