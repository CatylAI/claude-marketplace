import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { shouldRunTests, testCandidates } from './post-test.ts';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'post-test.ts');

describe('shouldRunTests', () => {
  const COOLDOWN = 3 * 60 * 1000;

  it('refuses below the edit threshold', () => {
    assert.equal(shouldRunTests({ edit_count: 1, last_run_at: 0 }, COOLDOWN + 1), false);
    assert.equal(shouldRunTests({ edit_count: 2, last_run_at: 0 }, COOLDOWN + 1), false);
  });

  it('runs at the threshold once the cooldown has passed', () => {
    assert.equal(shouldRunTests({ edit_count: 3, last_run_at: 0 }, COOLDOWN), true);
  });

  // BOTH conditions, not either. Threshold alone turns a five-edit refactor into repeated runs
  // against half-finished states; cooldown alone runs on a single stray edit.
  it('refuses inside the cooldown however many edits happened', () => {
    assert.equal(shouldRunTests({ edit_count: 50, last_run_at: 1000 }, 1000 + COOLDOWN - 1), false);
  });

  it('runs on a first-ever edit burst, since last_run_at is 0', () => {
    assert.equal(shouldRunTests({ edit_count: 3, last_run_at: 0 }, Date.now()), true);
  });
});

describe('testCandidates', () => {
  it('offers the python conventions', () => {
    const c = testCandidates('/r/src/pkg/thing.py', '/r');
    assert.ok(c.includes('/r/tests/test_thing.py'));
    assert.ok(c.includes('/r/src/pkg/test_thing.py'));
    assert.ok(c.includes('/r/tests/pkg/test_thing.py'));
  });

  it('offers the JS/TS conventions, sibling and __tests__', () => {
    const c = testCandidates('/r/src/thing.ts', '/r');
    assert.ok(c.includes('/r/src/thing.test.ts'));
    assert.ok(c.includes('/r/src/thing.spec.ts'));
    assert.ok(c.includes('/r/src/__tests__/thing.test.ts'));
  });

  it('covers the mts and cts spellings', () => {
    assert.ok(testCandidates('/r/src/thing.mts', '/r').length > 0);
    assert.ok(testCandidates('/r/src/thing.cts', '/r').length > 0);
  });

  it('offers nothing for a language it has no convention for', () => {
    assert.deepEqual(testCandidates('/r/main.go', '/r'), []);
    assert.deepEqual(testCandidates('/r/main.tf', '/r'), []);
  });
});

describe('post-test.ts as Claude Code runs it', () => {
  function run(payload: unknown, env: Record<string, string> = {}) {
    return spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: JSON.stringify(payload), encoding: 'utf-8', env: { ...process.env, ...env } },
    );
  }

  it('ignores a tool it does not govern', () => {
    const r = run({ tool_name: 'Bash', tool_input: { command: 'ls' } });
    assert.equal(r.status, 0);
    assert.equal(r.stderr.trim(), '');
  });

  it('never blocks, and never writes into the edited repository', () => {
    const repo = mkdtempSync(join(tmpdir(), 'pt-repo-'));
    spawnSync('git', ['init', '-q'], { cwd: repo });
    mkdirSync(join(repo, 'src'), { recursive: true });
    const file = join(repo, 'src', 'thing.ts');
    writeFileSync(file, 'export const a = 1;\n');

    const stateDir = mkdtempSync(join(tmpdir(), 'pt-state-'));
    for (let i = 0; i < 4; i++) {
      const r = run(
        { tool_name: 'Edit', tool_input: { file_path: file } },
        { CLAUDE_GUARDRAILS_STATE_DIR: stateDir },
      );
      assert.equal(r.status, 0, 'a PostToolUse hook must never block');
    }

    // The counter belongs in the scratch directory. A hook that drops state into the working
    // tree adds untracked files to `git status` and eventually someone commits them.
    const stray = spawnSync('ls', ['-A', repo], { encoding: 'utf-8' })
      .stdout.trim()
      .split('\n')
      .filter((n) => n !== '.git')
      .sort();
    assert.deepEqual(stray, ['src'], `unexpected files left in the repo: ${stray.join(', ')}`);
  });

  it('skips a test file, since running a half-written test reports the edit as a failure', () => {
    const repo = mkdtempSync(join(tmpdir(), 'pt-repo-'));
    const file = join(repo, 'thing.test.ts');
    writeFileSync(file, 'import { test } from "node:test";\n');
    const r = run({ tool_name: 'Edit', tool_input: { file_path: file } });
    assert.equal(r.status, 0);
    assert.equal(r.stderr.trim(), '');
  });
});
