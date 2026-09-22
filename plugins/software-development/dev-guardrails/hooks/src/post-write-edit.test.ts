import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  extLanguage,
  checkPython,
  checkJavaScript,
  checkTerraform,
  checkShellScript,
} from './post-write-edit.ts';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'post-write-edit.ts');

describe('extLanguage', () => {
  // The list lives here rather than only in `case` labels, because a missing extension there is
  // invisible: the checks simply never run on those files and nothing says so.
  it('maps every TypeScript and JavaScript spelling, including mts and cts', () => {
    for (const e of ['ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs']) {
      assert.equal(extLanguage(e), 'js', e);
    }
  });

  it('maps python, terraform and shell', () => {
    assert.equal(extLanguage('py'), 'py');
    assert.equal(extLanguage('tf'), 'tf');
    assert.equal(extLanguage('tfvars'), 'tf');
    for (const e of ['sh', 'bash', 'zsh']) assert.equal(extLanguage(e), 'shell', e);
  });

  it('maps anything else to other', () => {
    for (const e of ['md', 'json', 'yml', 'rs', '']) assert.equal(extLanguage(e), 'other', e);
  });
});

describe('checkPython', () => {
  it('flags shell=True', () => {
    const w = checkPython('subprocess.run(cmd, shell=True)', '/r/src/a.py');
    assert.ok(w.some((x) => /shell=True/.test(x)));
  });

  it('flags SQL built with an f-string', () => {
    const w = checkPython('q = f"SELECT * FROM t WHERE id={uid}"', '/r/src/a.py');
    assert.ok(w.some((x) => /f-string/.test(x)));
  });

  it('flags mocks under a source tree', () => {
    const w = checkPython('from unittest.mock import patch', '/r/src/a.py');
    assert.ok(w.some((x) => /STRUCTURE/.test(x)));
  });

  // The same import in the test tree is exactly where it belongs.
  it('does not flag mocks outside a source tree', () => {
    const w = checkPython('from unittest.mock import patch', '/r/tests/test_a.py');
    assert.ok(!w.some((x) => /STRUCTURE/.test(x)));
  });

  it('says nothing about clean code', () => {
    assert.deepEqual(checkPython('def add(a, b):\n    return a + b\n', '/r/src/a.py'), []);
  });
});

describe('checkJavaScript', () => {
  it('flags the XSS shapes', () => {
    assert.ok(checkJavaScript('el.innerHTML = x', '/r/src/a.ts').length > 0);
    assert.ok(checkJavaScript('<div dangerouslySetInnerHTML={h} />', '/r/src/a.tsx').length > 0);
    assert.ok(checkJavaScript('<div v-html="x" />', '/r/src/a.js').length > 0);
  });

  it('flags dynamic code evaluation', () => {
    const w = checkJavaScript('const r = eval(src)', '/r/src/a.ts');
    assert.ok(w.some((x) => /injection/.test(x)));
  });

  it('exempts a test file from the console-statement count', () => {
    const noisy = 'console.a();console.b();console.c();console.d();console.e();';
    assert.ok(checkJavaScript(noisy, '/r/src/a.ts').some((x) => /console/.test(x)));
    assert.ok(!checkJavaScript(noisy, '/r/src/a.test.ts').some((x) => /console/.test(x)));
  });

  it('says nothing about clean code', () => {
    assert.deepEqual(checkJavaScript('export const add = (a: number) => a + 1;', '/r/src/a.ts'), []);
  });
});

describe('checkTerraform', () => {
  it('flags an internet-facing or unencrypted resource', () => {
    assert.ok(checkTerraform('publicly_accessible = true').length > 0);
    assert.ok(checkTerraform('cidr_blocks = ["0.0.0.0/0"]').length > 0);
    assert.ok(checkTerraform('storage_encrypted = false').length > 0);
    assert.ok(checkTerraform('block_public_acls = false').length > 0);
  });

  // Either wildcard alone is how most real policies are written; both together is the admin
  // grant. Reporting them separately would make the check noise and it would be turned off.
  it('flags wildcard Action and Resource only TOGETHER', () => {
    assert.deepEqual(checkTerraform('Action = "*"\nResource = aws_s3_bucket.b.arn'), []);
    assert.deepEqual(checkTerraform('Action = "s3:GetObject"\nResource = "*"'), []);
    assert.ok(checkTerraform('Action = "*"\nResource = "*"').some((x) => /admin grant/.test(x)));
  });

  it('says nothing about an ordinary resource', () => {
    assert.deepEqual(checkTerraform('resource "aws_s3_bucket" "b" {\n  bucket = "x"\n}'), []);
  });
});

describe('checkShellScript', () => {
  it('flags a hardcoded interpreter path', () => {
    assert.ok(checkShellScript('#!/bin/bash\necho hi\n', '/r/s.sh').some((x) => /PORTABILITY/.test(x)));
    assert.deepEqual(checkShellScript('#!/usr/bin/env bash\necho hi\n', '/r/s.sh'), []);
  });

  // `set -e` in a hook exits mid-script with a non-zero status, which Claude Code reads as a deny
  // decision — from a script that was only tidying up.
  it('flags bare `set -e` in a hook script only', () => {
    const body = '#!/usr/bin/env bash\nset -e\necho hi\n';
    assert.ok(checkShellScript(body, '/r/hooks/x.sh').some((x) => /ERROR HANDLING/.test(x)));
    assert.ok(!checkShellScript(body, '/r/scripts/x.sh').some((x) => /ERROR HANDLING/.test(x)));
  });

  it('accepts set -uo pipefail in a hook', () => {
    const body = '#!/usr/bin/env bash\nset -uo pipefail\necho hi\n';
    assert.ok(!checkShellScript(body, '/r/hooks/x.sh').some((x) => /ERROR HANDLING/.test(x)));
  });

  it('flags terraform init with no backend config', () => {
    const body = '#!/usr/bin/env bash\nterraform init\n';
    assert.ok(checkShellScript(body, '/r/s.sh').some((x) => /TERRAFORM/.test(x)));
  });
});

describe('post-write-edit.ts as Claude Code runs it', () => {
  function run(payload: unknown) {
    return spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: JSON.stringify(payload), encoding: 'utf-8' },
    );
  }

  it('reports a finding without blocking', () => {
    // A real git repo, because the hook refuses to report on a file outside the project root it
    // resolves — without `git init` the temp file resolves outside and the hook correctly no-ops,
    // which would make this assertion pass for the wrong reason.
    const dir = mkdtempSync(join(tmpdir(), 'pwe-'));
    spawnSync('git', ['init', '-q'], { cwd: dir });
    const file = join(dir, 'main.tf');
    writeFileSync(file, 'resource "aws_db_instance" "d" {\n  publicly_accessible = true\n}\n');

    const r = run({ tool_name: 'Write', tool_input: { file_path: file, content: 'x' } });
    assert.equal(r.status, 0, 'a PostToolUse hook must never block');
    assert.match(r.stderr, /publicly_accessible/);
  });

  it('ignores a tool it does not govern', () => {
    const r = run({ tool_name: 'Bash', tool_input: { command: 'ls' } });
    assert.equal(r.status, 0);
    assert.equal(r.stderr.trim(), '');
  });

  it('exits clean when the file no longer exists', () => {
    const r = run({ tool_name: 'Write', tool_input: { file_path: '/nope/gone.ts', content: 'x' } });
    assert.equal(r.status, 0);
  });
});
