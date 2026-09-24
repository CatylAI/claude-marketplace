// lib/git.ts against a real throwaway repository: the helpers spawn git with argv arrays
// and must degrade, never throw, outside a repo.

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { getBranch, isGitRepo, isWorkingTreeClean, resolveGitAlias } from './git.ts';

describe('lib/git.ts', () => {
  let repo = '';
  let outside = '';
  before(() => {
    repo = mkdtempSync(join(tmpdir(), 'guardrails-git-'));
    outside = mkdtempSync(join(tmpdir(), 'guardrails-nogit-'));
    const g = (...args: string[]) => execFileSync('git', args, { cwd: repo, stdio: 'ignore' });
    g('init', '-q', '-b', 'trunk');
    g('config', 'user.email', 't@example.invalid');
    g('config', 'user.name', 't');
    g('config', 'alias.pf', 'push --force');
    writeFileSync(join(repo, 'a.txt'), 'a');
    g('add', 'a.txt');
    g('commit', '-q', '-m', 'chore: init');
  });
  after(() => {
    rmSync(repo, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  });

  it('reads the branch and cleanliness of the given directory', () => {
    assert.equal(isGitRepo(repo), true);
    assert.equal(getBranch(repo), 'trunk');
    assert.equal(isWorkingTreeClean(repo), true);
    writeFileSync(join(repo, 'a.txt'), 'changed');
    assert.equal(isWorkingTreeClean(repo), false);
    execFileSync('git', ['checkout', '-q', '--', 'a.txt'], { cwd: repo });
  });

  it('degrades outside a repository instead of throwing', () => {
    assert.equal(isGitRepo(outside), false);
    assert.equal(getBranch(outside), 'detached');
    assert.equal(isWorkingTreeClean(outside), false, 'unknown must read as dirty');
  });

  it('resolves an alias, and refuses a name that is not an alias name', () => {
    assert.equal(resolveGitAlias('pf', repo), 'push --force');
    assert.equal(resolveGitAlias('nope', repo), null);
    assert.equal(resolveGitAlias('--upload-pack=x', repo), null);
  });
});
