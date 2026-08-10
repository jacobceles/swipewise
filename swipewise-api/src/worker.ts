// SwipeWise catalog read API (Cloudflare Worker).
//
// The app fetches the catalog from here instead of downloading a static JSON,
// so we can serve it in whatever shape a given screen needs — whole catalog,
// one issuer, one card, or just the user's linked cards — while keeping every
// response ETag-gated so an unchanged catalog is never re-downloaded.
//
// Routes (all GET unless noted):
//   /healthz                  liveness + current catalog versions
//   /catalog.json             free catalog (rewards)   (R2 passthrough, native ETag)
//   /paid.json                full catalog + enrichment (gated — stubbed/deferred)
//   /brands.json              brand vocabulary         (R2 passthrough, native ETag)
//   /categories.json          category vocabulary      (R2 passthrough, native ETag)
//   /catalog/manifest         lightweight index        (derived)
//   /catalog/bank/:bank       one issuer's cards       (derived slice)
//   /catalog/card/:cardId     one card                 (derived slice)
//   /catalog/resolve?ids=a,b  the user's cards only     (derived slice; also POST {ids})
//   /places/nearby            POST — Google Places proxy (App Check attested)
//
// Passthrough routes lean on R2's own ETag via conditional GET. Derived slices
// can't, so their ETag is `"<catalog-etag>-<sliceId>"`: it changes whenever the
// catalog changes, giving the app the same "304 when unchanged" behaviour.

import {
  type Catalog,
  manifestSummary,
  sliceByBank,
  sliceByCard,
  sliceByCards,
} from './catalog';
import { type PlacesEnv, placesNearby } from './places';
import {
  META_CATALOG_VERSION,
  META_DATA_VERSION,
  R2_BRANDS_KEY,
  R2_CATALOG_KEY,
  R2_CATEGORIES_KEY,
  R2_PAID_KEY,
} from './layout';

/** Cloudflare Rate Limiting binding (see wrangler.toml `[[ratelimits]]`). */
interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  CATALOG: R2Bucket;
  /**
   * Comma-separated API keys that may fetch the paid (enrichment) bundle. Unset
   * today — the paid tier is stubbed/deferred until Phase 5 has data to sell, so
   * /paid.json returns 402 for everyone. Setting this (a secret) turns it on.
   */
  PAID_API_KEYS?: string;
  /**
   * Per-IP rate limiter for the public routes (declared in wrangler.toml). The
   * bucket is fully public and unauthenticated, so without this a scraper loop
   * can exhaust the free-plan daily quota and take catalog delivery down for
   * everyone. Optional so tests / `wrangler dev` without the binding are a no-op.
   */
  RL?: RateLimiter;
}

/** The Worker's full environment: catalog bindings plus the Places proxy's. */
export type WorkerEnv = Env & PlacesEnv;

const JSON_TYPE = 'application/json; charset=utf-8';
const CORS = { 'access-control-allow-origin': '*' };

