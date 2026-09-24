// PostToolUseFailure hook (MCP tools): map an authentication failure to the RIGHT re-auth action.
//
// The failure this exists for is not the 401 itself, it is what happens next. An MCP server
// and the vendor's own CLI are two different credentials for the same vendor, and they fail
// identically. So a 401 from a forge MCP server sends people to `gh auth login` / `glab auth
// login`, which succeeds, changes nothing about the MCP server's token, and produces the same
// 401 on the next call — with the added cost that the operator now believes the auth path is
// fine. Re-authorising the MCP SERVER is a different action entirely.
//
// WHICH EVENT. An MCP tool that returns an error result fires PostToolUseFailure, not
// PostToolUse (code.claude.com/docs/en/hooks, "PostToolUseFailure"), with the error text in a
// top-level `error` string. Registered on PostToolUse, this hook saw only successful calls and so
// could not see the failure it exists for. It reads `error` first and `tool_response` as a
// fallback, so it also works if a server reports auth failure inside a successful result.
//
// OUTPUT is JSON additionalContext on stdout, the only channel from this event that reaches
// Claude; stderr on exit 0 goes to the debug log. Non-blocking by construction: the call has
// already failed, so the hook only adds the correct next step. Fails open and silent.

import { readStdin } from './lib/stdin.ts';
import { emitContext } from './lib/additional-context.ts';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

/** One row of the re-auth registry. */
export interface McpAuthEntry {
  /** What to call this system in the reminder. */
  readonly system: string;
  /** Tested against the SERVER segment of the tool name, not the whole name. */
  readonly matcher: RegExp;
  /** The one correct way to re-authenticate THIS system. */
  readonly reauth: string;
}

/**
 * The registry is DATA, deliberately.
 *
 * A reader adding their own MCP server should be adding one row, not editing a branch in a
 * function — so this is an array a reader can extend by copying the line above theirs. It is
 * seeded with the generic cases plus the two forges, and nothing here names a private or
 * internal server: an entry for a server only one organisation runs belongs in that
 * organisation's fork, not in a shared plugin.
 *
 * ORDER MATTERS — first match wins, so the most specific matchers go first.
 */
export const MCP_AUTH_TABLE: readonly McpAuthEntry[] = [
  {
    system: 'GitHub MCP server',
    matcher: /github/i,
    reauth:
      'Re-authorise the MCP server itself — run `/mcp` in the Claude Code prompt and reconnect it. ' +
      '`gh auth login` re-authenticates the CLI, which is a SEPARATE credential and will not fix this.',
  },
  {
    system: 'GitLab MCP server',
    matcher: /gitlab/i,
    reauth:
      'Re-authorise the MCP server itself — run `/mcp` in the Claude Code prompt and reconnect it. ' +
      '`glab auth login` re-authenticates the CLI, which is a SEPARATE credential and will not fix this.',
  },
  {
    // Generic: servers that read the local cloud credential chain rather than holding their
    // own token. For these the CLI login IS the fix, which is exactly why the forge rows
    // above have to say the opposite explicitly.
    system: 'cloud-credential-backed MCP server',
    matcher: /(aws|bedrock|azure|gcloud|gcp)/i,
    reauth:
      'These servers read the machine\'s cloud credential chain, so the CLI login is the fix: ' +
      '`aws sso login --profile <profile>`, `az login`, or `gcloud auth login`. `/mcp` will not ' +
      'help — the server has no token of its own to refresh.',
  },
  {
    // Generic: OAuth-connected servers. The token lives with the connection, so the only
    // place to renew it is the connection.
    system: 'OAuth-connected MCP server',
    matcher: /(oauth|atlassian|jira|confluence|slack|notion|linear|google|gmail|gdrive|gcal)/i,
    reauth:
      'Run `/mcp` in the Claude Code prompt and reconnect the server. The token was issued to the ' +
      'MCP connection, so no CLI login touches it.',
  },
];

/**
 * Fallback for a server no row matches. It names the DECISION rather than guessing an action,
 * because guessing is the failure mode this hook exists to prevent.
 */
export const MCP_AUTH_FALLBACK =
  'Unrecognised MCP server. The fix depends on whether it holds its own token (fix: `/mcp`, ' +
  'reconnect the server) or reads a credential the machine already has (fix: that tool\'s own ' +
  'login). Another system\'s auth command will not help.';

