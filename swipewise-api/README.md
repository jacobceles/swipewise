# swipewise-api

The catalog distribution layer for SwipeWise. Two pieces, one R2 bucket:

1. **Read API** — a Cloudflare Worker ([`src/worker.ts`](src/worker.ts)) the app
   calls at runtime instead of downloading a static JSON. It reads catalog
   objects from R2 through a binding and serves them in whatever shape a screen
   needs (whole catalog, one issuer, one card, or just the user's cards), every
   response ETag-gated so an unchanged catalog is never re-downloaded.
2. **Publish CLI** — [`scripts/publish.ts`](scripts/publish.ts) takes a catalog
   bundle, mirrors its card art into R2, rewrites each `image_url` to the Worker's
   `/cards` URL, and uploads **only what changed**. It publishes the **free** bundle
   and — when `PAID_CATALOG_FILE` is set — the **paid** bundle too, with the *same*
   rewrite, so both R2 copies point at the Worker.

The backend engine is the source of truth **and the only R2 publisher**: its build emits the
full catalog (paid) and a projection of it (`free.json`), and its CI runs this
publish CLI (checking out this repo for the CLI + the canonical vocab) to push BOTH
bundles to R2. Both come from one build, so free is always a subset of paid. This
repo's *own* CI only deploys the Worker; the committed `free.json` here is the
public, browsable GitHub-CDN copy and keeps **raw crawled** image URLs (so rendering
it doesn't consume our R2/Worker).

```
backend engine (source of truth + only R2 publisher), one build:
  free.json   ─▶ publish CLI ─▶ R2 assets/catalog.json ◀─ Worker ◀─ app
  catalog.json ▶ (this repo's CLI,  R2 assets/paid.json (gated)
                  run by backend engine CI)
free.json is also committed here (raw image URLs) ─▶ GitHub CDN / download
```

Both run on Cloudflare's free tier: Workers (100k req/day, 10 ms CPU/req) and
R2 (10 GB, 1M Class A / 10M Class B ops/mo, **free egress**). Reads are mostly
304s; publishes write only changed objects, so ops stay near zero.

## Setup

```bash
npm install
npx wrangler login   # one-time, for deploy
```

R2 bucket `swipewise-assets`, **fully private** — disable public access; the
Worker reaches everything through its binding. Object layout (see
[`src/layout.ts`](src/layout.ts)):

```
assets/catalog.json    the FREE bundle — rewards slice the app reads (image_url → /cards)
assets/paid.json       the PAID bundle — full catalog + enrichment (gated)
assets/brands.json     the brand vocabulary
assets/categories.json the category vocabulary (matchers + place types)
assets/manifest.json   publish state (sha256 per object; the diff source)
cards/<id>.<ext>       card art, served by the Worker at /cards/<id>.<ext>
```

The Path B split is by column family, never by row — every card is in both bundles.
`assets/catalog.json` is the **free** projection (rewards fields the app reads);
`assets/paid.json` is the **full** record incl. enrichment (APR, fees beyond
annual+FX, structured SUB, transfer partners…). Both are published to R2 by this
repo's CLI but driven by the backend engine's CI (the single publisher); the projection that
produces them lives in the backend engine.

## The Worker (read API)

```bash
npm run dev      # local, against the R2 binding
npm run deploy   # publish to *.workers.dev (or a custom domain)
```

| Route | Returns |
|---|---|
| `POST /places/nearby` | **Places proxy.** Holds the Google Places key server-side and forwards a Google-shaped body. Requires a Firebase App Check token — see below |
| `GET /healthz` | liveness + current `catalogVersion`/`dataVersion` |
| `GET /catalog.json` | the free catalog — rewards slice (R2 passthrough, native ETag) |
| `GET /paid.json` | full catalog + enrichment — **gated** (`x-api-key`); stubbed/deferred → 402 |
| `GET /brands.json` | the brand vocabulary (R2 passthrough) |
| `GET /categories.json` | the category vocabulary (R2 passthrough) |
| `GET /catalog/manifest` | lightweight index: versions, banks, card list |
| `GET /catalog/bank/:bank` | one issuer's cards (derived slice) |
| `GET /catalog/card/:cardId` | one card (derived slice) |
| `GET /catalog/resolve?ids=a,b` | only those cards — also `POST {ids:[…]}` |
| `GET /cards/:file` | card art, streamed from R2 (edge-cached, `immutable`) |

Slices keep the **exact shape** of the full build (same version headers, same
five arrays) so the app hydrates a slice through its normal `CatalogLoader`
path. The app today fetches `/catalog.json` + `/brands.json`; the slice routes
exist for fetching less per screen later.

> **ETags.** Passthrough routes use R2's native ETag via conditional GET.
> Derived slices use `"<catalog-etag>-<sliceId>"`, which changes whenever the
> catalog changes — same "304 when unchanged" guarantee. The parsed catalog is
> memoised per version, so a hot Worker reparses only on a real update.

**The bucket is fully private.** Everything — catalog, brands, *and card art* —
is served through the Worker's R2 binding; nothing is exposed at an r2.dev URL.
`image_url` values point at `/cards/<id>.<ext>?v=<sha8>` on the Worker. The
`?v` is the art's content hash, so each URL is immutable: responses are served
`immutable, max-age=1y` and edge-cached (`caches.default`), and the app
disk-caches them (`cached_network_image`). A device fetches each image once,
ever — changed art ships a new `?v`, so it updates instantly without stale
caches. Steady-state Worker hits for art are ~zero.

After deploy, point the app's `R2_BASE_URL` (in `keys.json`) at the Worker URL.

## The publish CLI

```bash
cp .env.example .env          # fill in R2 S3 credentials (see below)
# Usually run by the backend engine (its `make publish` / CI), which provides a fresh free.json
# + PAID_CATALOG_FILE pointing at the full catalog. brands.json + categories.json are
# read from ../assets/vocab/.
PAID_CATALOG_FILE=/path/to/catalog.json npm run publish:catalog   # omit the env var → publish free only
```

What it does, in order:

1. **Download art** — every `card_products[].image_url` not already cached in
   `./cards` is fetched once. Data-URI placeholders and already-R2 URLs are
   skipped. The cache is idempotent across runs.
2. **Rewrite URLs** — each card with cached art gets
   `image_url = ${IMAGE_BASE_URL}/cards/<id>.<ext>?v=<sha8>` (the Worker's card
   route — no r2.dev URL; `?v` is the art hash, so the Worker can serve it
   `immutable`). The rewritten **free** bundle is written to `./dist`; when
   `PAID_CATALOG_FILE` is set, the **paid** bundle gets the *same* URLs (one
   rewrite, no drift) and is written to `./dist/paid.json`. The committed
   `catalog/free.json` source is **never mutated** — it keeps raw crawled URLs.
3. **Diff** — sha256 of `free.json` (→ `/catalog.json`), `paid.json`
   (→ `/paid.json`, when published), `brands.json`/`categories.json` (if present),
   and every image is compared against the R2 `manifest.json` (the source of truth
   for "what's already uploaded").
4. **Upload** — only changed objects are `PUT`, then the manifest is updated.
   An unchanged catalog ⇒ **zero writes**. Orphaned objects (art for dropped
   cards) are reported but left in place.

The free bundle at `catalog/free.json` is **committed** (the public, browsable copy
of the rewards data — raw image URLs); the rewritten `dist/` and the `cards/` art
cache are gitignored. The full/paid catalog is **never committed here** — it's
handed to the CLI out-of-band via `PAID_CATALOG_FILE` (from the backend engine's build) and
published to R2 by the backend engine's CI.

### Credentials (`.env`)

R2's S3-compatible API. Create an **Object Read & Write** R2 API token in the
Cloudflare dashboard. See [`.env.example`](.env.example) for the full list:
`R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`,
`IMAGE_BASE_URL`. The Worker needs none of these — it uses its R2 binding.

> `IMAGE_BASE_URL` is just your public Worker URL. The R2 identifiers
> (`R2_ACCOUNT_ID` / keys / `R2_BUCKET`) never appear in code or the committed
> catalog, and the CLI scrubs them from error output — so a public CI log can't
> leak which R2 instance you use.

## Layout

```
src/worker.ts            the read-API Worker
src/catalog.ts           pure slicing logic (shared with tests)
scripts/publish.ts       the publish CLI
scripts/smoke.ts         post-publish/deploy smoke gate (hits the live Worker)
scripts/lib/r2.ts        R2 over the S3 API (aws4fetch)
scripts/lib/manifest.ts  sha256 + diff
catalog/free.json        committed free bundle (public GitHub-CDN copy; backend engine CI publishes it to R2)
dist/                    rewritten build the publisher uploads (gitignored)
cards/                   downloaded card-art cache (gitignored)
test/                    vitest (slicing + diff)
```

## Test / typecheck

```bash
npm test
npm run typecheck
```

## CI

[`.github/workflows/swipewise-api.yml`](../.github/workflows/swipewise-api.yml)
runs on every push to `main` touching the Worker's **code** (`src/`, `test/`,
`scripts/`, `package.json`, `tsconfig.json`, `wrangler.toml`) — *not* `catalog/`, so
a `free.json` refresh deploys nothing here:

- **deploy-worker** — `npm ci` → typecheck → test → `wrangler deploy` → **smoke**.

R2 publishing of both bundles lives in the **backend engine's** CI, which checks this
repo out for the publish CLI + vocab. So the R2 credentials live in the **backend
engine** repo, not here; this repo only needs the deploy token.

### Smoke gate (`npm run smoke`)

After a publish or deploy, [`scripts/smoke.ts`](scripts/smoke.ts) hits the **live**
Worker and fails the build if it isn't serving a coherent catalog — `/healthz` is
`ok` with a numeric `dataVersion`, and `/catalog.json` is non-empty with a
`dataVersion` that matches `/healthz`. It's the check that turns a broken publish
(uploaded nothing / serving stale or empty) into a red build instead of a
silently-degraded app. (Retries briefly to absorb edge/R2 propagation; the Worker
origin is scrubbed from any failure output.)

- **Post-publish (the backend engine's CI):** runs with `EXPECTED_FREE` pointing at
  the just-built `free.json`, so it asserts the live API serves *that exact build*
  — `served dataVersion == just-published`. `WORKER_BASE_URL` is the Worker origin.
- **Post-deploy (here):** liveness-only — this repo ships Worker *code*, not data, so
  there's no "just-built" version to compare. Opt in by setting the repo **secret**
  `WORKER_BASE_URL` to the Worker's origin; without it the step is skipped. A secret,
  not a variable, so the URL stays out of the public Actions logs even though the app
  ships it (same reason `IMAGE_BASE_URL` is a secret on the backend-engine side).

Run it by hand against any environment:

```bash
WORKER_BASE_URL=https://…workers.dev npm run smoke            # liveness only
EXPECTED_DATA_VERSION=123 WORKER_BASE_URL=… npm run smoke     # assert an exact version
```

To publish a catalog update: edit cards in the backend engine and push — its `publish` CI
builds and pushes free + paid to R2. The committed `catalog/free.json` here (the
GitHub-CDN copy) is refreshed by the backend engine's pre-commit hook; commit + push it to
update the browsable snapshot (that commit deploys nothing).

### One-time GitHub setup

This repo's **Secrets** (Settings → Secrets and variables → Actions → Secrets):

| Secret | What |
|---|---|
| `CLOUDFLARE_API_TOKEN` | a token with **Workers Scripts: Edit** (for `wrangler deploy`) |
| `PLACES_API_KEY` | Google Places key. **Secret** — this is the whole point of the proxy: the key exists here and nowhere in the app |
| `FIREBASE_PROJECT_NUMBER` | pins the App Check audience to this project. Without it, enforcement would be enforcement in name only, so the route refuses with 500 rather than accept anything |
| `APPCHECK_ENFORCE` | set to `1` to reject unattested callers with 401. ⚠️ Read as `Boolean(env.APPCHECK_ENFORCE)`, and every non-empty string is truthy in JS — `"0"` still enforces. To disable, **delete the secret** |
| `R2_ACCOUNT_ID` | your Cloudflare account id (the deploy reads it; falls back to `CLOUDFLARE_ACCOUNT_ID`) |

The R2 S3 credentials (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`,
`IMAGE_BASE_URL`) now live in the **backend engine** repo, which runs the publish CLI.
`R2_BUCKET` and `IMAGE_BASE_URL` are kept as **secrets, not variables** there: a
public repo's Action logs are world-readable and variables aren't masked, so the
bucket name and Worker URL stay out of the logs (the CLI also scrubs them from error
output).
