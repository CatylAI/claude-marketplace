// Unit tests for the secret patterns and the placeholder filter.
//
// Every token fixture is assembled at runtime: a contiguous credential literal in this file
// would be blocked on the way in by pre-write-edit.ts and flagged at commit by gitleaks.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { findSecrets, isObviousPlaceholder, redactSecrets, containsPlaceholder } from './secrets.ts';

const R36 = 'Q7r8A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6';

describe('TOKEN_PATTERNS cover the common high-confidence vendor formats', () => {
  const cases: Array<[string, string]> = [
    ['stripe-secret-key', 'sk_' + 'live_' + R36.slice(0, 24)],
    ['stripe-secret-key', 'rk_' + 'live_' + R36.slice(0, 24)],
    ['npm-token', 'npm_' + R36],
    ['pypi-token', 'pypi-' + 'AgEIcHlwaS5vcmc' + R36 + R36],
    ['huggingface-token', 'hf_' + R36.slice(0, 34)],
    ['gitlab-token', 'glcbt-' + R36.slice(0, 20)],
    ['gitlab-token', 'glptt-' + R36.slice(0, 20)],
    ['gitlab-token', 'glsoat-' + R36.slice(0, 20)],
    ['google-oauth-access-token', 'ya29' + '.' + R36 + R36],
    ['sendgrid-api-key', 'SG' + '.' + R36.slice(0, 22) + '.' + R36 + R36.slice(0, 7)],
    ['slack-webhook-url', 'https://hooks.slack.com/services/' + 'T0123ABCD/B0123ABCD/' + R36.slice(0, 24)],
  ];
  for (const [name, value] of cases) {
    it(name, () => {
      const hits = findSecrets(`x ${value} y`);
      assert.equal(hits.length, 1, `expected exactly one hit for ${name}`);
      assert.equal(hits[0]!.patternName, name);
    });
  }
});

describe('the placeholder filter', () => {
  it('still treats documented placeholders as placeholders', () => {
    assert.equal(isObviousPlaceholder('glpat-' + 'your-token-goes-here-xx'), true);
    assert.equal(isObviousPlaceholder('AKIA' + 'IOSFODNN7EXAMPLE'), true);
    assert.equal(isObviousPlaceholder('glpat-' + 'xxxxxxxxxxxxxxxxxxxx'), true);
    assert.equal(isObviousPlaceholder('ghp_' + 'EXAMPLE' + R36.slice(0, 29)), true);
  });

  it('does not let a random mixed-case run that spells a placeholder word hide a real token', () => {
    // A random base62 body contains "TeSt", "tOdO", "XxX" and friends often enough that a
    // case-insensitive substring check silently exempted a real token now and then.
    const real = 'ghp_' + 'Q7r8TeSt3d4E5f6G7h8I9j0K1l2M3n4O5p6Z';
    assert.equal(isObviousPlaceholder(real), false);
    assert.equal(findSecrets(real).length, 1);
  });
});

describe('redaction', () => {
  it('replaces every hit and leaves a placeholder the patterns cannot re-match', () => {
    const t = 'ghp_' + R36;
    const { text, matches } = redactSecrets(`a ${t} b`);
    assert.equal(matches.length, 1);
    assert.ok(!text.includes(t));
    assert.ok(containsPlaceholder(text));
    assert.equal(findSecrets(text).length, 0);
  });
});
