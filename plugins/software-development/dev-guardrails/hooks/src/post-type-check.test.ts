import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tsconfigAllowsJs } from './post-type-check.ts';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'post-type-check.ts');

describe('tsconfigAllowsJs', () => {
  it('detects the opt-in', () => {
    assert.equal(tsconfigAllowsJs('{ "compilerOptions": { "allowJs": true } }'), true);
    assert.equal(tsconfigAllowsJs('{"compilerOptions":{"allowJs":true}}'), true);
  });

  // The naive check is "contains allowJs AND contains true", which passes on a config that
  // explicitly turns it OFF while enabling something else — so JS files get checked against a
  // config that does not cover them, and every result is noise.
  it('does not confuse an explicit opt-out with an opt-in', () => {
    const cfg = '{ "compilerOptions": { "allowJs": false, "strict": true } }';
    assert.equal(tsconfigAllowsJs(cfg), false);
  });

  it('is false when the key is absent', () => {
    assert.equal(tsconfigAllowsJs('{ "compilerOptions": { "strict": true } }'), false);
  });
});

describe('post-type-check.ts as Claude Code runs it', () => {
  function run(payload: unknown) {
    return spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: JSON.stringify(payload), encoding: 'utf-8' },
    );
  }

  it('ignores a tool it does not govern', () => {
    const r = run({ tool_name: 'Bash', tool_input: { command: 'ls' } });
    assert.equal(r.status, 0);
    assert.equal(r.stderr.trim(), '');
  });

  it('exits clean when the file no longer exists', () => {
    const r = run({ tool_name: 'Write', tool_input: { file_path: '/nope/gone.ts' } });
    assert.equal(r.status, 0);
  });

  // No tsconfig, no mypy config, nothing configured: the hook must do nothing rather than
  // introduce tooling the project never chose.
  it('says nothing for a file in a project with no checker configured', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ptc-'));
    const file = join(dir, 'thing.ts');
    writeFileSync(file, 'export const a: number = 1;\n');
    const r = run({ tool_name: 'Write', tool_input: { file_path: file } });
    assert.equal(r.status, 0, 'a PostToolUse hook must never block');
    assert.equal(r.stderr.trim(), '');
  });

  it('never blocks, whatever it finds', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ptc-'));
    const file = join(dir, 'broken.py');
    writeFileSync(file, 'def f(:\n');
    const r = run({ tool_name: 'Write', tool_input: { file_path: file } });
    assert.equal(r.status, 0);
  });
});