export default {
  async fetch(req: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    if (req.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          ...CORS,
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'content-type, if-none-match',
        },
      });
    }

    const url = new URL(req.url);
    const path = url.pathname;

    try {
      // /healthz stays exempt so uptime monitors can poll freely — but it is
      // now edge-cached (see `healthz`) so polling costs one R2 round of
      // head()s per window rather than four per request.
      if (path === '/healthz') return healthz(env, req, ctx);

      if (env.RL) {
        const ip = req.headers.get('cf-connecting-ip') ?? 'anon';
        const { success } = await env.RL.limit({ key: ip });
        if (!success) {
          return new Response(JSON.stringify({ error: 'rate limit exceeded' }), {
            status: 429,
            headers: { ...CORS, 'content-type': JSON_TYPE, 'retry-after': '10' },
          });
        }
      } else {
        // Loud, because the failure is otherwise invisible: an unbound RL
        // leaves every public route completely unthrottled and still returns
        // 200s, so nothing in the response tells you the protection is gone.
        // Deliberately not a hard failure — tests and `wrangler dev` run
        // without the binding, and refusing to serve there would be worse
        // than serving unthrottled. `[observability]` is on, so this surfaces
        // in the Workers dashboard and `wrangler tail`.
        console.error(
          'RL binding is not bound — all public routes are UNTHROTTLED. ' +
            'Expected in local dev/tests; in production this is a misconfig.',
        );
      }

      // Google Places, proxied so the key lives here instead of in the APK.
      // Rate-limited above like every other data route — App Check attests
      // *which app* is calling, the limiter caps how hard any one caller can.
      if (path === '/places/nearby') return placesNearby(req, env, CORS);

      if (path === '/catalog.json') return passthrough(env, req, R2_CATALOG_KEY);
      if (path === '/paid.json') return paidGate(env, req);
      if (path === '/brands.json') return passthrough(env, req, R2_BRANDS_KEY);
      if (path === '/categories.json') return passthrough(env, req, R2_CATEGORIES_KEY);
      if (path === '/catalog/manifest') return slice(env, req, 'manifest', manifestSummary);

      const cardFile = path.match(/^\/cards\/(.+)$/);
      if (cardFile) return serveCard(env, req, ctx, cardFile[1]!);

      const bank = path.match(/^\/catalog\/bank\/([^/]+)$/);
      if (bank) {
        const name = decodeURIComponent(bank[1]!);
        return slice(env, req, `bank:${name}`, (c) => sliceByBank(c, name));
      }

      const card = path.match(/^\/catalog\/card\/([^/]+)$/);
      if (card) {
        const id = decodeURIComponent(card[1]!);
        return slice(env, req, `card:${id}`, (c) => sliceByCard(c, id));
      }

      if (path === '/catalog/resolve') return resolve(env, req);

      return error(404, 'not found');
    } catch (e) {
      return error(500, e instanceof Error ? e.message : 'internal error');
    }
  },
} satisfies ExportedHandler<WorkerEnv>;

// ─────────────── handlers ───────────────

/** How long a /healthz answer is reused at the edge. */
const HEALTHZ_TTL_SECONDS = 30;

/**
 * Liveness + publish-skew probe.
 *
 * Exempt from the rate limiter so an uptime monitor is never throttled into a
 * false alarm — which left it as the one route a flood could hammer, and the
 * most expensive one at four R2 `head()` calls per request. Edge-caching the
 * answer for [HEALTHZ_TTL_SECONDS] fixes the cost without touching the
 * exemption: a normal monitor polls well under that, and a flood collapses
 * onto one cached response per window per PoP.
 *
 * The 503 case is cached too, deliberately and for the same short window: an
 * outage that resolves is picked up within 30s, and a monitor hammering during
 * an outage is exactly when the R2 calls are least useful.
 */
async function healthz(env: Env, req: Request, ctx: ExecutionContext): Promise<Response> {
  const cacheKey = new Request(new URL(req.url).toString(), { method: 'GET' });
  const cache = caches.default;
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const res = await healthzUncached(env);
  // `cache.put` refuses a 503, so only the healthy answer is stored. That is
  // the right way round anyway: the expensive-to-serve case is the steady
  // state, and an outage should re-probe.
  if (res.status === 200) {
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
  }
  return res;
}

async function healthzUncached(env: Env): Promise<Response> {
  const [catalogHead, brandsHead, categoriesHead, paidHead] = await Promise.all([
    env.CATALOG.head(R2_CATALOG_KEY),
    env.CATALOG.head(R2_BRANDS_KEY),
    env.CATALOG.head(R2_CATEGORIES_KEY),
    env.CATALOG.head(R2_PAID_KEY),
  ]);
  // R2 surfaces S3-API-written metadata keys lower-cased — read them by the
  // lower-case names publish.ts wrote (see META_* in layout.ts).
  const meta = catalogHead?.customMetadata ?? {};
  const dataVersion = meta[META_DATA_VERSION];
  // No catalog published → 503, not 200: an external uptime monitor checking
  // status codes must see the outage. The body still carries the detail the
  // smoke gate reads. (A published catalog serves 200 as before.)
  return Response.json(
    {
      status: catalogHead ? 'ok' : 'no catalog',
      catalogVersion: meta[META_CATALOG_VERSION] ?? null,
      dataVersion: dataVersion ? Number(dataVersion) : null,
      // Presence + etag for every other served object, so a monitor can catch a
      // SKEWED publish (e.g. catalog advanced but categories didn't). brands.json
      // and categories.json don't carry the catalogVersion/dataVersion custom
      // metadata (only assets/catalog.json + assets/paid.json do — see publish.ts),
      // so each object's own R2 etag (its content hash) is the version signal here.
      objects: {
        catalog: objectStatus(catalogHead),
        brands: objectStatus(brandsHead),
        categories: objectStatus(categoriesHead),
        paid: objectStatus(paidHead),
      },
    },
    {
      status: catalogHead ? 200 : 503,
      headers: { ...CORS, 'cache-control': `public, max-age=${HEALTHZ_TTL_SECONDS}` },
    },
  );
}

