// UserPromptSubmit hook: resolve the ambiguous parts of a prompt before the model reads it.
// Non-blocking; it never rewrites the prompt, only adds context next to it.
//
// COST MODEL. This runs before every prompt and blocks the model until it exits, and anything it
// prints is re-sent with every later request. So it prints only when the prompt contains
// something to resolve, and it runs no subprocess at all.
//
// What it resolves, and why the model cannot do it reliably on its own:
//
//   - A RELATIVE DATE ("EOW", "next friday", "tomorrow"). The weekday arithmetic is where models
//     slip. "today" alone is skipped: Claude Code already gives the model the current date.
//   - A TILDE PATH. `~` is expanded by a shell, not by file tools, so `~/src/foo` passed to Read
//     opens a directory literally named `~`.
//
// The branch's ticket key used to be injected here on every prompt. It moved out: session-start
// and the post-compaction hook each state it once, and a line repeated on every prompt is a
// per-request token cost for no new information.
//
// FAILURE MODE: fail open, silently. Any error exits 0 with no output, so the prompt goes through
// exactly as typed.

import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveDateExpr, todayISO } from './lib/dates.ts';

const DATE_PATTERNS: RegExp[] = [
  /\b(tomorrow|yesterday)\b/gi,
  /\b(EOW|EOM|end[\s-]of[\s-]week|end[\s-]of[\s-]month|next week|last week)\b/gi,
  /\b(next\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b/gi,
  /\b(this\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b/gi,
  /\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/gi,
];

export interface PromptContextOptions {
  today: Date;
  home: string | undefined;
}

/**
 * The context lines to add for `prompt`, or an empty string when there is nothing to resolve.
 * Pure: the date and home directory are passed in.
 */
export function buildPromptContext(prompt: string, opts: PromptContextOptions): string {
  const sections: string[] = [];

  const resolutions: Array<[string, string]> = [];
  for (const pattern of DATE_PATTERNS) {
    for (const match of prompt.matchAll(pattern)) {
      const expr = match[1];
      // A weekday already consumed by "next friday" / "this friday" is not resolved twice.
      const covered = resolutions.some(([e]) => e.toLowerCase().includes(expr.toLowerCase()));
      if (covered) continue;
      const isoDate = resolveDateExpr(expr, opts.today);
      if (isoDate) resolutions.push([expr, isoDate]);
    }
  }
  if (resolutions.length > 0) {
    const lines = resolutions.map(([expr, isoDate]) => `  "${expr}" -> ${isoDate}`);
    sections.push(`Date resolution (today is ${todayISO(opts.today)}):\n${lines.join('\n')}`);
  }

  if (opts.home) {
    const seen = new Set<string>();
    const expanded: string[] = [];
    for (const m of prompt.matchAll(/~\/([^\s"'`]+)/g)) {
      if (seen.has(m[1])) continue;
      seen.add(m[1]);
      expanded.push(`  ~/${m[1]} -> ${opts.home}/${m[1]}`);
    }
    if (expanded.length > 0) sections.push(`Path expansion:\n${expanded.join('\n')}`);
  }

  return sections.join('\n');
}

async function main(): Promise<void> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  const raw = Buffer.concat(chunks).toString('utf-8').trim();

  let prompt = '';
  try {
    prompt = (JSON.parse(raw) as { prompt?: string }).prompt ?? '';
  } catch {
    return; // an unparseable payload is not worth a failed prompt
  }
  if (!prompt) return;

  const text = buildPromptContext(prompt, { today: new Date(), home: process.env.HOME });
  // Plain stdout is added to Claude's context on UserPromptSubmit.
  if (text) process.stdout.write(text + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch {
    // Fail open: see the header.
  }
  process.exit(0);
}
