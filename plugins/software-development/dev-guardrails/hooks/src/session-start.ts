// SessionStart hook (matcher startup|resume|clear|fork): the repo facts worth knowing before the
// first prompt, said once.
//
// Plain stdout on SessionStart is added to Claude's context, and it is re-sent with every request
// for the rest of the session. So the default output is one line plus whatever the checks find,
// and nothing when there is nothing to say. Claude Code already puts the working directory and a
// git status snapshot in context, so this hook does not repeat them; it adds what Claude Code does
// not know: the branch's ticket key, worktree drift, and whether the repo's own gates are real.
//
// TWO OPT-IN SWITCHES, because a slow session start is a session start that gets disabled:
//
//   CLAUDE_SESSION_VERBOSE=1   recent commits, the first uncommitted paths, pre-commit health and
//                              plugin staleness on top of the default.
//   CLAUDE_SESSION_NETWORK=1   permits `git fetch` and a `--ff-only` pull of the base checkout.
//                              Without it, behind-counts come from the last-fetched origin state
//                              and the report says so.
//
// THREE CHECKS RUN UNCONDITIONALLY: CODEOWNERS health, branch currency, and project setup. The
// mechanism is "notice it the next time I work in this repo", so a verbose-only check would never
// fire. Each is cheap (no network, a few subprocesses, a text parse) and silent on a clean repo.
//
// NOTHING HERE MUTATES THE WORKING TREE. The only write is the optional base-checkout
// fast-forward, and only under CLAUDE_SESSION_NETWORK=1.
//
// FAILURE MODE: fail open, visibly. An unexpected error exits 1, which Claude Code shows the user
// as a non-blocking "hook error" notice; the session starts normally. Exit 0 with a stderr note
// would hide the failure in the debug log, and the user would believe the checks ran.

import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { context } from './lib/output.ts';
import { exec, execArgv } from './lib/shell.ts';
import { getBranch, isGitRepo, getBaseBranch } from './lib/git.ts';
import { extractTicket } from './lib/ticket.ts';
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

/**
 * The one-line summary: branch, ticket and uncommitted count. Pure, so the wording is testable
 * without a repository.
 */
export function formatSummaryLine(branch: string, ticket: string | null, uncommitted: number): string {
  const parts = [`Branch: ${branch}`];
  if (ticket) parts.push(`ticket ${ticket}`);
  parts.push(uncommitted > 0 ? `${uncommitted} uncommitted file(s)` : 'clean tree');
  return parts.join(' · ');
}

function run(): void {
  const networkEnrichment = process.env.CLAUDE_SESSION_NETWORK === '1';
  const verbose = process.env.CLAUDE_SESSION_VERBOSE === '1';

  if (isGitRepo()) {
    const branch = getBranch();
    const porcelain = exec('git status --porcelain', { timeout: 5000 });
    const changed = porcelain ? porcelain.split('\n').filter((l) => l) : [];
    context(formatSummaryLine(branch, extractTicket(branch), changed.length));

    if (verbose) {
      const log = exec('git log --oneline -5', { timeout: 5000 });
      context('Recent commits:');
      if (log) {
        for (const line of log.split('\n')) context(`   ${line}`);
      } else {
        context('   (no commits)');
      }
      if (changed.length > 0) context('Uncommitted:');
      for (const line of changed.slice(0, 5)) context(`   ${line}`);
      if (changed.length > 5) context(`   ... and ${changed.length - 5} more`);
      // Verbose-only: it emits multi-line remediation, and the drift it finds is rarely urgent.
      runPreCommitCheck(process.cwd());
    }

    // Unconditional: silent on a healthy repo; each answers "is the gate you think you have real?"
    runProjectHooksCheck(process.cwd());
    runCodeownersCheck(process.cwd());
    reportBranchCurrency(networkEnrichment);
  }

  // Plugin staleness: read-only, no network. Claude Code loads plugins before SessionStart hooks
  // fire and cannot reload them in-session, so the only remedy is a restart.
  if (verbose) {
    const stalePlugins = findStalePlugins();
    if (stalePlugins.length > 0) {
      context(`Plugins behind their marketplace checkout (restart Claude Code to load them):`);
      for (const p of stalePlugins) {
        context(`   - ${p.name}: loaded ${p.installed}, latest ${p.latest}`);
      }
    }
  }
}

function reportBranchCurrency(networkEnrichment: boolean): void {
  const baseBranch = getBaseBranch();
  if (!baseBranch) return;

  let basePull: BasePullResult | null = null;
  if (networkEnrichment) {
    execArgv('git', ['fetch', 'origin', '--prune', '--quiet'], { timeout: 10_000 });
  }

  const listed = parseWorktreeList(
    execArgv('git', ['worktree', 'list', '--porcelain'], { timeout: 5000 }) ?? '',
    baseBranch,
  );
  const baseWorktreePath = listed.basePath;
  const worktrees: WorktreeEntry[] = listed.others.map((wt) => ({ ...wt, clean: isClean(wt.path) }));

  // Fast-forward the base checkout only: --ff-only turns a divergence into an error instead of a
  // silent merge commit. Skipped unless clean, because `pull` would refuse a dirty tree anyway.
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
  for (const line of formatCurrencyReport(rows, baseBranch, { live: networkEnrichment })) {
    context(line);
  }
}

export interface ParsedWorktrees {
  /** Path of the worktree that has the base branch checked out, if any. */
  basePath: string | null;
  /** Every other worktree that is on a branch (detached worktrees are skipped). */
  others: Array<{ path: string; branch: string }>;
}

/**
 * Parse `git worktree list --porcelain`. Records are separated by blank lines; the output reaches
 * here trimmed, so the last record has no trailing blank line and is closed explicitly.
 */
export function parseWorktreeList(raw: string, baseBranch: string): ParsedWorktrees {
  const result: ParsedWorktrees = { basePath: null, others: [] };
  let wtPath = '';
  let wtBranch = '';
  for (const line of [...raw.split('\n'), '']) {
    if (line.startsWith('worktree ')) {
      wtPath = line.slice('worktree '.length).trim();
    } else if (line.startsWith('branch refs/heads/')) {
      wtBranch = line.slice('branch refs/heads/'.length).trim();
    } else if (line.trim() === '') {
      if (wtPath && wtBranch) {
        if (wtBranch === baseBranch) result.basePath = wtPath;
        else result.others.push({ path: wtPath, branch: wtBranch });
      }
      wtPath = '';
      wtBranch = '';
    }
  }
  return result;
}

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

// Only run as the hook entrypoint, so the test suite can import formatSummaryLine.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    run();
    process.exit(0);
  } catch (err) {
    process.stderr.write(`dev-guardrails session-start failed: ${String(err)}\n`);
    process.exit(1);
  }
}
