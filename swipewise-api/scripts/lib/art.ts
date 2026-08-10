// Card-art helpers for the publish CLI, kept here (not inline in publish.ts) so
// they're unit-testable — publish.ts runs main() on import, so nothing there can
// be imported by a test. Two pure functions:
//   sniffImageExt  — magic-byte format check, so an issuer CDN's HTML block page
//                    can't be cached and served as "card art" (A3-F5).
//   cardsBeforeAssets — upload order that puts cards/* ahead of assets/*, so a
//                    freshly-published catalog can never reference art that
//                    isn't in R2 yet (the stale-edge-cache race, A3-F1).

/**
 * Return the canonical extension for a real image, sniffed from its leading
 * bytes, or null if the bytes aren't a recognised image (e.g. an HTML challenge
 * page, a JSON error body, a truncated download). Never guesses from the URL.
 */
export function sniffImageExt(bytes: Uint8Array): string | null {
  const b = bytes;
  if (b.length < 4) return null;

  // PNG: 89 50 4E 47
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'png';
  // JPEG: FF D8 FF
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'jpg';
  // GIF: "GIF8"
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) return 'gif';
  // WEBP: "RIFF"...."WEBP"
  if (
    b.length >= 12 &&
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  ) {
    return 'webp';
  }

  // SVG is text — sniff a decoded prefix. Accept only when it actually opens an
  // <svg> (optionally behind an XML prolog); reject HTML block pages, which also
  // start with '<' but are '<!doctype html>' / '<html'.
  const head = latin1(b.subarray(0, 256)).trimStart().toLowerCase();
  if (head.startsWith('<svg')) return 'svg';
  if (head.startsWith('<?xml') && head.includes('<svg')) return 'svg';

  return null;
}

/** First few bytes as hex, for a "not an image" error message. */
export function describeBytes(bytes: Uint8Array): string {
  return Array.from(bytes.subarray(0, 4), (x) => x.toString(16).padStart(2, '0')).join(' ');
}

/**
 * Order upload keys so every `cards/*` object goes before every other object
 * (i.e. the `assets/*` bundles). Within each group keys are sorted for
 * determinism. Uploading art first guarantees a published catalog's `?v=` URLs
 * resolve to bytes already in R2.
 */
export function cardsBeforeAssets(keys: string[]): string[] {
  const cards = keys.filter((k) => k.startsWith('cards/')).sort();
  const rest = keys.filter((k) => !k.startsWith('cards/')).sort();
  return [...cards, ...rest];
}

function latin1(bytes: Uint8Array): string {
  let s = '';
  for (const byte of bytes) s += String.fromCharCode(byte);
  return s;
}
