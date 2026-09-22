// PostToolUse hook (Write/Edit): run the test file that covers the file just edited.
// Non-blocking — always exits 0.
//
// THRESHOLD-GATED, AND THE GATE IS THE DESIGN. Running a test suite on every single Edit turns a
// five-edit refactor into five test runs, four of which are against a half-finished state and all
// of which the model has to read. So a run needs BOTH: at least EDIT_THRESHOLD edits since the
// last run, AND at least COOLDOWN_MS since the last run. The counter and timestamp live in this
// plugin's scratch directory (lib/state-dir.ts) — not in the repository, which must not acquire
// untracked files because a hook ran, and not under the user's home Claude directory.
//
// IT ONLY RUNS A TEST THAT ALREADY EXISTS, found by naming convention next to the edited file. It
// never runs the whole suite: the point is a fast signal about the thing just changed, and a full
// suite is both slower and mostly about code this edit did not touch.

import { readStdin } from './lib/stdin.ts';
import { info } from './lib/output.ts';
import { execArgv, execArgvCapture, commandExists } from './lib/shell.ts';
import { stateFile } from './lib/state-dir.ts';
import { existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { resolve, extname, basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
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

function report(label: string, stdout: string, stderr: string): void {
  const output = [stdout, stderr].filter(Boolean).join('\n').trim();
  if (output) info(`TEST FAILURE: ${label}:\n${output.slice(0, 1500)}`);
}

function runTest(testFile: string, projectRoot: string): void {
  const ext = extname(testFile).slice(1).toLowerCase();

  if (ext === 'py') {
    if (!commandExists('pytest')) return;
    const result = execArgvCapture('pytest', [testFile, '-x', '-q', '--tb=short'], {
      timeout: TEST_TIMEOUT,
      cwd: projectRoot,
    });
    if (result.exitCode !== 0) report(`pytest ${basename(testFile)}`, result.stdout, result.stderr);
    return;
  }

  // Pick the runner the project actually configured. Guessing wrong costs a confusing error
  // about a missing runner, which reads as a test failure and is not one.
  const hasJest =
    existsSync(join(projectRoot, 'jest.config.js')) ||
    existsSync(join(projectRoot, 'jest.config.ts'));
  const hasVitest =
    existsSync(join(projectRoot, 'vitest.config.ts')) ||
    existsSync(join(projectRoot, 'vite.config.ts'));

  let bin: string | null = null;
  let args: string[] = [];
  if (hasVitest) {
    const local = join(projectRoot, 'node_modules', '.bin', 'vitest');
    bin = existsSync(local) ? local : 'npx';
    args = existsSync(local) ? ['run', testFile] : ['vitest', 'run', testFile];
  } else if (hasJest) {
    const local = join(projectRoot, 'node_modules', '.bin', 'jest');
    bin = existsSync(local) ? local : 'npx';
    args = existsSync(local) ? ['--bail', testFile] : ['jest', '--bail', testFile];
  }
  if (!bin) return;

  const result = execArgvCapture(bin, args, { timeout: TEST_TIMEOUT, cwd: projectRoot });
  if (result.exitCode !== 0) report(basename(testFile), result.stdout, result.stderr);
}

// --- Main --------------------------------------------------------------------------------------

async function run(): Promise<void> {
  try {
    const input = await readStdin();
    if (input.tool_name !== 'Write' && input.tool_name !== 'Edit') process.exit(0);

    const filePath = input.tool_input?.file_path ?? '';
    if (!filePath) process.exit(0);

    const fileAbs = resolve(filePath);
    if (!existsSync(fileAbs)) process.exit(0);

    const ext = extname(fileAbs).slice(1).toLowerCase();
    if (!['py', 'ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs'].includes(ext)) process.exit(0);

    // Editing a test does not need the test run — the author is about to run it themselves, and
    // running a half-written test reports a failure that is the point of the edit.
    const base = basename(fileAbs);
    if (/\.(test|spec)\.[cm]?[jt]sx?$/.test(base) || base.startsWith('test_')) process.exit(0);

    const skipDirs = ['/node_modules/', '/dist/', '/build/', '/__pycache__/', '/.git/'];
    if (skipDirs.some((d) => fileAbs.includes(d))) process.exit(0);

    const projectRoot =
      execArgv('git', ['-C', dirname(fileAbs), 'rev-parse', '--show-toplevel'], { timeout: 5000 }) ??
      process.cwd();

    const statePath = getStatePath(projectRoot);
    if (!statePath) process.exit(0); // no scratch space: do not run, rather than run on every edit

    const state = loadState(statePath);
    state.edit_count++;
    saveState(statePath, state);

    const now = Date.now();
    if (!shouldRunTests(state, now)) process.exit(0);

    const testFile = findTestFile(fileAbs, projectRoot);
    if (!testFile) {
      // Reset anyway. Otherwise a file with no test keeps the counter above threshold forever and
      // the very next edit to a file that DOES have one runs immediately, defeating the cooldown.
      saveState(statePath, { edit_count: 0, last_run_at: now });
      process.exit(0);
    }

    runTest(testFile, projectRoot);
    saveState(statePath, { edit_count: 0, last_run_at: now });
  } catch {
    // Silent failure — never surface a hook fault as a failed edit.
  }

  process.exit(0);
}

// Only run as the hook entrypoint. WITHOUT THIS GUARD THE TEST SUITE HANGS FOREVER: importing a
// module whose body awaits stdin at top level blocks during module evaluation, and the runner
// never reaches a single assertion.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
