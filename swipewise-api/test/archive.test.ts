import { describe, expect, it } from 'vitest';

import { archiveCatalog, type ArchiveStore } from '../scripts/lib/archive';
import { archiveKey } from '../src/layout';

describe('archiveKey', () => {
  it('namespaces by catalogVersion under archive/', () => {
    expect(archiveKey('2026.07.22')).toBe('archive/2026.07.22.json');
  });
});

describe('archiveCatalog', () => {
  function fakeStore(exists: boolean): { store: ArchiveStore; puts: { key: string; body: unknown; contentType: string }[] } {
    const puts: { key: string; body: unknown; contentType: string }[] = [];
    const store: ArchiveStore = {
      async exists() {
        return exists;
      },
      async put(key, body, contentType) {
        puts.push({ key, body, contentType });
      },
    };
    return { store, puts };
  }

  it('PUTs the catalog to its versioned key when no archive exists yet', async () => {
    const { store, puts } = fakeStore(false);
    const result = await archiveCatalog(store, '2026.07.22', '{"card_products":[]}');
    expect(result).toEqual({ key: 'archive/2026.07.22.json', archived: true });
    expect(puts).toEqual([
      { key: 'archive/2026.07.22.json', body: '{"card_products":[]}', contentType: 'application/json' },
    ]);
  });

  it('skips the PUT when the archive for that version already exists (no clobber)', async () => {
    const { store, puts } = fakeStore(true);
    const result = await archiveCatalog(store, '2026.07.22', '{"card_products":[]}');
    expect(result).toEqual({ key: 'archive/2026.07.22.json', archived: false });
    expect(puts).toEqual([]);
  });
});
