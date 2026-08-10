import { describe, expect, it } from 'vitest';

import { diffObjects, isRollback, sha256 } from '../scripts/lib/manifest';

describe('sha256', () => {
  it('is stable and content-addressed', () => {
    expect(sha256('hello')).toBe(sha256('hello'));
    expect(sha256('hello')).not.toBe(sha256('world'));
  });
});

describe('diffObjects', () => {
  const remote = {
    'catalog.json': 'aaa',
    'cards/chase.x.png': 'bbb',
    'cards/chase.y.png': 'ccc',
  };

  it('flags new and modified keys as changed, leaves equal ones unchanged', () => {
    const local = {
      'catalog.json': 'AAA', // modified
      'cards/chase.x.png': 'bbb', // unchanged
      'cards/chase.z.png': 'ddd', // new
    };
    const diff = diffObjects(local, remote);
    expect(diff.changed).toEqual(['cards/chase.z.png', 'catalog.json']);
    expect(diff.unchanged).toEqual(['cards/chase.x.png']);
  });

  it('reports keys dropped from the catalog as removed orphans', () => {
    const local = { 'catalog.json': 'aaa' };
    const diff = diffObjects(local, remote);
    expect(diff.removed).toEqual(['cards/chase.x.png', 'cards/chase.y.png']);
  });

  it('produces an all-changed diff against an empty manifest', () => {
    const local = { 'catalog.json': 'aaa', 'cards/chase.x.png': 'bbb' };
    const diff = diffObjects(local, {});
    expect(diff.changed).toHaveLength(2);
    expect(diff.unchanged).toHaveLength(0);
    expect(diff.removed).toHaveLength(0);
  });

  it('is a no-op diff when local equals remote', () => {
    const diff = diffObjects(remote, remote);
    expect(diff.changed).toHaveLength(0);
    expect(diff.unchanged).toHaveLength(3);
    expect(diff.removed).toHaveLength(0);
  });
});

describe('isRollback (A3-F8)', () => {
  it('flags an older catalogVersion published over a newer live one', () => {
    expect(isRollback('2026.07.02', '2026.07.20')).toBe(true);
  });

  it('allows an equal or newer version (republish / normal advance)', () => {
    expect(isRollback('2026.07.20', '2026.07.20')).toBe(false);
    expect(isRollback('2026.07.21', '2026.07.20')).toBe(false);
  });

  it('never treats the first publish (empty remote) as a rollback', () => {
    expect(isRollback('2026.07.20', '')).toBe(false);
  });
});
