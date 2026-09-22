// PreCompact hook: restate the session's active working state so compaction cannot lose it.
//
// REGISTERED ON PreCompact, WHICH IS THE ONLY COMPACTION EVENT CLAUDE CODE EXPOSES. There is no
// post-compaction event to hook, and that turns out to be the better place anyway: output emitted
// HERE is part of the material the compaction summarises, so the facts survive into the summary
// instead of being appended after it.
//
// Everything printed is CHEAP AND CURRENT — read fresh from git at the moment it runs, rather
// than recovered from the transcript that is about to be discarded.
//
// Deliberately a subset of session-start: branch, ticket key, uncommitted count. No repo-health
// checks, no worktree enumeration. Those belong to a session's opening moments; repeating them at
// every compaction would be noise in the middle of ongoing work.

import { context } from './lib/output.ts';
import { getBranch, isGitRepo } from './lib/git.ts';
import { exec } from './lib/shell.ts';
import { extractTicket } from './pre-bash.ts';

context('=== Carry Forward Through Compaction ===');
context('');

if (isGitRepo()) {
  const branch = getBranch();
  context(`Branch: ${branch}`);

  const ticket = extractTicket(branch);
  if (ticket) context(`Ticket: ${ticket}`);

  const porcelain = exec('git status --porcelain', { timeout: 5000 });
  if (porcelain) {
    const count = porcelain.split('\n').filter((l) => l).length;
    if (count > 0) context(`Uncommitted: ${count} file(s)`);
  }
  context('');
}

context('=== End Carry Forward ===');
process.exit(0);
