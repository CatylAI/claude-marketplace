import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { evaluateTodos } from './post-todo.ts';
import type { TodoItem } from './lib/types.ts';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'post-todo.ts');

const todo = (content: string, status: TodoItem['status']): TodoItem => ({ content, status });

describe('evaluateTodos', () => {
  it('says nothing about an empty list', () => {
    assert.deepEqual(evaluateTodos([]), []);
  });

  it('says nothing about a healthy list', () => {
    const lines = evaluateTodos([
      todo('ABC-1 write the parser', 'in_progress'),
      todo('wire it up', 'pending'),
    ]);
    assert.deepEqual(lines, []);
  });

  it('reminds to close completed items upstream', () => {
    const lines = evaluateTodos([todo('ABC-1 ship it', 'completed')]);
    assert.equal(lines.length, 1);
    assert.match(lines[0], /TODO SYNC: 1 item/);
  });

  // Exactly one item in flight is the contract. More than one is the shape of a list that stopped
  // being maintained, and a later reader treats each as "someone is on this".
  it('flags more than one in-progress item', () => {
    const lines = evaluateTodos([
      todo('ABC-1 a', 'in_progress'),
      todo('ABC-2 b', 'in_progress'),
    ]);
    assert.ok(lines.some((l) => /TODO HYGIENE: 2 items/.test(l)));
  });

  it('does not flag a single in-progress item', () => {
    const lines = evaluateTodos([todo('ABC-1 a', 'in_progress')]);
    assert.ok(!lines.some((l) => /TODO HYGIENE/.test(l)));
  });

  it('flags in-progress work that carries no ticket key', () => {
    const lines = evaluateTodos([todo('tidy the imports', 'in_progress')]);
    assert.ok(lines.some((l) => /TODO TRACKING: 1 in-progress/.test(l)));
  });

  // The key shape is the same one pre-bash uses, so a project that configured
  // CLAUDE_TICKET_PATTERN gets one consistent answer rather than two.
  it('recognises a ticket key anywhere in the item text', () => {
    const lines = evaluateTodos([todo('finish the work for PROJ-4821', 'in_progress')]);
    assert.ok(!lines.some((l) => /TODO TRACKING/.test(l)));
  });

  it('only counts pending items against nothing at all', () => {
    assert.deepEqual(evaluateTodos([todo('later', 'pending'), todo('also later', 'pending')]), []);
  });
});

describe('post-todo.ts as Claude Code runs it', () => {
  function run(payload: unknown) {
    return spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: JSON.stringify(payload), encoding: 'utf-8' },
    );
  }

  it('reports on a TodoWrite payload without blocking', () => {
    const r = run({
      tool_name: 'TodoWrite',
      tool_input: { todos: [{ content: 'done thing', status: 'completed' }] },
    });
    assert.equal(r.status, 0, 'a PostToolUse hook must never block');
    assert.match(r.stderr, /TODO SYNC/);
  });

  it('ignores a tool it does not govern', () => {
    const r = run({ tool_name: 'Bash', tool_input: { command: 'ls' } });
    assert.equal(r.status, 0);
    assert.equal(r.stderr.trim(), '');
  });
});
