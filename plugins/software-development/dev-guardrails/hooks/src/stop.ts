// Stop hook: the completion gate. Three nudges, all non-blocking, all exiting 0.
//
// A Stop hook fires at the one moment when the whole change is visible at once and nothing has
// been pushed yet. That makes it the right place for "you changed X and not the Y that records
// it" — and the wrong place for anything expensive or chatty, because it fires at the end of
// EVERY turn.
//
// THE FIRING RATE IS THE DESIGN CONSTRAINT. A nudge that fires on most turns is worse than no
// nudge: it teaches the reader to skip the channel it shares with the real ones. So each
// predicate below is deliberately narrow, and each is pure over a file list so its rate can be
// measured against a real repository instead of guessed at.
//
// All three suppress themselves once the work is committed: the file lists come from the working
// tree and the index, so they go quiet on commit rather than nagging for the life of the branch.

import { context } from './lib/output.ts';
import {
  getBranch,
  getBaseBranch,
  isGitRepo,
  getChangedFiles,
  getAddedFiles,
} from './lib/git.ts';
import { execArgv } from './lib/shell.ts';
import { extractTicket } from './pre-bash.ts';
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

function run(): void {
  try {
    if (!isGitRepo()) return;

    const branch = getBranch();
    const baseBranch = getBaseBranch();
    if (branch === 'detached' || !baseBranch) return;

    const ticket = extractTicket(branch);
    if (ticket) {
      // argv, not a shell string. `baseBranch` is whatever the REMOTE advertises through
      // refs/remotes/origin/HEAD; getBaseBranch() already refuses anything that is not a plain
      // ref name, and running it without a shell means a substitution could not fire even if
      // that validation were ever loosened.
      const commitCount = execArgv(
        'git',
        ['rev-list', '--count', `${baseBranch}..HEAD`],
        { timeout: 5000 },
      );
      if (commitCount && parseInt(commitCount, 10) > 0) {
        context(
          `TICKET SYNC: ${branch} has ${commitCount} commit(s) for ${ticket}. If the work is ` +
            'done, move the issue — nothing else will.',
        );
      }
    }

    const changedFiles = getChangedFiles();
    const addedFiles = getAddedFiles();

    if (shouldNudgeAdr(changedFiles, addedFiles)) {
      context(
        'ADR CURRENCY: a decision-bearing path changed with no decision record updated — a code ' +
          'path, or a NEW gate, hook, pipeline or plugin manifest. If this introduced or altered ' +
          'an architectural decision (a module boundary, a dependency, an auth or data-model ' +
          'choice, infrastructure topology), record it in the same change. If it did not, this ' +
          'line needs nothing from you.',
      );
    }

    if (shouldNudgeCi(changedFiles)) {
      context(
        'CI CHANGED: pipeline configuration was edited. Confirm the change actually runs — a ' +
          'malformed job is skipped silently, and a job that never runs looks exactly like a job ' +
          'that passes.',
      );
    }

    if (shouldNudgeDependencies(changedFiles)) {
      context(
        'DEPENDENCIES CHANGED: a dependency manifest was edited. Make sure the lockfile was ' +
          'regenerated in the same change — a manifest and lockfile that disagree install ' +
          'different trees for you and for CI.',
      );
    }
  } catch {
    // Silent failure — a Stop hook must never be the reason a turn ends badly.
  }
}

// Only run as the hook entrypoint — importing (e.g. from stop.test.ts) must not execute the hook.
//
// WITHOUT THIS GUARD THE TEST SUITE IS VACUOUS. Importing a module whose body runs at top level
// and ends in `process.exit(0)` exits the test runner during module evaluation: node:test reports
// one passing test, exit code 0, green, and never invokes a single assertion. A suite that cannot
// fail is worse than a missing one, because it is counted as coverage.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  run();
  process.exit(0);
}
