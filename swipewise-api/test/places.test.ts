import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';

import { placesNearby, verifyAppCheck } from '../src/places';

const CORS = { 'access-control-allow-origin': '*' };

function post(body: unknown = { locationRestriction: {} }, headers: Record<string, string> = {}) {
  return new Request('https://api.test/places/nearby', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });
}

/**
 * The proxy exists so the Places key stops shipping in the APK. That only helps
 * if the endpoint replacing it isn't itself an open relay — an unauthenticated
 * proxy is *worse* than the key in the app, because abusing it needs the URL
 * (public) rather than a decompiler. So the tests that matter are the ones
 * about refusing to serve, and about not silently pretending to enforce.
 */
describe('/places/nearby', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('refuses to run without a key rather than calling Google keyless', async () => {
    const res = await placesNearby(post(), {}, CORS);
    expect(res.status).toBe(503);
  });

  it('rejects GET — this is a POST-only forward', async () => {
    const req = new Request('https://api.test/places/nearby');
    const res = await placesNearby(req, { PLACES_API_KEY: 'k' }, CORS);
    expect(res.status).toBe(405);
  });

  it('with enforcement OFF, an unattested caller is served (rollout step 1)', async () => {
    // Deliberate: the app still calls Places directly at this stage, so
    // enforcing here would only break things while proving nothing.
    const fetchMock = vi.fn(async () => new Response('{"places":[]}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const res = await placesNearby(post(), { PLACES_API_KEY: 'k' }, CORS);

    expect(res.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it('with enforcement ON, an unattested caller gets 401', async () => {
    const fetchMock = vi.fn(async () => new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const res = await placesNearby(post(), {
      PLACES_API_KEY: 'k',
      FIREBASE_PROJECT_NUMBER: '123',
      APPCHECK_ENFORCE: '1',
    }, CORS);

    expect(res.status).toBe(401);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('refuses to start if enforcement is on but the audience is unset', async () => {
    // Otherwise "enforcement" would verify a signature and accept a token
    // minted for *any* Firebase project — enforcement in name only, which is
    // more dangerous than none because it reads as secure.
    const res = await placesNearby(post(), {
      PLACES_API_KEY: 'k',
      APPCHECK_ENFORCE: '1',
    }, CORS);
    expect(res.status).toBe(500);
  });

  it('never lets the caller widen the field mask (it sets the billing SKU)', async () => {
    const fetchMock = vi.fn(async () => new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    await placesNearby(
      post({ locationRestriction: {}, 'X-Goog-FieldMask': 'places.*' }),
      { PLACES_API_KEY: 'k' },
      CORS,
    );

    const call = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    const mask = (call[1].headers as Record<string, string>)['X-Goog-FieldMask'];
    expect(mask).not.toContain('*');
    expect(mask).toContain('places.id');
  });

  it('keeps the key out of the response it hands back', async () => {
    vi.stubGlobal('fetch', async () => new Response('{"places":[]}', { status: 200 }));
    const res = await placesNearby(post(), { PLACES_API_KEY: 'super-secret' }, CORS);
    const body = await res.text();
    expect(body).not.toContain('super-secret');
    expect(JSON.stringify([...res.headers])).not.toContain('super-secret');
  });

  it('rejects a non-JSON body instead of forwarding garbage', async () => {
    vi.stubGlobal('fetch', async () => new Response('{}', { status: 200 }));
    const req = new Request('https://api.test/places/nearby', {
      method: 'POST',
      body: 'not json',
    });
    const res = await placesNearby(req, { PLACES_API_KEY: 'k' }, CORS);
    expect(res.status).toBe(400);
  });
});

describe('App Check token verification', () => {
  beforeEach(() => vi.unstubAllGlobals());

  it('rejects a missing token', async () => {
    expect((await verifyAppCheck(null, '123')).ok).toBe(false);
  });

  it('rejects a malformed token without touching the network', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    expect((await verifyAppCheck('not.a.jwt.at.all', '123')).ok).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('fails closed when Google\'s key set is unreachable', async () => {
    // A JWKS outage must not become "everyone is verified".
    vi.stubGlobal('fetch', async () => new Response('nope', { status: 500 }));
    const token = [
      btoa(JSON.stringify({ alg: 'RS256' })),
      btoa(JSON.stringify({ aud: ['projects/123'], exp: 9e9 })),
      'c2ln',
    ].join('.');
    const r = await verifyAppCheck(token, '123');
    expect(r.ok).toBe(false);
    expect(r.reason).toMatch(/jwks/);
  });

  it('rejects a token whose signature does not verify', async () => {
    vi.stubGlobal('fetch', async () => new Response(JSON.stringify({ keys: [] }), { status: 200 }));
    const token = [
      btoa(JSON.stringify({ alg: 'RS256' })),
      btoa(JSON.stringify({ aud: ['projects/123'], exp: 9e9 })),
      'c2ln',
    ].join('.');
    const r = await verifyAppCheck(token, '123');
    expect(r.ok).toBe(false);
    expect(r.reason).toBe('bad signature');
  });
});
