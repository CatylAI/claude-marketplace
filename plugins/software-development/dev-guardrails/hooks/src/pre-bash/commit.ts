// Commit-message shape (a block) plus two non-blocking notes: a commit landing on a
// protected branch, and creating a branch without syncing the base first.
//
// Fail direction: OPEN. A message this parser cannot read (an editor, `-F file`, `$MSG`)
// is allowed; a repo-side commit-msg hook is the safety net. Guessing would block a
// legitimate message the parser simply cannot see.

import { heredocsOf } from '../lib/bash-parse.ts';
import { CONVENTIONAL_COMMIT } from '../lib/patterns.ts';
import { DEFAULT_TICKET_PATTERN, extractTicket, ticketPattern } from '../lib/ticket.ts';
import { protectedBranches } from './config.ts';
import { gitInvocations, resolveLongOption, type GitInvocation } from './git-invocation.ts';

// git commit's long options that this parser reads or must skip a value for, so an
// abbreviation such as `--mess` resolves the way git does.
const COMMIT_LONG_OPTIONS = [
  '--message', '--file', '--reuse-message', '--reedit-message', '--fixup', '--squash',
  '--template', '--author', '--date', '--cleanup', '--trailer', '--amend', '--all', '--patch',
  '--no-edit', '--allow-empty', '--allow-empty-message', '--signoff', '--verbose', '--quiet',
];

/**
 * Subjects git and its standard workflows write themselves: a merge commit finished by
 * hand after a conflict, a revert, and autosquash markers. These are not "non-conventional"
 * in any useful sense, and commitlint's own defaults ignore them for the same reason.
 */
const GIT_GENERATED_SUBJECT = /^(?:Merge |Revert "|(?:fixup|squash|amend)! )/;

interface CommitArgs {
  /** First `-m` value (the subject paragraph), or null. */
  message: string | null;
  /** `-F` value, or null. */
  file: string | null;
  /** The message comes from elsewhere: `-C`/`-c` reuse, `--fixup`, `--squash`. */
  generated: boolean;
}

// Short options of `git commit` that take a value, attached or as the next word.
const SHORT_WITH_VALUE = new Set(['m', 'F', 'C', 'c', 't']);
// Short options whose value is optional and only ever attached.
const SHORT_OPTIONAL_ATTACHED = new Set(['S', 'u']);

function readCommitArgs(args: readonly string[]): CommitArgs {
  const out: CommitArgs = { message: null, file: null, generated: false };
  const take = (opt: string, value: string | undefined): void => {
    if (value === undefined) return;
    if (opt === 'm' && out.message === null) out.message = value;
    else if (opt === 'F') out.file = value;
    else if (opt === 'C' || opt === 'c') out.generated = true;
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === '--') break;
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      const token = eq > 0 ? a.slice(0, eq) : a;
      // git accepts an unambiguous prefix, so `--mess` is `--message`.
      const name = resolveLongOption(token, COMMIT_LONG_OPTIONS);
      const inline = eq > 0 ? a.slice(eq + 1) : undefined;
      if (name === '--message') take('m', inline ?? args[++i]);
      else if (name === '--file') take('F', inline ?? args[++i]);
      else if (name === '--reuse-message' || name === '--reedit-message') take('C', inline ?? args[++i]);
      else if (name === '--fixup' || name === '--squash') { out.generated = true; if (inline === undefined) i++; }
      else if (name === '--template' || name === '--author' || name === '--date' || name === '--cleanup' || name === '--trailer') {
        if (inline === undefined) i++;
      }
      continue;
    }
    if (!a.startsWith('-') || a === '-') continue;
    // Bundled short options: `-am "msg"`, `-m"msg"`, `-vm msg`.
    for (let k = 1; k < a.length; k++) {
      const f = a[k]!;
      if (SHORT_WITH_VALUE.has(f)) {
        const attached = a.slice(k + 1);
        take(f, attached !== '' ? attached : args[++i]);
        break;
      }
      if (SHORT_OPTIONAL_ATTACHED.has(f)) break;
    }
  }
  return out;
}

