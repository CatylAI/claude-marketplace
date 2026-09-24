// SessionStart hook, matcher `compact`: restate the working state right after compaction.
//
// WHY SessionStart AND NOT PreCompact. A PreCompact hook's stdout on exit 0 goes to the debug log
// only; it never reaches the model or the summary. After a compaction Claude Code fires
// SessionStart with `source: "compact"`, and SessionStart is one of the events whose plain stdout
// is added to Claude's context. So this is the hook point where carried-forward facts land in the
// new context. (PostCompact exists too, but it has no context output.)
//
// Everything printed is read fresh from git now, not recovered from the transcript that was just
// summarised. Deliberately a subset of session-start: branch, ticket key, uncommitted count, on
// one line. Repo-health checks belong to a session's opening, not to every compaction.
//
// FAILURE MODE: fail open, silently. It exits 0 on any error with nothing on stdout; losing one
// carry-forward line is cheaper than a hook-error notice in the middle of ongoing work.

import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { context } from './lib/output.ts';
import { getBranch, isGitRepo } from './lib/git.ts';
import { exec } from './lib/shell.ts';
import { extractTicket } from './lib/ticket.ts';

/** The single carry-forward line. Pure, so the wording is testable without a repository. */
export function formatCarryForward(branch: string, ticket: string | null, uncommitted: number): string {
  const parts = [`Branch: ${branch}`];
  if (ticket) parts.push(`ticket ${ticket}`);
  if (uncommitted > 0) parts.push(`${uncommitted} uncommitted file(s)`);
  return `Carried forward after compaction: ${parts.join(' · ')}`;
}

function run(): void {
  if (!isGitRepo()) return;
  const branch = getBranch();
  const porcelain = exec('git status --porcelain', { timeout: 5000 });
  const count = porcelain ? porcelain.split('\n').filter((l) => l).length : 0;
  context(formatCarryForward(branch, extractTicket(branch), count));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    run();
  } catch {
    // Fail open: see the header.
  }
  process.exit(0);
}
