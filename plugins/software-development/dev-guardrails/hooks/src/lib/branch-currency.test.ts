import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  classifyWorktrees,
  formatCurrencyReport,
  formatBasePullReport,
  type WorktreeEntry,
} from './branch-currency.ts';

const wt = (branch: string, clean = true): WorktreeEntry => ({
  path: `/wt/${branch}`,
  branch,
  clean,
});

describe('classifyWorktrees', () => {
  it('attaches the behind count for each worktree', () => {
    const rows = classifyWorktrees([wt('a'), wt('b')], 'main', (p) => (p.endsWith('a') ? 3 : 0));
    assert.deepEqual(
      rows.map((r) => [r.branch, r.behind]),
      [
        ['a', 3],
        ['b', 0],
      ],
    );
  });

  it('carries a null through rather than coercing it', () => {
    const rows = classifyWorktrees([wt('a')], 'main', () => null);
    assert.equal(rows[0].behind, null);
  });
});

describe('formatCurrencyReport', () => {
  it('says nothing when every worktree is current', () => {
    const rows = classifyWorktrees([wt('a'), wt('b')], 'main', () => 0);
    assert.deepEqual(formatCurrencyReport(rows, 'main', { live: true }), []);
  });

  it('reports a clean worktree that is behind', () => {
    const rows = classifyWorktrees([wt('a')], 'main', () => 4);
    const lines = formatCurrencyReport(rows, 'main', { live: true });
    assert.match(lines[0], /BEHIND origin\/main/);
    assert.match(lines[0], /a \(\+4 behind main\)/);
  });

  it('separates the dirty case, because a rebase would refuse over it', () => {
    const rows = classifyWorktrees([wt('a', false)], 'main', () => 4);
    const lines = formatCurrencyReport(rows, 'main', { live: true });
    assert.ok(lines.some((l) => l.startsWith('BEHIND + DIRTY:')));
    assert.ok(!lines.some((l) => l.startsWith('BEHIND origin/')));
  });

  // The failure this whole shape exists to prevent: an indeterminate count reported as "current".
  it('gives an indeterminate count its own line, never silence', () => {
    const rows = classifyWorktrees([wt('a')], 'main', () => null);
    const lines = formatCurrencyReport(rows, 'main', { live: true });
    assert.match(lines[0], /BEHIND-COUNT UNKNOWN/);
    assert.ok(lines.some((l) => /git fetch origin/.test(l)));
  });

  it('marks a non-live report as coming from cached origin state', () => {
    const rows = classifyWorktrees([wt('a')], 'main', () => 2);
    const live = formatCurrencyReport(rows, 'main', { live: true })[0];
    const cached = formatCurrencyReport(rows, 'main', { live: false })[0];
    assert.ok(!live.includes('cached origin'));
    assert.match(cached, /cached origin/);
  });
});

describe('formatBasePullReport', () => {
  it('says nothing when no pull was attempted', () => {
    assert.deepEqual(formatBasePullReport('main', null), []);
  });

  it('says nothing when the fast-forward succeeded', () => {
    assert.deepEqual(formatBasePullReport('main', { ok: true, output: '' }), []);
  });

  // --ff-only refuses exactly when local base has commits origin does not. That is a real finding,
  // and the two obvious "fixes" both lose work, so the report names them as forbidden.
  it('reports a refusal loudly and warns off both destructive workarounds', () => {
    const lines = formatBasePullReport('main', { ok: false, output: 'Not possible to fast-forward' });
    assert.match(lines[0], /FAILED/);
    const joined = lines.join('\n');
    assert.match(joined, /do NOT plain-pull/);
    assert.match(joined, /reset --hard/);
    assert.match(joined, /Not possible to fast-forward/);
  });
});
