// Destructive git: force pushes, protected-branch rewrites and deletes, and commands that
// discard uncommitted work.
//
// Fail direction, per check:
//   - force/delete/mirror push: decided from argv alone, no I/O, so no failure path.
//   - discarding work (reset --hard, checkout/restore/switch that discard): fails CLOSED.
//     "Could not tell whether the tree is clean" (git error, unresolvable `cd "$X"`) reads
//     as dirty. A false block is cheap (stash first); a false allow loses work for good.
//   - protected-branch lookup of the CURRENT branch: fails OPEN. An unreadable branch reads
//     as `detached`, which is not protected; the bare-force rule still applies regardless.

import { parseCommand } from '../lib/bash-parse.ts';
import {
  FORCE_PUSH_ALLOW_MARKER, escapeLine, protectedBranches, waived,
} from './config.ts';
import { existsSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { analyzePush, gitInvocations, resolveLongOption, type GitAliasLookup, type GitInvocation } from './git-invocation.ts';

// Collaborators injected so the decision logic is unit-testable without shelling out to git.
export interface GitForceDeps {
  getBranch: (cwd?: string) => string;
  isWorkingTreeClean: (cwd?: string) => boolean;
  /** Resolves a git alias. Optional: without it, aliases are not expanded. */
  gitAlias?: GitAliasLookup;
  /**
   * Does `path` name an existing file in the command's directory? Used to tell
   * `git checkout <file>` (a discard) from `git checkout <branch>`. Optional and injectable;
   * defaults to a real filesystem check against the invocation's directory.
   */
  pathExists?: (path: string, dir: string | undefined | null) => boolean;
}

function realPathExists(path: string, dir: string | undefined | null): boolean {
  if (path.includes('$') || path.includes('`')) return false;
  const base = typeof dir === 'string' ? dir : process.cwd();
  try {
    return existsSync(isAbsolute(path) ? path : resolve(base, path));
  } catch {
    return false;
  }
}

/**
 * Does this push target a protected branch by an explicit refspec?
 *
 * Space-separated (`origin main`), colon refspec (`HEAD:main`), fully-qualified
 * (`refs/heads/main`) and the force shorthand (`+main`) all count. A branch whose last
 * path segment happens to be `main` (`feature/main`) does not: it is its own branch.
 */
export function targetsProtectedBranch(command: string, branches: string[]): boolean {
  if (branches.length === 0) return false;
  return gitInvocations(command, undefined)
    .filter((g) => g.sub === 'push' || g.sub === 'send-pack')
    .some((g) => analyzePush(g.args).destinations.some((d) => branches.includes(d)));
}

const BARE_FORCE_MESSAGE = (branches: string[]): string => `❌ BLOCKED: git push --force is prohibited — use --force-with-lease

  Tried:    git push --force (or -f, a +refspec, or --mirror)
  Why:      A bare --force overwrites the remote unconditionally, including commits that
            landed after your last fetch. --force-with-lease refuses in exactly that case,
            which is the difference between rewriting your own history and destroying
            someone else's.
  Instead:  git push --force-with-lease origin <branch>
            Fetch immediately before pushing: the lease only protects against commits you
            have NOT fetched, so a stale fetch makes it as blunt as --force.

  Protected branches (${branches.join(', ')}) are never force-pushable; set
  CLAUDE_PROTECTED_BRANCHES to change the list.
${escapeLine(FORCE_PUSH_ALLOW_MARKER)}`;

const PROTECTED_LEASE_MESSAGE = (branches: string[]): string => `❌ BLOCKED: force-pushing a protected branch (${branches.join(', ')}) is prohibited

  Why:      it rewrites shared history for every other contributor
  Instead:  create a new commit that undoes the change:
              git revert HEAD
            Local branch merely BEHIND the remote?  git pull --ff-only origin <branch>

  Set CLAUDE_PROTECTED_BRANCHES to change which branches this covers.`;

const PROTECTED_DELETE_MESSAGE = (target: string): string => `❌ BLOCKED: this push deletes the protected branch \`${target}\`

  Why:      deleting a shared branch on the remote removes it for every contributor and
            every open merge request that targets it
  Instead:  delete the branch you meant (git push origin --delete <feature-branch>), or ask
            the repository owner to do it through the forge's branch settings.
${escapeLine(FORCE_PUSH_ALLOW_MARKER)}`;

function evaluatePush(
  g: GitInvocation,
  deps: GitForceDeps,
  branches: string[],
  handOff: boolean,
): string | null {
  if (handOff) return null;
  const plan = analyzePush(g.args);

  if (plan.bareForce || plan.mirror) return BARE_FORCE_MESSAGE(branches);

  const protectedDelete = plan.deletes.find((d) => branches.includes(d));
  if (protectedDelete) return PROTECTED_DELETE_MESSAGE(protectedDelete);

  if (!plan.lease) return null;

  // Only now is the current branch needed, for an implicit or HEAD destination. A plain
  // push never pays for the git call.
  const current = deps.getBranch(g.dir ?? undefined);
  const destinations = plan.destinations.map((d) => (d === 'HEAD' ? current : d));
  if (plan.implicitCurrent) destinations.push(current);
  const hitsProtected = plan.allBranches || destinations.some((d) => branches.includes(d));

  // ALLOWED on every non-protected branch. A lease push to a feature branch is a normal
  // part of resolving a rebase, and blocking it outright only teaches people to reach
  // for the escape marker by reflex. The lease is not a guarantee: it protects against
  // commits you have NOT fetched. On a shared branch, fetch immediately before pushing.
  // No branch-name exemption: the source branch's name says nothing about whether rewriting
  // the protected DESTINATION is safe, and an exemption keyed on it let
  // `git push --force-with-lease origin hotfix/x:main` rewrite main.
  if (hitsProtected) return PROTECTED_LEASE_MESSAGE(branches);
  return null;
}

// Long options of the discard-capable subcommands, for prefix resolution (git accepts `--har`
// for `--hard`, `--discard` for `--discard-changes`, and so on).
const RESET_OPTS = ['--soft', '--mixed', '--hard', '--merge', '--keep', '--quiet', '--pathspec-from-file'];
const CHECKOUT_OPTS = ['--force', '--quiet', '--merge', '--patch', '--detach', '--ours', '--theirs', '--track', '--orphan', '--pathspec-from-file'];
const RESTORE_OPTS = ['--staged', '--worktree', '--source', '--patch', '--quiet', '--ours', '--theirs', '--merge', '--pathspec-from-file'];
const SWITCH_OPTS = ['--create', '--force-create', '--detach', '--discard-changes', '--force', '--quiet', '--track', '--orphan'];
const CLEAN_OPTS = ['--force', '--dry-run', '--interactive', '--quiet', '--exclude'];

/** True when `a` contains `long` (or a unique prefix of it), or a short flag bundling `short`. */
function hasFlag(a: readonly string[], long: string, opts: readonly string[], short?: string): boolean {
  return a.some((w) => {
    if (w.startsWith('--')) return resolveLongOption(w.split('=', 1)[0]!, opts) === long;
    if (short && w.startsWith('-') && w.length > 1) return w.slice(1).includes(short);
    return false;
  });
}

/**
 * Does this invocation discard uncommitted working-tree changes? `exists` reports whether a
 * pathspec names a real file in the command's directory, so `git checkout <file>` — which
 * overwrites that file from the index — is caught while `git checkout <branch>` is not.
 */
function discardsWork(g: GitInvocation, exists: (path: string) => boolean): string | null {
  const a = g.args;
  const positionalsAfter = (skipRefs: number): string[] => {
    const dashDash = a.indexOf('--');
    if (dashDash >= 0) return a.slice(dashDash + 1);
    return a.filter((w) => !w.startsWith('-')).slice(skipRefs);
  };
  const looksLikePath = (w: string): boolean =>
    w === '.' || w === '..' || w.startsWith('./') || w.startsWith(':/') || w.includes('*') || exists(w);

  if (g.sub === 'reset') return hasFlag(a, '--hard', RESET_OPTS) ? 'reset --hard' : null;

  if (g.sub === 'checkout') {
    const dashDash = a.indexOf('--');
    if (dashDash >= 0 && dashDash < a.length - 1) return 'checkout -- <path>';
    if (hasFlag(a, '--force', CHECKOUT_OPTS, 'f')) return 'checkout --force';
    // Without `--`, a positional may still be a path. `git checkout <ref> <path>` overwrites
    // <path>; `git checkout <path>` does too when <path> is a real file (else it is a branch).
    const positional = a.filter((w) => !w.startsWith('-'));
    if (positional.some(looksLikePath)) return 'checkout <path>';
    // Two positionals: the second is a pathspec regardless of whether the file exists yet.
    if (positional.length >= 2) return 'checkout <path>';
    return null;
  }

  if (g.sub === 'checkout-index') {
    return hasFlag(a, '--force', ['--force', '--all', '--index', '--quiet', '--prefix'], 'f')
      ? 'checkout-index -f' : null;
  }

  if (g.sub === 'read-tree') {
    const update = a.some((w) => w === '-u' || (w.startsWith('-') && !w.startsWith('--') && w.includes('u')));
    return update && a.includes('--reset') ? 'read-tree -u --reset' : null;
  }

  if (g.sub === 'restore') {
    const staged = hasFlag(a, '--staged', RESTORE_OPTS, 'S');
    const worktree = hasFlag(a, '--worktree', RESTORE_OPTS, 'W');
    if (staged && !worktree) return null; // unstage only: the working tree keeps its changes
    const paths = a.filter((w) => !w.startsWith('-'));
    return paths.length > 0 ? 'restore <path>' : null;
  }

  if (g.sub === 'switch') {
    return hasFlag(a, '--discard-changes', SWITCH_OPTS) || hasFlag(a, '--force', SWITCH_OPTS, 'f')
      ? 'switch --discard-changes'
      : null;
  }

  if (g.sub === 'clean') {
    // `-f`/`--force` deletes untracked files; `-n`/`--dry-run` only lists them.
    const force = hasFlag(a, '--force', CLEAN_OPTS, 'f');
    const dryRun = hasFlag(a, '--dry-run', CLEAN_OPTS, 'n');
    return force && !dryRun ? 'clean -f' : null;
  }

  return null;
}

const DISCARD_MESSAGE = (what: string): string => what === 'reset --hard'
  ? `❌ BLOCKED: git reset --hard discards uncommitted work permanently

  Why:      it destroys every uncommitted change with no recovery path
  Instead:  git stash                    ← save changes temporarily (recoverable)
            git stash push -m "message"  ← save with a description
            git stash pop                ← restore later

            If you truly want to discard:
              git stash && git stash drop  ← explicit two-step`
  : `❌ BLOCKED: git ${what} discards working tree changes permanently

  Why:      the working tree has uncommitted changes, and this overwrites them with no
            recovery path
  Instead:  git stash                    ← save changes temporarily (recoverable)
            git restore --staged <file>  ← unstage only (keeps working tree changes)
            git diff -- <path>           ← look first at what would be lost`;

/**
 * Pure decision: the block-reason message, or null to allow.
 *
 * isWorkingTreeClean is only consulted for a command that would discard work, and
 * getBranch only for a lease push, so an ordinary `git push` costs no extra git call.
 */
export function evaluateGitForce(
  command: string,
  cwd: string | undefined,
  deps: GitForceDeps,
  branches: string[] = protectedBranches(),
): string | null {
  // Cheap exit before alias lookups: no git anywhere in the parsed line.
  if (!parseCommand(command).some((c) => c.head === 'git')) return null;

  // The marker opts a push out of the FORCE checks only. The discard guards below still
  // apply — it is narrow on purpose.
  const handOff = waived(command, FORCE_PUSH_ALLOW_MARKER);

  for (const g of gitInvocations(command, cwd, deps.gitAlias)) {
    if (g.sub === 'push' || g.sub === 'send-pack') {
      const reason = evaluatePush(g, deps, branches, handOff);
      if (reason) return reason;
      continue;
    }
    const exists = (path: string): boolean => (deps.pathExists ?? realPathExists)(path, g.dir);
    const discard = discardsWork(g, exists);
    if (!discard) continue;
    // Judged against the COMMAND's directory, not the hook process cwd: a clean main
    // checkout must not green-light a reset --hard in a dirty worktree.
    const clean = g.dir === null ? false : deps.isWorkingTreeClean(g.dir);
    if (!clean) return DISCARD_MESSAGE(discard);
  }
  return null;
}
