// The publish manifest is the source of truth for "what's already in R2": a
// map of object key -> sha256. The CLI diffs the local build against it and
// uploads only what changed, so a re-publish of an unchanged catalog costs
// zero R2 writes. It lives in R2 (not on disk) so the diff is correct even
// from a fresh clone.

import { createHash } from 'node:crypto';

export interface PublishManifest {
  catalogVersion: string;
  dataVersion: number;
  schemaVersion: number;
  updatedAt: string;
  /** object key -> sha256 hex */
  objects: Record<string, string>;
}

export function sha256(data: Uint8Array | string): string {
  return createHash('sha256').update(data).digest('hex');
}

export interface Diff {
  /** new or modified keys — need a PUT */
  changed: string[];
  unchanged: string[];
  /** keys in R2 the current catalog no longer produces (orphans) */
  removed: string[];
}

/** Compare local `{key: sha}` against the remote manifest's objects. */
export function diffObjects(
  local: Record<string, string>,
  remote: Record<string, string>,
): Diff {
  const changed: string[] = [];
  const unchanged: string[] = [];
  for (const [key, sha] of Object.entries(local)) {
    if (remote[key] === sha) unchanged.push(key);
    else changed.push(key);
  }
  const localKeys = new Set(Object.keys(local));
  const removed = Object.keys(remote).filter((k) => !localKeys.has(k));
  return {
    changed: changed.sort(),
    unchanged: unchanged.sort(),
    removed: removed.sort(),
  };
}

/**
 * True when publishing `localVersion` over the live `remoteVersion` would move
 * the catalog BACKWARDS. `catalogVersion` is a zero-padded YYYY.MM.DD date, so a
 * plain string compare orders it; `dataVersion` is a content hash and carries no
 * ordering, so it can't answer this. An empty remote (first publish) is never a
 * rollback. Used by the publish CLI to refuse a stale-checkout downgrade (A3-F8).
 */
export function isRollback(localVersion: string, remoteVersion: string): boolean {
  return Boolean(remoteVersion) && localVersion < remoteVersion;
}
