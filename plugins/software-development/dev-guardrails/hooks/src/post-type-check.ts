// PostToolUse hook (Write/Edit): run the project's own static analysis on the file just written
// and feed the errors straight back to Claude. Non-blocking — always exits 0.
//
// THE POINT IS THE LATENCY, not the coverage. Every tool run here also runs in CI; the difference
// is that CI answers in minutes and after a push, by which time the model has moved on and the
// error has to be re-derived from a log. Running it inline turns a type error into something the
// model fixes in its next turn.
//
// NOTHING IS INSTALLED AND NOTHING IS CONFIGURED. Each checker runs only when the tool is already
// on PATH and the project already has the config that tool needs (a tsconfig, a mypy section).
// A hook that introduces a linter the project never chose is a hook that gets uninstalled.
//
// FORMATTERS ARE DELIBERATELY ABSENT. Running `ruff format` / `prettier` / `terraform fmt` on
// every intermediate Edit rewrites a file mid-way through a multi-step change, which invalidates
// the `old_string` of the edits still to come. Formatting belongs at commit time.

import { readStdin } from './lib/stdin.ts';
import { info } from './lib/output.ts';
import { execArgv, execArgvCapture, commandExists } from './lib/shell.ts';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { resolve, extname, basename, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_OUTPUT = 2000;
const TOOL_TIMEOUT = 15_000;

function truncate(text: string): string {
  if (text.length <= MAX_OUTPUT) return text;
  return text.slice(0, MAX_OUTPUT) + '\n... (truncated)';
}

function reportErrors(
  language: string,
  tool: string,
  file: string,
  stdout: string,
  stderr: string,
): void {
  const output = [stdout, stderr].filter(Boolean).join('\n').trim();
  if (!output) return;
  info(`TYPE CHECK [${language}]: ${tool} found issues in ${basename(file)}:\n${truncate(output)}`);
}

// argv, not a shell string: `filePath` is tool input and a directory whose NAME contains a
// command substitution would otherwise execute here.
function findProjectRoot(filePath: string): string {
  return (
    execArgv('git', ['-C', dirname(filePath), 'rev-parse', '--show-toplevel'], { timeout: 5000 }) ??
    process.cwd()
  );
}

// --- Language-specific checkers --------------------------------------------------------------

function hasMypyConfig(projectRoot: string): boolean {
  if (
    existsSync(join(projectRoot, 'mypy.ini')) ||
    existsSync(join(projectRoot, '.mypy.ini')) ||
    existsSync(join(projectRoot, 'setup.cfg'))
  ) {
    return true;
  }
  const pyproject = join(projectRoot, 'pyproject.toml');
  if (!existsSync(pyproject)) return false;
  try {
    return readFileSync(pyproject, 'utf-8').includes('[tool.mypy]');
  } catch {
    return false;
  }
}

function checkPython(filePath: string, projectRoot: string): void {
  // Lint only — never `--fix`. See the header on formatters.
  if (commandExists('ruff')) {
    const result = execArgvCapture('ruff', ['check', filePath], { timeout: TOOL_TIMEOUT });
    if (result.exitCode !== 0) reportErrors('Python', 'ruff', filePath, result.stdout, result.stderr);
  }

  // mypy is opt-in by config. Running it on a project that never adopted it produces hundreds of
  // findings about code nobody intends to annotate.
  if (commandExists('mypy') && hasMypyConfig(projectRoot)) {
    const result = execArgvCapture('mypy', [filePath, '--no-error-summary'], {
      timeout: TOOL_TIMEOUT,
      cwd: projectRoot,
    });
    if (result.exitCode !== 0) reportErrors('Python', 'mypy', filePath, result.stdout, result.stderr);
  }
}

function checkTypeScript(filePath: string, projectRoot: string): void {
  if (!existsSync(join(projectRoot, 'tsconfig.json'))) return;

  // Prefer the project's own tsc: `npx` may download a different version, and a version mismatch
  // produces errors that do not reproduce in the project's real build.
  const localTsc = join(projectRoot, 'node_modules', '.bin', 'tsc');
  const [bin, args]: [string, string[]] = existsSync(localTsc)
    ? [localTsc, ['--noEmit']]
    : ['npx', ['tsc', '--noEmit']];

  const result = execArgvCapture(bin, args, { timeout: TOOL_TIMEOUT, cwd: projectRoot });
  if (result.exitCode !== 0) reportErrors('TypeScript', 'tsc', filePath, result.stdout, result.stderr);
}

function checkTerraform(filePath: string): void {
  const tfDir = dirname(filePath);

  if (commandExists('tflint')) {
    const result = execArgvCapture('tflint', [filePath], { timeout: TOOL_TIMEOUT, cwd: tfDir });
    if (result.exitCode !== 0) {
      reportErrors('Terraform', 'tflint', filePath, result.stdout, result.stderr);
    }
  }

  // `terraform validate` needs an initialized directory; running it uninitialized reports a
  // missing-provider error that says nothing about the file just written.
  if (existsSync(join(tfDir, '.terraform')) && commandExists('terraform')) {
    const result = execArgvCapture('terraform', ['validate'], { timeout: TOOL_TIMEOUT, cwd: tfDir });
    if (result.exitCode !== 0) {
      reportErrors('Terraform', 'terraform validate', filePath, result.stdout, result.stderr);
    }
  }
}

/** True when a tsconfig opts JavaScript into type checking. */
export function tsconfigAllowsJs(tsconfigText: string): boolean {
  return /"allowJs"\s*:\s*true/.test(tsconfigText);
}

// --- Main --------------------------------------------------------------------------------------

async function run(): Promise<void> {
  try {
    const input = await readStdin();
    if (input.tool_name !== 'Write' && input.tool_name !== 'Edit') process.exit(0);

    const filePath = input.tool_input?.file_path ?? '';
    if (!filePath) process.exit(0);

    const resolved = resolve(filePath);
    if (!existsSync(resolved)) process.exit(0);

    // Through realpath first: `git rev-parse --show-toplevel` answers with symlinks resolved, so
    // the containment check below rejects every repo reached through a symlinked parent unless
    // both sides are normalised the same way.
    const fileAbs = realpathSync(resolved);

    const skipDirs = ['/node_modules/', '/dist/', '/build/', '/__pycache__/', '/.git/'];
    if (skipDirs.some((d) => fileAbs.includes(d))) process.exit(0);

    const projectRoot = findProjectRoot(fileAbs);
    // Refuse to run a project's tooling against a file outside that project.
    if (!fileAbs.startsWith(projectRoot + '/') && fileAbs !== projectRoot) process.exit(0);

    const ext = extname(fileAbs).slice(1).toLowerCase();

    switch (ext) {
      case 'py':
        checkPython(fileAbs, projectRoot);
        break;

      case 'ts':
      case 'tsx':
      case 'mts':
      case 'cts':
        checkTypeScript(fileAbs, projectRoot);
        break;

      case 'js':
      case 'jsx':
      case 'mjs':
      case 'cjs': {
        const tsconfigPath = join(projectRoot, 'tsconfig.json');
        if (existsSync(tsconfigPath)) {
          try {
            if (tsconfigAllowsJs(readFileSync(tsconfigPath, 'utf-8'))) {
              checkTypeScript(fileAbs, projectRoot);
            }
          } catch {
            /* unreadable tsconfig — nothing to check against */
          }
        }
        break;
      }

      case 'tf':
        checkTerraform(fileAbs);
        break;
    }
  } catch {
    // Silent failure — a broken checker must never look like a failed edit.
  }

  process.exit(0);
}

// Only run as the hook entrypoint. WITHOUT THIS GUARD THE TEST SUITE HANGS FOREVER: importing a
// module whose body awaits stdin at top level blocks during module evaluation, and the runner
// never reaches a single assertion.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
