import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseCodeowners, checkCodeowners } from './codeowners-check.ts';

function repoWith(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), 'co-'));
  for (const [rel, body] of Object.entries(files)) {
    const full = join(root, rel);
    mkdirSync(join(full, '..'), { recursive: true });
    writeFileSync(full, body);
  }
  return root;
}

describe('parseCodeowners', () => {
  it('reads a pattern and its owners', () => {
    const { rules } = parseCodeowners('*.tf   @org/platform @alice\n');
    assert.equal(rules.length, 1);
    assert.equal(rules[0].pattern, '*.tf');
    assert.deepEqual(rules[0].owners, ['@org/platform', '@alice']);
  });

  it('ignores blank lines and comments, including trailing ones', () => {
    const { rules } = parseCodeowners('# header\n\nsrc/ @org/team  # owns the source\n');
    assert.equal(rules.length, 1);
    assert.deepEqual(rules[0].owners, ['@org/team']);
  });

  it('accepts an email address as an owner', () => {
    const { rules } = parseCodeowners('docs/ dev@example.com\n');
    assert.deepEqual(rules[0].owners, ['dev@example.com']);
  });

  // A section heading is not a rule, and mistaking it for one invents both a pattern and an owner.
  it('treats a section heading as a heading, not a rule', () => {
    const { rules, sectionHeadings } = parseCodeowners('[Backend]\nsrc/ @org/backend\n');
    assert.deepEqual(sectionHeadings, ['Backend']);
    assert.equal(rules.length, 1);
    assert.equal(rules[0].section, 'Backend');
  });

  it('applies a section heading\'s default owners to rules that name none', () => {
    const { rules } = parseCodeowners('[Backend] @org/backend\nsrc/\nlib/ @alice\n');
    assert.deepEqual(rules[0].owners, ['@org/backend']);
    assert.deepEqual(rules[1].owners, ['@alice']);
  });

  it('handles the optional and numbered section spellings', () => {
    const { sectionHeadings } = parseCodeowners('^[Optional]\n[Docs][2]\n');
    assert.deepEqual(sectionHeadings, ['Optional', 'Docs']);
  });
});

describe('checkCodeowners', () => {
  it('reports nothing for a repo with no CODEOWNERS', () => {
    const result = checkCodeowners(repoWith({ 'README.md': 'hi' }));
    assert.equal(result.present, false);
  });

  it('passes a file where every rule names a team', () => {
    const result = checkCodeowners(repoWith({ CODEOWNERS: '* @org/platform\nsrc/ @org/backend\n' }));
    assert.equal(result.present, true);
    assert.deepEqual(result.ownerless, []);
    assert.deepEqual(result.soleIndividualOwner, []);
    assert.deepEqual(result.malformedOwners, []);
    assert.deepEqual(result.shadowedByCatchAll, []);
  });

  // An owner-less rule does not fall back to a broader rule; it removes the path from coverage.
  it('flags a rule with no owners', () => {
    const result = checkCodeowners(repoWith({ CODEOWNERS: '* @org/platform\nvendor/\n' }));
    assert.equal(result.ownerless.length, 1);
    assert.equal(result.ownerless[0].pattern, 'vendor/');
  });

  // The quiet one: the author is removed from eligible approvers, so the rule requires zero
  // approvals on exactly the change it exists to gate.
  it('flags a rule whose only owner is an individual', () => {
    const result = checkCodeowners(repoWith({ CODEOWNERS: 'src/ @alice\n' }));
    assert.equal(result.soleIndividualOwner.length, 1);
  });

  it('does not flag a sole owner that is a team path', () => {
    const result = checkCodeowners(repoWith({ CODEOWNERS: 'src/ @org/backend\n' }));
    assert.deepEqual(result.soleIndividualOwner, []);
  });

  it('does not flag an individual who is listed alongside a team', () => {
    const result = checkCodeowners(repoWith({ CODEOWNERS: 'src/ @alice @org/backend\n' }));
    assert.deepEqual(result.soleIndividualOwner, []);
  });

  it('flags a malformed owner token', () => {
    const result = checkCodeowners(repoWith({ CODEOWNERS: 'src/ @@bogus\n' }));
    assert.equal(result.malformedOwners.length, 1);
    assert.equal(result.malformedOwners[0].owner, '@@bogus');
  });

  // Only the LAST matching pattern applies, so a trailing catch-all silently replaces everything
  // declared above it.
  it('flags rules shadowed by a later catch-all', () => {
    const result = checkCodeowners(
      repoWith({ CODEOWNERS: 'src/ @org/backend\ndocs/ @org/docs\n* @org/platform\n' }),
    );
    assert.deepEqual(
      result.shadowedByCatchAll.map((r) => r.pattern),
      ['src/', 'docs/'],
    );
  });

  it('does not flag a catch-all that comes first', () => {
    const result = checkCodeowners(
      repoWith({ CODEOWNERS: '* @org/platform\nsrc/ @org/backend\n' }),
    );
    assert.deepEqual(result.shadowedByCatchAll, []);
  });

  it('notices the same file in two locations', () => {
    const result = checkCodeowners(
      repoWith({ CODEOWNERS: '* @org/a\n', '.github/CODEOWNERS': '* @org/b\n' }),
    );
    assert.deepEqual(result.duplicateLocations, ['CODEOWNERS', '.github/CODEOWNERS']);
  });

  it('leaves the required-owner arm off unless it is configured', () => {
    const root = repoWith({ CODEOWNERS: 'src/ @org/backend\n' });
    assert.deepEqual(checkCodeowners(root, {} as NodeJS.ProcessEnv).missingRequiredOwner, []);

    const strict = checkCodeowners(root, {
      CLAUDE_CODEOWNERS_REQUIRED_OWNER: '@org/platform',
    } as NodeJS.ProcessEnv);
    assert.equal(strict.missingRequiredOwner.length, 1);
  });

  it('matches the required owner case-insensitively', () => {
    const root = repoWith({ CODEOWNERS: 'src/ @Org/Platform\n' });
    const result = checkCodeowners(root, {
      CLAUDE_CODEOWNERS_REQUIRED_OWNER: '@org/platform',
    } as NodeJS.ProcessEnv);
    assert.deepEqual(result.missingRequiredOwner, []);
  });
});
