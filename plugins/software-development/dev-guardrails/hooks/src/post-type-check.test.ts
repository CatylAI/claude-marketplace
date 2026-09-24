import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  PROJECT_CHECK_COOLDOWN_MS,
  filterTscOutput,
  runTypeChecks,
  shouldRunProjectCheck,
  tscCommand,
  tsconfigAllowsJs,
} from './post-type-check.ts';

// The type-check stage runs inside the consolidated PostToolUse entry.
const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'post-write-edit.ts');

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

describe('tscCommand', () => {
  it('uses the project tsc and never falls back to npx', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ptc-'));
    writeFileSync(join(dir, 'tsconfig.json'), '{}');
    assert.equal(tscCommand(dir), null, 'no local tsc: skip rather than npx a different version');
    mkdirSync(join(dir, 'node_modules', '.bin'), { recursive: true });
    writeFileSync(join(dir, 'node_modules', '.bin', 'tsc'), '');
    assert.equal(tscCommand(dir)?.[0], join(dir, 'node_modules', '.bin', 'tsc'));
  });
});

describe('filterTscOutput', () => {
  const OUT = [
    "src/a.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.",
    '  Some continuation line.',
    "src/b.ts(1,1): error TS2304: Cannot find name 'x'.",
    "src/b.ts(2,1): error TS2304: Cannot find name 'y'.",
  ].join('\n');

  it('keeps the edited file and summarises the rest', () => {
    const f = filterTscOutput(OUT, '/r/src/a.ts', '/r');
    assert.match(f, /src\/a\.ts\(3,7\)/);
    assert.match(f, /Some continuation line/);
    assert.doesNotMatch(f, /Cannot find name/);
    assert.match(f, /2 diagnostic\(s\) in other files: src\/b\.ts \(2\)/);
  });

  it('is empty when there is nothing', () => {
    assert.equal(filterTscOutput('', '/r/src/a.ts', '/r'), '');
  });
});

describe('project-wide rate limit', () => {
  it('opens only after the cooldown', () => {
    assert.equal(shouldRunProjectCheck(0, PROJECT_CHECK_COOLDOWN_MS), true);
    assert.equal(shouldRunProjectCheck(1000, 1000 + PROJECT_CHECK_COOLDOWN_MS - 1), false);
  });

  it('runs tsc at most once per cooldown window per project', () => {
    // A fake local tsc that records each invocation, so the assertion is about spawns, not output.
    const dir = mkdtempSync(join(tmpdir(), 'ptc-rl-'));
    const log = join(dir, 'calls.log');
    writeFileSync(join(dir, 'tsconfig.json'), '{}');
    mkdirSync(join(dir, 'node_modules', '.bin'), { recursive: true });
    const fake = join(dir, 'node_modules', '.bin', 'tsc');
    writeFileSync(fake, `#!/usr/bin/env sh\necho x >> "${log}"\nexit 0\n`);
    chmodSync(fake, 0o755);
    const file = join(dir, 'a.ts');
    writeFileSync(file, 'export const a = 1;\n');

    const prev = process.env.CLAUDE_GUARDRAILS_STATE_DIR;
    process.env.CLAUDE_GUARDRAILS_STATE_DIR = mkdtempSync(join(tmpdir(), 'ptc-state-'));
    try {
      const t0 = 10_000_000;
      runTypeChecks(file, dir, 'ts', t0);
      runTypeChecks(file, dir, 'ts', t0 + 1000);
      runTypeChecks(file, dir, 'ts', t0 + PROJECT_CHECK_COOLDOWN_MS);
    } finally {
      if (prev === undefined) delete process.env.CLAUDE_GUARDRAILS_STATE_DIR;
      else process.env.CLAUDE_GUARDRAILS_STATE_DIR = prev;
    }
    const calls = readFileSync(log, 'utf-8').trim().split('\n').length;
    assert.equal(calls, 2, 'the second edit inside the window must not spawn tsc');
  });
});

describe('the type-check stage, as Claude Code runs it', () => {
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