/** Pull the subject line out of one `git commit` invocation, or null if it cannot be read. */
function subjectOf(g: GitInvocation, command: string): string | null {
  const args = readCommitArgs(g.args);
  if (args.generated) return null;

  let message = args.message;
  if (message === null && (args.file === '-' || args.file === '/dev/stdin')) message = g.cmd.stdin;
  if (message === null) return null;

  // `-m "$(cat <<'EOF' … EOF)"`: the body lives in the heredoc, not in the argument.
  const opener = message.match(/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)/);
  if (opener) {
    const doc = heredocsOf(command).find((h) => h.delimiter === opener[1]);
    if (!doc) return null;
    message = doc.body;
  }

  const first = message.split('\n').map((l) => l.trim()).find((l) => l !== '') ?? '';
  return first === '' ? null : first;
}

/** The first commit subject in `command`, or null. Kept for callers of the old helper. */
export function extractCommitMessage(command: string): string | null {
  for (const g of gitInvocations(command, undefined)) {
    if (g.sub !== 'commit') continue;
    const s = subjectOf(g, command);
    if (s !== null) return s;
  }
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
  for (const g of gitInvocations(command, undefined)) {
    if (g.sub !== 'commit') continue;
    const subject = subjectOf(g, command);
    if (subject === null) continue;
    if (CONVENTIONAL_COMMIT.test(subject)) continue;
    if (GIT_GENERATED_SUBJECT.test(subject)) continue;
    // `-m "$MSG"`, `-m "$(git log -1 --format=%s)"`: the real text is not visible here.
    if (/[$`]/.test(subject)) continue;

    const ticket = extractTicket(branch, pattern);
    const scopeExample = ticket ?? 'api';
    return `❌ BLOCKED: commit message does not follow Conventional Commits

  Tried:    ${subject.slice(0, 80)}
  Why:      the first line must match <type>(<scope>): <description>
            Types: feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert
  Instead:  feat(${scopeExample}): add search filter
            fix(api): handle null response
            chore: update dependencies
            feat(auth)!: change token format  ← breaking change

  Semver:   feat = MINOR | fix = PATCH | ! or BREAKING CHANGE = MAJOR | other types: none
  Scope:    ${ticket ? `this branch carries the ticket key ${ticket} — use it as the scope` : 'a component name, or a ticket key if your project uses them'}
            (ticket shape comes from CLAUDE_TICKET_PATTERN; default ${DEFAULT_TICKET_PATTERN})`;
  }
  return null;
}

/** The directory of the first `git commit` in `command`, for reading its branch. */
export function commitDirs(command: string, cwd: string | undefined): Array<string | undefined> {
  return gitInvocations(command, cwd)
    .filter((g) => g.sub === 'commit')
    .map((g) => g.dir ?? undefined);
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
  if (!gitInvocations(command, undefined).some((g) => g.sub === 'commit')) return null;
  if (!branches.includes(branch)) return null;
  return `ℹ️  This commit lands directly on \`${branch}\`, a protected branch.
  If this project reviews changes, branch first:  git switch -c <type>/<short-description>
  Set CLAUDE_PROTECTED_BRANCHES to change which branches this mentions.`;
}

export function evaluateBranchCreation(command: string): string | null {
  const createsBranch = gitInvocations(command, undefined).some((g) => {
    if (g.sub === 'checkout') return g.args.some((a) => a === '-b' || a === '-B');
    if (g.sub === 'switch') return g.args.some((a) => a === '-c' || a === '-C' || a === '--create' || a === '--force-create');
    if (g.sub === 'worktree') return g.args[0] === 'add';
    return false;
  });
  if (!createsBranch) return null;

  return `ℹ️  Sync the base branch first so the new branch does not start behind.
  Run first:  git switch main && git pull --ff-only origin main
  --ff-only is deliberate: it REFUSES to create a merge commit. If it errors, your local
  base has commits of its own — a real thing to look at, not something to paper over with
  a plain \`git pull\` (which would quietly merge) or a reset.`;
}
