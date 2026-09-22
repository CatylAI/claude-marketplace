// Branch-currency reporting for session start: how far each worktree has drifted from the base
// branch, and what (if anything) to do about it.
//
// Kept out of session-start.ts for two reasons. First, session-start.ts runs its work at module
// scope and ends in process.exit(0), so it cannot be imported by a test — anything worth
// asserting on has to live outside it. Second, this report prints in every session, which makes
// its correctness worth pinning.
//
// The reporting rule that drives the shapes below: a `null` behind count means the comparison
// COULD NOT BE MADE, not that the branch is up to date. Those two answers get different lines,
// because collapsing them is what lets a missing `origin/<base>` ref read as "all current".

export interface WorktreeEntry {
  path: string;
  branch: string;
  clean: boolean;
}

export interface WorktreeCurrency extends WorktreeEntry {
  // null = indeterminate (no origin/<base> ref, unreadable tree). Never conflate with 0.
  behind: number | null;
}

export function classifyWorktrees(
  worktrees: WorktreeEntry[],
  baseBranch: string,
  behindCount: (worktreePath: string, baseBranch: string) => number | null,
): WorktreeCurrency[] {
  return worktrees.map((wt) => ({ ...wt, behind: behindCount(wt.path, baseBranch) }));
}

export interface CurrencyReportOptions {
  // false → counts came from the last-fetched origin state, so say so rather than implying they
  // are live. Being wrong quietly is the failure mode this whole report exists to avoid.
  live: boolean;
}

/**
 * The lines to print for the feature worktrees. An empty array means everything is current —
 * print nothing. Worktrees with `behind === 0` are omitted; `behind === null` gets its own line.
 */
export function formatCurrencyReport(
  rows: WorktreeCurrency[],
  baseBranch: string,
  opts: CurrencyReportOptions,
): string[] {
  const behind = rows.filter((r) => r.behind !== null && r.behind > 0 && r.clean);
  const dirty = rows.filter((r) => r.behind !== null && r.behind > 0 && !r.clean);
  const unknown = rows.filter((r) => r.behind === null);

  const lines: string[] = [];
  const freshness = opts.live
    ? ''
    : ' (cached origin — set CLAUDE_SESSION_NETWORK=1 for a live fetch)';

  if (behind.length > 0) {
    const list = behind.map((r) => `${r.branch} (+${r.behind} behind ${baseBranch})`).join(', ');
    lines.push(`BEHIND origin/${baseBranch}${freshness}: ${list}`);
    // Deliberately NOT "rebase these". Being behind the base does not block a push, and a merge
    // queue rebases an in-flight change at merge time anyway.
    lines.push('   Not urgent — being behind does not block a push.');
    lines.push(`   To bring one current: git -C <worktree> pull --rebase origin ${baseBranch}`);
  }

  if (dirty.length > 0) {
    const list = dirty
      .map((r) => `${r.branch} (+${r.behind} behind, working tree dirty)`)
      .join(', ');
    lines.push(`BEHIND + DIRTY: ${list}`);
    lines.push('   Commit or stash first — a rebase will refuse to run over these.');
  }

  if (unknown.length > 0) {
    const list = unknown.map((r) => r.branch).join(', ');
    lines.push(`BEHIND-COUNT UNKNOWN for: ${list}`);
    // Naming the likely cause matters: the alternative reading of a silent report is "everything
    // is current", which is the dangerous one.
    lines.push(
      `   Could not compare against origin/${baseBranch} — usually a missing ref. Try: git fetch origin`,
    );
  }

  return lines;
}

export interface BasePullResult {
  ok: boolean;
  output: string;
}

/**
 * The base checkout is the ONE branch that should fast-forward, and `--ff-only` is what makes
 * that safe: it refuses rather than inventing a merge commit. A refusal is a real finding — local
 * base has commits of its own — so it is reported loudly and never worked around.
 */
export function formatBasePullReport(
  baseBranch: string,
  result: BasePullResult | null,
): string[] {
  if (result === null) return []; // no network this session, or no base checkout to pull
  if (result.ok) return [];

  return [
    `git pull --ff-only origin ${baseBranch} FAILED in the base checkout.`,
    `   --ff-only refuses only when local ${baseBranch} has commits origin does not have.`,
    `   Look at them (git log origin/${baseBranch}..${baseBranch}) — do NOT plain-pull (that`,
    `   merges) or reset --hard (that discards). ${result.output.split('\n')[0] ?? ''}`.trimEnd(),
  ];
}
