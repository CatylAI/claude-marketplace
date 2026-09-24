import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { formatSummaryLine, parseWorktreeList } from './session-start.ts';
import { formatCarryForward } from './post-compact.ts';
import { buildPromptContext } from './user-prompt-submit.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const SESSION_START = join(HERE, 'session-start.ts');
const POST_COMPACT = join(HERE, 'post-compact.ts');
const USER_PROMPT = join(HERE, 'user-prompt-submit.ts');

// What is pinned here is the contract Claude Code depends on: context goes to STDOUT, the process
// exits 0, and no session hook is ever the reason a session fails to start. Plain stdout on
// SessionStart and UserPromptSubmit is re-sent with every request, so silence when there is
// nothing to say is part of the contract too.
function spawnHook(
  file: string,
  input: string,
  env: Record<string, string> = {},
  cwd = process.cwd(),
) {
  return spawnSync(
    process.execPath,
    ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', file],
    { input, encoding: 'utf-8', cwd, env: { ...process.env, ...env } },
  );
}

// A throwaway git repo with one commit, so the summary/commit-log assertions do not depend on
// the suite's own working directory being inside a repository (it is not when the plugin tree
// is checked out on its own).
function tempRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ss-repo-'));
  const run = (...args: string[]): void => { spawnSync('git', args, { cwd: dir }); };
  run('init', '-q', '-b', 'feat/PROJ-1-thing');
  run('config', 'user.email', 'a@b.test');
  run('config', 'user.name', 'Tester');
  run('commit', '-q', '--allow-empty', '-m', 'feat: initial commit');
  return dir;
}

describe('session-start.ts', () => {
  it('exits 0 and writes a one-line summary to stdout', () => {
    const r = spawnHook(SESSION_START, '{}', {}, tempRepo());
    assert.equal(r.status, 0);
    assert.match(r.stdout, /^Branch: /);
  });

  // Claude Code already supplies the working directory, and banners and a hint aimed at the user
  // are tokens Claude pays for on every request.
  it('carries no banners, working directory or user-facing hint by default', () => {
    const r = spawnHook(SESSION_START, '{}');
    assert.ok(!/===/.test(r.stdout), 'no banner lines');
    assert.ok(!/Working Directory/.test(r.stdout));
    assert.ok(!/CLAUDE_SESSION_VERBOSE/.test(r.stdout));
    assert.ok(!/Recent commits:/.test(r.stdout), 'the commit log is verbose-only');
  });

  it('adds the commit log under CLAUDE_SESSION_VERBOSE', () => {
    const r = spawnHook(SESSION_START, '{}', { CLAUDE_SESSION_VERBOSE: '1' }, tempRepo());
    assert.equal(r.status, 0);
    assert.match(r.stdout, /Recent commits:/);
  });

  it('says nothing and exits 0 outside a git repository', () => {
    const empty = mkdtempSync(join(tmpdir(), 'ss-'));
    const r = spawnHook(SESSION_START, '{}', {}, empty);
    assert.equal(r.status, 0);
    assert.equal(r.stdout, '');
  });

  // It reports; it never fixes.
  it('leaves the directory it inspected untouched', () => {
    const empty = mkdtempSync(join(tmpdir(), 'ss-'));
    spawnHook(SESSION_START, '{}', { CLAUDE_SESSION_VERBOSE: '1' }, empty);
    const after = spawnSync('ls', ['-A', empty], { encoding: 'utf-8' }).stdout.trim();
    assert.equal(after, '', `session start created files: ${after}`);
  });
});

describe('formatSummaryLine', () => {
  it('names the ticket when the branch carries one', () => {
    assert.equal(formatSummaryLine('feat/PROJ-7-x', 'PROJ-7', 2), 'Branch: feat/PROJ-7-x · ticket PROJ-7 · 2 uncommitted file(s)');
  });

  it('says clean tree when nothing is uncommitted', () => {
    assert.equal(formatSummaryLine('main', null, 0), 'Branch: main · clean tree');
  });
});

describe('parseWorktreeList', () => {
  // Regression: the output reaches the parser trimmed, so the final record has no trailing blank
  // line. The old loop only closed a record on a blank line and silently dropped the last worktree.
  it('keeps the last record of trimmed porcelain output', () => {
    const raw = [
      'worktree /repo',
      'HEAD 111',
      'branch refs/heads/main',
      '',
      'worktree /repo-wt/feature',
      'HEAD 222',
      'branch refs/heads/feature/x',
    ].join('\n');
    const parsed = parseWorktreeList(raw, 'main');
    assert.equal(parsed.basePath, '/repo');
    assert.deepEqual(parsed.others, [{ path: '/repo-wt/feature', branch: 'feature/x' }]);
  });

  it('skips a detached worktree', () => {
    const raw = ['worktree /repo', 'HEAD 111', 'branch refs/heads/main', '', 'worktree /d', 'HEAD 333', 'detached'].join('\n');
    assert.deepEqual(parseWorktreeList(raw, 'main').others, []);
  });
});

