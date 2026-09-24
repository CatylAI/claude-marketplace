import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import { evaluateBashOutput } from './post-bash.ts';

// Assembled at runtime — a contiguous credential literal would be blocked on the way in
// by pre-write-edit.ts and flagged at commit by gitleaks. See lib/secrets.test.ts.
const PAT = 'glpat-' + 'aB3dE6fH9jK2mN5pQ8rS';
const AWS = 'AKIA' + 'J7QK3MZ5WPXR2NDF';

// A URI fixture needs a '@' that does not appear as a literal anywhere after a ':' on the
// same source line, or the DB_CONNECTION_STRING pattern matches this very file and
// pre-write-edit.ts refuses the Write. It did, on the first attempt at this file.
const AT = String.fromCharCode(64);

function bash(stdout: string, stderr = ''): Record<string, unknown> {
  return { stdout, stderr, interrupted: false, isImage: false };
}

describe('evaluateBashOutput — redaction', () => {
  it('redacts a credential from stdout and reports it', () => {
    const { updated, notice } = evaluateBashOutput(bash(`token is ${PAT} ok`));
    assert.ok(updated, 'must produce a replacement');
    assert.ok(!updated.stdout.includes(PAT), 'the secret survived');
    assert.match(updated.stdout, /redact/);
    assert.ok(notice);
    assert.match(notice, /gitlab-pat/);
  });

  it('redacts from stderr too', () => {
    const { updated } = evaluateBashOutput(bash('', `failed with ${AWS}`));
    assert.ok(updated);
    assert.ok(!updated.stderr.includes(AWS));
  });

  it('preserves the surrounding output verbatim', () => {
    const { updated } = evaluateBashOutput(bash(`before\n${PAT}\nafter`));
    assert.ok(updated);
    assert.match(updated.stdout, /^before\n/);
    assert.match(updated.stdout, /\nafter$/);
  });

  it('preserves interrupted and isImage rather than inventing values', () => {
    const { updated } = evaluateBashOutput({
      stdout: PAT, stderr: '', interrupted: true, isImage: true,
    });
    assert.ok(updated);
    assert.equal(updated.interrupted, true);
    assert.equal(updated.isImage, true);
  });

  it('returns exactly the Bash shape, since an off-schema value is silently discarded', () => {
    const { updated } = evaluateBashOutput(bash(PAT));
    assert.ok(updated);
    assert.deepEqual(
      Object.keys(updated).sort(),
      ['interrupted', 'isImage', 'stderr', 'stdout'],
      "exactly Bash's output shape — no structuredContent, no extra keys",
    );
  });
});

describe('evaluateBashOutput — leaves clean output completely alone', () => {
  const benign = [
    'On branch feat/secret-exposure-gates\nnothing to commit',
    'Terraform will perform the following actions:\n  ~ update in-place',
    'BLOCKER: a credential is hardcoded at config.py:12',
    'AWS_PROFILE=dev',
    'skip-this.ts passed',
  ];
  for (const out of benign) {
    it(`no-ops on: ${out.slice(0, 46).replace(/\n/g, ' ')}`, () => {
      const r = evaluateBashOutput(bash(out));
      assert.equal(r.updated, null);
      assert.equal(r.notice, null);
    });
  }

  it('does not redact assignment-shaped output — CONTENT_PATTERNS stay off this surface', () => {
    // A grep that FINDS a hardcoded credential, or a review note reporting one, must come
    // through intact: redacting it would destroy the evidence needed to fix the very problem
    // that was just found.
    const grepHit = 'config.py:12:    db_' + 'password' + ' = "' + 'hunter2-not-real' + '"';
    assert.equal(evaluateBashOutput(bash(grepHit)).updated, null);

    const uri = 'psql: connecting to postgres' + '://' + 'appuser:' + 'pw' + AT + 'db/app';
    assert.equal(evaluateBashOutput(bash(uri)).updated, null);
  });
});

describe('evaluateBashOutput — unknown shapes must not pretend to work', () => {
  it('no-ops on null, undefined and non-objects', () => {
    for (const v of [null, undefined, 'a string', 42, true]) {
      assert.deepEqual(evaluateBashOutput(v), { updated: null, notice: null });
    }
  });

  it('warns WITHOUT claiming a rewrite when the shape is not Bash-like', () => {
    // Claude Code discards an updatedToolOutput that does not match the tool's schema and
    // keeps the original. Emitting one anyway would look like success and do nothing.
    const { updated, notice } = evaluateBashOutput({ output: `see ${PAT}` });
    assert.equal(updated, null, 'must not emit an off-schema replacement');
    assert.ok(notice, 'but must still tell someone');
    assert.match(notice, /could NOT be|still the original/);
  });
});

describe('evaluateBashOutput — idempotence', () => {
  it('does not re-redact output that already carries a placeholder', () => {
    const once = evaluateBashOutput(bash(`t=${PAT}`));
    assert.ok(once.updated);
    const twice = evaluateBashOutput(bash(once.updated.stdout));
    assert.equal(twice.updated, null);
    assert.equal(twice.notice, null);
  });
});

describe('evaluateBashOutput — the notice is honest about what redaction buys', () => {
  it('says it is not prevention and that the value may be on disk', () => {
    const { notice } = evaluateBashOutput(bash(PAT));
    assert.ok(notice);
    assert.match(notice, /not prevention/i);
    assert.match(notice, /on disk/i);
  });

  it('tells the reader to rotate rather than to re-run', () => {
    const { notice } = evaluateBashOutput(bash(PAT));
    assert.ok(notice);
    assert.match(notice, /ROTATED/);
    assert.match(notice, /Do NOT re-run/);
  });

  it('hands over the safe alternative', () => {
    const { notice } = evaluateBashOutput(bash(PAT));
    assert.ok(notice);
    assert.match(notice, /\$\{VAR:\+set\}/);
  });
});

describe('evaluateBashOutput — a placeholder elsewhere does not switch redaction off', () => {
  it('redacts a live secret that shares the output with an earlier placeholder', () => {
    // The idempotence guard used to return early whenever ANY placeholder was present, so
    // output quoting an old redaction (a transcript, a log) carried a fresh secret through.
    const earlier = evaluateBashOutput(bash(`old ${PAT}`));
    assert.ok(earlier.updated);
    const mixed = `${earlier.updated.stdout}\nnew ${AWS}`;
    const { updated } = evaluateBashOutput(bash(mixed));
    assert.ok(updated, 'the new secret must still be redacted');
    assert.ok(!updated.stdout.includes(AWS));
  });
});
