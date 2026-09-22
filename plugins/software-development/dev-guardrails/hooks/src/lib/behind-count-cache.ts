// Behind-count cache — how many commits a worktree is behind `origin/<base>`, memoised.
//
// The enumeration shells out `git rev-list --count HEAD..origin/<base>` per worktree, which is
// cheap individually and noisy when session start fans out across many worktrees on every
// session. Cache the answer for 10 minutes, keyed by BOTH the worktree's HEAD sha AND
// `origin/<base>`'s tip sha.
//
// BOTH SHAS MUST BE PINNED. Omitting the base-side sha opens a stale-cache hole: a `git fetch`
// during the same session advances `origin/<base>`, but a key that ignores it still hits the
// pre-fetch entry and reports a behind count that is quietly wrong for the rest of the TTL.
//
// Location: a scratch file under lib/state-dir.ts's root — an OS temp directory by default,
// overridable with `CLAUDE_GUARDRAILS_STATE_DIR`. This plugin does not write into the user's
// home Claude directory, and it does not drop files into the repository it is watching. The
// cache is pure derived data: losing it costs one `git rev-list`.
//
// Best-effort throughout — a corrupt, unwritable or missing file is treated as an empty cache.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { execArgv } from './shell.ts';
import { stateFile } from './state-dir.ts';

const TTL_MS = 10 * 60 * 1000; // 10 minutes

/**
 * Branch names this module will hand to git. Anything else is refused as undeterminable.
 *
 * NOT cosmetic validation. `baseBranch` is remote-supplied — it comes from whatever
 * `refs/remotes/origin/HEAD` advertises — and git's own rules accept far more than looks safe:
 * `x$(id)`, `x${IFS}y` and `` x`id` `` are all legal ref names (verified with
 * `git check-ref-format --branch`; only a literal space is refused, and `$IFS` substitutes for
 * one). So a branch name is simultaneously a valid ref and a working command substitution.
 *
 * The argv-based execution below is the primary defence — no shell runs, so a substitution is
 * just bytes in an argument. This predicate is defence in depth, and it also closes the OTHER
 * argv hazard: an argument beginning with `-` is read by git as a FLAG, not a ref, so a branch
 * named `--upload-pack=…` would smuggle an option into `git rev-parse` even with no shell
 * involved. Leading `-` is therefore rejected explicitly.
 */
const SAFE_BRANCH_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;

export function isSafeBranchName(branch: string): boolean {
  if (!branch || branch.startsWith('-')) return false;
  return SAFE_BRANCH_RE.test(branch);
}

export interface CacheEntry {
  behind: number;
  ts: number; // ms since epoch
}

export interface CacheShape {
  [key: string]: CacheEntry;
}

/**
 * Location on disk, or null when no writable scratch directory could be made.
 * Exported for the test suite.
 */
export function cachePath(env: NodeJS.ProcessEnv = process.env): string | null {
  return stateFile('behind-count-cache.json', env);
}

function nowMs(): number {
  return Date.now();
}

function loadCache(path: string): CacheShape {
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf-8'));
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as CacheShape;
    }
    return {};
  } catch {
    return {};
  }
}

function saveCache(path: string, cache: CacheShape): void {
  try {
    writeFileSync(path, JSON.stringify(cache), 'utf-8');
  } catch {
    /* best-effort */
  }
}

// Every git call in this file goes through execArgv — argv, no shell. A worktree path comes from
// `git worktree list` and a branch name from the remote, so neither is text this process authored.
// Double quotes in a shell string are NOT a defence: `$(…)` and backticks substitute inside them.
function headSha(worktreePath: string): string | null {
  const out = execArgv('git', ['-C', worktreePath, 'rev-parse', 'HEAD'], { timeout: 3000 });
  return out ? out.trim() || null : null;
}

// `origin/<base>`'s tip sha, resolved through the worktree's local remote-tracking ref. When a
// session fetches, this advances, and that MUST invalidate the cache. Null when the ref is
// missing (a clone that never fetched) — the caller then degrades to computing fresh, which is
// correct: there is no base-side pin to cache against.
function originBaseSha(worktreePath: string, baseBranch: string): string | null {
  if (!isSafeBranchName(baseBranch)) return null;
  const out = execArgv('git', ['-C', worktreePath, 'rev-parse', `origin/${baseBranch}`], {
    timeout: 3000,
  });
  return out ? out.trim() || null : null;
}

// Returns the behind count, or `null` when it CANNOT BE DETERMINED — a missing `origin/<base>`
// ref, an unreadable worktree, unparseable output. Never conflate the two: returning 0 on
// failure makes "there is no origin/<base> to compare against" read as "the branch is up to
// date", which is the more dangerous answer because it silences the report entirely.
function computeBehind(worktreePath: string, baseBranch: string): number | null {
  if (!isSafeBranchName(baseBranch)) return null;
  const out = execArgv(
    'git',
    ['-C', worktreePath, 'rev-list', '--count', `HEAD..origin/${baseBranch}`],
    { timeout: 5000 },
  );
  if (out === null) return null;
  const n = parseInt(out.trim(), 10);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/** Optional overrides for tests — inject a fake clock, disk path and shellers. */
export interface CacheDeps {
  now?: () => number;
  path?: string | null;
  getHeadSha?: (worktreePath: string) => string | null;
  getOriginBaseSha?: (worktreePath: string, baseBranch: string) => string | null;
  computeBehind?: (worktreePath: string, baseBranch: string) => number | null;
}

/**
 * The behind count for `worktreePath` against `origin/<baseBranch>`, or `null` when it could not
 * be determined. Callers MUST distinguish `null` from `0` — see computeBehind above.
 *
 * A cache hit costs two `git rev-parse` calls and no network. A miss shells out via
 * `git rev-list` and writes back. A `null` result is never cached, so a transient failure does
 * not stick for the rest of the TTL window.
 */
export function getBehindCount(
  worktreePath: string,
  baseBranch: string,
  deps: CacheDeps = {},
): number | null {
  // Refused at the door, before any subprocess or disk read: a branch name that is not a plain
  // ref cannot be compared against, and "could not determine" is exactly what null means.
  if (!isSafeBranchName(baseBranch)) return null;

  const now = deps.now ?? nowMs;
  const path = deps.path !== undefined ? deps.path : cachePath();
  const shaFn = deps.getHeadSha ?? headSha;
  const originShaFn = deps.getOriginBaseSha ?? originBaseSha;
  const computeFn = deps.computeBehind ?? computeBehind;

  // No writable scratch location: still answer the question, just without memoising it.
  if (!path) return computeFn(worktreePath, baseBranch);

  const sha = shaFn(worktreePath);
  if (!sha) return computeFn(worktreePath, baseBranch);
  const baseSha = originShaFn(worktreePath, baseBranch);
  if (!baseSha) return computeFn(worktreePath, baseBranch);

  const key = `${worktreePath}:${sha}:${baseBranch}:${baseSha}`;
  const cache = loadCache(path);
  const hit = cache[key];
  if (hit && now() - hit.ts < TTL_MS) return hit.behind;

  const behind = computeFn(worktreePath, baseBranch);
  // Never persist an indeterminate result: the on-disk shape has no sentinel for it, so a cached
  // null would re-read as 0 and resurrect exactly the bug computeBehind guards against.
  if (behind === null) return null;
  cache[key] = { behind, ts: now() };

  // Opportunistic eviction: drop anything past TTL.
  for (const k of Object.keys(cache)) {
    if (now() - cache[k].ts >= TTL_MS) delete cache[k];
  }

  saveCache(path, cache);
  return behind;
}
