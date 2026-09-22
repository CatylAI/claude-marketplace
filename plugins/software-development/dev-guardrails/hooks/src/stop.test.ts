import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { shouldNudgeAdr, shouldNudgeCi, shouldNudgeDependencies } from './stop.ts';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'stop.ts');

describe('shouldNudgeAdr', () => {
  it('fires when a code path changed and no decision record did', () => {
    assert.equal(shouldNudgeAdr(['src/auth/session.ts']), true);
    assert.equal(shouldNudgeAdr(['infrastructure/network.tf']), true);
    assert.equal(shouldNudgeAdr(['modules/vpc/main.tf']), true, '.tf anywhere counts');
  });

  // Suppression must read BOTH lists. A brand-new decision record is UNTRACKED, so the changed
  // list cannot see it — and the nudge would fire at the exact moment the author complied.
  it('is suppressed by a decision record in either list', () => {
    assert.equal(shouldNudgeAdr(['src/a.ts', 'docs/adr/004-thing.md']), false);
    assert.equal(shouldNudgeAdr(['src/a.ts'], ['docs/adr/004-thing.md']), false);
    assert.equal(shouldNudgeAdr(['src/a.ts'], ['docs/decisions/004-thing.md']), false);
  });

  // Adding or changing a test is not an architectural decision, whatever tree it lives in.
  it('ignores test files on both arms', () => {
    assert.equal(shouldNudgeAdr(['src/foo.test.ts']), false);
    assert.equal(shouldNudgeAdr(['src/foo.spec.ts']), false);
    assert.equal(shouldNudgeAdr(['tests/test_thing.py']), false);
    assert.equal(shouldNudgeAdr([], ['hooks/src/a.test.ts']), false);
  });

  it('ignores ordinary non-code changes', () => {
    assert.equal(shouldNudgeAdr(['README.md', 'package.json', '.gitignore']), false);
  });

  // ADDING a gate/hook/pipeline/plugin is a decision; editing one usually is not. Reading the
  // added list for that arm is what keeps the firing rate down.
  it('fires on a NEWLY ADDED decision artifact', () => {
    assert.equal(shouldNudgeAdr([], ['hooks/src/pre-push.ts']), true);
    assert.equal(shouldNudgeAdr([], ['.github/workflows/release.yml']), true);
    assert.equal(shouldNudgeAdr([], ['scripts/check-thing.sh']), true);
    assert.equal(shouldNudgeAdr([], ['plugins/x/.claude-plugin/plugin.json']), true);
  });

  it('does not fire when those same paths were merely EDITED', () => {
    assert.equal(shouldNudgeAdr(['hooks/src/pre-push.ts']), false);
    assert.equal(shouldNudgeAdr(['.github/workflows/release.yml']), false);
    assert.equal(shouldNudgeAdr(['scripts/check-thing.sh']), false);
  });

  it('says nothing about an empty change', () => {
    assert.equal(shouldNudgeAdr([], []), false);
  });
});

describe('shouldNudgeCi', () => {
  it('fires on either forge\'s configuration', () => {
    assert.equal(shouldNudgeCi(['.github/workflows/ci.yml']), true);
    assert.equal(shouldNudgeCi(['.github/workflows/ci.yaml']), true);
    assert.equal(shouldNudgeCi(['.gitlab-ci.yml']), true);
    assert.equal(shouldNudgeCi(['.gitlab/ci/build.yml']), true);
  });

  it('does not fire on unrelated YAML', () => {
    assert.equal(shouldNudgeCi(['docker-compose.yml', 'config/app.yaml']), false);
  });
});

describe('shouldNudgeDependencies', () => {
  it('fires on a manifest', () => {
    for (const f of [
      'package.json',
      'pyproject.toml',
      'requirements.txt',
      'Cargo.toml',
      'go.mod',
      'Gemfile',
      'services/api/package.json',
    ]) {
      assert.equal(shouldNudgeDependencies([f]), true, f);
    }
  });

  // A lockfile moving on its own is a routine refresh, not a dependency decision.
  it('does not fire on a lockfile alone', () => {
    assert.equal(shouldNudgeDependencies(['package-lock.json', 'Cargo.lock', 'go.sum']), false);
  });
});

describe('stop.ts as Claude Code runs it', () => {
  // WITHOUT THE ENTRYPOINT GUARD THIS SUITE WOULD BE VACUOUS: importing a module that ends in
  // process.exit(0) at top level exits the runner during evaluation, reporting green with zero
  // assertions run. This test proves the guard both ways — the import above worked, and the file
  // still runs when invoked directly.
  it('runs standalone and exits 0', () => {
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: '{}', encoding: 'utf-8' },
    );
    assert.equal(r.status, 0);
  });
});
