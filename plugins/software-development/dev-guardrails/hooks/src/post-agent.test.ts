import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recordAgentEvent } from './post-agent.ts';

// Verifies the Pre/Post lifecycle bookkeeping. The load-bearing case is that a PreToolUse:Agent
// event opens a 'running' entry with a distinct started_at, and the PostToolUse:Agent event
// closes THAT entry — so started_at != completed_at and duration/stuck detection is meaningful.
// Before the Pre hook existed, Post recorded started_at == completed_at (duration always 0) and
// the 'running'/STUCK code was unreachable.

function freshProgress() {
  return {
    session_id: null,
    started_at: null,
    last_update: null,
    last_report_at: null,
    agents: {},
    config: { max_parallel: 4, progress_interval_sec: 300, stuck_threshold_sec: 1200 },
  };
}

function agentInput(event: string, over: Record<string, unknown> = {}) {
  return {
    hook_event_name: event,
    tool_name: 'Agent',
    tool_input: { description: 'Review the diff', subagent_type: 'code-reviewer' },
    session_id: 'sess-1',
    ...over,
  };
}

test('PreToolUse opens a running entry with started_at set', () => {
  const p = recordAgentEvent(freshProgress(), agentInput('PreToolUse'), '2026-01-01T00:00:00.000Z');
  const entries = Object.values(p.agents);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].status, 'running');
  assert.equal(entries[0].started_at, '2026-01-01T00:00:00.000Z');
  assert.equal(entries[0].completed_at, null);
});

test('PostToolUse closes the matching running entry, preserving started_at', () => {
  let p = recordAgentEvent(freshProgress(), agentInput('PreToolUse'), '2026-01-01T00:00:00.000Z');
  p = recordAgentEvent(p, agentInput('PostToolUse'), '2026-01-01T00:05:00.000Z');
  const entries = Object.values(p.agents);
  assert.equal(entries.length, 1, 'Post must close the existing entry, not create a second');
  assert.equal(entries[0].status, 'completed');
  assert.equal(entries[0].started_at, '2026-01-01T00:00:00.000Z');
  assert.equal(entries[0].completed_at, '2026-01-01T00:05:00.000Z');
  assert.notEqual(entries[0].started_at, entries[0].completed_at, 'duration must be non-zero');
});

test('PostToolUse with an error marks the entry failed and records the error', () => {
  let p = recordAgentEvent(freshProgress(), agentInput('PreToolUse'), '2026-01-01T00:00:00.000Z');
  p = recordAgentEvent(p, agentInput('PostToolUse', {
    // `tool_response` is the real hook-input field. A fixture that says `tool_result` passes
    // while the production read is always undefined — the field name is the assertion here.
    tool_response: { error: 'boom' },
  }), '2026-01-01T00:01:00.000Z');
  const entry = Object.values(p.agents)[0];
  assert.equal(entry.status, 'failed');
  assert.equal(entry.error, 'boom');
  assert.equal(entry.completed_at, '2026-01-01T00:01:00.000Z');
});

test('PostToolUse with no prior Pre records a terminal entry (hook installed mid-run)', () => {
  const p = recordAgentEvent(freshProgress(), agentInput('PostToolUse'), '2026-01-01T00:00:00.000Z');
  const entries = Object.values(p.agents);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].status, 'completed');
  assert.equal(entries[0].started_at, entries[0].completed_at);
});

test('two concurrent Pre events open two distinct running entries', () => {
  let p = recordAgentEvent(freshProgress(), agentInput('PreToolUse', {
    tool_input: { description: 'task A', subagent_type: 'x' },
  }), '2026-01-01T00:00:00.000Z');
  p = recordAgentEvent(p, agentInput('PreToolUse', {
    tool_input: { description: 'task B', subagent_type: 'y' },
  }), '2026-01-01T00:00:01.000Z');
  assert.equal(Object.keys(p.agents).length, 2);
});

test('Post closes the OLDEST running entry when two share a description; newer stays running', () => {
  // Guards the stuck-detection path against an insertion-order refactor: with two same-description
  // Pre entries, a single Post must close the first-opened one and leave the second running.
  let p = recordAgentEvent(freshProgress(), agentInput('PreToolUse'), '2026-01-01T00:00:00.000Z');
  p = recordAgentEvent(p, agentInput('PreToolUse'), '2026-01-01T00:00:10.000Z');
  p = recordAgentEvent(p, agentInput('PostToolUse'), '2026-01-01T00:05:00.000Z');

  const first = p.agents['1'];
  const second = p.agents['2'];
  assert.equal(first.status, 'completed', 'oldest matching entry is closed');
  assert.equal(first.started_at, '2026-01-01T00:00:00.000Z');
  assert.equal(first.completed_at, '2026-01-01T00:05:00.000Z');
  assert.equal(second.status, 'running', 'newer same-description entry stays running');
  assert.equal(second.completed_at, null);
});

test('PostToolUse with an error and no prior Pre records a FAILED terminal entry', () => {
  // MINOR-1: the terminal (no-Pre) branch's failed path — status:'failed' + error captured with
  // started_at == completed_at. Distinct from the matched-entry failed path already covered above.
  const p = recordAgentEvent(freshProgress(), agentInput('PostToolUse', {
    tool_response: { error: 'mid-run install, blew up' },
  }), '2026-01-01T00:00:00.000Z');
  const entry = Object.values(p.agents)[0];
  assert.equal(entry.status, 'failed');
  assert.equal(entry.error, 'mid-run install, blew up');
  assert.equal(entry.started_at, entry.completed_at, 'no Pre means zero-duration terminal entry');
});

test('missing description/subagent_type fall back to defaults', () => {
  // INFO-10: exercise the `|| 'Unknown task'` / `|| 'general-purpose'` right-hand sides.
  const p = recordAgentEvent(freshProgress(), agentInput('PreToolUse', {
    tool_input: {},
  }), '2026-01-01T00:00:00.000Z');
  const entry = Object.values(p.agents)[0];
  assert.equal(entry.task, 'Unknown task');
  assert.equal(entry.agent_type, 'general-purpose');
});

test('recordAgentEvent does not mutate its input (pure over progress)', () => {
  const original = freshProgress();
  const snapshot = JSON.stringify(original);
  recordAgentEvent(original, agentInput('PreToolUse'), '2026-01-01T00:00:00.000Z');
  assert.equal(JSON.stringify(original), snapshot, 'input Progress must be untouched');
});
