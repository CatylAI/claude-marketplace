import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { evaluateShebang, evaluateWriteSecrets } from './pre-write-edit.ts';

// Assembled at runtime so this test file never contains a contiguous token-shaped literal
// — which would make the file unwritable by the very gate it tests.
const FAKE_GH_TOKEN = 'ghp_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8';
const FAKE_AWS_KEY = 'AKIA' + 'QRSTUVWX7Y2Z3B4C';

describe('evaluateWriteSecrets', () => {
  it('blocks a vendor-prefixed token', () => {
    const d = evaluateWriteSecrets(`const token = "${FAKE_GH_TOKEN}";`);
    assert.ok(d);
    assert.equal(d.patternName, 'github-token');
  });

  it('blocks an AWS access key id', () => {
    const d = evaluateWriteSecrets(`AWS_ACCESS_KEY_ID=${FAKE_AWS_KEY}`);
    assert.ok(d);
    assert.equal(d.patternName, 'aws-access-key-id');
  });

  it('blocks assignment-shaped credentials (file content only)', () => {
    assert.ok(evaluateWriteSecrets('password = "s3rv1ceAcct99"'));
    assert.ok(evaluateWriteSecrets('DATABASE_URL = "postgres://svc:s3rv1ceAcct99@db.internal/app"'));
  });

  it('blocks private key material', () => {
    const pem = '-----BEGIN' + ' RSA PRIVATE KEY' + '-----';
    const d = evaluateWriteSecrets(`${pem}\nMIIE...\n`);
    assert.ok(d);
    assert.equal(d.patternName, 'private-key-block');
    assert.match(d.message, /secret manager/);
  });

  it('allows an obvious placeholder, so the gate does not block its own documentation', () => {
    // Without this, a rule doc or a fixture showing what a token looks like is unwritable.
    assert.equal(evaluateWriteSecrets('token = "ghp_your_token_here_placeholder_value"'), null);
    assert.equal(evaluateWriteSecrets('password = "changeme"'), null);
    assert.equal(evaluateWriteSecrets('password = "xxxxxxxxxx"'), null);
  });

  it('allows ordinary content', () => {
    assert.equal(evaluateWriteSecrets('export const PORT = 8080;'), null);
    assert.equal(evaluateWriteSecrets('read the password from the environment'), null);
    assert.equal(evaluateWriteSecrets(''), null);
  });

  it('names every family it found, not just the first', () => {
    const d = evaluateWriteSecrets(`a="${FAKE_GH_TOKEN}"\nb="${FAKE_AWS_KEY}"`);
    assert.ok(d);
    assert.match(d.message, /aws-access-key-id/);
    assert.match(d.message, /github-token/);
  });
});

describe('evaluateShebang', () => {
  it('warns on a hardcoded interpreter path in a .sh file', () => {
    assert.ok(evaluateShebang('build.sh', '#!/bin/bash\nset -e\n'));
    assert.ok(evaluateShebang('build.sh', '#!/usr/bin/bash\n'));
  });
  it('says nothing for the portable form, or for a non-.sh file', () => {
    assert.equal(evaluateShebang('build.sh', '#!/usr/bin/env bash\n'), null);
    assert.equal(evaluateShebang('build.sh', '#!/usr/bin/env zsh\n'), null);
    assert.equal(evaluateShebang('notes.md', '#!/bin/bash\n'), null);
  });
});

describe('pre-write-edit.ts as Claude Code runs it', () => {
  const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'pre-write-edit.ts');

  function runHook(payload: unknown): { code: number; stderr: string } {
    const env = { ...process.env };
    delete env.CLAUDE_GUARDRAILS_OFF;
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: JSON.stringify(payload), encoding: 'utf-8', env },
    );
    return { code: r.status ?? -1, stderr: r.stderr ?? '' };
  }

  it('blocks a Write whose content carries a token', () => {
    const r = runHook({
      tool_name: 'Write',
      tool_input: { file_path: 'config.ts', content: `const t = "${FAKE_GH_TOKEN}";` },
    });
    assert.equal(r.code, 2);
    assert.match(r.stderr, /BLOCKED/);
  });

  it('blocks an Edit whose replacement text carries a token', () => {
    const r = runHook({
      tool_name: 'Edit',
      tool_input: { file_path: 'config.ts', new_string: `const t = "${FAKE_GH_TOKEN}";` },
    });
    assert.equal(r.code, 2);
  });

  it('allows a clean Write', () => {
    const r = runHook({
      tool_name: 'Write',
      tool_input: { file_path: 'config.ts', content: 'export const PORT = 8080;' },
    });
    assert.equal(r.code, 0);
  });

  it('a style warning must NEVER pre-empt a credential block', () => {
    // The ordering defect this pins: warn() exits 1, so a shebang nit placed before the
    // credential checks returned from the hook ahead of every security gate.
    const r = runHook({
      tool_name: 'Write',
      tool_input: {
        file_path: 'deploy.sh',
        content: `#!/bin/bash\nexport TOKEN="${FAKE_GH_TOKEN}"\n`,
      },
    });
    assert.equal(r.code, 2, 'must BLOCK (2), not merely warn (1)');
  });

  it('warns without blocking on the shebang alone', () => {
    const r = runHook({
      tool_name: 'Write',
      tool_input: { file_path: 'deploy.sh', content: '#!/bin/bash\nset -euo pipefail\n' },
    });
    assert.equal(r.code, 1);
    assert.match(r.stderr, /SHEBANG/);
  });

  it('ignores a tool it does not govern', () => {
    assert.equal(runHook({ tool_name: 'Bash', tool_input: { command: 'ls' } }).code, 0);
  });
});