/** Presence + etag for one R2 object, for the /healthz `objects` breakdown. */
function objectStatus(head: R2Object | null): { present: boolean; etag: string | null } {
  return { present: head !== null, etag: head?.etag ?? null };
}

/**
 * Paid (enrichment) bundle — gated. STUBBED/DEFERRED until Phase 5 has enrichment
 * to sell: no keys are provisioned (`PAID_API_KEYS` unset), so this returns 402 for
 * everyone today. The gate lives here so turning the paid tier on is a config change
 * (set the secret + issue keys), not a code change. When enabled, a request must
 * present a matching `x-api-key`; the bundle then streams like any other R2 object.
 */
async function paidGate(env: Env, req: Request): Promise<Response> {
  const keys = (env.PAID_API_KEYS ?? '')
    .split(',')
    .map((k) => k.trim())
    .filter(Boolean);
  const provided = req.headers.get('x-api-key')?.trim() ?? '';
  if (keys.length === 0 || !provided || !keys.includes(provided)) {
    return error(402, 'paid tier not available');
  }
  return passthrough(env, req, R2_PAID_KEY);
}

/** Stream an R2 object straight through, honouring If-None-Match via R2. */
async function passthrough(env: Env, req: Request, key: string): Promise<Response> {
  const obj = await env.CATALOG.get(key, { onlyIf: req.headers });
  if (obj === null) return error(404, `${key} not published`);

  const headers = new Headers(CORS);
  obj.writeHttpMetadata(headers);
  headers.set('etag', obj.httpEtag);
  if (!headers.has('content-type')) headers.set('content-type', JSON_TYPE);
  // 6h, not 60s. `dataVersion` is content-derived and the catalog only moves
  // when someone publishes — roughly weekly — so a one-minute TTL made every
  // launch re-validate data that is almost never different. At 6h the device's
  // own HTTP cache answers most cold starts with no network call at all, and
  // correctness is unaffected: the ETag above still forces a revalidation
  // once the window lapses, and a publish that matters ships with the app's
  // own catalog-version check.
  headers.set('cache-control', 'public, max-age=21600');

  // With `onlyIf`, a precondition failure (If-None-Match matched → unchanged)
  // returns an R2Object with no `body`.
  if (!('body' in obj) || (obj as R2ObjectBody).body == null) {
    return new Response(null, { status: 304, headers });
  }
  return new Response((obj as R2ObjectBody).body, { headers });
}

/**
 * Serve card art from the R2 binding so the bucket can stay fully private.
 * Edge-cached (keyed by URL) so repeat loads skip the R2 read; the app also
 * caches images on-device, so steady-state Worker hits per image are low.
 */
async function serveCard(
  env: Env,
  req: Request,
  ctx: ExecutionContext,
  file: string,
): Promise<Response> {
  const cacheKey = new Request(new URL(req.url).toString(), { method: 'GET' });
  const cache = caches.default;
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const obj = await env.CATALOG.get(`cards/${file}`);
  if (obj === null) return error(404, 'card art not found');

  const headers = new Headers(CORS);
  obj.writeHttpMetadata(headers); // content-type from the object's stored metadata
  headers.set('etag', obj.httpEtag);
  if (!headers.has('content-type')) headers.set('content-type', 'application/octet-stream');
  // The catalog cache-busts each art URL with ?v=<sha8>, so a given URL's bytes
  // never change — cache it immutably. Changed art ships a new ?v (new URL).
  headers.set('cache-control', 'public, max-age=31536000, immutable');

  const res = new Response(obj.body, { headers });
  ctx.waitUntil(cache.put(cacheKey, res.clone()));
  return res;
}

