import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import {
  applyEdit,
  evaluateEditSecrets,
  evaluateWriteSecrets,
  extractWriteTarget,
} from './pre-write-edit.ts';

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

describe('evaluateEditSecrets: an Edit is judged in the file it lands in', () => {
  // The realistic miss this pins: the assignment shape lives in the UNCHANGED text, so the
  // replacement alone (a bare string literal) matches no CONTENT_PATTERN.
  const BEFORE = 'db = connect(\n  password = os.environ["DB_PASSWORD"],\n)\n';

  it('blocks a literal that completes an assignment already in the file', () => {
    const d = evaluateEditSecrets(BEFORE, 'os.environ["DB_PASSWORD"]', '"s3rv1ceAcct99"', false);
    assert.ok(d, 'the password literal must be caught in context');
    assert.equal(d.patternName, 'hardcoded-password');
  });

  it('does not re-judge a credential-shaped value the file already had', () => {
    const before = 'password = "s3rv1ceAcct99"\nport = 1\n';
    assert.equal(evaluateEditSecrets(before, 'port = 1', 'port = 2', false), null);
  });

  it('falls back to the replacement text when the file cannot be read', () => {
    assert.ok(evaluateEditSecrets(null, 'x', `t = "${FAKE_GH_TOKEN}"`, false));
    assert.equal(evaluateEditSecrets(null, 'x', '"s3rv1ceAcct99"', false), null);
  });

  it('applyEdit splices literally and honours replace_all', () => {
    assert.equal(applyEdit('a b a', 'a', '$&', false), '$& b a');
    assert.equal(applyEdit('a b a', 'a', 'c', true), 'c b c');
    assert.equal(applyEdit('a b a', 'zz', 'c', false), null);
  });
});

describe('extractWriteTarget', () => {
  it('covers NotebookEdit through notebook_path and new_source', () => {
    const t = extractWriteTarget({
      tool_name: 'NotebookEdit',
      tool_input: { notebook_path: '/p/n.ipynb', new_source: 'x = 1' },
    });
    assert.deepEqual(t, { tool: 'NotebookEdit', filePath: '/p/n.ipynb', written: 'x = 1' });
  });
  it('ignores tools that do not write files', () => {
    assert.equal(extractWriteTarget({ tool_name: 'Read', tool_input: { file_path: '/p' } }), null);
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

  it('allows the shebang alone silently — exit 1 reached only the user, never Claude', () => {
    // The portability note moved to post-write-edit, which reports via additionalContext.
    const r = runHook({
      tool_name: 'Write',
      tool_input: { file_path: 'deploy.sh', content: '#!/bin/bash\nset -euo pipefail\n' },
    });
    assert.equal(r.code, 0);
    assert.equal(r.stderr, '');
  });

  it('blocks a token written into a notebook cell via NotebookEdit', () => {
    const r = runHook({
      tool_name: 'NotebookEdit',
      tool_input: {
        notebook_path: '/tmp/analysis.ipynb',
        cell_id: 'abc',
        new_source: `client = Client(token="${FAKE_GH_TOKEN}")`,
      },
    });
    assert.equal(r.code, 2, r.stderr);
    assert.match(r.stderr, /github-token/);
  });

  it('blocks an Edit whose literal completes a password assignment on disk', () => {
    const dir = mkdtempSync(join(tmpdir(), 'pwe-'));
    try {
      const file = join(dir, 'settings.py');
      writeFileSync(file, 'DB = dict(\n    password=os.environ["DB_PASSWORD"],\n)\n');
      const r = runHook({
        tool_name: 'Edit',
        tool_input: {
          file_path: file,
          old_string: 'os.environ["DB_PASSWORD"]',
          new_string: '"s3rv1ceAcct99"',
        },
      });
      assert.equal(r.code, 2, r.stderr);
      assert.match(r.stderr, /hardcoded-password/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('ignores a tool it does not govern', () => {
    assert.equal(runHook({ tool_name: 'Bash', tool_input: { command: 'ls' } }).code, 0);
  });
});
