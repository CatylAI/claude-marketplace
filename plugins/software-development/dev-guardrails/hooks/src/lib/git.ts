// Git helpers used by the destructive-git guards.
//
// Every helper accepts an optional cwd so a hook can evaluate the repo the Bash command
// actually runs in. Without it, git resolves against the hook PROCESS cwd (usually the
// main checkout) — wrong for worktree flows, where the guarded command targets a
// different branch and tree. Callers pass the PreToolUse payload's `cwd`.
//
// Nothing here throws. A missing git, a directory that is not a repo, and a timeout all
// degrade to the conservative answer rather than crashing the hook: a hook that throws
// is a hook that gets uninstalled.

import { execSync, type ExecSyncOptionsWithStringEncoding } from 'node:child_process';

function gitOpts(cwd?: string): ExecSyncOptionsWithStringEncoding {
  const opts: ExecSyncOptionsWithStringEncoding = {
    encoding: 'utf-8',
    stdio: ['pipe', 'pipe', 'pipe'],
    timeout: 5_000,
  };
  // Only set cwd when given, so execSync inherits the process cwd otherwise.
  if (cwd) opts.cwd = cwd;
  return opts;
}

/** The checked-out branch, or `detached` when there is none (or no repo at all). */
export function getBranch(cwd?: string): string {
  try {
    return execSync('git branch --show-current', gitOpts(cwd)).trim() || 'detached';
  } catch {
    return 'detached';
  }
}

/** True when `cwd` (or the process cwd) sits inside a git repository. */
export function isGitRepo(cwd?: string): boolean {
  try {
    execSync('git rev-parse --git-dir', gitOpts(cwd));
    return true;
  } catch {
    return false;
  }
}

/**
 * Branch names this module will hand back. Anything else is refused as undeterminable.
 *
 * NOT cosmetic validation. `getBaseBranch()` reads whatever the REMOTE advertises through
 * `refs/remotes/origin/HEAD`, and its value flows into git invocations elsewhere in this
 * package. Git's own rules are far more permissive than they look: `x$(id)`, `x${IFS}y` and
 * `` x`id` `` are all legal ref names (verified with `git check-ref-format --branch` — only a
 * literal space is refused, and `$IFS` substitutes for one). So a branch name is simultaneously
 * a valid ref and a working command substitution, and cloning a hostile repository would be
 * enough to reach it. A leading `-` is refused too: in argv form git reads such an argument as a
 * FLAG rather than a ref, so `--upload-pack=…` would smuggle an option in with no shell present.
 */
const SAFE_BRANCH_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;

/**
 * The repo's default branch, or null when it cannot be determined.
 *
 * Asks the REMOTE first: `refs/remotes/origin/HEAD` is the only authoritative source, and it is
 * correct for repos whose default is neither `main` nor `master` (`develop`, `trunk`, …).
 * Probing local ref existence alone returns null for those repos, so every behind-count keyed
 * off this helper is skipped entirely rather than being wrong loudly.
 *
 * A name that fails SAFE_BRANCH_RE is refused OUTRIGHT rather than falling through to the
 * local-ref probe. Returning `main` there would substitute a plausible answer for a remote that
 * is doing something wrong, which is the "could not check" → "fine" conflation this package
 * refuses everywhere else. Every caller already handles null.
 */
export function getBaseBranch(cwd?: string): string | null {
  try {
    const ref = execSync('git symbolic-ref --quiet refs/remotes/origin/HEAD', gitOpts(cwd)).trim();
    const name = ref.replace(/^refs\/remotes\/origin\//, '');
    // Guard against an unexpected shape: only accept it if the prefix actually stripped.
    if (name && name !== ref) {
      return SAFE_BRANCH_RE.test(name) ? name : null;
    }
  } catch {
    /* origin/HEAD unset — fall through to the local-ref probe */
  }

  try {
    execSync('git show-ref --verify --quiet refs/heads/main', gitOpts(cwd));
    return 'main';
  } catch {
    try {
      execSync('git show-ref --verify --quiet refs/heads/master', gitOpts(cwd));
      return 'master';
    } catch {
      return null;
    }
  }
}

/**
 * Paths that are NEW in the working tree: untracked (`??`) plus staged adds (`A`).
 *
 * SEPARATE FROM getChangedFiles() on purpose. That helper runs `git diff` and `git diff
 * --cached`, and NEITHER shows an untracked file — so a brand-new file Claude has just written
 * is invisible to it. Any consumer that reacts to a new artifact appearing would be dead in
 * exactly the case it exists for if it were built on getChangedFiles().
 *
 * RENAME DESTINATIONS ARE DELIBERATELY EXCLUDED. Git reports a rename as `R`, not `A`, precisely
 * because the two differ: a moved file is not a new artifact, and counting it as one fires on
 * every pure-move refactor. The `R`/`C` records are still PARSED — each carries a second
 * NUL-terminated original-path field that must be consumed or the stream desyncs and the
 * following entry is read as a path.
 *
 * `-z` rather than plain `--porcelain`: with `-z`, git emits raw NUL-terminated paths and never
 * applies the C-style quoting `core.quotePath` does to paths with spaces or non-ASCII bytes.
 * Parsing quoted output correctly means unescaping it; not parsing it means silently dropping
 * those files.
 */
export function getAddedFiles(cwd?: string): string[] {
  try {
    const out = execSync('git status --porcelain -z', gitOpts(cwd));
    const records = out.split('\0');
    const added: string[] = [];
    for (let i = 0; i < records.length; i++) {
      const rec = records[i];
      // Shortest meaningful record is `XY ` plus a one-character path.
      if (!rec || rec.length < 4) continue;
      const x = rec[0]!;
      const y = rec[1]!;
      const path = rec.slice(3);
      if (x === 'R' || x === 'C') {
        i++;
        continue;
      }
      if ((x === '?' && y === '?') || x === 'A' || y === 'A') added.push(path);
    }
    return [...new Set(added)];
  } catch {
    return [];
  }
}

/**
 * Changed paths in the working tree — staged plus unstaged, deduplicated, repo-relative.
 * Empty array on any failure (no changes, not a repo, git absent).
 */
export function getChangedFiles(cwd?: string): string[] {
  try {
    const unstaged = execSync('git diff --name-only', gitOpts(cwd));
    const staged = execSync('git diff --cached --name-only', gitOpts(cwd));
    const all = `${unstaged}\n${staged}`
      .split('\n')
      .map((p) => p.trim())
      .filter(Boolean);
    return [...new Set(all)];
  } catch {
    return [];
  }
}

/**
 * True only when both the index and the working tree are clean.
 *
 * Returns FALSE on any failure. That direction is deliberate: the sole caller uses this
 * to decide whether `git reset --hard` may proceed, and "I could not tell" must not read
 * as "nothing to lose".
 */
export function isWorkingTreeClean(cwd?: string): boolean {
  try {
    execSync('git diff --quiet', gitOpts(cwd));
    execSync('git diff --cached --quiet', gitOpts(cwd));
    return true;
  } catch {
    return false;
  }
}
