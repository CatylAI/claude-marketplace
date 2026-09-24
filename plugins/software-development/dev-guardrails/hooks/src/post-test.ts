// Test stage of the PostToolUse Write|Edit hook: run the test file that covers the file just
// edited. A MODULE, not an entry point: post-write-edit.ts calls maybeRunTests() below, so an
// edit costs one process, not one per stage.
//
// THRESHOLD-GATED, AND THE GATE IS THE DESIGN. Running a test on every single Edit turns a
// five-edit refactor into five test runs, four of which are against a half-finished state and all
// of which the model has to read. So a run needs BOTH: at least EDIT_THRESHOLD edits since the
// last run, AND at least COOLDOWN_MS since the last run. The counter and timestamp live in this
// plugin's scratch directory (lib/state-dir.ts), never in the repository.
//
// IT ONLY RUNS A TEST THAT ALREADY EXISTS, found by naming convention next to the edited file, and
// only with a runner the project installed locally (no `npx`, which can download a different
// version). It never runs the whole suite.

import { execArgvCapture, commandExists } from './lib/shell.ts';
import { stateFile } from './lib/state-dir.ts';
import { existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { extname, basename, dirname, join } from 'node:path';
import { createHash } from 'node:crypto';

const EDIT_THRESHOLD = 3;
const COOLDOWN_MS = 3 * 60 * 1000;
const TEST_TIMEOUT = 30_000;

export interface TestState {
  edit_count: number;
  last_run_at: number;
}

/**
 * Should a run happen now? Pure, so the gate is assertable without a filesystem or a clock.
 * Both conditions must hold — see the header on why either alone is the wrong gate.
 */
export function shouldRunTests(state: TestState, now: number): boolean {
  if (state.edit_count < EDIT_THRESHOLD) return false;
  return now - state.last_run_at >= COOLDOWN_MS;
}

// One state file per project root, so two repos edited in the same session do not share a counter
// and trip each other's threshold. The hash keeps the filename flat and filesystem-safe.
function getStatePath(projectRoot: string): string | null {
  const key = createHash('sha256').update(projectRoot).digest('hex').slice(0, 16);
  return stateFile(`pending-test-${key}.json`);
}

function loadState(statePath: string): TestState {
  try {
    if (existsSync(statePath)) {
      return JSON.parse(readFileSync(statePath, 'utf-8')) as TestState;
    }
  } catch {
    /* fresh state */
  }
  return { edit_count: 0, last_run_at: 0 };
}

function saveState(statePath: string, state: TestState): void {
  try {
    const tmp = statePath + '.tmp';
    writeFileSync(tmp, JSON.stringify(state, null, 2));
    renameSync(tmp, statePath);
  } catch {
    /* best-effort: losing the counter costs one extra test run, nothing else */
  }
}

/**
 * The conventional test-file locations for a source file, in preference order. Exported so the
 * conventions are assertable — a silently wrong convention makes this hook a no-op forever.
 */
export function testCandidates(filePath: string, projectRoot: string): string[] {
  const ext = extname(filePath).slice(1).toLowerCase();
  const base = basename(filePath, extname(filePath));
  const dir = dirname(filePath);

  if (ext === 'py') {
    return [
      join(projectRoot, 'tests', `test_${base}.py`),
      join(dir, `test_${base}.py`),
      join(projectRoot, 'tests', basename(dir), `test_${base}.py`),
    ];
  }

  if (['ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs'].includes(ext)) {
    const suffixes = [
      'test.ts', 'test.tsx', 'spec.ts', 'spec.tsx',
      'test.js', 'test.jsx', 'spec.js', 'spec.jsx',
    ];
    const candidates: string[] = [];
    for (const s of suffixes) {
      candidates.push(join(dir, `${base}.${s}`));
      candidates.push(join(dir, '__tests__', `${base}.${s}`));
    }
    return candidates;
  }

  return [];
}

function findTestFile(filePath: string, projectRoot: string): string | null {
  return testCandidates(filePath, projectRoot).find((c) => existsSync(c)) ?? null;
}

function report(label: string, stdout: string, stderr: string): string | null {
  const output = [stdout, stderr].filter(Boolean).join('\n').trim();
  return output ? `TEST FAILURE: ${label}:\n${output.slice(0, 1500)}` : null;
}

/**
 * The JS/TS runner command for `testFile`, or null. The project must configure the runner AND
 * have it installed in node_modules/.bin: guessing wrong costs a confusing "missing runner"
 * error that reads as a test failure, and `npx` may fetch a different version.
 */
export function jsRunnerCommand(projectRoot: string, testFile: string): [string, string[]] | null {
  const hasVitest =
    existsSync(join(projectRoot, 'vitest.config.ts')) ||
    existsSync(join(projectRoot, 'vite.config.ts'));
  const hasJest =
    existsSync(join(projectRoot, 'jest.config.js')) ||
    existsSync(join(projectRoot, 'jest.config.ts'));
  const bin = join(projectRoot, 'node_modules', '.bin');
  if (hasVitest && existsSync(join(bin, 'vitest'))) return [join(bin, 'vitest'), ['run', testFile]];
  if (hasJest && existsSync(join(bin, 'jest'))) return [join(bin, 'jest'), ['--bail', testFile]];
  return null;
}

function runTest(testFile: string, projectRoot: string): string | null {
  const ext = extname(testFile).slice(1).toLowerCase();

  if (ext === 'py') {
    if (!commandExists('pytest')) return null;
    const result = execArgvCapture('pytest', [testFile, '-x', '-q', '--tb=short'], {
      timeout: TEST_TIMEOUT,
      cwd: projectRoot,
    });
    return result.exitCode !== 0 ? report(`pytest ${basename(testFile)}`, result.stdout, result.stderr) : null;
  }

  const cmd = jsRunnerCommand(projectRoot, testFile);
  if (!cmd) return null;
  const result = execArgvCapture(cmd[0], cmd[1], { timeout: TEST_TIMEOUT, cwd: projectRoot });
  return result.exitCode !== 0 ? report(basename(testFile), result.stdout, result.stderr) : null;
}

const TESTABLE_EXTS = ['py', 'ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs'];

/**
 * Count this edit and, when the gate opens, run the covering test. Returns a failure report or
 * null. `fileAbs` is already realpath'd and inside `projectRoot`. Never throws.
 */
export function maybeRunTests(fileAbs: string, projectRoot: string, now: number = Date.now()): string | null {
  try {
    const ext = extname(fileAbs).slice(1).toLowerCase();
    if (!TESTABLE_EXTS.includes(ext)) return null;

    // Editing a test does not need the test run: running a half-written test reports a failure
    // that is the point of the edit.
    const base = basename(fileAbs);
    if (/\.(test|spec)\.[cm]?[jt]sx?$/.test(base) || base.startsWith('test_')) return null;

    const statePath = getStatePath(projectRoot);
    if (!statePath) return null; // no scratch space: do not run, rather than run on every edit

    const state = loadState(statePath);
    state.edit_count++;
    saveState(statePath, state);
    if (!shouldRunTests(state, now)) return null;

    // Reset even when no test exists. Otherwise a file with no test keeps the counter above the
    // threshold and the next edit to a file that DOES have one runs immediately.
    saveState(statePath, { edit_count: 0, last_run_at: now });
    const testFile = findTestFile(fileAbs, projectRoot);
    return testFile ? runTest(testFile, projectRoot) : null;
  } catch {
    return null;
  }
}
