// PreToolUse hook: Bash policy enforcement.
//
// Gates, in the order main() runs them:
//   Gate A  never PRINT a secret into the transcript
//   Gate C  never PUBLISH a secret through a forge CLI
//   then the reversible-damage guards: rm -rf, forge policy, TTY, terraform backend,
//   destructive git, commit-message shape, branch-creation nudge.
//
// Exit codes: 0 = allow, 2 = block. Non-blocking notes go to stdout via context().
//
// Everything policy-shaped is read from the environment with a permissive default, so
// installing this plugin with no configuration blocks nothing that a default-configured
// project does. A gate that fires on ordinary work gets switched off, and switching it
// off takes the destructive-git guards down with it.

import { readStdin } from './lib/stdin.ts';
import { block, allow, context } from './lib/output.ts';
import { isWorkingTreeClean, getBranch } from './lib/git.ts';
import {
  GH_CLI, GLAB_CLI,
  GIT_COMMIT, GIT_COMMAND, TERRAFORM_INIT, CONVENTIONAL_COMMIT,
} from './lib/patterns.ts';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findSecrets, isSecretVarName } from './lib/secrets.ts';
import { classifyExpansions, extractHeredocs, hasAllowMarker, parseCommand } from './lib/bash-parse.ts';

type Env = Record<string, string | undefined>;

// --- Configuration ------------------------------------------------------------------

/**
 * The generic escape hatch. Appended as a trailing comment it lifts any rule that has an
 * escape at all. Rule-specific markers below are narrower; either one satisfies its own
 * rule, and because the check is a substring test, a specific marker also satisfies the
 * generic one.
 *
 * Deliberately visible: the marker stays in the transcript, so a reviewer can see exactly
 * what was waived and on which command.
 */
export const ALLOW_MARKER = '# claude-allow';
export const RMRF_ALLOW_MARKER = '# claude-allow-rm-rf';
export const FORCE_PUSH_ALLOW_MARKER = '# claude-allow-force-push';
export const SECRET_PRINT_ALLOW_MARKER = '# claude-allow-secret-print';

/** True when `command` carries the rule's own marker, or the generic one. */
function waived(command: string, specific: string): boolean {
  return hasAllowMarker(command, specific) || hasAllowMarker(command, ALLOW_MARKER);
}

/**
 * Which forge this project uses.
 *
 * `both` is the DEFAULT and blocks neither CLI. A hook shipped to an unknown project
 * cannot know which forge it uses, and guessing wrong makes every session unusable —
 * so the unconfigured answer is "do not judge the CLI at all". A project that has
 * actually chosen one opts in by exporting CLAUDE_FORGE, and only then does using the
 * other forge's CLI become a block.
 */
export type Forge = 'github' | 'gitlab' | 'both';
export const DEFAULT_FORGE: Forge = 'both';

export function resolveForge(env: Env = process.env): Forge {
  const raw = (env.CLAUDE_FORGE ?? '').trim().toLowerCase();
  if (raw === 'github' || raw === 'gitlab' || raw === 'both') return raw;
  // Unset, empty, or a value this hook does not understand. An unrecognised value must
  // not be treated as a declaration: the permissive default is the safe reading.
  return DEFAULT_FORGE;
}

/** Ticket-key shape used for branch-name and commit-scope guidance. */
export const DEFAULT_TICKET_PATTERN = '[A-Z][A-Z0-9]+-[0-9]+';

export function ticketPattern(env: Env = process.env): string {
  return (env.CLAUDE_TICKET_PATTERN ?? '').trim() || DEFAULT_TICKET_PATTERN;
}

/**
 * The ticket key carried by a branch name, or null.
 *
 * An unparseable CLAUDE_TICKET_PATTERN falls back to the default rather than throwing:
 * a bad regex in someone's shell profile must not take every Bash call down with it.
 */
export function extractTicket(branch: string, pattern: string = ticketPattern()): string | null {
  let re: RegExp;
  try {
    re = new RegExp(pattern);
  } catch {
    re = new RegExp(DEFAULT_TICKET_PATTERN);
  }
  const m = branch.match(re);
  return m ? m[0] : null;
}

/** Branches that may not be force-pushed, and that a commit warns about. */
export const DEFAULT_PROTECTED_BRANCHES = ['main', 'master'] as const;

