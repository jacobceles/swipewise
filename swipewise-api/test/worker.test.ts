import { beforeEach, describe, expect, it } from 'vitest';

import worker from '../src/worker';
import type { Env } from '../src/worker';
import { META_CATALOG_VERSION, META_DATA_VERSION, R2_BRANDS_KEY, R2_CATALOG_KEY, R2_CATEGORIES_KEY } from '../src/layout';

/**
 * `caches` is a Workers runtime global; vitest runs on node, where it doesn't
 * exist. Stubbed rather than guarded in the Worker, so production code isn't
 * shaped by the test environment. Keyed by URL, which is all the Worker uses.
 *
 * Reset in `beforeEach` — without that, the first /healthz test would serve its
 * cached answer to every later one and they'd stop testing their own R2 state.
 */
const edgeCache = new Map<string, Response>();
(globalThis as unknown as { caches: unknown }).caches = {
  default: {
    async match(req: Request) {
      return edgeCache.get(req.url)?.clone();
    },
    async put(req: Request, res: Response) {
      edgeCache.set(req.url, res.clone());
    },
  },
};

beforeEach(() => edgeCache.clear());

// `waitUntil` runs the work synchronously here so a cache write is observable
// on the next line; the real runtime defers it, which is fine either way.
const ctx = {
  waitUntil(p: Promise<unknown>) {
    void p;
  },
  passThroughOnException() {},
} as unknown as ExecutionContext;

/**
 * Minimal in-memory R2 stand-in covering only what the read paths touch:
 * `head` (healthz) and `get` with `onlyIf` conditional semantics (passthrough).
 * A matching `If-None-Match` returns the object WITHOUT a body, exactly as R2
 * does on a precondition hit — that's what drives the Worker's 304 branch.
 */
interface FakeObj {
  body: string;
  etag: string; // raw etag (R2's obj.etag); httpEtag is this quoted
  customMetadata?: Record<string, string>;
  contentType?: string;
}

function envWith(objects: Record<string, FakeObj>): Env {
  const bucket = {
    async head(key: string) {
      const o = objects[key];
      if (!o) return null;
      return {
        etag: o.etag,
        httpEtag: `"${o.etag}"`,
        customMetadata: o.customMetadata ?? {},
        writeHttpMetadata(_h: Headers) {},
      };
    },
    async get(key: string, opts?: { onlyIf?: Headers }) {
      const o = objects[key];
      if (!o) return null;
      const httpEtag = `"${o.etag}"`;
      const common = {
        etag: o.etag,
        httpEtag,
        customMetadata: o.customMetadata ?? {},
        writeHttpMetadata(h: Headers) {
          if (o.contentType) h.set('content-type', o.contentType);
        },
      };
      const inm = opts?.onlyIf instanceof Headers ? opts.onlyIf.get('if-none-match') : null;
      // Precondition hit (unchanged) → R2 yields metadata with no body.
      if (inm && inm === httpEtag) return common;
      return { ...common, body: o.body };
    },
  } as unknown as R2Bucket;
  return { CATALOG: bucket } as Env;
}

// The paid bundle is the security boundary: enrichment must never leak without a
// key. The gate is stubbed (no keys provisioned) so /paid.json is 402 for all.
describe('/paid.json gate (stubbed/deferred)', () => {
  it('returns 402 when no API keys are configured', async () => {
    const res = await worker.fetch(new Request('https://api.test/paid.json'), {} as Env, ctx);
    expect(res.status).toBe(402);
  });

  it('returns 402 for a non-matching key', async () => {
    const env = { PAID_API_KEYS: 'secret123' } as Env;
    const req = new Request('https://api.test/paid.json', { headers: { 'x-api-key': 'nope' } });
    const res = await worker.fetch(req, env, ctx);
    expect(res.status).toBe(402);
  });
});

// /healthz is what CI smoke-tests after publish/deploy: it must surface the
// served catalog version, and degrade cleanly (not 500) when nothing's there.
// /healthz is exempt from the rate limiter, which makes it the one route a
// flood can hammer — and the most expensive, at four R2 head() calls a hit.
// Edge-caching is what makes that exemption affordable, so it is pinned here.
describe('/healthz edge caching', () => {
  function countingEnv(counter: { heads: number }): Env {
    const bucket = {
      async head(key: string) {
        counter.heads++;
        return key === R2_CATALOG_KEY
          ? { etag: 'abc', httpEtag: '"abc"', customMetadata: {}, writeHttpMetadata() {} }
          : null;
      },
    } as unknown as R2Bucket;
    return { CATALOG: bucket } as Env;
  }

  it('serves a repeat poll from cache instead of re-hitting R2', async () => {
    const counter = { heads: 0 };
    const env = countingEnv(counter);

    const first = await worker.fetch(new Request('https://api.test/healthz'), env, ctx);
    expect(first.status).toBe(200);
    const afterFirst = counter.heads;
    expect(afterFirst).toBeGreaterThan(0);

    const second = await worker.fetch(new Request('https://api.test/healthz'), env, ctx);
    expect(second.status).toBe(200);
    expect(counter.heads).toBe(afterFirst);
  });

  it('does not cache an outage, so recovery is picked up promptly', async () => {
    const counter = { heads: 0 };
    // Nothing published anywhere → 503 on every call.
    const env = { CATALOG: { async head() { counter.heads++; return null; } } as unknown as R2Bucket } as Env;

    const first = await worker.fetch(new Request('https://api.test/healthz'), env, ctx);
    expect(first.status).toBe(503);
    const afterFirst = counter.heads;

    await worker.fetch(new Request('https://api.test/healthz'), env, ctx);
    expect(counter.heads).toBeGreaterThan(afterFirst);
  });
});