describe('post-compact.ts (SessionStart, matcher compact)', () => {
  it('exits 0 and emits one carry-forward line on stdout', () => {
    const r = spawnHook(
      POST_COMPACT,
      JSON.stringify({ hook_event_name: 'SessionStart', source: 'compact' }),
      {},
      tempRepo(),
    );
    assert.equal(r.status, 0);
    assert.match(r.stdout, /^Carried forward after compaction: Branch: /);
    assert.equal(r.stdout.trim().split('\n').length, 1);
  });

  it('says nothing and exits 0 outside a git repository', () => {
    const empty = mkdtempSync(join(tmpdir(), 'pc-'));
    const r = spawnHook(POST_COMPACT, '{}', {}, empty);
    assert.equal(r.status, 0);
    assert.equal(r.stdout, '');
  });

  it('formats branch, ticket and uncommitted count', () => {
    assert.equal(
      formatCarryForward('fix/AB-1', 'AB-1', 3),
      'Carried forward after compaction: Branch: fix/AB-1 · ticket AB-1 · 3 uncommitted file(s)',
    );
    assert.equal(formatCarryForward('main', null, 0), 'Carried forward after compaction: Branch: main');
  });
});

describe('buildPromptContext', () => {
  // 2026-09-23 is a Wednesday.
  const today = new Date(2026, 8, 23, 12);
  const opts = { today, home: '/home/dev' };

  it('resolves a relative date to an ISO date', () => {
    const out = buildPromptContext('ship this by EOW please', opts);
    assert.match(out, /Date resolution \(today is 2026-09-23\)/);
    assert.match(out, /"EOW" -> 2026-09-25/);
  });

  // Claude Code already tells the model today's date; restating it on every prompt that says
  // "today" is a per-request cost for nothing.
  it('does not resolve "today" on its own', () => {
    assert.equal(buildPromptContext('what did we change today', opts), '');
  });

  it('resolves "next friday" once, not again as a bare "friday"', () => {
    const out = buildPromptContext('demo next friday', opts);
    assert.equal((out.match(/->/g) ?? []).length, 1);
    assert.match(out, /"next friday" -> 2026-09-25/);
  });

  it('expands a tilde path to an absolute one', () => {
    const out = buildPromptContext('read ~/notes/todo.md and ~/notes/todo.md', opts);
    assert.match(out, /Path expansion:\n {2}~\/notes\/todo\.md -> \/home\/dev\/notes\/todo\.md$/);
  });

  it('returns nothing for a prompt with nothing to resolve', () => {
    assert.equal(buildPromptContext('refactor the parser', opts), '');
  });
});

describe('user-prompt-submit.ts as Claude Code runs it', () => {
  it('writes the resolution to stdout and exits 0', () => {
    const r = spawnHook(USER_PROMPT, JSON.stringify({ prompt: 'ship this by EOW please' }));
    assert.equal(r.status, 0);
    assert.match(r.stdout, /Date resolution/);
  });

  // Regression: the branch's ticket key used to be injected on every prompt.
  it('does not inject the branch ticket', () => {
    const repo = mkdtempSync(join(tmpdir(), 'ups-git-'));
    spawnSync('git', ['init', '-q', '-b', 'feat/PROJ-42-thing', repo]);
    const r = spawnHook(USER_PROMPT, JSON.stringify({ prompt: 'refactor the parser' }), {}, repo);
    assert.equal(r.status, 0);
    assert.equal(r.stdout, '');
  });

  it('exits 0 on an empty prompt and on unparseable input', () => {
    assert.equal(spawnHook(USER_PROMPT, JSON.stringify({ prompt: '' })).status, 0);
    assert.equal(spawnHook(USER_PROMPT, 'not json at all').status, 0);
  });

  it('writes nothing to disk', () => {
    const empty = mkdtempSync(join(tmpdir(), 'ups-'));
    spawnHook(USER_PROMPT, JSON.stringify({ prompt: 'due tomorrow' }), {}, empty);
    const after = spawnSync('ls', ['-A', empty], { encoding: 'utf-8' }).stdout.trim();
    assert.equal(after, '');
  });
});