/** Compute + serve a derived slice, ETag-gated against the catalog's version. */
async function slice(
  env: Env,
  req: Request,
  sliceId: string,
  build: (c: Catalog) => unknown,
): Promise<Response> {
  const head = await env.CATALOG.head(R2_CATALOG_KEY);
  if (!head) return error(404, 'catalog not published');

  // Cheap 304 short-circuit off the head() ETag: a client on the current version
  // matches and skips the body; a stale client won't match and falls through.
  const headEtag = `"${head.etag}-${sliceId}"`;
  if (req.headers.get('if-none-match') === headEtag) {
    return new Response(null, { status: 304, headers: sliceHeaders(headEtag) });
  }

  // The 200 ETag comes from the object that actually produced the body — NOT the
  // head() above — so a publish landing between head() and get() can't pair fresh
  // bytes with the stale head ETag (A3-F6).
  const { etag: catalogEtag, catalog } = await loadCatalog(env, head.etag);
  const bodyEtag = `"${catalogEtag}-${sliceId}"`;
  return new Response(JSON.stringify(build(catalog)), { headers: sliceHeaders(bodyEtag) });
}

// Cap on ids per /catalog/resolve request. Comfortably above both the full
// catalog (181 cards) and any real wallet, so it never limits a legitimate
// "resolve everything I hold" — it only rejects a pathological id list that
// would cost a needless sort + hash + full-catalog filter, uncached (A3-F7).
const MAX_RESOLVE_IDS = 200;

async function resolve(env: Env, req: Request): Promise<Response> {
  let ids: string[] = [];
  if (req.method === 'POST') {
    const body = (await req.json().catch(() => ({}))) as { ids?: unknown };
    if (Array.isArray(body.ids)) ids = body.ids.filter((x): x is string => typeof x === 'string');
  } else {
    const raw = new URL(req.url).searchParams.get('ids') ?? '';
    ids = raw.split(',').map((s) => s.trim()).filter(Boolean);
  }

  const unique = [...new Set(ids)].sort();
  if (unique.length === 0) return error(400, 'no card ids given (?ids=a,b or POST {ids:[…]})');
  if (unique.length > MAX_RESOLVE_IDS) {
    return error(400, `too many ids (max ${MAX_RESOLVE_IDS}); resolve serves a wallet-scoped subset — use /catalog.json for the full catalog`);
  }

  return slice(env, req, `resolve:${fnv1a(unique.join(','))}`, (c) => sliceByCards(c, unique));
}

// ─────────────── helpers ───────────────

/**
 * Parse `catalog.json` once per version. R2 isolates are reused, so a hot
 * Worker reparses only when the catalog actually changes — keeping CPU per
 * request well under the free-tier 10 ms ceiling.
 */
let cached: { etag: string; catalog: Catalog } | null = null;
async function loadCatalog(env: Env, etag: string): Promise<{ etag: string; catalog: Catalog }> {
  if (cached && cached.etag === etag) return cached;
  const obj = await env.CATALOG.get(R2_CATALOG_KEY);
  if (!obj) throw new Error('catalog not published');
  const catalog = (await obj.json()) as Catalog;
  // Cache (and hand back) the object's OWN etag, not the head() etag passed in,
  // so the slice ETag always tracks the bytes we actually served (A3-F6).
  cached = { etag: obj.etag, catalog };
  return cached;
}

function sliceHeaders(etag: string): Headers {
  return new Headers({
    ...CORS,
    'content-type': JSON_TYPE,
    etag,
    'cache-control': 'public, max-age=60',
  });
}

function error(status: number, message: string): Response {
  return Response.json({ error: message }, { status, headers: CORS });
}

/** Tiny stable string hash for resolve-set ETags (FNV-1a, 32-bit hex). */
function fnv1a(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16);
}