describe('/healthz', () => {
  it('reports ok + versions from the catalog object metadata', async () => {
    const env = envWith({
      [R2_CATALOG_KEY]: {
        body: '{}',
        etag: 'abc',
        // R2 lower-cases S3-API-written metadata keys; mirror that here so this
        // fixture matches the live binding (camelCase keys would read back null).
        customMetadata: { [META_CATALOG_VERSION]: '2026.06.25', [META_DATA_VERSION]: '12345' },
      },
    });
    const res = await worker.fetch(new Request('https://api.test/healthz'), env, ctx);
    expect(res.status).toBe(200);
    const json = (await res.json()) as { status: string; catalogVersion: unknown; dataVersion: unknown };
    expect(json.status).toBe('ok');
    expect(json.catalogVersion).toBe('2026.06.25');
    // dataVersion is coerced from the string customMetadata to a number.
    expect(json.dataVersion).toBe(12345);
  });

  it('reports "no catalog" as 503 (not 200/500) when nothing is published', async () => {
    // An external uptime monitor watching status codes must see the outage;
    // 200 would hide an empty bucket. The body still carries the detail.
    const res = await worker.fetch(new Request('https://api.test/healthz'), envWith({}), ctx);
    expect(res.status).toBe(503);
    const json = (await res.json()) as { status: string; dataVersion: unknown };
    expect(json.status).toBe('no catalog');
    expect(json.dataVersion).toBeNull();
  });

  // The publish smoke gate / monitors need the whole served tuple (not just the
  // catalog) to catch a SKEWED publish — e.g. catalog advanced but categories.json
  // didn't — so /healthz must report presence + etag for every other object too.
  it('reports presence + etag for brands/categories/paid alongside the catalog', async () => {
    const env = envWith({
      [R2_CATALOG_KEY]: {
        body: '{}',
        etag: 'abc',
        customMetadata: { [META_CATALOG_VERSION]: '2026.06.25', [META_DATA_VERSION]: '12345' },
      },
      [R2_BRANDS_KEY]: { body: '{}', etag: 'brand-etag' },
      [R2_CATEGORIES_KEY]: { body: '{}', etag: 'cat-etag' },
      // paid.json deliberately absent — the paid tier is stubbed/deferred.
    });
    const res = await worker.fetch(new Request('https://api.test/healthz'), env, ctx);
    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      status: string;
      catalogVersion: unknown;
      objects: Record<string, { present: boolean; etag: string | null }>;
    };
    // Existing top-level fields are unchanged (backward-compatible).
    expect(json.status).toBe('ok');
    expect(json.catalogVersion).toBe('2026.06.25');
    expect(json.objects.catalog).toEqual({ present: true, etag: 'abc' });
    expect(json.objects.brands).toEqual({ present: true, etag: 'brand-etag' });
    expect(json.objects.categories).toEqual({ present: true, etag: 'cat-etag' });
    expect(json.objects.paid).toEqual({ present: false, etag: null });
  });

  it('reports every object as absent (still 503 overall) when nothing is published', async () => {
    const res = await worker.fetch(new Request('https://api.test/healthz'), envWith({}), ctx);
    const json = (await res.json()) as { objects: Record<string, { present: boolean; etag: string | null }> };
    expect(json.objects.catalog).toEqual({ present: false, etag: null });
    expect(json.objects.brands).toEqual({ present: false, etag: null });
    expect(json.objects.categories).toEqual({ present: false, etag: null });
    expect(json.objects.paid).toEqual({ present: false, etag: null });
  });
});

// The public routes are unauthenticated, so a per-IP rate limit is the only
// thing stopping a scraper loop from burning the free-plan quota for everyone.
describe('rate limiting', () => {
  const catalogEnv = (rl?: Env['RL']): Env => ({
    ...envWith({ [R2_CATALOG_KEY]: { body: '{"card_products":[]}', etag: 'v1' } }),
    RL: rl,
  });

  it('returns 429 with Retry-After when the per-IP limit is exceeded', async () => {
    const env = catalogEnv({ async limit() { return { success: false }; } });
    const res = await worker.fetch(new Request('https://api.test/catalog.json'), env, ctx);
    expect(res.status).toBe(429);
    expect(res.headers.get('retry-after')).toBe('10');
  });

  it('serves normally when under the limit', async () => {
    const env = catalogEnv({ async limit() { return { success: true }; } });
    const res = await worker.fetch(new Request('https://api.test/catalog.json'), env, ctx);
    expect(res.status).toBe(200);
  });

  it('never rate-limits /healthz (monitors must poll freely)', async () => {
    const env = catalogEnv({ async limit() { return { success: false }; } });
    const res = await worker.fetch(new Request('https://api.test/healthz'), env, ctx);
    expect(res.status).toBe(200);
  });
});

