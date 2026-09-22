import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { getBehindCount, cachePath, isSafeBranchName } from './behind-count-cache.ts';
import { stateRoot } from './state-dir.ts';

function tmpCache(): string {
  return join(mkdtempSync(join(tmpdir(), 'bcc-')), 'cache.json');
}

describe('isSafeBranchName', () => {
  it('accepts ordinary ref names', () => {
    for (const b of ['main', 'master', 'develop', 'release/2.1', 'feat_x', 'v1.0.0-rc.1']) {
      assert.equal(isSafeBranchName(b), true, b);
    }
  });

  // Each of these is a LEGAL git ref name and simultaneously shell syntax. Git accepts them
  // (`git check-ref-format --branch` refuses only a literal space, and `$IFS` substitutes for
  // one), and the value arrives from whatever a remote advertises — so cloning a hostile repo is
  // the whole attack.
  it('refuses a name that is also a command substitution', () => {
    for (const b of [
      'main$(touch /tmp/pwned)',
      'main`id`',
      'main${IFS}x',
      'main;rm -rf /',
      'main|tee /tmp/x',
      'main&&id',
      'main\nid',
    ]) {
      assert.equal(isSafeBranchName(b), false, b);
    }
  });

  it('refuses a leading dash, which git reads as a flag rather than a ref', () => {
    assert.equal(isSafeBranchName('--upload-pack=touch'), false);
    assert.equal(isSafeBranchName('-x'), false);
  });

  it('refuses the empty string', () => {
    assert.equal(isSafeBranchName(''), false);
  });
});

describe('getBehindCount — injection refusal', () => {
  // The point of this test is that the REAL shellers are in play: no computeBehind override, no
  // sha overrides. If the guard were removed, execution would reach git with the hostile string.
  it('returns null and runs nothing for a substitution-shaped branch name', () => {
    const marker = join(mkdtempSync(join(tmpdir(), 'bcc-pwn-')), 'pwned');
    const hostile = `main$(touch ${marker})`;

    const result = getBehindCount(process.cwd(), hostile, { path: tmpCache() });

    assert.equal(result, null);
    assert.equal(existsSync(marker), false, 'a subprocess executed the substitution');
  });

  it('returns null for a flag-shaped branch name', () => {
    assert.equal(getBehindCount(process.cwd(), '--version', { path: tmpCache() }), null);
  });

  it('refuses before touching the cache file at all', () => {
    const path = tmpCache();
    getBehindCount('/some/worktree', 'main$(id)', { path });
    assert.equal(existsSync(path), false, 'a refused branch still wrote a cache entry');
  });
});

describe('getBehindCount — caching', () => {
  const deps = (over: Record<string, unknown> = {}) => ({
    getHeadSha: () => 'aaaa',
    getOriginBaseSha: () => 'bbbb',
    now: () => 1_000_000,
    ...over,
  });

  it('computes and persists on a miss', () => {
    const path = tmpCache();
    let calls = 0;
    const n = getBehindCount('/wt', 'main', {
      ...deps(),
      path,
      computeBehind: () => {
        calls++;
        return 7;
      },
    });
    assert.equal(n, 7);
    assert.equal(calls, 1);
    const onDisk = JSON.parse(readFileSync(path, 'utf-8'));
    assert.deepEqual(onDisk['/wt:aaaa:main:bbbb'], { behind: 7, ts: 1_000_000 });
  });

  it('serves a hit without recomputing', () => {
    const path = tmpCache();
    writeFileSync(path, JSON.stringify({ '/wt:aaaa:main:bbbb': { behind: 3, ts: 1_000_000 } }));
    let calls = 0;
    const n = getBehindCount('/wt', 'main', {
      ...deps(),
      path,
      computeBehind: () => {
        calls++;
        return 99;
      },
    });
    assert.equal(n, 3);
    assert.equal(calls, 0);
  });

  // The whole reason the base sha is in the key: a fetch that advances origin/<base> inside the
  // TTL window must invalidate, or the report is quietly wrong for up to ten minutes.
  it('misses when origin/<base> has advanced, even inside the TTL', () => {
    const path = tmpCache();
    writeFileSync(path, JSON.stringify({ '/wt:aaaa:main:bbbb': { behind: 3, ts: 1_000_000 } }));
    const n = getBehindCount('/wt', 'main', {
      ...deps({ getOriginBaseSha: () => 'cccc' }),
      path,
      computeBehind: () => 12,
    });
    assert.equal(n, 12);
  });

  it('expires an entry past the TTL', () => {
    const path = tmpCache();
    writeFileSync(path, JSON.stringify({ '/wt:aaaa:main:bbbb': { behind: 3, ts: 0 } }));
    const n = getBehindCount('/wt', 'main', {
      ...deps({ now: () => 11 * 60 * 1000 }),
      path,
      computeBehind: () => 5,
    });
    assert.equal(n, 5);
  });

  // null means "could not determine". Caching it would re-read as 0, which says "up to date" —
  // the more dangerous of the two answers.
  it('never persists an indeterminate result', () => {
    const path = tmpCache();
    const n = getBehindCount('/wt', 'main', { ...deps(), path, computeBehind: () => null });
    assert.equal(n, null);
    assert.equal(existsSync(path), false);
  });

  it('still answers when there is no writable cache location', () => {
    const n = getBehindCount('/wt', 'main', { ...deps(), path: null, computeBehind: () => 4 });
    assert.equal(n, 4);
  });

  it('computes fresh when the base ref is missing (nothing to pin against)', () => {
    const n = getBehindCount('/wt', 'main', {
      ...deps({ getOriginBaseSha: () => null }),
      path: tmpCache(),
      computeBehind: () => 2,
    });
    assert.equal(n, 2);
  });
});

describe('cachePath', () => {
  it('lands under the configured state root, never under the home Claude directory', () => {
    const dir = mkdtempSync(join(tmpdir(), 'bcc-root-'));
    const p = cachePath({ CLAUDE_GUARDRAILS_STATE_DIR: dir } as NodeJS.ProcessEnv);
    assert.equal(p, join(dir, 'behind-count-cache.json'));
  });

  it('defaults to an OS temp directory', () => {
    const root = stateRoot({} as NodeJS.ProcessEnv);
    assert.ok(root.startsWith(tmpdir()), `expected a temp path, got ${root}`);
    assert.ok(!root.includes('/.claude/'), 'state must not live under the home Claude directory');
  });
});
