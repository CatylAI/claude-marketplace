// SessionStart hook: the state of the repo you are about to work in, said once, at the start.
//
// Everything here answers a question that is expensive to get wrong and cheap to ask now: which
// branch, what is uncommitted, which worktrees have drifted, and whether the repo's own gates
// (pre-commit, CODEOWNERS, project settings) are capable of doing what they claim.
//
// TWO ORTHOGONAL SWITCHES, both opt-in, because a slow session start is a session start that gets
// disabled:
//
//   CLAUDE_SESSION_VERBOSE=1   the full dump. The default is a tight block — cwd, branch, ticket,
//                              a one-line git status — plus the unconditional checks below.
//   CLAUDE_SESSION_NETWORK=1   permits `git fetch`. Without it, behind-counts come from the
//                              last-fetched origin state and the report SAYS SO, rather than
//                              implying they are live.
//
// THREE CHECKS RUN UNCONDITIONALLY: CODEOWNERS health, branch currency, and project setup. Not
// because they are the most important, but because the entire mechanism is "notice it the next
// time I am working in this repo" — a verbose-only check would in practice never fire. Each is
// cheap enough to earn that (no network, a handful of subprocesses, a text parse) and each is
// SILENT when the repo is clean.
//
// NOTHING HERE MUTATES ANYTHING. No install, no fix, no file written into the working tree. A
// session-start hook that changes the repo is a hook that surprises somebody at the worst moment.

import { context } from './lib/output.ts';
import { exec, execArgv } from './lib/shell.ts';
import { getBranch, isGitRepo, getBaseBranch } from './lib/git.ts';
import { extractTicket } from './pre-bash.ts';
import { runPreCommitCheck } from './lib/pre-commit-check.ts';
import { runProjectHooksCheck } from './lib/project-hooks-check.ts';
import { runCodeownersCheck } from './lib/codeowners-check.ts';
import { getBehindCount } from './lib/behind-count-cache.ts';
import { findStalePlugins } from './lib/plugin-staleness.ts';
import {
  classifyWorktrees,
  formatCurrencyReport,
  formatBasePullReport,
  type WorktreeEntry,
  type BasePullResult,
} from './lib/branch-currency.ts';

const networkEnrichment = process.env.CLAUDE_SESSION_NETWORK === '1';
const verbose = process.env.CLAUDE_SESSION_VERBOSE === '1';

context('=== Session Context ===');
context('');
context(`Working Directory: ${process.cwd()}`);
context('');

