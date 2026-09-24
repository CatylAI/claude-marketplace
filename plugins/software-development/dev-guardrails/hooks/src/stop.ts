// Stop hook: the completion gate. Four non-blocking nudges: ticket, ADR, CI, dependencies.
//
// A Stop hook fires at the one moment when the whole change is visible at once and nothing has
// been pushed yet. That makes it the right place for "you changed X and not the Y that records
// it", and the wrong place for anything expensive or chatty, because it fires at the end of
// EVERY turn.
//
// WHERE THE NUDGE GOES. Plain stdout from a Stop hook reaches only the debug log. The two visible
// channels are `hookSpecificOutput.additionalContext`, which makes the conversation continue so
// Claude can act (an extra model turn every time it fires), and `systemMessage`, which shows the
// user a warning line and ends the turn normally. These nudges are about decisions the user owns
// (record an ADR, move the ticket, check the pipeline), so they go to the user as a systemMessage.
//
// THE FIRING RATE IS THE DESIGN CONSTRAINT. A nudge that fires on most turns teaches the reader
// to skip the channel. So each predicate is narrow and pure over a file list, and the whole
// message is shown once per session: an identical message on the next turn is suppressed (the
// last one shown is remembered per session_id in the plugin's scratch state directory).
//
// All three go quiet once the work is committed: the file lists come from the working tree and the
// index.
//
// FAILURE MODE: fail open, silently. Any error exits 0 with no output; a Stop hook must never be
// the reason a turn ends badly.

import { systemMessageJson } from './lib/output.ts';
import { readStdin } from './lib/stdin.ts';
import { stateFile } from './lib/state-dir.ts';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import {
  getBranch,
  getBaseBranch,
  isGitRepo,
  getChangedFiles,
  getAddedFiles,
} from './lib/git.ts';
import { execArgv } from './lib/shell.ts';
import { extractTicket } from './lib/ticket.ts';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// A code path embodies architectural decisions; an ADR path is the record of them.
const CODE_PATH = /^(src\/|lib\/|app\/|crates\/|internal\/|pkg\/|infrastructure\/|schemas\/)|\.tf$/;
const ADR_PATH = /docs\/(adr|decisions)\//i;

// A NEW gate, hook, pipeline stage or plugin. ADDING one is a decision; editing an existing one
// usually is not, which is why this arm reads ADDED paths only. Without that distinction the
// predicate fires on routine maintenance of files that were decided on long ago.
const NEW_HOOK = /(^|\/)hooks\/.*\.(ts|js|py|sh)$/;
const NEW_PIPELINE = /(^|\/)(\.github\/workflows|\.gitlab\/ci|pipeline)\/.+\.(ya?ml|py|sh)$/;
const NEW_GATE = /(^|\/)scripts\/.*\.(sh|py|ts)$/;
const NEW_PLUGIN_MANIFEST = /(^|\/)\.claude-plugin\/plugin\.json$/;
const TEST_FILE = /\.test\.|\.spec\.|_test\.|(^|\/)tests?\//;

function isNewDecisionArtifact(path: string): boolean {
  // Adding a test is not an architectural decision, whatever directory it lands in.
  if (TEST_FILE.test(path)) return false;
  return (
    NEW_HOOK.test(path) ||
    NEW_PIPELINE.test(path) ||
    NEW_GATE.test(path) ||
    NEW_PLUGIN_MANIFEST.test(path)
  );
}

// CI configuration, whichever forge. Both spellings, because a repo that has migrated usually
// keeps the old file around for a while and changes to either one matter.
const CI_PATH =
  /(^|\/)\.github\/workflows\/.+\.ya?ml$|(^|\/)\.gitlab-ci\.yml$|(^|\/)\.gitlab\/ci\/.+\.ya?ml$/;

// Dependency manifests. A lockfile moving on its own is a routine refresh; a MANIFEST moving is a
// dependency decision, which is why only the manifest side is matched.
const DEPENDENCY_MANIFEST =
  /(^|\/)(package\.json|pyproject\.toml|requirements\.txt|Cargo\.toml|go\.mod|Gemfile)$/;

/**
 * Should we nudge for an ADR update? Pure over the two file lists.
 *
 * `addedFiles` reads BOTH lists for the suppression, and that is not cosmetic: a brand-new
 * `docs/adr/010-*.md` is UNTRACKED, so `getChangedFiles()` cannot see it and the nudge would fire
 * at the very moment the author complied.
 */
