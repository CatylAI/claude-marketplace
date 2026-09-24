import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { shouldNudgeAdr, shouldNudgeCi, shouldNudgeDependencies, shouldShowOnce } from './stop.ts';

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

describe('shouldShowOnce', () => {
  it('shows a message once per session, and again when it changes', () => {
    const path = join(mkdtempSync(join(tmpdir(), 'stop-once-')), 'seen.json');
    assert.equal(shouldShowOnce('s1', 'msg A', path), true);
    assert.equal(shouldShowOnce('s1', 'msg A', path), false);
    assert.equal(shouldShowOnce('s2', 'msg A', path), true, 'another session sees it');
    assert.equal(shouldShowOnce('s1', 'msg B', path), true, 'a changed message is shown');
  });

  it('always shows when there is no state file or session id', () => {
    assert.equal(shouldShowOnce('s1', 'm', null), true);
    assert.equal(shouldShowOnce('', 'm', join(tmpdir(), 'unused.json')), true);
  });
});

function git(cwd: string, ...args: string[]) {
  return spawnSync('git', ['-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args], {
    cwd,
    encoding: 'utf-8',
  });
}

/** A repo on branch feat/x with an uncommitted edit to a code path (fires the ADR nudge). */
function repoWithCodeChange(): string {
  const repo = mkdtempSync(join(tmpdir(), 'stop-repo-'));
  git(repo, 'init', '-q', '-b', 'main');
  mkdirSync(join(repo, 'src'));
  writeFileSync(join(repo, 'src', 'a.ts'), 'export const a = 1;\n');
  git(repo, 'add', '.');
  git(repo, 'commit', '-q', '-m', 'init');
  git(repo, 'checkout', '-q', '-b', 'feat/x');
  writeFileSync(join(repo, 'src', 'a.ts'), 'export const a = 2;\n');
  return repo;
}

function runStop(cwd: string, stateDir: string, sessionId = 'sess-1') {
  return spawnSync(
    process.execPath,
    ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
    {
      input: JSON.stringify({ hook_event_name: 'Stop', session_id: sessionId, stop_hook_active: false }),
      encoding: 'utf-8',
      cwd,
      env: { ...process.env, CLAUDE_GUARDRAILS_STATE_DIR: stateDir },
    },
  );
}

describe('stop.ts output channel', () => {
  // Regression: nudges were printed as plain stdout, which Claude Code sends only to the debug
  // log on a Stop hook. They now arrive as one JSON object with a systemMessage for the user.
  it('emits the nudge as a single systemMessage JSON object', () => {
    const r = runStop(repoWithCodeChange(), mkdtempSync(join(tmpdir(), 'stop-state-')));
    assert.equal(r.status, 0);
    const parsed = JSON.parse(r.stdout) as { systemMessage?: string };
    assert.match(parsed.systemMessage ?? '', /ADR currency/);
    assert.deepEqual(Object.keys(parsed), ['systemMessage'], 'no decision field: it never blocks');
  });

  it('does not repeat an identical nudge on the next turn of the same session', () => {
    const repo = repoWithCodeChange();
    const state = mkdtempSync(join(tmpdir(), 'stop-state-'));
    assert.notEqual(runStop(repo, state).stdout, '');
    assert.equal(runStop(repo, state).stdout, '');
    assert.notEqual(runStop(repo, state, 'sess-2').stdout, '', 'a new session is told again');
  });

  it('says nothing on a clean tree', () => {
    const repo = repoWithCodeChange();
    git(repo, 'checkout', '-q', '--', '.');
    assert.equal(runStop(repo, mkdtempSync(join(tmpdir(), 'stop-state-'))).stdout, '');
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
