import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  MCP_AUTH_FALLBACK,
  MCP_AUTH_TABLE,
  detectMcpAuthError,
  flattenResultText,
  mcpServerName,
} from './post-mcp-tool.ts';

describe('mcpServerName', () => {
  it('takes the server segment, not the tool segment', () => {
    assert.equal(mcpServerName('mcp__github__create_issue'), 'github');
    assert.equal(mcpServerName('mcp__plugin_forge_gitlab__list_mrs'), 'plugin_forge_gitlab');
  });

  it('returns null for a tool that is not an MCP call', () => {
    assert.equal(mcpServerName('Bash'), null);
    assert.equal(mcpServerName('Write'), null);
  });
});

describe('flattenResultText', () => {
  it('reaches an error however deeply the server nested it', () => {
    assert.match(flattenResultText({ content: [{ type: 'text', text: 'HTTP 401' }] }), /401/);
    assert.match(flattenResultText({ isError: true, error: { message: 'Unauthorized' } }), /Unauthorized/);
  });

  it('terminates instead of hanging on a pathological payload', () => {
    let deep: unknown = 'bottom';
    for (let i = 0; i < 50; i += 1) deep = { next: deep };
    assert.equal(flattenResultText(deep).includes('bottom'), false);
  });
});

describe('detectMcpAuthError', () => {
  it('names the MCP server as the thing to re-authorise, not the vendor CLI', () => {
    // The whole point. After an MCP-layer 401 the reflex is a CLI login, which succeeds,
    // changes nothing, and reproduces the same 401 on the next call.
    const msg = detectMcpAuthError('mcp__github__create_issue', { error: 'HTTP 401 Unauthorized' });
    assert.ok(msg);
    assert.match(msg, /GitHub MCP server/);
    assert.match(msg, /\/mcp/);
    assert.match(msg, /gh auth login.*SEPARATE credential/s);
  });

  it('gives the other forge its own row, since this plugin is forge-neutral', () => {
    const msg = detectMcpAuthError('mcp__gitlab__create_merge_request', { error: '401' });
    assert.ok(msg);
    assert.match(msg, /GitLab MCP server/);
    assert.match(msg, /glab auth login/);
  });

  it('sends a cloud-credential-backed server to the CLI login instead', () => {
    // The generic row that makes the forge rows meaningful: for these the CLI login IS the
    // fix, so "always run /mcp" would be exactly as wrong as "always run the CLI login".
    const msg = detectMcpAuthError('mcp__aws_pricing__get_pricing', { error: 'ExpiredToken' });
    assert.ok(msg);
    assert.match(msg, /cloud-credential-backed/);
    assert.match(msg, /aws sso login/);
  });

  it('falls back to naming the decision rather than guessing an action', () => {
    const msg = detectMcpAuthError('mcp__somevendor__do_thing', { error: '403 Forbidden' });
    assert.ok(msg);
    assert.match(msg, /Unrecognised MCP server/);
    assert.equal(msg.includes(MCP_AUTH_FALLBACK), true);
  });

  it('stays quiet on failures that are not authentication failures', () => {
    // A reminder that fires on every 404 and every rate limit is a reminder people stop
    // reading, which costs more than it saves.
    assert.equal(detectMcpAuthError('mcp__github__create_issue', { error: 'HTTP 404 Not Found' }), null);
    assert.equal(detectMcpAuthError('mcp__github__create_issue', { error: 'rate limit exceeded' }), null);
    assert.equal(detectMcpAuthError('mcp__github__create_issue', { ok: true }), null);
  });

  it('ignores anything that is not an MCP call', () => {
    assert.equal(detectMcpAuthError('Bash', { stderr: '401 Unauthorized' }), null);
    assert.equal(detectMcpAuthError(undefined, { error: '401' }), null);
  });
});

describe('the registry is data a reader can extend', () => {
  it('matches on the server segment, so a tool NAMED for a vendor is not misattributed', () => {
    const msg = detectMcpAuthError('mcp__somevendor__get_github_status', { error: '401' });
    assert.ok(msg);
    assert.doesNotMatch(msg, /GitHub MCP server/);
  });

  it('every row carries all three fields, so a copied row cannot be half-filled', () => {
    for (const entry of MCP_AUTH_TABLE) {
      assert.ok(entry.system.length > 0, 'system must be set');
      assert.ok(entry.matcher instanceof RegExp, 'matcher must be a RegExp');
      assert.ok(entry.reauth.length > 0, `reauth must be set for ${entry.system}`);
    }
  });

  it('names no private or internal server', () => {
    // A server only one organisation runs belongs in that organisation's fork. Rows here
    // must be either a public vendor or a generic class.
    for (const entry of MCP_AUTH_TABLE) {
      assert.doesNotMatch(entry.matcher.source, /internal|intranet|corp\b/i);
    }
  });
});

describe('post-mcp-tool.ts as Claude Code runs it', () => {
  const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'post-mcp-tool.ts');

  function runHook(payload: unknown): { code: number; stdout: string; stderr: string } {
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
      { input: JSON.stringify(payload), encoding: 'utf-8' },
    );
    return { code: r.status ?? -1, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
  }

  it('reads the PostToolUseFailure `error` string and answers through additionalContext', () => {
    // An MCP error result fires PostToolUseFailure, not PostToolUse, and stderr on exit 0
    // never reaches Claude. Both halves are pinned here.
    const r = runHook({
      hook_event_name: 'PostToolUseFailure',
      tool_name: 'mcp__gitlab__create_merge_request',
      error: '401 Unauthorized',
    });
    assert.equal(r.code, 0, 'this hook must never block');
    const out = JSON.parse(r.stdout);
    assert.equal(out.hookSpecificOutput.hookEventName, 'PostToolUseFailure');
    assert.match(out.hookSpecificOutput.additionalContext, /MCP AUTH/);
    assert.equal(r.stderr, '');
  });

  it('still reads tool_response when an auth failure arrives in a successful result', () => {
    // `tool_result` is the model-facing content-block name and is never a hook-input field.
    const r = runHook({
      hook_event_name: 'PostToolUse',
      tool_name: 'mcp__gitlab__create_merge_request',
      tool_response: { error: '401 Unauthorized' },
    });
    assert.equal(r.code, 0);
    assert.equal(JSON.parse(r.stdout).hookSpecificOutput.hookEventName, 'PostToolUse');
  });

  it('says nothing on a successful call', () => {
    const r = runHook({
      tool_name: 'mcp__gitlab__create_merge_request',
      tool_response: { web_url: 'https://example.com/mr/1' },
    });
    assert.equal(r.code, 0);
    assert.equal(r.stdout, '');
    assert.equal(r.stderr, '');
  });

  it('exits 0 on malformed input rather than throwing', () => {
    assert.equal(runHook({}).code, 0);
  });
});
