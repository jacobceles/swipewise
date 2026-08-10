// Archive-on-publish: every published FREE catalog is also written to a
// permanent, versioned key (archive/<catalogVersion>.json) that's never
// overwritten, so a past catalogVersion can always be recovered even after
// later publishes advance assets/catalog.json. Kept here (not inline in
// publish.ts) so it's unit-testable — publish.ts runs main() on import, so
// nothing there can be imported by a test.

import { archiveKey } from '../../src/layout';

/** Minimal R2 surface this needs — matches scripts/lib/r2.ts's R2 class. */
export interface ArchiveStore {
  exists(key: string): Promise<boolean>;
  put(key: string, body: Uint8Array | string, contentType: string): Promise<void>;
}

export interface ArchiveResult {
  key: string;
  archived: boolean;
}

/**
 * PUT the catalog to its versioned archive key, unless one is already there.
 * A re-publish of the same catalogVersion must never clobber the archived
 * copy — the archive is a permanent history, not a cache.
 */
export async function archiveCatalog(
  r2: ArchiveStore,
  catalogVersion: string,
  catalogJson: string,
): Promise<ArchiveResult> {
  const key = archiveKey(catalogVersion);
  if (await r2.exists(key)) return { key, archived: false };
  await r2.put(key, catalogJson, 'application/json');
  return { key, archived: true };
}
