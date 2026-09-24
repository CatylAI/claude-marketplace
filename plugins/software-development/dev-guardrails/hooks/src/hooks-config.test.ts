import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// hooks.json is the one file that decides whether any of these hooks run at all, and a mistake
// in it fails open without an error: a matcher that matches nothing, a script path that breaks on
// a space, or a registration on an event whose output is discarded. These tests pin it.

const HOOKS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');
const config = JSON.parse(readFileSync(join(HOOKS_DIR, 'hooks.json'), 'utf-8')) as {
  hooks: Record<string, Array<{ matcher?: string; hooks: Array<{ type: string; command: string; timeout?: number }> }>>;
};

type Registration = { event: string; matcher: string | undefined; command: string; timeout?: number };
const registrations: Registration[] = Object.entries(config.hooks).flatMap(([event, groups]) =>
  groups.flatMap((g) => g.hooks.map((h) => ({ event, matcher: g.matcher, command: h.command, timeout: h.timeout }))),
);

function scriptOf(command: string): string {
  const m = command.match(/hooks\/src\/([a-z-]+\.ts)$/);
  assert.ok(m, `command does not end in a hooks/src script: ${command}`);
  return m[1];
}

function registeredOn(script: string): string[] {
  return registrations
    .filter((r) => scriptOf(r.command) === script)
    .map((r) => (r.matcher ? `${r.event}:${r.matcher}` : r.event));
}

describe('hooks.json', () => {
  it('quotes ${CLAUDE_PLUGIN_ROOT} in every command, so an install path with a space works', () => {
    for (const r of registrations) {
      assert.ok(r.command.includes('"${CLAUDE_PLUGIN_ROOT}"'), r.command);
    }
  });

  it('sets an explicit timeout on every hook', () => {
    for (const r of registrations) {
      assert.equal(typeof r.timeout, 'number', r.command);
      assert.ok(r.timeout! > 0 && r.timeout! <= 60, `${r.command}: ${r.timeout}`);
    }
  });

  it('points every command at a script that exists', () => {
    for (const r of registrations) {
      assert.ok(existsSync(join(HOOKS_DIR, 'src', scriptOf(r.command))), r.command);
    }
  });

  // Exact-match matchers (letters, digits, _ and |) are compared as whole names. A regex matcher
  // is unanchored, so `Edit` as a regex would also match NotebookEdit.
  it('uses exact-name matchers for built-in tools and a prefix regex only for MCP', () => {
    for (const r of registrations) {
      if (r.matcher === undefined || r.matcher === 'mcp__.*') continue;
      assert.match(r.matcher, /^[A-Za-z0-9_|]+$/, `${r.event} matcher ${r.matcher}`);
    }
  });

  // Regression: post-compact.ts was registered on PreCompact, whose stdout goes to the debug log
  // only. SessionStart with matcher `compact` is where post-compaction context reaches Claude.
  it('registers post-compact on SessionStart:compact and nothing on PreCompact', () => {
    assert.deepEqual(registeredOn('post-compact.ts'), ['SessionStart:compact']);
    assert.equal(config.hooks.PreCompact, undefined);
  });

  it('keeps session-start off the compact source, so compaction does not re-run the full report', () => {
    assert.deepEqual(registeredOn('session-start.ts'), ['SessionStart:startup|resume|clear|fork']);
  });

  // post-type-check and post-test are modules post-write-edit dispatches, so a Write or Edit
  // costs one node process after the tool runs, not three.
  it('runs a single post-edit process that dispatches the type check and tests', () => {
    assert.deepEqual(registeredOn('post-write-edit.ts'), ['PostToolUse:Write|Edit']);
    assert.deepEqual(registeredOn('post-type-check.ts'), []);
    assert.deepEqual(registeredOn('post-test.ts'), []);
    const group = config.hooks.PostToolUse.find((g) => g.matcher === 'Write|Edit');
    assert.equal(group?.hooks.length, 1);
  });

  // An MCP tool that returns an error result fires PostToolUseFailure, not PostToolUse, so the
  // re-auth hint only ever fires there.
  it('registers post-mcp-tool on PostToolUseFailure only', () => {
    assert.deepEqual(registeredOn('post-mcp-tool.ts'), ['PostToolUseFailure:mcp__.*']);
  });

  it('has no Agent or TodoWrite registrations (both hooks were cut)', () => {
    for (const r of registrations) {
      assert.ok(r.matcher !== 'Agent' && r.matcher !== 'TodoWrite', `${r.event}:${r.matcher}`);
    }
  });

  it('registers every blocking gate on PreToolUse', () => {
    assert.deepEqual(registeredOn('pre-bash.ts'), ['PreToolUse:Bash']);
    assert.deepEqual(registeredOn('pre-write-edit.ts'), ['PreToolUse:Write|Edit|NotebookEdit']);
    assert.deepEqual(registeredOn('pre-mcp-tool.ts'), ['PreToolUse:mcp__.*']);
  });
});
