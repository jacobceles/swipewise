// Google Places proxy + Firebase App Check verification.
//
// ## Why this exists
//
// Today the app calls Places directly with a key compiled into the APK. That
// key is extractable, and the "Android app restriction" that supposedly binds
// it to our package is weaker than it sounds: we issue raw HTTP requests, so
// `X-Android-Package` and `X-Android-Cert` are headers *we* set — and the key,
// the package name and the cert SHA all sit in the same binary. Anyone who
// lifts one has all three and can replay the request from anywhere.
//
// Moving the key here fixes that half. It does NOT fix the other half on its
// own: an unauthenticated proxy is *worse* than the status quo, because
// abusing it needs only the URL (which is in a public repo) rather than
// decompiling an APK. App Check is what closes it — Play Integrity attests
// that the caller is a genuine, Play-installed copy of the app, which a script
// cannot forge.
//
// Hence the deliberate rollout order encoded here:
//
//   1. deploy with APPCHECK_ENFORCE unset  → tokens verified and logged, never
//      rejected. Nothing can break while the app still calls Places directly.
//   2. register App Check in the Firebase console, ship an app build that
//      sends tokens, confirm real devices verify.
//   3. set APPCHECK_ENFORCE=1              → unverified callers get 401.
//   4. only then remove the key from the app.
//
// Skipping to 3 before 2 locks out every user; stopping at 1 and forgetting
// leaves an open proxy. The log line in step 1 is what tells you 2 worked.

/** Verified-token cache TTL for Google's App Check public keys (JWKS). */
const JWKS_TTL_MS = 60 * 60 * 1000;
const JWKS_URL = 'https://firebaseappcheck.googleapis.com/v1/jwks';

const PLACES_ENDPOINT = 'https://places.googleapis.com/v1/places:searchNearby';
const PLACES_FIELD_MASK =
  'places.id,places.displayName,places.location,places.primaryType,places.businessStatus';

interface Jwks {
  keys: JsonWebKey[];
}

let jwksCache: { at: number; keys: CryptoKey[] } | null = null;

/** Google's App Check signing keys, cached — one fetch per hour per isolate. */
async function appCheckKeys(): Promise<CryptoKey[]> {
  const now = Date.now();
  if (jwksCache && now - jwksCache.at < JWKS_TTL_MS) return jwksCache.keys;

  const res = await fetch(JWKS_URL);
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  const jwks = (await res.json()) as Jwks;
  const keys = await Promise.all(
    (jwks.keys ?? []).map((jwk) =>
      crypto.subtle.importKey(
        'jwk',
        jwk,
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify'],
      ),
    ),
  );
  jwksCache = { at: now, keys };
  return keys;
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '=');
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export interface AppCheckResult {
  ok: boolean;
  reason?: string;
}

/**
 * Verify a Firebase App Check token.
 *
 * Checks the signature against Google's published keys and then the claims that
 * actually matter: audience must name *our* project (otherwise a token minted
 * for any other Firebase project would pass), issuer must be Google's App Check
 * service, and it must not be expired.
 */
export async function verifyAppCheck(
  token: string | null,
  projectNumber: string,
): Promise<AppCheckResult> {
  if (!token) return { ok: false, reason: 'missing token' };
  const parts = token.split('.');
  if (parts.length !== 3) return { ok: false, reason: 'malformed token' };

  const [header, claims, signature] = parts as [string, string, string];

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(claims)));
  } catch {
    return { ok: false, reason: 'unparseable payload' };
  }

  const signed = new TextEncoder().encode(`${header}.${claims}`);
  const sig = b64urlToBytes(signature);
  let keys: CryptoKey[];
  try {
    keys = await appCheckKeys();
  } catch (e) {
    return { ok: false, reason: `jwks unavailable: ${e}` };
  }

  let signatureOk = false;
  for (const key of keys) {
    if (await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, sig, signed)) {
      signatureOk = true;
      break;
    }
  }
  if (!signatureOk) return { ok: false, reason: 'bad signature' };

  const aud = payload.aud;
  const audiences = Array.isArray(aud) ? aud.map(String) : [String(aud ?? '')];
  if (!audiences.includes(`projects/${projectNumber}`)) {
    return { ok: false, reason: 'audience is a different Firebase project' };
  }
  if (!String(payload.iss ?? '').startsWith('https://firebaseappcheck.googleapis.com/')) {
    return { ok: false, reason: 'unexpected issuer' };
  }
  const exp = Number(payload.exp ?? 0);
  if (!exp || exp * 1000 <= Date.now()) return { ok: false, reason: 'expired' };

  return { ok: true };
}

export interface PlacesEnv {
  /** Google Places key, held here so it never ships in the app. A secret. */
  PLACES_API_KEY?: string;
  /** Firebase project *number* — the App Check audience. */
  FIREBASE_PROJECT_NUMBER?: string;
  /** Any non-empty value turns rejection on. Unset = verify and log only. */
  APPCHECK_ENFORCE?: string;
}

/**
 * `POST /places/nearby` — forwards a Nearby Search to Google with the key held
 * server-side.
 *
 * The body is passed through rather than reconstructed, so the app keeps
 * control of radius and place types without this needing to know their shape.
 * The field mask is fixed here because it determines the billing SKU, and that
 * is not something a client should be able to widen.
 */
export async function placesNearby(
  req: Request,
  env: PlacesEnv,
  cors: Record<string, string>,
): Promise<Response> {
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, 'content-type': 'application/json; charset=utf-8' },
    });

  if (req.method !== 'POST') return json(405, { error: 'POST only' });
  if (!env.PLACES_API_KEY) return json(503, { error: 'places proxy not configured' });

  const enforce = Boolean(env.APPCHECK_ENFORCE);
  const projectNumber = env.FIREBASE_PROJECT_NUMBER ?? '';
  if (enforce && !projectNumber) {
    // Refuse rather than silently accept everything: enforcement that cannot
    // check the audience is enforcement in name only.
    return json(500, { error: 'APPCHECK_ENFORCE set without FIREBASE_PROJECT_NUMBER' });
  }

  const verdict = await verifyAppCheck(
    req.headers.get('x-firebase-appcheck'),
    projectNumber,
  );
  if (!verdict.ok) {
    if (enforce) return json(401, { error: 'app check failed' });
    // Observability for step 2 of the rollout: this line going quiet is how
    // you know real devices started verifying.
    console.warn(`app-check not verified (${verdict.reason}); passing through — enforcement is OFF`);
  }

  let body: string;
  try {
    body = JSON.stringify(await req.json());
  } catch {
    return json(400, { error: 'body must be JSON' });
  }

  const upstream = await fetch(PLACES_ENDPOINT, {
    method: 'POST',
    headers: {
      'X-Goog-Api-Key': env.PLACES_API_KEY,
      'X-Goog-FieldMask': PLACES_FIELD_MASK,
      'Content-Type': 'application/json',
    },
    body,
  });

  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      ...cors,
      'content-type': upstream.headers.get('content-type') ?? 'application/json',
      // Places results are already cached on-device per tile; caching here too
      // is the shared-cache win, but it needs a cache key derived from the body,
      // which `fetch` cannot do for a POST. Left for when the route moves to GET.
      'cache-control': 'no-store',
    },
  });
}
