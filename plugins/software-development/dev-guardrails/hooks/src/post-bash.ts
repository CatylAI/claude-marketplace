// PostToolUse hook (Bash): redact credentials out of command output.
//
// THIS IS A BLAST-RADIUS LIMITER, NOT PREVENTION. Do not weaken Gate A in pre-bash.ts on
// the grounds that "redaction covers it" — it does not, for three reasons:
//
//   1. The command has already run. Anything it sent over the network is gone.
//   2. Claude Code writes large Bash output to a file under the session directory BEFORE
//      this hook sees it. Rewriting what the model reads does not unwrite that file, so a
//      leaked value can still be sitting on disk in cleartext.
//   3. The hook only fires on output it is wired to. Gate A is the control that stops the
//      value being produced at all.
//
// What this DOES buy: a secret that reaches output anyway does not then propagate into the
// conversation, into a later file write, or into a pull-request description. That is worth
// having. It is not the primary control.
//
// Only TOKEN_PATTERNS are used here. CONTENT_PATTERNS match the shape of an ASSIGNMENT, which
// appears constantly in legitimate command output — a `grep` for a hardcoded credential, a
// `terraform plan` diff, a review note reporting one. Redacting those would corrupt the output
// Claude needs in order to fix the very problem it just found.

import { readStdin } from './lib/stdin.ts';
import { info } from './lib/output.ts';
import { findSecrets, redactSecrets, containsPlaceholder } from './lib/secrets.ts';
import type { BashToolOutput } from './lib/types.ts';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export interface RedactionResult {
  /** Replacement output, or null when nothing matched and the original should stand. */
  readonly updated: BashToolOutput | null;
  /** Human-readable note for Claude. Always present when something was redacted. */
  readonly notice: string | null;
}

/**
 * Decide what to do about a Bash tool response. Pure, so it is unit-testable.
 *
 * Returns `updated: null` whenever the response shape is not recognisably Bash's
 * `{stdout, stderr, interrupted, isImage}`. That is deliberate: Claude Code ignores an
 * `updatedToolOutput` that does not match the tool's schema and keeps the ORIGINAL
 * output, so guessing at a shape would silently do nothing while looking like it worked.
 * When the shape is unknown we warn instead, which at least reaches a human.
 */
export function evaluateBashOutput(response: unknown): RedactionResult {
  if (response === null || typeof response !== 'object') {
    return { updated: null, notice: null };
  }
  const r = response as Record<string, unknown>;

  const hasBashShape = typeof r.stdout === 'string' || typeof r.stderr === 'string';
  const stdout = typeof r.stdout === 'string' ? r.stdout : '';
  const stderr = typeof r.stderr === 'string' ? r.stderr : '';

  // On an unrecognised shape there are no stdout/stderr fields to scan, but the secret is
  // still in there somewhere. Flatten every string value so the warning path can see it —
  // otherwise an unknown shape silently reports "nothing found", which is the worst
  // possible outcome: a real disclosure that looks clean.
  const scanTarget = hasBashShape
    ? stdout + '\n' + stderr
    : Object.values(r)
        .filter((v): v is string => typeof v === 'string')
        .join('\n');

  const combined = scanTarget;
  if (containsPlaceholder(combined)) {
    // Already redacted (a re-fired hook, or a replayed transcript). Do nothing.
    return { updated: null, notice: null };
  }

  const outResult = redactSecrets(stdout);
  const errResult = redactSecrets(stderr);
  const matches = hasBashShape
    ? [...outResult.matches, ...errResult.matches]
    : findSecrets(scanTarget);
  if (matches.length === 0) return { updated: null, notice: null };

  const kinds = [...new Set(matches.map((m) => m.patternName))].sort();
  const noticeLines = [
    `SECRET REDACTED FROM OUTPUT: ${matches.length} credential-shaped value(s) ` +
      `(${kinds.join(', ')}) were removed from this command's output before you saw them.`,
    '',
    '  This is damage limitation, not prevention. The command already ran, and Claude Code',
    '  may have written the ORIGINAL output to a file in the session directory before this',
    '  hook ran — so the value can still be on disk in cleartext.',
    '',
    '  Do NOT re-run the command to see the value. If you need to know whether a variable',
    '  is set, use `echo "VAR: ${VAR:+set}"` or `echo "${#VAR}"`.',
    '  If a live credential was disclosed, it must be ROTATED — redaction does not undo it.',
  ];

  if (!hasBashShape) {
    // Cannot safely replace: an off-schema updatedToolOutput is discarded and the original
    // output is kept. Say so rather than pretending the redaction happened.
    return {
      updated: null,
      notice:
        noticeLines.join('\n') +
        '\n\n  NOTE: this output did not match the Bash tool schema, so it could NOT be' +
        '\n  rewritten — the value above is still the original. Treat it as disclosed.',
    };
  }

  return {
    updated: {
      stdout: outResult.text,
      stderr: errResult.text,
      interrupted: typeof r.interrupted === 'boolean' ? r.interrupted : false,
      isImage: typeof r.isImage === 'boolean' ? r.isImage : false,
    },
    notice: noticeLines.join('\n'),
  };
}

async function run(): Promise<void> {
  try {
    const input = await readStdin();
    if (input.tool_name !== 'Bash') process.exit(0);

    const { updated, notice } = evaluateBashOutput(input.tool_response);
    if (!notice) process.exit(0);

    // `additionalContext` is emitted ALWAYS when something matched, even alongside
    // `updatedToolOutput`. On a Claude Code build that does not honour
    // `updatedToolOutput`, the note still reaches the model — the hook degrades to
    // warn-only instead of silently doing nothing.
    const payload: Record<string, unknown> = {
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: notice,
        ...(updated ? { updatedToolOutput: updated } : {}),
      },
    };
    process.stdout.write(JSON.stringify(payload) + '\n');
  } catch {
    // Never break a command that already succeeded. A crash here must not surface as a
    // tool failure, so swallow and exit clean.
  }
  process.exit(0);
}

// Only run as the hook entrypoint — importing (e.g. from tests) must not block on stdin.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
