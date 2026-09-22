// Fake credentials are assembled at runtime. A contiguous literal would be blocked on the
// way in by pre-write-edit.ts and flagged at commit by the secret scanners.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  evaluateOutbound,
  findOutboundSecrets,
  isPublishingTool,
} from './pre-mcp-tool.ts';
import { redactionPlaceholder } from './lib/secrets.ts';

const FAKE_PAT = 'glpat-' + 'q7Kd9mZ2vB4nR6tY8wXa';
const FAKE_AWS_KEY = 'AKIA' + 'WZ7QK3MR5PXT2NDF';

describe('isPublishingTool', () => {
  it('recognises the tools that write somewhere other people read', () => {
    assert.ok(isPublishingTool('mcp__forge__create_pull_request'));
    assert.ok(isPublishingTool('mcp__forge__create_merge_request'));
    assert.ok(isPublishingTool('mcp__forge__create_issue'));
    assert.ok(isPublishingTool('mcp__chat__send_message'));
    assert.ok(isPublishingTool('mcp__wiki__update_page'));
  });

  it('leaves read-only tools alone', () => {
    // A gate on a read is pure cost: nothing leaves the session.
    assert.equal(isPublishingTool('mcp__forge__list_pull_requests'), false);
    assert.equal(isPublishingTool('mcp__forge__get_file_contents'), false);
    assert.equal(isPublishingTool('mcp__chat__search'), false);
  });
});

describe('findOutboundSecrets', () => {
  it('finds a credential nested anywhere in the arguments, and names the field', () => {
    const hits = findOutboundSecrets({ title: 'fix', body: { text: `use ${FAKE_PAT}` } });
    assert.equal(hits.length, 1);
    assert.equal(hits[0]?.patternName, 'gitlab-pat');
    assert.equal(hits[0]?.path, 'body.text');
  });

  it('walks arrays, because block-structured message payloads are lists', () => {
    const hits = findOutboundSecrets({ blocks: [{ text: 'ok' }, { text: FAKE_AWS_KEY }] });
    assert.equal(hits.length, 1);
    assert.equal(hits[0]?.path, 'blocks[1].text');
  });

  it('finds nothing in ordinary arguments', () => {
    assert.deepEqual(findOutboundSecrets({ title: 'fix: rename the config loader' }), []);
    assert.deepEqual(findOutboundSecrets(null), []);
  });

  it('terminates on a deeply nested payload instead of hanging the gate', () => {
    // The input is untrusted; a PreToolUse hook that does not return blocks every call.
    let deep: unknown = FAKE_PAT;
    for (let i = 0; i < 50; i += 1) deep = { next: deep };
    assert.deepEqual(findOutboundSecrets(deep), []);
  });
});

describe('evaluateOutbound', () => {
  it('blocks a credential in a pull-request body', () => {
    const d = evaluateOutbound('mcp__forge__create_pull_request', {
      title: 'ci: add deploy step',
      body: `set the runner token to ${FAKE_PAT}`,
    });
    assert.ok(d);
    assert.match(d.message, /BLOCKED/);
    assert.match(d.message, /gitlab-pat/);
    assert.match(d.message, /body/);
  });

  it('blocks a credential in a chat message', () => {
    assert.ok(
      evaluateOutbound('mcp__chat__send_message', { text: `key: ${FAKE_AWS_KEY}` }),
    );
  });

  it('lets a review note DESCRIBE a leak without reproducing it', () => {
    // The reviewer's whole job is reporting this. Blocking the report would be worse than
    // the finding it describes, which is why the assignment-shaped patterns are excluded.
    assert.equal(
      evaluateOutbound('mcp__forge__create_review_comment', {
        body: 'a live personal access token is hardcoded at config.py:12 — rotate it',
      }),
      null,
    );
    assert.equal(
      evaluateOutbound('mcp__forge__create_issue', {
        body: 'password = "hunter2" is committed in settings.py — move it to <FORGE>_TOKEN',
      }),
      null,
    );
  });

  it('lets an already-redacted value through', () => {
    assert.equal(
      evaluateOutbound('mcp__forge__create_issue', {
        body: `the leaked value was ${redactionPlaceholder('gitlab-pat')}`,
      }),
      null,
    );
  });

  it('does not gate a read-only tool, however many tokens the arguments hold', () => {
    assert.equal(evaluateOutbound('mcp__forge__list_issues', { q: FAKE_PAT }), null);
  });

  it('ignores a call with no tool name', () => {
    assert.equal(evaluateOutbound(undefined, { body: FAKE_PAT }), null);
  });
});

describe('pre-mcp-tool.ts as Claude Code runs it', () => {
  const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'pre-mcp-tool.ts');

  function runHook(payload: unknown, extraEnv: Record<string, string> = {}) {
    const env = { ...process.env, ...extraEnv };
    if (!('CLAUDE_GUARDRAILS_OFF' in extraEnv)) delete env.CLAUDE_GUARDRAILS_OFF;
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: JSON.stringify(payload), encoding: 'utf-8', env },
    );
    return { code: r.status ?? -1, stderr: r.stderr ?? '' };
  }

  it('exits 2 on an outbound credential', () => {
    const r = runHook({
      tool_name: 'mcp__forge__create_merge_request',
      tool_input: { description: `token ${FAKE_PAT}` },
    });
    assert.equal(r.code, 2);
    assert.match(r.stderr, /BLOCKED/);
  });

  it('exits 0 on a clean publish', () => {
    const r = runHook({
      tool_name: 'mcp__forge__create_merge_request',
      tool_input: { description: 'adds the deploy step' },
    });
    assert.equal(r.code, 0);
  });

  it('honours the global off-switch', () => {
    const r = runHook(
      {
        tool_name: 'mcp__forge__create_merge_request',
        tool_input: { description: `token ${FAKE_PAT}` },
      },
      { CLAUDE_GUARDRAILS_OFF: '1' },
    );
    assert.equal(r.code, 0);
  });
});
