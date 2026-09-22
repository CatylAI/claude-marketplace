import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SESSION_START = join(HERE, 'session-start.ts');
const POST_COMPACT = join(HERE, 'post-compact.ts');
const USER_PROMPT = join(HERE, 'user-prompt-submit.ts');

// These three hooks run their work at module scope and end in process.exit(0), so they cannot be
// imported — every assertion has to be made against a real spawn. What is worth pinning is the
// contract Claude Code depends on: context goes to STDOUT, the process exits 0, and no session
// hook is ever the reason a session fails to start.
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

describe('session-start.ts', () => {
  it('exits 0 and writes its context to stdout', () => {
    const r = spawnHook(SESSION_START, '{}');
    assert.equal(r.status, 0);
    assert.match(r.stdout, /=== Session Context ===/);
    assert.match(r.stdout, /=== Ready ===/);
    assert.match(r.stdout, /Working Directory:/);
  });

  // The default must stay tight: a slow, chatty session start is one people disable, and a
  // disabled hook reports nothing at all.
  it('keeps the default terse and points at the verbose switch', () => {
    const r = spawnHook(SESSION_START, '{}');
    assert.match(r.stdout, /CLAUDE_SESSION_VERBOSE=1/);
    assert.ok(!/Recent Commits:/.test(r.stdout), 'the commit log is verbose-only');
  });

  it('adds the commit log under CLAUDE_SESSION_VERBOSE', () => {
    const r = spawnHook(SESSION_START, '{}', { CLAUDE_SESSION_VERBOSE: '1' });
    assert.equal(r.status, 0);
    assert.match(r.stdout, /Recent Commits:/);
  });

  it('exits 0 outside a git repository', () => {
    const empty = mkdtempSync(join(tmpdir(), 'ss-'));
    const r = spawnHook(SESSION_START, '{}', {}, empty);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /=== Ready ===/);
  });

  // It reports; it never fixes. A session-start hook that installs or rewrites something
  // surprises the user at the moment they have the least context for it.
  it('leaves the directory it inspected untouched', () => {
    const empty = mkdtempSync(join(tmpdir(), 'ss-'));
    spawnHook(SESSION_START, '{}', { CLAUDE_SESSION_VERBOSE: '1' }, empty);
    const after = spawnSync('ls', ['-A', empty], { encoding: 'utf-8' }).stdout.trim();
    assert.equal(after, '', `session start created files: ${after}`);
  });
});

describe('post-compact.ts', () => {
  it('exits 0 and emits the carry-forward block on stdout', () => {
    const r = spawnHook(POST_COMPACT, '{}');
    assert.equal(r.status, 0);
    assert.match(r.stdout, /Carry Forward Through Compaction/);
    assert.match(r.stdout, /End Carry Forward/);
  });

  it('exits 0 outside a git repository', () => {
    const empty = mkdtempSync(join(tmpdir(), 'pc-'));
    const r = spawnHook(POST_COMPACT, '{}', {}, empty);
    assert.equal(r.status, 0);
  });
});

describe('user-prompt-submit.ts', () => {
  it('resolves a relative date to an ISO date', () => {
    const r = spawnHook(USER_PROMPT, JSON.stringify({ prompt: 'ship this by EOW please' }));
    assert.equal(r.status, 0);
    assert.match(r.stdout, /DATE RESOLUTION/);
    assert.match(r.stdout, /\d{4}-\d{2}-\d{2}/);
  });

  // `~` is expanded by the shell, so a tool call that passes it through verbatim opens a
  // directory literally named `~`.
  it('expands a tilde path to an absolute one', () => {
    const r = spawnHook(USER_PROMPT, JSON.stringify({ prompt: 'read ~/notes/todo.md' }));
    assert.equal(r.status, 0);
    assert.match(r.stdout, /PATH EXPANSION/);
    assert.match(r.stdout, /notes\/todo\.md/);
  });

  it('says nothing about a prompt with nothing to resolve', () => {
    const r = spawnHook(USER_PROMPT, JSON.stringify({ prompt: 'refactor the parser' }));
    assert.equal(r.status, 0);
    assert.ok(!/DATE RESOLUTION/.test(r.stdout));
    assert.ok(!/PATH EXPANSION/.test(r.stdout));
  });

  it('exits 0 on an empty prompt and on unparseable input', () => {
    assert.equal(spawnHook(USER_PROMPT, JSON.stringify({ prompt: '' })).status, 0);
    assert.equal(spawnHook(USER_PROMPT, 'not json at all').status, 0);
  });

  // It normalizes context; it does not persist anything. An earlier design cached ticket
  // summaries under the user's home directory on every prompt.
  it('writes nothing to disk', () => {
    const empty = mkdtempSync(join(tmpdir(), 'ups-'));
    spawnHook(USER_PROMPT, JSON.stringify({ prompt: 'due tomorrow' }), {}, empty);
    const after = spawnSync('ls', ['-A', empty], { encoding: 'utf-8' }).stdout.trim();
    assert.equal(after, '');
  });
});
