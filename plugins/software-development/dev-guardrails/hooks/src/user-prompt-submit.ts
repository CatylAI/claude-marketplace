// UserPromptSubmit hook: normalize the ambiguous parts of a developer prompt before the model
// reads it. Non-blocking — always exits 0, and never rewrites the prompt itself.
//
// Everything here resolves something the model CANNOT resolve correctly on its own:
//
//   - A RELATIVE DATE. "EOW" has no meaning without today's date, and a model asked to guess
//     will guess from its training cutoff. Resolving it to an ISO date at submit time is the
//     only way the answer is right.
//   - A TILDE PATH. `~/src/foo` is shell syntax; a tool call that passes it through verbatim
//     opens a directory literally named `~`.
//   - THE BRANCH'S TICKET KEY. The branch name is the one piece of task context that is already
//     on disk and almost never in the prompt.
//
// It adds context; it does not fetch anything, write anything, or cache anything. An earlier
// design kept a ticket-summary cache under the user's home directory — this one does not, because
// a prompt hook that writes to disk on every keystroke-ending is a surprise nobody asked for.

import { context } from './lib/output.ts';
import { exec } from './lib/shell.ts';
import { resolveDateExpr, todayISO as toTodayISO } from './lib/dates.ts';
import { extractTicket } from './pre-bash.ts';

const chunks: Buffer[] = [];
for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
const raw = Buffer.concat(chunks).toString('utf-8').trim();

interface PromptInput {
  prompt?: string;
  session_id?: string;
}

let input: PromptInput = {};
try {
  input = JSON.parse(raw) as PromptInput;
} catch {
  /* an unparseable payload is not worth a failed hook */
}

const prompt = input.prompt ?? '';
if (!prompt) process.exit(0);

// --- ISO date normalization ---------------------------------------------------------------

const today = new Date();
const todayISO = toTodayISO(today);

const datePatterns = [
  /\b(today|tomorrow|yesterday)\b/gi,
  /\b(EOW|EOM|end[\s-]of[\s-]week|end[\s-]of[\s-]month|next week|last week)\b/gi,
  /\b(next\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b/gi,
  /\b(this\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b/gi,
  /\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/gi,
];

const resolutions: Array<[string, string]> = [];
for (const pattern of datePatterns) {
  for (const match of prompt.matchAll(pattern)) {
    const expr = match[1];
    const isoDate = resolveDateExpr(expr, today);
    if (isoDate && !resolutions.some(([e]) => e.toLowerCase() === expr.toLowerCase())) {
      resolutions.push([expr, isoDate]);
    }
  }
}

if (resolutions.length > 0) {
  const lines = resolutions.map(([expr, isoDate]) => `  "${expr}" -> ${isoDate}`);
  context(`DATE RESOLUTION (today is ${todayISO}):\n${lines.join('\n')}`);
}

// --- Branch ticket context ------------------------------------------------------------------
// Only when the prompt does not already name it. Repeating a key the user just typed adds a line
// and no information, and an injected line that is always there stops being read.

const branch = exec('git branch --show-current 2>/dev/null', { timeout: 3000 });
if (branch) {
  const ticket = extractTicket(branch);
  if (ticket && !prompt.toUpperCase().includes(ticket.toUpperCase())) {
    context(`Active ticket on branch ${branch}: ${ticket}`);
  }
}

// --- Tilde path expansion --------------------------------------------------------------------
// `~` is expanded by the SHELL, not by any tool that takes a path argument, so a prompt that says
// `~/src/foo` will produce tool calls against a directory literally named `~` unless the absolute
// form is in context.

const home = process.env.HOME;
if (home) {
  const tildeMatches = [...prompt.matchAll(/~\/([^\s"'`]+)/g)];
  const seen = new Set<string>();
  const expanded: string[] = [];
  for (const m of tildeMatches) {
    if (seen.has(m[1])) continue;
    seen.add(m[1]);
    expanded.push(`  ~/${m[1]} -> ${home}/${m[1]}`);
  }
  if (expanded.length > 0) context(`PATH EXPANSION:\n${expanded.join('\n')}`);
}

process.exit(0);
