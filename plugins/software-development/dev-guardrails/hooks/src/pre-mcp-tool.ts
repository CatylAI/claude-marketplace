// PreToolUse hook (MCP tools): stop a credential going OUT.
//
// A different vector from the two Bash gates, not a duplicate of either. Once a secret is
// in context — from a file read, an earlier command, a pasted message — the plausible next
// mistake is not printing it again, it is PUBLISHING it: into a pull-request description,
// an issue comment, a chat message, a wiki page. Those are durable, they notify people, and
// on a public project they are world-readable within seconds.
//
// It must be PreToolUse. A PostToolUse hook fires after the call returns, which is far too
// late to stop a message that has already been sent.
//
// It BLOCKS rather than redacting. A silently altered description is its own defect: the
// author believes they published one thing and the reader sees another. Blocking hands the
// decision back to a human, which is the right owner for "should this go out".
//
// TOKEN_PATTERNS only. CONTENT_PATTERNS match the SHAPE of an assignment, and a review note
// reporting "api_key is hardcoded at config.py:12" has that shape while containing no
// credential at all. Blocking a reviewer from describing the defect it found would be worse
// than the risk being described — see the header of lib/secrets.ts.

import { readStdin } from './lib/stdin.ts';
import { block, allow } from './lib/output.ts';
import { TOKEN_PATTERNS, findSecrets, redactionPlaceholder } from './lib/secrets.ts';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// A publishing tool is a MUTATING VERB applied to a DURABLE SURFACE. Matching on the
// surface alone is what a first attempt does and it is wrong: `list_pull_requests` and
// `get_page` name a durable surface while sending nothing anywhere. Gating a read is pure
// cost — it cannot prevent a leak, and it teaches people that this hook fires on calls
// that were never a risk, which is how a gate ends up switched off.
//
// Both lists are matched as substrings of the whole tool name, so this stays vendor-neutral:
// any MCP server whose tool is named for what it does is covered without naming the server.

/** Verbs that send something rather than fetch it. */
const MUTATING_VERBS = [
  'create', 'add', 'update', 'edit', 'post', 'send', 'publish',
  'announce', 'submit', 'schedule', 'reply', 'write',
];

/** Surfaces that are durable, or that notify other people, or both. */
const DURABLE_SURFACES = [
  'pull_request', 'merge_request', 'issue', 'comment', 'note', 'review',
  'wiki', 'page', 'discussion', 'message', 'canvas', 'thread', 'reply',
];

/** True when this MCP tool sends content somewhere it cannot easily be taken back. */
export function isPublishingTool(toolName: string): boolean {
  const lower = toolName.toLowerCase();
  return (
    MUTATING_VERBS.some((v) => lower.includes(v)) &&
    DURABLE_SURFACES.some((s) => lower.includes(s))
  );
}

/** One credential found in the tool arguments, with the field path that carried it. */
export interface OutboundHit {
  readonly patternName: string;
  readonly path: string;
}

/**
 * Walk every string in the tool arguments and report the credentials found, each with the
 * dotted path of the field that carried it.
 *
 * Arguments arrive as arbitrary JSON — a body string, a list of blocks, a nested payload —
 * so a top-level scan of one well-known field would miss the common case. Depth is bounded
 * because the input is untrusted and a cyclic or pathologically deep payload must not hang
 * a PreToolUse hook.
 */
export function findOutboundSecrets(value: unknown, path = '', depth = 0): OutboundHit[] {
  if (depth > 6 || value == null) return [];
  if (typeof value === 'string') {
    return findSecrets(value, TOKEN_PATTERNS).map((m) => ({
      patternName: m.patternName,
      path: path || '(argument)',
    }));
  }
  if (Array.isArray(value)) {
    return value.flatMap((v, i) => findOutboundSecrets(v, `${path}[${i}]`, depth + 1));
  }
  if (typeof value === 'object') {
    return Object.entries(value as Record<string, unknown>).flatMap(([k, v]) =>
      findOutboundSecrets(v, path ? `${path}.${k}` : k, depth + 1),
    );
  }
  return [];
}

export interface OutboundDecision {
  readonly message: string;
}

/** Pure decision: the block message, or null to allow. */
export function evaluateOutbound(
  toolName: string | undefined,
  toolInput: unknown,
): OutboundDecision | null {
  if (!toolName || !isPublishingTool(toolName)) return null;

  const hits = findOutboundSecrets(toolInput);
  if (hits.length === 0) return null;

  const kinds = [...new Set(hits.map((h) => h.patternName))].sort().join(', ');
  const where = [...new Set(hits.map((h) => h.path))].slice(0, 5).join(', ');

  return {
    message: `❌ BLOCKED: this would publish a credential via ${toolName}

  Found:    ${hits.length} credential-shaped value(s) — ${kinds}
  Field(s): ${where}
  Why:      pull-request descriptions, issue and review notes, wiki pages and chat
            messages are durable and notify other people. On a public project they are
            world-readable within seconds, and deleting the message does not un-send the
            notification or clear the caches that already have it.

  Not redacted on purpose: silently altering what you publish is its own defect — you
  would believe you sent one thing while the reader sees another. This is handed back to
  you instead.

  Instead:  remove the value and refer to it indirectly
              "the token in the password manager at op://vault/item/field"
              "the value of <FORGE>_TOKEN (not reproduced here)"
            If you are DESCRIBING a leak, name the LOCATION, not the value:
              "a live personal access token is hardcoded at config.py:12 — rotate it"
            If the credential is real and was already exposed, it must be ROTATED.

  Note:     an already-redacted value such as ${redactionPlaceholder('forge-pat')} passes
            freely — this gate only stops the live shape.`,
  };
}

async function main(): Promise<void> {
  const input = await readStdin();

  // One switch for the whole engine, matching the other two blocking hooks.
  if ((process.env.CLAUDE_GUARDRAILS_OFF ?? '') === '1') allow();

  const decision = evaluateOutbound(input.tool_name, input.tool_input);
  if (decision) block(decision.message);
  allow();
}

// Run main only when invoked directly (not when imported by tests).
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