/**
 * The server segment of an MCP tool name: `mcp__<server>__<tool>` → `<server>`.
 *
 * Matching on the server rather than the whole name keeps a tool called `get_github_status`
 * on an unrelated server from being attributed to the GitHub row.
 */
export function mcpServerName(toolName: string): string | null {
  const m = /^mcp__([^_]+(?:_[^_]+)*?)__/.exec(toolName);
  return m?.[1] ?? null;
}

// Auth-error signal words. Deliberately narrow, so ordinary failures — rate limits, 404s,
// validation errors — do not trip this hook and train people to ignore it.
const AUTH_ERROR_PATTERNS: readonly RegExp[] = [
  /\b401\b/,
  /\b403\b/,
  /\bunauthori[sz]ed\b/i,
  /\bauthentication\s+(required|failed|error)\b/i,
  /\bauthentication[_\s-]*required\b/i,
  /\btoken\s+(expired|invalid|missing)\b/i,
  // `[_\s-]*` and not `\s+`: the separator is often absent. AWS returns the bare error code
  // `ExpiredToken` / `ExpiredTokenException`, which a whitespace-only pattern misses — and
  // missing it is exactly the case that sends someone to `/mcp` when the fix was a CLI login.
  /\bexpired[_\s-]*(token|session|credential)\b/i,
  /\binvalid[_\s-]*(token|credential|api[_\s-]*key|session)\b/i,
  /\bpermission\s+denied\b/i,
  /\bnot\s+authenticated\b/i,
  /\baccess\s+denied\b/i,
];

/**
 * Flatten every stringy value in a tool response into one blob, so the patterns above match
 * wherever the server put its error — a top-level `error`, a nested `content[0].text`, an
 * `isError: true` wrapper. Depth-bounded: the payload is untrusted.
 */
export function flattenResultText(result: unknown, depth = 0): string {
  if (depth > 6 || result == null) return '';
  if (typeof result === 'string') return result;
  if (typeof result === 'number' || typeof result === 'boolean') return String(result);
  if (Array.isArray(result)) return result.map((r) => flattenResultText(r, depth + 1)).join('\n');
  if (typeof result === 'object') {
    return Object.values(result as Record<string, unknown>)
      .map((v) => flattenResultText(v, depth + 1))
      .join('\n');
  }
  return '';
}

/**
 * Pure decision: the reminder to emit, or null when this is not an MCP call or carries no
 * auth-error signal.
 */
export function detectMcpAuthError(
  toolName: string | undefined,
  toolResponse: unknown,
): string | null {
  if (!toolName) return null;
  const server = mcpServerName(toolName);
  if (server === null) return null;

  const blob = flattenResultText(toolResponse);
  if (!blob) return null;
  if (!AUTH_ERROR_PATTERNS.some((re) => re.test(blob))) return null;

  const entry = MCP_AUTH_TABLE.find((e) => e.matcher.test(server));

  return (
    `MCP AUTH: ${toolName} returned an authentication error (${entry?.system ?? 'MCP server'}).\n` +
    `  Correct action: ${entry?.reauth ?? MCP_AUTH_FALLBACK}\n` +
    '  An MCP server\'s credential and the vendor CLI\'s credential are separate; re-running the\n' +
    '  wrong login succeeds, fixes nothing, and hides the real failure.'
  );
}

async function run(): Promise<void> {
  try {
    const input = await readStdin();
    // PostToolUseFailure carries `error` (a string). `tool_response`, not `tool_result`, is the
    // PostToolUse field; `tool_result` is the model-facing block name and never a hook input.
    const failure = (input as { error?: unknown }).error;
    const payload = typeof failure === 'string' && failure ? failure : input.tool_response;
    const msg = detectMcpAuthError(input.tool_name, payload);
    const event = input.hook_event_name === 'PostToolUse' ? 'PostToolUse' : 'PostToolUseFailure';
    if (msg) emitContext(event, msg);
  } catch {
    // Silent — never interfere on the post-tool path.
  }
  process.exit(0);
}

// Run only when invoked directly (not when imported by tests).
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
