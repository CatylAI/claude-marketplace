// Ordering invariant: an advisory style check must never suppress a credential gate.
//
// `warn()` is `never`-typed and calls process.exit(1). Any advisory emitted ABOVE the
// credential checks therefore returns from the hook in front of every security gate: a
// `.sh` file carrying BOTH a hardcoded shebang AND a live key would exit 1 with a style
// nit and the key would be written to disk, to git history, and to every clone. A style
// nit outranking a security gate purely by source ordering is the failure this pins.
//
// It has to be end to end. The ordering lives in main()'s control flow, not in any pure
// function, so importing a helper cannot see it. These tests spawn the real hook with a
// real stdin payload and assert on the real exit code.
//
// Every fake credential below is BUILT AT RUNTIME by concatenation. A contiguous literal
// would be matched by the very gate under test when this file is written, and by the
// secret scanners in CI. Concatenation keeps the shape out of the bytes on disk.
//
// This file is deliberately separate from pre-write-edit.test.ts. That suite tests the
// two decision functions; this one tests only the order in which main() calls them, and
// keeping the invariant in a file named after it means a future reorder has to delete a
// file whose name says what it protects.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { EXIT_ALLOW, EXIT_BLOCK, EXIT_WARN } from './lib/types.ts';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'pre-write-edit.ts');

/** Run the hook exactly as Claude Code does, and return its exit code + stderr. */
function runHook(filePath: string, content: string): { code: number; stderr: string } {
  // The global off-switch would make every assertion below vacuously pass.
  const env = { ...process.env };
  delete env.CLAUDE_GUARDRAILS_OFF;
  const r = spawnSync(
    process.execPath,
    ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
    {
      input: JSON.stringify({ tool_name: 'Write', tool_input: { file_path: filePath, content } }),
      encoding: 'utf-8',
      env,
    },
  );
  return { code: r.status ?? -1, stderr: r.stderr ?? '' };
}

// Assembled at runtime so no literal credential shape exists in this file. None of these
// values contains a placeholder word, because a value that reads as documentation is
// suppressed by design and would make every BLOCK assertion below vacuous.
const FAKE_FORGE_PAT = 'ghp_' + 'B4nR6tY8wZa2xK7dQ9mV3cJ5hL1gF0sP2uXe';
const FAKE_AWS_KEY = 'AKIA' + 'WZ7QK3MR5PXT2NDF';
const FAKE_PRIVATE_KEY = '-----BEGIN' + ' RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxQ==\n';

const PORTABLE = '#!/usr/bin/env bash\n';
const HARDCODED = '#!/bin/bash\n';

describe('pre-write-edit ordering: a style warning cannot suppress a credential gate', () => {
  it('BLOCKS a forge personal access token in a script that also has a hardcoded shebang', () => {
    const r = runHook('deploy.sh', HARDCODED + `TOKEN="${FAKE_FORGE_PAT}"\n`);
    assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /github-token/);
  });

  it('BLOCKS an AWS access key in a script that also has a hardcoded shebang', () => {
    const r = runHook('setup.sh', HARDCODED + `AWS_ACCESS_KEY_ID=${FAKE_AWS_KEY}\n`);
    assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /aws-access-key-id/);
  });

  it('BLOCKS private key material in a script that also has a hardcoded shebang', () => {
    const r = runHook('rotate-key.sh', HARDCODED + FAKE_PRIVATE_KEY);
    assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /private-key-block/);
  });

  it('BLOCKS the same credential when the shebang is already portable', () => {
    // Control. Proves the block is a property of the credential, not an artefact of a
    // shebang being present at all — without this, a gate that fired only on `#!/bin/bash`
    // would pass every test above.
    const r = runHook('deploy.sh', PORTABLE + `TOKEN="${FAKE_FORGE_PAT}"\n`);
    assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /github-token/);
  });

  it('still WARNS on a hardcoded shebang when there is no credential', () => {
    // The advisory must survive being moved below the blocks, not be quietly dropped.
    // Deleting the warning would also make every "BLOCK not WARN" assertion above pass.
    const r = runHook('clean.sh', HARDCODED + 'set -euo pipefail\necho hello\n');
    assert.equal(r.code, EXIT_WARN, `expected a WARN, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /SHEBANG/);
  });

  it('ALLOWS a clean script with a portable shebang', () => {
    const r = runHook('clean.sh', PORTABLE + 'set -euo pipefail\necho hello\n');
    assert.equal(r.code, EXIT_ALLOW, `expected ALLOW, got ${r.code}: ${r.stderr}`);
    assert.equal(r.stderr, '');
  });

  it('reports the CREDENTIAL, not the shebang, when both are present', () => {
    // The decision alone is not enough. A future edit could emit both messages and still
    // exit 2, which is acceptable; what is not acceptable is the operator reading a style
    // nit and never learning a key was in the file. Assert on the message, not the code.
    const r = runHook('deploy.sh', HARDCODED + `TOKEN="${FAKE_FORGE_PAT}"\n`);
    assert.match(r.stderr, /BLOCKED: credential-shaped content/);
    assert.doesNotMatch(r.stderr, /SHEBANG/, 'the style nit must not be what gets reported');
    assert.notEqual(r.code, EXIT_WARN, 'a credential must never downgrade to a warning');
  });

  it('suppresses an obvious placeholder even inside a script with a hardcoded shebang', () => {
    // The other half of the invariant, and the reason the canonical published AWS example
    // key id cannot be used as a BLOCK fixture anywhere in this suite: findSecrets() treats
    // any value containing a placeholder word as documentation. A script that documents the
    // shape of a key is a style warning and nothing more.
    const placeholder = 'AKIA' + 'IOSFODNN7EXAMPLE';
    const r = runHook('docs-snippet.sh', HARDCODED + `AWS_ACCESS_KEY_ID=${placeholder}\n`);
    assert.equal(r.code, EXIT_WARN, `expected a WARN, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /SHEBANG/);
  });
});