export function shouldNudgeAdr(changedFiles: string[], addedFiles: string[] = []): boolean {
  const touchedAdr =
    changedFiles.some((f) => ADR_PATH.test(f)) || addedFiles.some((f) => ADR_PATH.test(f));
  if (touchedAdr) return false;

  const touchedCode = changedFiles.some((f) => !TEST_FILE.test(f) && CODE_PATH.test(f));
  const addedArtifact = addedFiles.some(isNewDecisionArtifact);
  return touchedCode || addedArtifact;
}

/**
 * Did this change touch CI configuration? Path-pure on purpose: whether the pipeline is actually
 * wrong needs the file's contents and the project's conventions, neither of which a Stop hook
 * should be reading. It points at the question; it does not answer it.
 */
export function shouldNudgeCi(changedFiles: string[]): boolean {
  return changedFiles.some((f) => CI_PATH.test(f));
}

/** Did this change edit a dependency manifest? */
export function shouldNudgeDependencies(changedFiles: string[]): boolean {
  return changedFiles.some((f) => DEPENDENCY_MANIFEST.test(f));
}

/** The nudges for the current tree, in display order. Empty when there is nothing to say. */
function collectNudges(): string[] {
  if (!isGitRepo()) return [];

  const branch = getBranch();
  const baseBranch = getBaseBranch();
  if (branch === 'detached' || !baseBranch) return [];

  const nudges: string[] = [];
  const ticket = extractTicket(branch);
  if (ticket) {
    // argv, not a shell string. `baseBranch` is whatever the REMOTE advertises through
    // refs/remotes/origin/HEAD; getBaseBranch() already refuses anything that is not a plain
    // ref name, and running it without a shell means a substitution could not fire even if
    // that validation were ever loosened.
    const commitCount = execArgv('git', ['rev-list', '--count', `${baseBranch}..HEAD`], {
      timeout: 5000,
    });
    // The count is deliberately left out of the text: a message that changes with every commit
    // would defeat the once-per-session suppression.
    if (commitCount && parseInt(commitCount, 10) > 0) {
      nudges.push(`Ticket sync: ${branch} has commits for ${ticket}. If the work is done, move the issue.`);
    }
  }

  const changedFiles = getChangedFiles();
  const addedFiles = getAddedFiles();

  if (shouldNudgeAdr(changedFiles, addedFiles)) {
    nudges.push(
      'ADR currency: a decision-bearing path changed (code, or a new gate, hook, pipeline or ' +
        'plugin manifest) and no decision record did. If this changed an architectural decision, ' +
        'record it in the same change.',
    );
  }
  if (shouldNudgeCi(changedFiles)) {
    nudges.push(
      'CI changed: confirm the edited pipeline actually runs. A malformed job is skipped ' +
        'silently, and a job that never runs looks like a job that passes.',
    );
  }
  if (shouldNudgeDependencies(changedFiles)) {
    nudges.push(
      'Dependencies changed: regenerate the lockfile in the same change, so you and CI install ' +
        'the same tree.',
    );
  }
  return nudges;
}

/**
 * Should `message` be shown for `sessionId`, given what was shown last? Records it when yes.
 * Without a writable state directory it always says yes: a repeated nudge beats a lost one.
 */
export function shouldShowOnce(
  sessionId: string,
  message: string,
  path: string | null = stateFile('stop-nudges.json'),
): boolean {
  if (!path || !sessionId) return true;
  const digest = createHash('sha256').update(message).digest('hex');
  let seen: Record<string, string> = {};
  try {
    if (existsSync(path)) seen = JSON.parse(readFileSync(path, 'utf-8')) as Record<string, string>;
  } catch {
    seen = {};
  }
  if (seen[sessionId] === digest) return false;
  seen[sessionId] = digest;
  try {
    writeFileSync(path, JSON.stringify(seen), 'utf-8');
  } catch {
    /* best-effort */
  }
  return true;
}

async function run(): Promise<void> {
  try {
    const input = await readStdin();
    const nudges = collectNudges();
    if (nudges.length === 0) return;
    const message = `dev-guardrails:\n- ${nudges.join('\n- ')}`;
    if (!shouldShowOnce(input.session_id ?? '', message)) return;
    process.stdout.write(systemMessageJson(message) + '\n');
  } catch {
    // Fail open: see the header.
  }
}

// Only run as the hook entrypoint — importing (e.g. from stop.test.ts) must not execute the hook.
//
// WITHOUT THIS GUARD THE TEST SUITE IS VACUOUS. Importing a module whose body runs at top level
// and ends in `process.exit(0)` exits the test runner during module evaluation: node:test reports
// one passing test, exit code 0, green, and never invokes a single assertion. A suite that cannot
// fail is worse than a missing one, because it is counted as coverage.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
  process.exit(0);
}