if (isGitRepo()) {
  const branch = getBranch();
  const ticket = extractTicket(branch);

  context('Git Status:');
  context(`   Branch: ${branch}`);
  if (ticket) context(`   Ticket: ${ticket}`);

  if (!verbose) {
    const porcelain = exec('git status --porcelain', { timeout: 5000 });
    const count = porcelain ? porcelain.split('\n').filter((l) => l).length : 0;
    context(`   Uncommitted: ${count > 0 ? `${count} file(s)` : 'clean'}`);
    context('');
    context('   (set CLAUDE_SESSION_VERBOSE=1 for the full dump)');
    context('');
  } else {
    context('');

    context('Recent Commits:');
    const log = exec('git log --oneline -5', { timeout: 5000 });
    if (log) {
      for (const line of log.split('\n')) context(`   ${line}`);
    } else {
      context('   (no commits)');
    }
    context('');

    const porcelain = exec('git status --porcelain', { timeout: 5000 });
    if (porcelain) {
      const lines = porcelain.split('\n').filter((l) => l);
      context(`Uncommitted Changes: ${lines.length} file(s)`);
      for (const line of lines.slice(0, 5)) context(`    ${line}`);
      if (lines.length > 5) context(`    ... and ${lines.length - 5} more`);
      context('');
    }
  }

  // Pre-commit health. Verbose-only: it emits multi-line remediation when it finds drift, and the
  // drift it finds is not usually urgent.
  if (verbose) runPreCommitCheck(process.cwd());

  // --- Unconditional: project setup and CODEOWNERS health ------------------------------------
  // Both are silent on a healthy repo, and both answer "is the gate you think you have real?",
  // which is the question nobody thinks to ask until the gate has already failed to fire.
  runProjectHooksCheck(process.cwd());
  runCodeownersCheck(process.cwd());

  // --- Unconditional: branch currency ---------------------------------------------------------
  // Reads the cached behind-count (no network unless CLAUDE_SESSION_NETWORK=1), so it is cheap
  // enough to always run — and the cost of NOT knowing is acting on a stale tree.
  const baseBranch = getBaseBranch();
  if (baseBranch) {
    let basePull: BasePullResult | null = null;
    if (networkEnrichment) {
      exec('git fetch origin --prune --quiet 2>&1', { timeout: 10_000 });
    }

    const worktrees: WorktreeEntry[] = [];
    let baseWorktreePath: string | null = null;

    const wtListRaw = exec('git worktree list --porcelain 2>/dev/null', { timeout: 5000 });
    if (wtListRaw) {
      let wtPath = '';
      let wtBranch = '';
      for (const line of wtListRaw.split('\n')) {
        if (line.startsWith('worktree ')) {
          wtPath = line.slice('worktree '.length).trim();
        } else if (line.startsWith('branch refs/heads/')) {
          wtBranch = line.slice('branch refs/heads/'.length).trim();
        } else if (line === '') {
          if (wtPath && wtBranch) {
            if (wtBranch === baseBranch) {
              baseWorktreePath = wtPath;
            } else {
              worktrees.push({ path: wtPath, branch: wtBranch, clean: isClean(wtPath) });
            }
          }
          wtPath = '';
          wtBranch = '';
        }
      }
    }

    // Fast-forward the base checkout — the one branch that should ever fast-forward, and only
    // with --ff-only so a divergence surfaces as an error instead of a silent merge commit.
    // Skipped unless clean: a dirty base checkout is its own problem and `pull` would refuse.
    if (networkEnrichment && baseWorktreePath && isClean(baseWorktreePath)) {
      const out = execArgv(
        'git',
        ['-C', baseWorktreePath, 'pull', '--ff-only', 'origin', baseBranch],
        { timeout: 15_000 },
      );
      basePull = { ok: out !== null, output: out ?? 'pull --ff-only exited non-zero' };
    }

    for (const line of formatBasePullReport(baseBranch, basePull)) context(line);

    const rows = classifyWorktrees(worktrees, baseBranch, getBehindCount);
    const currencyLines = formatCurrencyReport(rows, baseBranch, { live: networkEnrichment });
    for (const line of currencyLines) context(line);
    if (currencyLines.length > 0 || (basePull && !basePull.ok)) context('');
  }
}

// Plugin staleness — read-only, no network. This session already loaded whatever plugin versions
// were current at launch. If a marketplace checkout has since advanced, the running session is
// stale and can only be freshened by a RESTART: Claude Code loads plugin content BEFORE
// SessionStart hooks fire, and there is no in-session reload.
if (verbose) {
  const stalePlugins = findStalePlugins();
  if (stalePlugins.length > 0) {
    context(`Plugins stale: ${stalePlugins.length} behind their marketplace checkout —`);
    for (const p of stalePlugins) {
      context(`   - ${p.name}: loaded ${p.installed}, latest ${p.latest}`);
    }
    context('   Restart Claude Code to pick these up; this session cannot reload them.');
    context('');
  }
}

context('=== Ready ===');
process.exit(0);

/**
 * Is a worktree clean? Both `git diff` arms must be quiet.
 *
 * argv, not a shell string: `path` comes out of `git worktree list`, so it is a filesystem path
 * this process did not author, and a directory named with a command substitution would run.
 */
function isClean(path: string): boolean {
  const unstaged = execArgv('git', ['-C', path, 'diff', '--quiet'], { timeout: 3000 });
  if (unstaged === null) return false;
  return execArgv('git', ['-C', path, 'diff', '--cached', '--quiet'], { timeout: 3000 }) !== null;
}