// Passthrough routes lean on R2's native ETag so an unchanged catalog is never
// re-downloaded. The 304 path is the bandwidth contract the app depends on.
describe('/catalog.json passthrough', () => {
  const env = () => envWith({ [R2_CATALOG_KEY]: { body: '{"card_products":[]}', etag: 'v1' } });

  it('serves the body with the object ETag on a fresh GET', async () => {
    const res = await worker.fetch(new Request('https://api.test/catalog.json'), env(), ctx);
    expect(res.status).toBe(200);
    expect(res.headers.get('etag')).toBe('"v1"');
    expect(await res.text()).toBe('{"card_products":[]}');
  });

  it('returns 304 with no body when If-None-Match matches', async () => {
    const req = new Request('https://api.test/catalog.json', { headers: { 'if-none-match': '"v1"' } });
    const res = await worker.fetch(req, env(), ctx);
    expect(res.status).toBe(304);
    expect(await res.text()).toBe('');
  });

  it('returns 404 (not 500) when the object is missing', async () => {
    const res = await worker.fetch(new Request('https://api.test/catalog.json'), envWith({}), ctx);
    expect(res.status).toBe(404);
  });

  // The catalog moves roughly weekly and `dataVersion` is content-derived, so a
  // short TTL made every app launch revalidate data that is almost never
  // different. Pinned because it is a deliberate cost/latency decision, not an
  // arbitrary constant — correctness still rides on the ETag above.
  it('caches for hours, not seconds', async () => {
    const res = await worker.fetch(new Request('https://api.test/catalog.json'), env(), ctx);
    const maxAge = Number(/max-age=(\d+)/.exec(res.headers.get('cache-control') ?? '')?.[1]);
    expect(maxAge).toBeGreaterThanOrEqual(3600);
  });
});

// The derived-slice routes must stamp an ETag that matches the bytes they serve
// even if a publish lands mid-request (A3-F6), and /catalog/resolve must bound its
// input so a pathological id list can't burn CPU (A3-F7). These use a bespoke
// bucket because slicing reads the body via obj.json() (the passthrough fake doesn't).
describe('slice ETag/body consistency (A3-F6)', () => {
  it('stamps the ETag of the object that produced the body, not a raced head()', async () => {
    // head() reports the OLD version; get() returns the NEW body — the publish
    // landed between them. The 200 must carry the NEW etag, never the stale head one.
    const cat = { card_products: [{ card_product_id: 'chase.x' }], reward_rules: [], reward_rule_exclusions: [], product_perks: [], point_systems: [] };
    const bucket = {
      async head() { return { etag: 'raced-old', httpEtag: '"raced-old"', customMetadata: {}, writeHttpMetadata() {} }; },
      async get() { return { etag: 'raced-new', httpEtag: '"raced-new"', customMetadata: {}, writeHttpMetadata() {}, async json() { return cat; } }; },
    } as unknown as R2Bucket;
    const res = await worker.fetch(new Request('https://api.test/catalog/manifest'), { CATALOG: bucket } as Env, ctx);
    expect(res.status).toBe(200);
    expect(res.headers.get('etag')).toBe('"raced-new-manifest"');
  });
});

describe('/catalog/resolve bound (A3-F7)', () => {
  const cat = { card_products: [{ card_product_id: 'chase.a' }, { card_product_id: 'amex.b' }], reward_rules: [], reward_rule_exclusions: [], product_perks: [], point_systems: [] };
  const env = () => ({
    CATALOG: {
      async head() { return { etag: 'rv1', httpEtag: '"rv1"', customMetadata: {}, writeHttpMetadata() {} }; },
      async get() { return { etag: 'rv1', httpEtag: '"rv1"', customMetadata: {}, writeHttpMetadata() {}, async json() { return cat; } }; },
    } as unknown as R2Bucket,
  } as Env);

  it('400s on an empty id set', async () => {
    const res = await worker.fetch(new Request('https://api.test/catalog/resolve'), env(), ctx);
    expect(res.status).toBe(400);
  });

  it('400s when more than 200 ids are requested', async () => {
    const ids = Array.from({ length: 201 }, (_, i) => `x.${i}`).join(',');
    const res = await worker.fetch(new Request(`https://api.test/catalog/resolve?ids=${ids}`), env(), ctx);
    expect(res.status).toBe(400);
  });

  it('resolves a wallet subset to just those cards', async () => {
    const res = await worker.fetch(new Request('https://api.test/catalog/resolve?ids=chase.a'), env(), ctx);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { card_products: { card_product_id: string }[] };
    expect(body.card_products.map((c) => c.card_product_id)).toEqual(['chase.a']);
  });
});

describe('unknown route', () => {
  it('returns 404', async () => {
    const res = await worker.fetch(new Request('https://api.test/nope'), envWith({}), ctx);
    expect(res.status).toBe(404);
  });
});