export function protectedBranches(env: Env = process.env): string[] {
  const raw = (env.CLAUDE_PROTECTED_BRANCHES ?? '').trim();
  if (!raw) return [...DEFAULT_PROTECTED_BRANCHES];
  const list = raw.split(',').map((s) => s.trim()).filter(Boolean);
  return list.length > 0 ? list : [...DEFAULT_PROTECTED_BRANCHES];
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Does this push target a protected branch, in any refspec form?
 *
 * Space-separated (`origin main`), colon refspec (`HEAD:main`), fully-qualified
 * (`refs/heads/main`) and the force shorthand (`+main`) all count. A bare `/` is
 * deliberately NOT a delimiter: that would match any branch whose final segment is
 * `main` (`feature/main`), which both blocks a legitimate push to it and silently
 * exempts it from the protected-branch rule.
 */
export function targetsProtectedBranch(command: string, branches: string[]): boolean {
  if (branches.length === 0) return false;
  const alt = branches.map(escapeRe).join('|');
  return new RegExp(`(?:[\\s:+]|refs/heads/)(?:${alt})(?:\\s|$)`).test(command);
}

// --- rm -rf ---------------------------------------------------------------------------
//
// Ephemeral prefixes that tooling churns on every run. A blocking `rm -rf` on these would
// break legitimate cleanup — but the block still fires for anything outside the list, and
// a command that mixes a listed target with an unlisted one falls back to the block
// (unanimous match required, no partial exemptions).
export const RMRF_WHITELIST_PREFIXES = [
  'node_modules/',
  'dist/',
  'build/',
  'coverage/',
  '.next/',
  '.turbo/',
  '.cache/',
  '__pycache__/',
  '.pytest_cache/',
  '.mypy_cache/',
  '.worktrees/',
  '.claude/worktrees/',
] as const;

export type RmRfDecision =
  | { kind: 'allow' }
  | { kind: 'allow-with-warning'; message: string }
  | { kind: 'block'; reason: string };

type RmSegment = { recursive: boolean; force: boolean; targets: string[] };

// Parse EVERY rm segment of a compound command independently, recording each segment's own
// flags and positional targets.
//
// Flags MUST be read per segment, never from the joined command string. A compound like
// `grep -R pattern src && rm -f /tmp/out.md` carries `-R` on the *grep* segment; scoring
// the whole string would count that as "recursive", pair it with the rm's `-f`, and block a
// plain single-file `rm -f`. That collision is routine, and the only workaround was the
// escape marker — which trains operators to bypass the guard for commands that were never
// destructive.
//
// Targets are still collected across every rm segment, because
// `rm -rf .worktrees/x && rm -rf /etc` has TWO destructive segments and inspecting only the
// first would let the second run unchecked. Only tokens BEFORE a `#` shell comment count.
// Surrounding quotes are stripped so `rm -rf "dist/"` still matches the whitelist.
function parseRmSegments(command: string): RmSegment[] {
  const parsed: RmSegment[] = [];
  for (const seg of command.split(/[;&|]+/)) {
    if (!/^\s*rm\s/.test(seg)) continue;
    const segment: RmSegment = { recursive: false, force: false, targets: [] };
    for (const raw of seg.trim().split(/\s+/).slice(1)) {
      if (raw.startsWith('#')) break; // shell comment — halt this segment's parsing
      if (raw.length === 0) continue;
      if (raw.startsWith('--')) {
        if (raw === '--recursive') segment.recursive = true;
        if (raw === '--force') segment.force = true;
        continue;
      }
      if (raw.startsWith('-')) {
        // Short flags may be bundled (`-rf`, `-Rf`) or separate (`-r -f`) — accumulate both.
        if (/[rR]/.test(raw)) segment.recursive = true;
        if (/[fF]/.test(raw)) segment.force = true;
        continue;
      }
      segment.targets.push(raw.replace(/^["']|["']$/g, ''));
    }
    parsed.push(segment);
  }
  return parsed;
}

/**
 * Pure decision for `rm -rf`.
 *
 * `platform` is injectable so BOTH arms are testable; it defaults to the real platform.
 * The macOS arm blocks and names `trash`; every other platform must NOT, because `trash`
 * is a macOS-only Homebrew binary. Emitted unconditionally, the block refuses a working
 * command on Linux and substitutes one that does not exist — which is worse than no guard:
 * it stops the work and offers no route through.
 */
export function evaluateRmRf(
  command: string,
  platform: string = process.platform,
): RmRfDecision {
  if (!/(?:^|[;&|]\s*)rm\s/.test(command)) return { kind: 'allow' };

  // Only segments that are themselves recursive AND force are destructive. A sibling
  // segment's `-R`/`-r` (grep, ls, cp) must never combine with this rm's `-f`.
  const destructive = parseRmSegments(command).filter((s) => s.recursive && s.force);
  if (destructive.length === 0) return { kind: 'allow' };

  if (waived(command, RMRF_ALLOW_MARKER)) {
    return {
      kind: 'allow-with-warning',
      message: `⚠️  rm -rf allowed via the ${RMRF_ALLOW_MARKER} marker.`,
    };
  }

  const targets = destructive.flatMap((s) => s.targets);
  const matchesWhitelist = (t: string): boolean =>
    RMRF_WHITELIST_PREFIXES.some((p) => t.includes(p));

  if (targets.length > 0 && targets.every(matchesWhitelist)) {
    return {
      kind: 'allow-with-warning',
      message: `⚠️  rm -rf allowed — every target is under a build/ephemeral prefix.
  Targets:   ${targets.join(', ')}
  Whitelist: ${RMRF_WHITELIST_PREFIXES.join(', ')}`,
    };
  }

  // Off macOS there is no `trash`, so this degrades to a loud warning rather than a block.
  // The deliberate trade: the destructive command still runs, and the operator is told it
  // is unrecoverable. Blocking while naming a command the machine does not have is the
  // same defect as blocking with no alternative, plus extra steps. `trash-put` (trash-cli)
  // and `gio trash` are named as POSSIBILITIES, not instructions — neither is probed for,
  // so neither is asserted to exist.
  if (platform !== 'darwin') {
    return {
      kind: 'allow-with-warning',
      message: `⚠️  rm -rf is unrecoverable — allowed because this is not macOS (platform: ${platform}).

  Targets:  ${targets.length > 0 ? targets.join(', ') : '(unparsed)'}
  Note:     the \`trash\` remediation is macOS-only, so it is NOT suggested here.
            If your system has trash-cli (\`trash-put\`) or GIO (\`gio trash\`), prefer one.`,
    };
  }

  return {
    kind: 'block',
    reason: `❌ BLOCKED: rm -rf is unrecoverable — use trash instead

  Tried:    rm -rf (or rm -fr, rm -Rf, rm --recursive --force)
  Why:      rm -rf is permanent; trash moves to the recycle bin, which is recoverable
  Instead:  trash <path>
            trash src/old-module/

  Ephemeral-path whitelist (allowed with a warning if EVERY target matches):
    ${RMRF_WHITELIST_PREFIXES.join(', ')}
  Escape hatch (one-off): append \`${RMRF_ALLOW_MARKER}\` to the same command line.`,
  };
}

function checkRmRf(command: string): void {
  const decision = evaluateRmRf(command);
  if (decision.kind === 'block') block(decision.reason);
  if (decision.kind === 'allow-with-warning') {
    // Non-blocking: warn on stderr but let the rest of the check chain run.
    process.stderr.write(decision.message + '\n');
  }
}

// --- Forge policy -----------------------------------------------------------------------
//
// TWO separate things, and only the first depends on a DECLARED forge:
//
//   1. Wrong-CLI. Blocked only when CLAUDE_FORGE names one forge. With the default
//      (`both`) neither `gh` nor `glab` is blocked — most developers have both installed
//      and legitimately use both, and a hook that refuses the user's primary CLI out of
//      the box is a hook that gets deleted on day one.
//   2. Wrong FLAG on the right CLI. `--body` is GitHub's and `--description` is GitLab's;
//      each is simply an error on the other tool, and one that surfaces late — after the
//      branch has already been pushed. This fires for whichever CLI is permitted, so it
//      still helps under the permissive default.

function isFlag(word: string, flag: string): boolean {
  return word === flag || word.startsWith(flag + '=');
}

export function evaluateForgePolicy(command: string, forge: Forge): string | null {
  if (forge === 'gitlab' && GH_CLI.test(command)) {
    return `❌ BLOCKED: this project is configured for GitLab (CLAUDE_FORGE=gitlab)

  Tried:    a GitHub CLI command (gh pr / gh issue / gh api / gh repo)
  Instead:  glab mr create --description "text"   ← not --body
            glab mr list / view / merge
            glab issue create
            glab api projects/...                 ← not repos/...
            --target-branch main                  ← not --base
            --source-branch feature               ← not --head

  If this project actually uses GitHub, unset CLAUDE_FORGE or set it to \`github\`
  (\`both\` is the default and blocks neither CLI).`;
  }

  if (forge === 'github' && GLAB_CLI.test(command)) {
    return `❌ BLOCKED: this project is configured for GitHub (CLAUDE_FORGE=github)

  Tried:    a GitLab CLI command (glab mr / glab issue / glab api / glab ci)
  Instead:  gh pr create --body "text"            ← not --description
            gh pr list / view / merge
            gh issue create
            gh api repos/...                      ← not projects/...
            --base main                           ← not --target-branch
            --head feature                        ← not --source-branch

  If this project actually uses GitLab, unset CLAUDE_FORGE or set it to \`gitlab\`
  (\`both\` is the default and blocks neither CLI).`;
  }

  // Flag guidance, scoped per command segment so a compound command cannot cross-blame:
  // `gh pr create --body x && glab mr list` must not read as "glab was given --body".
  let segments;
  try {
    segments = parseCommand(command);
  } catch {
    return null; // cannot segment -> cannot attribute a flag; the other gates still run
  }

  for (const seg of segments) {
    if (seg.head === 'glab' && forge !== 'github' && seg.words.some((w) => isFlag(w, '--body'))) {
      return `❌ BLOCKED: --body is a GitHub CLI flag; glab does not accept it

  Tried:    glab ... --body "..."
  Why:      glab spells it --description. The call fails, and for \`glab mr create\` it
            fails only after the branch has been pushed.
  Instead:  glab mr create --description "text"`;
    }
    if (seg.head === 'gh' && forge !== 'gitlab' && seg.words.some((w) => isFlag(w, '--description'))) {
      return `❌ BLOCKED: --description is a GitLab CLI flag; gh does not accept it

  Tried:    gh ... --description "..."
  Why:      gh spells it --body.
  Instead:  gh pr create --body "text"`;
    }
  }

  return null;
}

function checkForgePolicy(command: string): void {
  const reason = evaluateForgePolicy(command, resolveForge());
  if (reason) block(reason);
}

// --- Commands that need a TTY ------------------------------------------------------------

export function evaluateNoTty(command: string): string | null {
  if (
    /(?:^|[;&|]\s*)glab ci view(?:\s|$)/.test(command) &&
    !/(?:^|[;&|]\s*)glab ci view-/.test(command)
  ) {
    return `❌ BLOCKED: glab ci view requires an interactive TTY

  Why:      it needs a terminal and errors out in an agent context
  Instead:  glab ci status              ← pipeline status (non-interactive)
            glab ci get                 ← pipeline details
            glab ci trace <job-id>      ← stream job logs`;
  }

  if (/(?:^|[;&|]\s*)glab pipeline view(?:\s|$)/.test(command)) {
    return `❌ BLOCKED: glab pipeline view requires an interactive TTY

  Instead:  glab pipeline list          ← list pipelines (non-interactive)
            glab ci status              ← current pipeline status`;
  }

  return null;
}

function checkNoTty(command: string): void {
  const reason = evaluateNoTty(command);
  if (reason) block(reason);
}

// --- Destructive git ----------------------------------------------------------------------

// Collaborators injected so the decision logic is unit-testable without shelling out to git.
export interface GitForceDeps {
  getBranch: (cwd?: string) => string;
  isWorkingTreeClean: (cwd?: string) => boolean;
}

/**
 * Pure decision: the block-reason message, or null to allow.
 *
 * isWorkingTreeClean is only consulted on the `reset --hard` path, preserving the laziness
 * that keeps a plain `git push` free of a working-tree git call.
 */
export function evaluateGitForce(
  command: string,
  cwd: string | undefined,
  deps: GitForceDeps,
  branches: string[] = protectedBranches(),
): string | null {
  if (!GIT_COMMAND.test(command)) return null;

  // hotfix/* and fix/* branches are exempt from the protected-branch force rules.
  // Resolved against the command's cwd so worktree branches are read correctly.
  const branch = deps.getBranch(cwd);
  const isHotfix = /^(hotfix|fix)\//.test(branch);

  // The marker opts a push out of the FORCE checks only. The destructive
  // reset/checkout/restore guards below still apply — it is narrow on purpose.
  const handOff = waived(command, FORCE_PUSH_ALLOW_MARKER);

  // Block: git push --force (not --force-with-lease).
  if (
    !handOff &&
    /(?:^|[;&|]\s*)git\s+push\s.*(-f\b|--force\b)/.test(command) &&
    !command.includes('force-with-lease')
  ) {
    const targetingProtected = targetsProtectedBranch(command, branches);
    if (!isHotfix || !targetingProtected) {
      return `❌ BLOCKED: git push --force is prohibited — use --force-with-lease

  Tried:    git push --force (or -f)
  Why:      A bare --force overwrites the remote unconditionally, including commits that
            landed after your last fetch. --force-with-lease refuses in exactly that case,
            which is the difference between rewriting your own history and destroying
            someone else's.
  Instead:  git push --force-with-lease origin <branch>
            Fetch immediately before pushing: the lease only protects against commits you
            have NOT fetched, so a stale fetch makes it as blunt as --force.

  Protected branches (${branches.join(', ')}) are never force-pushable; set
  CLAUDE_PROTECTED_BRANCHES to change the list.
  Escape (one-off): append \`${FORCE_PUSH_ALLOW_MARKER}\` to the command.`;
    }
  }

  // Block: --force-with-lease to a protected branch. Checked BEFORE the general lease arm
  // so the protected case keeps its own message and its own hotfix exemption.
  if (!handOff && /(?:^|[;&|]\s*)git\s+push\s.*--force-with-lease/.test(command)) {
    if (targetsProtectedBranch(command, branches) && !isHotfix) {
      return `❌ BLOCKED: force-pushing a protected branch (${branches.join(', ')}) is prohibited

  Why:      it rewrites shared history for every other contributor
  Instead:  create a new commit that undoes the change:
              git revert HEAD
            Local branch merely BEHIND the remote?  git pull --ff-only origin <branch>

  Set CLAUDE_PROTECTED_BRANCHES to change which branches this covers.
  (hotfix/* and fix/* branches are exempt.)`;
    }

    // ALLOWED on every non-protected branch. A lease push to a feature branch is a normal
    // part of resolving a rebase, and blocking it outright only teaches people to reach
    // for the escape marker by reflex. What still holds: a bare --force stays blocked, and
    // the lease is not a guarantee — it protects against commits you have NOT fetched, and
    // will happily overwrite a teammate's commit you already have. On a shared branch,
    // fetch immediately before pushing.
    return null;
  }

  // Block: git reset --hard, unless the working tree is clean.
  // Checked against the COMMAND's cwd, not the hook process cwd — a clean main checkout
  // must not green-light a reset --hard in a dirty worktree.
  if (/(?:^|[;&|]\s*)git\s+reset\s+--hard/.test(command)) {
    if (!deps.isWorkingTreeClean(cwd)) {
      return `❌ BLOCKED: git reset --hard discards uncommitted work permanently

  Why:      it destroys every uncommitted change with no recovery path
  Instead:  git stash                    ← save changes temporarily (recoverable)
            git stash push -m "message"  ← save with a description
            git stash pop                ← restore later

            If you truly want to discard:
              git stash && git stash drop  ← explicit two-step`;
    }
    return null; // Clean tree — reset --hard is safe
  }

  // Block: git checkout -- . / git checkout -- <path>
  if (/(?:^|[;&|]\s*)git\s+checkout\s+--\s/.test(command)) {
    return `❌ BLOCKED: git checkout -- discards working tree changes permanently

  Instead:  git stash                    ← save changes temporarily (recoverable)
            git restore --staged <file>  ← unstage only (keeps working tree changes)`;
  }

  // Block: git restore .
  if (/(?:^|[;&|]\s*)git\s+restore\s+\./.test(command)) {
    return `❌ BLOCKED: git restore . discards working tree changes permanently

  Instead:  git stash                    ← save changes temporarily (recoverable)
            git restore --staged <file>  ← unstage a specific file (safe)`;
  }

  return null;
}

function checkGitForce(command: string, cwd?: string): void {
  const reason = evaluateGitForce(command, cwd, { getBranch, isWorkingTreeClean });
  if (reason) block(reason);
}

// --- terraform init without a backend config -----------------------------------------------

export function evaluateTerraformBackend(command: string): string | null {
  if (!TERRAFORM_INIT.test(command)) return null;
  if (/terraform\s+init\s.*(--help|-help)\b/.test(command)) return null;
  if (command.includes('-backend-config=')) return null;
  // -backend=false is the sanctioned form for validate, lock-file upgrade and module-only init.
  if (command.includes('-backend=false')) return null;

  return `❌ BLOCKED: terraform init without -backend-config

  Why:      with no backend config Terraform falls back to LOCAL state, which diverges
            from the remote state every teammate and every CI run is using
  Instead:  terraform init -backend-config=backends/<env>.tfbackend

            Lock-file upgrade only (no remote state needed):
              terraform init -upgrade -backend=false`;
}

function checkTerraformBackend(command: string): void {
  const reason = evaluateTerraformBackend(command);
  if (reason) block(reason);
}

// --- Commit message shape --------------------------------------------------------------------

/** Pull the commit message out of a `git commit` command, or null if it cannot be read. */
export function extractCommitMessage(command: string): string | null {
  // HEREDOC: -m "$(cat <<'EOF'\n<subject>\n...\nEOF\n)"
  if (command.includes('cat <<')) {
    const lines = command.split('\n');
    const idx = lines.findIndex((l) => /cat <</.test(l));
    const next = idx >= 0 ? lines[idx + 1] : undefined;
    if (next !== undefined && next.trim()) return next.trim();
  }
  const dq = command.match(/-m\s+"([^"]*)"/);
  if (dq && dq[1]) return dq[1];
  const sq = command.match(/-m\s+'([^']*)'/);
  if (sq && sq[1]) return sq[1];
  return null;
}

/**
 * Pure decision for the commit-message shape.
 *
 * `branch` supplies the ticket key used in the suggested scope, so the guidance names the
 * key this branch is actually about instead of a hardcoded example.
 */
export function evaluateCommitMsg(
  command: string,
  branch: string = 'detached',
  pattern: string = ticketPattern(),
): string | null {
  if (!GIT_COMMIT.test(command)) return null;
  // Bypass: --amend --no-edit (rebase, fixup) reuses an existing message.
  if (/--amend\s+--no-edit|--no-edit\s+--amend/.test(command)) return null;
  // Bypass: no -m flag means the message is written in an editor, which this cannot read.
  if (!/-m\s/.test(command)) return null;

  const msg = extractCommitMessage(command);
  // Unreadable message -> allow. A repo-side commit-msg hook is the safety net, and
  // guessing here would block a legitimate message this parser simply cannot see.
  if (msg === null) return null;

  const firstLine = msg.split('\n')[0] ?? '';
  if (CONVENTIONAL_COMMIT.test(firstLine)) return null;

  const ticket = extractTicket(branch, pattern);
  const scopeExample = ticket ?? 'api';

  return `❌ BLOCKED: commit message does not follow Conventional Commits

  Tried:    ${firstLine.slice(0, 80)}
  Why:      the first line must match <type>(<scope>): <description>
            Types: feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert
  Instead:  feat(${scopeExample}): add search filter
            fix(api): handle null response
            chore: update dependencies
            feat(auth)!: change token format  ← breaking change

  Semver:   feat = MINOR | fix/docs/chore/etc = PATCH | ! or BREAKING CHANGE = MAJOR
  Scope:    ${ticket ? `this branch carries the ticket key ${ticket} — use it as the scope` : 'a component name, or a ticket key if your project uses them'}
            (ticket shape comes from CLAUDE_TICKET_PATTERN; default ${DEFAULT_TICKET_PATTERN})`;
}

function checkCommitMsg(command: string, cwd?: string): void {
  if (!GIT_COMMIT.test(command)) return;
  const branch = getBranch(cwd);
  const reason = evaluateCommitMsg(command, branch);
  if (reason) block(reason);
}

/**
 * Non-blocking note when a commit lands directly on a protected branch.
 *
 * A NOTE and not a block, deliberately. Plenty of real repositories are worked on
 * trunk-first by one person, and blocking there would be this hook firing on ordinary
 * work — the failure mode that gets the whole thing uninstalled.
 */
export function evaluateCommitOnProtected(
  command: string,
  branch: string,
  branches: string[] = protectedBranches(),
): string | null {
  if (!GIT_COMMIT.test(command)) return null;
  if (!branches.includes(branch)) return null;
  return `ℹ️  This commit lands directly on \`${branch}\`, a protected branch.
  If this project reviews changes, branch first:  git switch -c <type>/<short-description>
  Set CLAUDE_PROTECTED_BRANCHES to change which branches this mentions.`;
}

// --- Branch creation nudge ---------------------------------------------------------------

export function evaluateBranchCreation(command: string): string | null {
  const createsBranch =
    /(?:^|[;&|]\s*)git\s+checkout\s+(?:-b|-B)\s/.test(command) ||
    /(?:^|[;&|]\s*)git\s+switch\s+(?:-c|-C)\s/.test(command) ||
    /(?:^|[;&|]\s*)git\s+worktree\s+add\b/.test(command);
  if (!createsBranch) return null;

  return `ℹ️  Sync the base branch first so the new branch does not start behind.
  Run first:  git switch main && git pull --ff-only origin main
  --ff-only is deliberate: it REFUSES to create a merge commit. If it errors, your local
  base has commits of its own — a real thing to look at, not something to paper over with
  a plain \`git pull\` (which would quietly merge) or a reset.`;
}

function checkBranchCreation(command: string): void {
  const nudge = evaluateBranchCreation(command);
  if (nudge) context(nudge);
}

// --- Gate A: never print a secret -----------------------------------------------------------
//
// The incident this exists for, run to check whether a token was configured:
//
//   echo "TF_TOKEN set: ${TF_TOKEN_example_com:+yes}${TF_TOKEN_example_com:-no}"
//
// It printed `yes` followed by the full token, into the transcript and into task-output
// files on disk. The token had to be rotated. `${VAR:-fallback}` yields VAR'S VALUE when
// VAR is set — only `${VAR:+literal}` is safe. Half the command was right, which is exactly
// why it passed review.
//
// Secret scanners see staged FILES; this secret never touched one. This gate is the
// enforcement point for secrets in flight.
//
// Scoping is deliberately NARROW: it fires only when an unsafe expansion reaches the
// resolved head word of a command that prints to the transcript. A broad "any unsafe
// expansion anywhere" rule would fire on `export TOKEN="$X"` and on
// `curl -H "Authorization: Bearer $TOKEN"` — ordinary work. A gate that fires on ordinary
// work gets deleted, and that would take the rm -rf and force-push guards down with it.
// Narrow-and-kept beats broad-and-removed.

// Commands that put their arguments in front of the model.
const PRINTING_HEADS = new Set([
  'echo', 'printf', 'print', 'cat', 'tee', 'less', 'more', 'head', 'tail', 'od',
  'xxd', 'hexdump', 'base64', 'strings', 'jq', 'yq', 'awk', 'sed', 'tr', 'rev',
  'nl', 'pr', 'fmt', 'column', 'logger', 'banner', 'say',
]);

// Commands whose whole purpose is to hand back a plaintext credential.
const RETRIEVAL_PATTERNS: ReadonlyArray<{ rule: string; re: RegExp }> = [
  { rule: 'op read', re: /\bop\s+(read|item\s+get)\b/ },
  { rule: 'gh auth token', re: /\bgh\s+auth\s+token\b/ },
  { rule: 'glab auth token', re: /\bglab\s+auth\s+token\b/ },
  { rule: 'aws secretsmanager get-secret-value', re: /\baws\s+secretsmanager\s+get-secret-value\b/ },
  { rule: 'aws ssm get-parameter --with-decryption', re: /\baws\s+ssm\s+get-parameters?\b[\s\S]*--with-decryption\b/ },
  { rule: 'gcloud auth print-*-token', re: /\bgcloud\s+auth\s+print-(access|identity)-token\b/ },
  { rule: 'vault kv get', re: /\bvault\s+(kv\s+get|read)\b/ },
  { rule: 'security find-generic-password', re: /\bsecurity\s+find-(generic|internet)-password\b/ },
  { rule: 'pass show', re: /\bpass\s+show\b/ },

  // --- CI/CD variable stores -------------------------------------------------------
  // These read a variable STORE, not one named secret, so a single call hands back every
  // credential the project holds. Both forges return the value in plaintext for masked
  // variables too — masking governs job-log display, not the API. A substring filter over
  // the response does not help: the filter matches on the KEY and prints the whole
  // {"key":…,"value":…} object.
  //
  // Matched on the path, not the verb, and deliberately so: a GET is the leak, and the
  // POST/PUT that SETS a variable also carries the value on the command line unless it
  // comes from a heredoc or --input. Both want the same treatment.
  { rule: 'glab api …/variables', re: /\bglab\s+api\b[^|;&]*\/variables\b/ },
  { rule: 'gh api …/variables', re: /\bgh\s+api\b[^|;&]*\/variables\b/ },
  { rule: 'glab variable get', re: /\bglab\s+variable\s+(get|list|export)\b/ },
  { rule: 'gh variable get', re: /\bgh\s+variable\s+(get|list)\b/ },

  // Token MINTING returns the only copy of the token that will ever exist — the API never
  // shows it again. Printing it is therefore worse than printing a re-readable secret.
  { rule: 'glab api …/access_tokens', re: /\bglab\s+api\b[^|;&]*\/(access_tokens|personal_access_tokens|deploy_tokens|runners)\b/ },
  { rule: 'gh api …/tokens', re: /\bgh\s+api\b[^|;&]*\/(access_tokens|personal_access_tokens)\b/ },

  // Other stores that return plaintext on read.
  { rule: 'kubectl get secret -o', re: /\bkubectl\s+get\s+secrets?\b[\s\S]*-o[\s=]?(json|yaml|jsonpath|go-template)/ },
  { rule: 'az keyvault secret show', re: /\baz\s+keyvault\s+secret\s+(show|download)\b/ },
  { rule: 'gcloud secrets versions access', re: /\bgcloud\s+secrets\s+versions\s+access\b/ },
  { rule: 'aws ecr get-login-password', re: /\baws\s+ecr\s+get-login-password\b/ },
  { rule: 'doppler secrets', re: /\bdoppler\s+secrets\s+(get|download)\b/ },
];

// Consumers that take a credential on stdin and do not echo it. Piping a retrieval into
// one of these is the SANCTIONED pattern, not a leak.
const SANCTIONED_CONSUMERS = new Set([
  'docker', 'podman', 'buildah', 'skopeo', 'crane', 'glab', 'gh', 'helm', 'kubectl',
  'npm', 'yarn', 'pnpm', 'pip', 'pip3', 'twine', 'vault', 'aws', 'gcloud', 'az',
  'op', 'gpg', 'ssh-add', 'keyring',
]);

// Consumers that cannot pass a VALUE through to the transcript, so `env | …` is a safe way
// to inspect WHICH variables exist. `grep` qualifies only with -c/-q/-l, because a plain
// `env | grep AWS` prints whole NAME=value lines.
//
// `wc` counts and cannot emit input. `cut` only qualifies in FIELD mode with an `=`
// delimiter — the `env | cut -d= -f1` idiom this rule exists to permit. Bare `cut` must not
// qualify unconditionally: `env | cut -c1-200` prints whole NAME=value lines straight past
// the guard. Character mode and any `-f` range reaching past field 1 both carry the value.
const VALUE_STRIPPING_HEADS = new Set(['wc']);
function stripsValues(head: string, words: string[]): boolean {
  if (VALUE_STRIPPING_HEADS.has(head)) return true;
  if (head === 'cut') {
    const joined = words.join(' ');
    const fieldsOnEquals = /-d[\s=]?'?"?=/.test(joined) || /--delimiter[\s=]'?"?=/.test(joined);
    const firstFieldOnly = /-f[\s=]?'?"?1'?"?(\s|$)/.test(joined) || /--fields[\s=]'?"?1'?"?(\s|$)/.test(joined);
    return fieldsOnEquals && firstFieldOnly;
  }
  if (head === 'grep' || head === 'egrep' || head === 'rg') {
    return words.some((w) => /^-[a-zA-Z]*[cql]/.test(w));
  }
  return false;
}

// `set`, `export -p` and `declare -x` are always full dumps.
const ALWAYS_DUMP = /(?:^|[;&|]\s*)set\s*(?:$|[;&|])|export\s+-p|declare\s+-x/;

// Files that exist to hold credentials.
//
// The suffixed arm matters as much as the exact-name arm. With only a complete-filename
// match, `~/.aws/credentials` is caught and `~/.config/credentials-backup-2026.json` is
// not — and the second is just as live. `.md` is absent from the extension list on
// purpose: a document named `credentials-standards.md` is prose ABOUT credentials, and
// blocking it trains people around the gate.
const CREDENTIAL_FILE_EXTS = 'json|yaml|yml|txt|csv|env|ini|conf|toml|xml|properties';
const CREDENTIAL_FILES = new RegExp(
  `(?:^|[\\s'"=/])(?:` +
  `\\.env(?:\\.[\\w.-]+)?|\\.terraformrc|\\.netrc|\\.pgpass|credentials|config\\.json` +
  `)(?:['"\\s;|&]|$)` +
  `|[\\w.-]*credentials[\\w.-]*\\.(?:${CREDENTIAL_FILE_EXTS})(?:['"\\s;|&]|$)`);
const CREDENTIAL_FILE_PATHS = /(?:\.aws\/credentials|\.docker\/config\.json|\.netrc|\.terraformrc|\.pgpass|\.npmrc)/;

// grep and friends read a file and print the matching lines, which is the same disclosure
// `cat` makes. They are a SEPARATE set rather than an addition to PRINTING_HEADS: that set
// also drives Rule 1, and adding grep there would start blocking `grep "$TOKEN" file`,
// which is a behaviour change nobody asked for. This rule is narrow already — it fires only
// when the ARGUMENTS name a credential file.
const CONTENT_SEARCH_HEADS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ripgrep', 'ag', 'ack']);

// Flags that make a search emit counts, filenames or nothing instead of file content.
// These MUST stay allowed, because this rule's own block message recommends
// `grep -c . .env` as the safe alternative. A gate that blocks the remediation it prints
// teaches people to reach for the escape marker instead.
//
// `[cqlL]` and not `[cqlLC]`: lowercase -l is files-with-matches and -L is
// files-without-match, both of which suppress content, while uppercase -C is context
// lines, which prints more of it.
const CONTENT_SUPPRESSING_FLAGS =
  /(?:^|\s)-[a-zA-Z]*[cqlL][a-zA-Z]*(?:\s|$)|--(?:count|quiet|silent|files-with-matches|files-without-match)\b/;

/** The words of a search command with its PATTERN removed, leaving the paths. */
function dropSearchPattern(words: readonly string[]): string[] {
  const out: string[] = [];
  let droppedPattern = false;
  for (const w of words) {
    if (!droppedPattern && !w.startsWith('-')) {
      droppedPattern = true; // this is the pattern; omit it
      continue;
    }
    out.push(w);
  }
  return out;
}

const SAFE_IDIOMS = `  Instead:  [ -n "\${VAR:-}" ] && echo "VAR: set" || echo "VAR: unset"   # preferred
            echo "VAR: \${VAR:+set}"                                      # empty when unset
            echo "VAR length: \${#VAR}"                                   # length only
            echo "VAR prefix: \${VAR:0:4}…"                               # identify key type`;

const EXPANSION_TRUTH_TABLE = `  Why:      \`\${VAR:-x}\` prints VAR'S VALUE when VAR is set — it only yields \`x\` when VAR is
            UNSET. You want \`\${VAR:+x}\`. That one character is the whole bug.

              \${VAR}      \${VAR:-x}  \${VAR:=x}  \${VAR:?x}   → the value    UNSAFE
              \${VAR:+x}   \${VAR+x}   \${#VAR}    \${VAR:0:4}  → not the value SAFE`;

export interface SecretPrintDecision {
  /** Short rule id, used in tests and in the block message. */
  readonly rule: string;
  readonly message: string;
}

/**
 * Pure decision for Gate A: the block message, or null to allow.
 *
 * Allowed by construction, because none of these puts a secret in front of the model:
 *   - a safe expansion form (`${V:+x}`, `${V+x}`, `${#V}`, `${V:0:4}`)
 *   - assignment or pass-through: `FOO="$SECRET" cmd`, `export TOKEN="$Y"`
 *   - a header or request body: `curl -H "Authorization: Bearer $TOKEN"`
 *   - stdout redirected to a file — it never reaches the transcript, and this is how
 *     `~/.terraformrc` and `.npmrc` are legitimately generated
 *   - a retrieval captured into a variable, or piped to a sanctioned consumer
 */
export function evaluateSecretPrint(command: string): SecretPrintDecision | null {
  if (!command) return null;

  // The marker opts a single deliberate line out. Applied per-rule, NOT globally: the
  // env-dump rule has no escape, because there is always a targeted alternative and a full
  // dump is unbounded disclosure.
  const marked = waived(command, SECRET_PRINT_ALLOW_MARKER);

  const commands = parseCommand(command);
  // `withoutHeredocs` is the command with heredoc BODIES removed. Rule 2 matches on it
  // rather than on `command`, because a heredoc body is DATA, not a command to run:
  // writing a test file or a doc that merely MENTIONS `op read` would otherwise trip the
  // gate — the gate obstructing the documentation of itself, which is how gates get
  // switched off.
  const { command: withoutHeredocs, heredocs } = extractHeredocs(command);
  const anyRedirect = commands.some((c) => c.redirectsStdout);

  // --- Rule 1: an unsafe expansion of a secret-named variable reaches a printer -----
  for (const cmd of commands) {
    if (marked) break;
    if (cmd.redirectsStdout) continue; // goes to a file, not the transcript
    const headIsPrinter = cmd.head !== null && PRINTING_HEADS.has(cmd.head);

    // An expansion in HEAD position is executed; "command not found: <token>" echoes it.
    // headRaw skips assignment prefixes, so `FOO="$SECRET" make deploy` is not a print.
    const headExpansions = classifyExpansions(cmd.headRaw ?? '');
    const argExpansions = headIsPrinter ? classifyExpansions(cmd.words.join(' ')) : [];

    for (const e of [...headExpansions, ...argExpansions]) {
      if (e.safe) continue;
      // For indirect expansion the pointer's own name says nothing about its target, so
      // the allowlist must not apply — `${!CFG}` may well dereference a token.
      const isSecret = e.form === 'indirect' ? true : isSecretVarName(e.name);
      if (!isSecret) continue;

      const where = headExpansions.includes(e) ? 'as the command itself' : `as an argument to \`${cmd.head}\``;
      return {
        rule: 'unsafe-expansion',
        message: `❌ BLOCKED: this would print the value of ${e.name}

  Tried:    ${e.raw}  ${where}
${EXPANSION_TRUTH_TABLE}

${SAFE_IDIOMS}

            Writing it to a file instead of stdout is also fine — a redirect never
            reaches the transcript.

  Escape:   append \`${SECRET_PRINT_ALLOW_MARKER}\` to opt this one line out.`,
      };
    }
  }

  // --- Rule 1b: an expansion-enabled heredoc body carrying a secret ------------------
  if (!anyRedirect && !marked) {
    for (const doc of heredocs) {
      if (doc.quoted) continue; // <<'EOF' performs no expansion at all
      for (const e of classifyExpansions(doc.body)) {
        if (e.safe) continue;
        if (!(e.form === 'indirect' || isSecretVarName(e.name))) continue;
        return {
          rule: 'unsafe-expansion-heredoc',
          message: `❌ BLOCKED: an unquoted heredoc would expand ${e.name} into its body

  Tried:    ${e.raw} inside <<${doc.delimiter}
  Why:      an unquoted heredoc delimiter performs expansion. Quote it — <<'${doc.delimiter}' —
            and the body is passed through literally.
${EXPANSION_TRUTH_TABLE}

  Escape:   append \`${SECRET_PRINT_ALLOW_MARKER}\` to opt this one line out.`,
        };
      }
    }
  }

  // --- Rule 2: a retrieval command whose plaintext output is not consumed ------------
  for (const { rule, re } of RETRIEVAL_PATTERNS) {
    if (marked) break;
    if (!re.test(withoutHeredocs)) continue;
    // No fallback to commands[0]: if the pattern matched the stripped command but no single
    // segment owns it, we cannot say which command to blame or whether its output is
    // consumed. Blaming an arbitrary segment produces a block whose "Tried:" line names an
    // unrelated `cd`. Skip instead — Rule 1 still covers the value itself.
    const owner = commands.find((c) => re.test(c.raw));
    if (!owner) continue;
    if (owner.captured) continue; // TOKEN=$(op read …) — assigned, not printed
    if (owner.redirectsStdout) continue; // written to a file
    if (owner.pipeTo.some((h) => SANCTIONED_CONSUMERS.has(h))) continue;

    return {
      rule: 'secret-retrieval-print',
      message: `❌ BLOCKED: \`${rule}\` returns a plaintext credential and nothing consumes it

  Tried:    ${owner.raw.slice(0, 160)}
  Why:      retrieving a secret is the sanctioned pattern; PRINTING the result is the
            defect. With no capture, no redirect and no consumer on the other side of a
            pipe, the value lands in the transcript and in the task-output file on disk.

  Instead:  TOKEN="$(${rule} …)"                     # capture into a variable
            ${rule} … | docker login --password-stdin  # hand straight to a consumer
            ${rule} … > "$HOME/.config/…"             # write to a file
            echo "retrieved: \${TOKEN:+yes}"           # confirm without disclosing

  Escape:   append \`${SECRET_PRINT_ALLOW_MARKER}\` to opt this one line out.`,
    };
  }

  // --- Rule 3: unfiltered environment dumps -----------------------------------------
  // No allow-marker on this rule: there is always a targeted alternative, and a full dump
  // in a session that has ever exported a token is an unbounded disclosure.
  const envDump = commands.find((c) => {
    if (c.redirectsStdout) return false;
    if (c.head === 'env' || c.head === 'printenv') {
      // With an operand it reads one variable; only a bare invocation is a dump.
      const operands = c.words.filter((w) => !w.startsWith('-'));
      if (operands.length > 0) return false;
      // `env | cut -d= -f1` and `env | grep -c AWS` cannot pass a value through.
      const next = commands.find((o) => o.depth === c.depth && c.pipeTo[0] === o.head);
      if (c.pipeTo.length > 0 && next && stripsValues(next.head ?? '', next.words)) return false;
      return true;
    }
    return false;
  });

  if (envDump || ALWAYS_DUMP.test(command)) {
    return {
      rule: 'env-dump',
      message: `❌ BLOCKED: an unfiltered environment dump discloses every exported secret

  Tried:    ${command.slice(0, 160)}
  Why:      this session's environment may hold AWS_SESSION_TOKEN, GITHUB_TOKEN,
            TF_TOKEN_* and more. A dump prints all of them at once.

  Instead:  echo "VAR: \${VAR:+set}"                       # one variable, no value
            env | cut -d= -f1                             # names only, never values
            env | grep -c AWS                             # a count, not the values

  No escape: there is always a targeted alternative to a full dump.`,
    };
  }

  // --- Rule 4: printing a credential file --------------------------------------------
  for (const cmd of commands) {
    if (marked) break;
    if (cmd.head === null) continue;
    const isPrinter = PRINTING_HEADS.has(cmd.head);
    const isSearch = CONTENT_SEARCH_HEADS.has(cmd.head);
    if (!isPrinter && !isSearch) continue;
    // A search invoked with a content-suppressing flag reports counts or filenames.
    if (isSearch && CONTENT_SUPPRESSING_FLAGS.test(cmd.raw)) continue;
    if (cmd.redirectsStdout) continue;
    // For a SEARCH the first non-flag word is the PATTERN, not a path, so it must not be
    // tested against the credential-file names: without this, `grep -rn credentials docs/`
    // is blocked for searching FOR the word.
    const words = isSearch ? dropSearchPattern(cmd.words) : cmd.words;
    const args = words.join(' ');
    if (!CREDENTIAL_FILES.test(args) && !CREDENTIAL_FILE_PATHS.test(args)) continue;
    return {
      rule: 'credential-file-print',
      message: `❌ BLOCKED: \`${cmd.head}\` on a credential file exposes its contents

  Tried:    ${cmd.raw.slice(0, 160)}
  Why:      .env, ~/.terraformrc, ~/.aws/credentials, ~/.netrc, ~/.npmrc and
            ~/.docker/config.json exist to hold live credentials.

  Instead:  grep -c . .env                    # how many entries, no values
            cut -d= -f1 .env                  # key names only
            grep -q '^TF_TOKEN' ~/.terraformrc && echo present

  Escape:   append \`${SECRET_PRINT_ALLOW_MARKER}\` to opt this one line out.`,
    };
  }

  return null;
}

function checkSecretPrint(command: string): void {
  const decision = evaluateSecretPrint(command);
  if (decision) block(decision.message);
}

// --- Gate C: do not publish a credential through a forge CLI ----------------------------
//
// TOKEN_PATTERNS only — a review note reporting "a credential is hardcoded at config.py:12"
// must be publishable, or the reviewer cannot describe what it found.

const FORGE_PUBLISHING =
  /\b(?:glab|gh)\s+(?:mr|pr|issue)\s+(?:create|update|edit|note|comment)\b|\b(?:glab|gh)\s+api\b[\s\S]*(?:description|body|note)=/;

export function evaluateOutboundBash(command: string): string | null {
  if (!FORGE_PUBLISHING.test(command)) return null;
  const hits = findSecrets(command);
  if (hits.length === 0) return null;

  const kinds = [...new Set(hits.map((h) => h.patternName))].sort().join(', ');
  return `❌ BLOCKED: this command would publish a credential

  Found:    ${hits.length} credential-shaped value(s) — ${kinds}
  Why:      pull-request descriptions and issue notes are durable and notify reviewers.
            Editing the note afterwards does not un-send the notification.

  Instead:  refer to the secret indirectly — "the token at op://vault/item/field".
            If you are describing a leak, name the LOCATION, not the value.
            If the credential is real and was exposed, it must be ROTATED.`;
}

function checkOutboundBash(command: string): void {
  const reason = evaluateOutboundBash(command);
  if (reason) block(reason);
}

// --- Main ---------------------------------------------------------------------------------

async function main(): Promise<void> {
  const input = await readStdin();
  if (input.tool_name !== 'Bash') allow();

  const command = input.tool_input?.command ?? '';
  if (!command) allow();

  // One switch for the whole engine, for debugging a suspected false positive.
  if ((process.env.CLAUDE_GUARDRAILS_OFF ?? '') === '1') allow();

  // Gates A and C run FIRST. A leak is irreversible once the value is in the transcript or
  // published, so neither may depend on an earlier check allowing the command through.
  checkSecretPrint(command);
  checkOutboundBash(command);

  // Then the reversible-damage guards: cheapest regex first, git working-tree checks last.
  checkRmRf(command);
  checkForgePolicy(command);
  checkNoTty(command);
  checkTerraformBackend(command);
  checkGitForce(command, input.cwd);
  checkCommitMsg(command, input.cwd);

  // Non-blocking notes.
  if (GIT_COMMIT.test(command)) {
    const note = evaluateCommitOnProtected(command, getBranch(input.cwd));
    if (note) context(note);
  }
  checkBranchCreation(command);

  allow();
}

// Run main only when invoked directly (not when imported by tests).
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
