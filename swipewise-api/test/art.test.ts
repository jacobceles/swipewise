import { describe, expect, it } from 'vitest';
import { cardsBeforeAssets, sniffImageExt } from '../scripts/lib/art';

const bytes = (...b: number[]) => new Uint8Array(b);
const text = (s: string) => new TextEncoder().encode(s);

describe('sniffImageExt', () => {
  it('recognises PNG / JPEG / GIF / WEBP magic bytes', () => {
    expect(sniffImageExt(bytes(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a))).toBe('png');
    expect(sniffImageExt(bytes(0xff, 0xd8, 0xff, 0xe0))).toBe('jpg');
    expect(sniffImageExt(bytes(0x47, 0x49, 0x46, 0x38, 0x39, 0x61))).toBe('gif');
    expect(
      sniffImageExt(bytes(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50)),
    ).toBe('webp');
  });

  it('recognises SVG (with or without an XML prolog)', () => {
    expect(sniffImageExt(text('<svg xmlns="http://www.w3.org/2000/svg"></svg>'))).toBe('svg');
    expect(sniffImageExt(text('<?xml version="1.0"?>\n<svg></svg>'))).toBe('svg');
  });

  it('rejects an HTML block page (the A3-F5 failure)', () => {
    expect(sniffImageExt(text('<!DOCTYPE html>\n<html><head>Access denied</head>'))).toBeNull();
    expect(sniffImageExt(text('<html><body>Just a moment...</body></html>'))).toBeNull();
  });

  it('rejects a JSON error body and too-short input', () => {
    expect(sniffImageExt(text('{"error":"not found"}'))).toBeNull();
    expect(sniffImageExt(bytes(0x00, 0x01))).toBeNull();
  });
});

describe('cardsBeforeAssets', () => {
  it('puts every cards/* key ahead of assets/*, each group sorted', () => {
    const ordered = cardsBeforeAssets([
      'assets/catalog.json',
      'cards/z.png',
      'assets/brands.json',
      'cards/a.png',
    ]);
    expect(ordered).toEqual([
      'cards/a.png',
      'cards/z.png',
      'assets/brands.json',
      'assets/catalog.json',
    ]);
  });

  it('is a no-op ordering when there are no cards', () => {
    expect(cardsBeforeAssets(['assets/paid.json', 'assets/catalog.json'])).toEqual([
      'assets/catalog.json',
      'assets/paid.json',
    ]);
  });
});
