// Type-check / lint stage of the PostToolUse Write|Edit hook. A MODULE, not an entry point:
// post-write-edit.ts is the only process Claude Code spawns for an edit, and it calls
// runTypeChecks() below. (Three separate processes used to run per edit; see that file.)
//
// THE POINT IS THE LATENCY, not the coverage. Every tool run here also runs in CI; the difference
// is that CI answers after a push, by which time the model has moved on. Inline, a type error is
// something the model fixes in its next turn.
//
// COST CONTROL, because this runs synchronously inside every edit:
//   - Per-file tools (ruff, tflint) run on every edit. They are fast and scoped to the file.
//   - Project-wide tools (tsc, mypy, terraform validate) are rate-limited per project by
//     PROJECT_CHECK_COOLDOWN_MS. `tsc --noEmit` checks the WHOLE project, so on a real codebase it
//     costs seconds per edit, and most edits in a multi-step change land on a half-finished state.
//   - tsc output is filtered to the edited file, with a one-line count of errors elsewhere, so a
//     broken neighbour does not re-inject the same wall of errors after every edit.
//
// NOTHING IS INSTALLED AND NOTHING IS CONFIGURED. A checker runs only when it is already on PATH
// (or in the project's node_modules/.bin) and the project already has its config. There is no
// `npx` fallback: npx resolves whatever tsc it can find or downloads one, and a different version
// produces errors that do not reproduce in the project's real build.
//
// FORMATTERS ARE DELIBERATELY ABSENT. Running one on every intermediate Edit rewrites the file
// mid-way through a multi-step change and invalidates the `old_string` of the edits still queued.

import { execArgvCapture, commandExists } from './lib/shell.ts';
import { stateFile } from './lib/state-dir.ts';
import { existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { basename, join, dirname, relative } from 'node:path';
import { createHash } from 'node:crypto';

const MAX_OUTPUT = 2000;
const TOOL_TIMEOUT = 15_000;

/** Minimum gap between project-wide checks for one project. */
export const PROJECT_CHECK_COOLDOWN_MS = 30_000;

function truncate(text: string): string {
  if (text.length <= MAX_OUTPUT) return text;
  return text.slice(0, MAX_OUTPUT) + '\n... (truncated)';
}

function section(language: string, tool: string, file: string, output: string): string | null {
  const body = output.trim();
  if (!body) return null;
  return `TYPE CHECK [${language}]: ${tool} reported issues for ${basename(file)}:\n${truncate(body)}`;
}

function captured(stdout: string, stderr: string): string {
  return [stdout, stderr].filter(Boolean).join('\n');
}

// --- Rate limit -------------------------------------------------------------------------------

function cooldownPath(projectRoot: string): string | null {
  const key = createHash('sha256').update(projectRoot).digest('hex').slice(0, 16);
  return stateFile(`typecheck-${key}.json`);
}

/**
 * True when a project-wide check may run now, and records the run when it does.
 * No scratch space means no rate limit record, so the answer is "skip": running tsc on every
 * edit is the failure this exists to prevent.
 */
function claimProjectCheck(projectRoot: string, now: number): boolean {
  const path = cooldownPath(projectRoot);
  if (!path) return false;
  let last = 0;
  try {
    if (existsSync(path)) last = Number(JSON.parse(readFileSync(path, 'utf-8')).last_run_at) || 0;
  } catch {
    /* unreadable state: treat as never run */
  }
  if (!shouldRunProjectCheck(last, now)) return false;
  try {
    writeFileSync(path + '.tmp', JSON.stringify({ last_run_at: now }));
    renameSync(path + '.tmp', path);
  } catch {
    /* best-effort */
  }
  return true;
}

/** Pure form of the rate limit, so it is assertable without a clock or a filesystem. */
export function shouldRunProjectCheck(lastRunAt: number, now: number): boolean {
  return now - lastRunAt >= PROJECT_CHECK_COOLDOWN_MS;
}

// --- TypeScript -------------------------------------------------------------------------------

/**
 * The tsc to run, or null. Only the project's own compiler: see the header on `npx`.
 */
export function tscCommand(projectRoot: string): [string, string[]] | null {
  if (!existsSync(join(projectRoot, 'tsconfig.json'))) return null;
  const localTsc = join(projectRoot, 'node_modules', '.bin', 'tsc');
  return existsSync(localTsc) ? [localTsc, ['--noEmit', '--pretty', 'false']] : null;
}

/**
 * Keep the diagnostics for the edited file; summarise the rest as counts per file.
 *
 * tsc (with --pretty false) prints `path(line,col): error TSnnnn: …` with paths relative to its
 * cwd, which is the project root here, and indents continuation lines. A continuation line
 * belongs to the diagnostic above it.
 */
export function filterTscOutput(output: string, fileAbs: string, projectRoot: string): string {
  const rel = relative(projectRoot, fileAbs).replace(/\\/g, '/');
  const own: string[] = [];
  const elsewhere = new Map<string, number>();
  let keeping = false;
  for (const line of output.split('\n')) {
    const m = /^(.+?)\(\d+,\d+\): (error|warning)/.exec(line);
    if (m) {
      const path = (m[1] as string).replace(/\\/g, '/');
      keeping = path === rel;
      if (keeping) own.push(line);
      else elsewhere.set(path, (elsewhere.get(path) ?? 0) + 1);
      continue;
    }
    if (keeping && /^\s/.test(line)) own.push(line);
    else if (!/^\s/.test(line)) keeping = false;
  }
  const parts: string[] = [];
  if (own.length > 0) parts.push(own.join('\n'));
  if (elsewhere.size > 0) {
    const total = [...elsewhere.values()].reduce((a, b) => a + b, 0);
    const files = [...elsewhere.entries()].slice(0, 5).map(([f, n]) => `${f} (${n})`).join(', ');
    const more = elsewhere.size > 5 ? `, +${elsewhere.size - 5} more files` : '';
    parts.push(`${total} diagnostic(s) in other files: ${files}${more}`);
  }
  return parts.join('\n');
}

function checkTypeScript(fileAbs: string, projectRoot: string): string | null {
  const cmd = tscCommand(projectRoot);
  if (!cmd) return null;
  const result = execArgvCapture(cmd[0], cmd[1], { timeout: TOOL_TIMEOUT, cwd: projectRoot });
  if (result.exitCode === 0) return null;
  const out = captured(result.stdout, result.stderr);
  return section('TypeScript', 'tsc', fileAbs, filterTscOutput(out, fileAbs, projectRoot));
}

/** True when a tsconfig opts JavaScript into type checking. */
export function tsconfigAllowsJs(tsconfigText: string): boolean {
  return /"allowJs"\s*:\s*true/.test(tsconfigText);
}

// --- Python -----------------------------------------------------------------------------------

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

// --- Entry for post-write-edit ----------------------------------------------------------------

/**
 * Run the checks that apply to `fileAbs` and return one report section per tool that found
 * something. `ext` is the lower-case extension without the dot. Never throws.
 */
export function runTypeChecks(
  fileAbs: string,
  projectRoot: string,
  ext: string,
  now: number = Date.now(),
): string[] {
  const out: Array<string | null> = [];
  // Claimed lazily, at most once, and only when a project-wide tool would actually run, so an
  // edit to a Markdown file does not consume the window.
  let claimed: boolean | null = null;
  const mayRunProjectWide = (): boolean => (claimed ??= claimProjectCheck(projectRoot, now));

  try {
    switch (ext) {
      case 'py': {
        // Lint only — never `--fix`. See the header on formatters.
        if (commandExists('ruff')) {
          const r = execArgvCapture('ruff', ['check', fileAbs], { timeout: TOOL_TIMEOUT });
          if (r.exitCode !== 0) out.push(section('Python', 'ruff', fileAbs, captured(r.stdout, r.stderr)));
        }
        // mypy is opt-in by config: on a project that never adopted it, it reports hundreds of
        // findings about code nobody intends to annotate.
        if (commandExists('mypy') && hasMypyConfig(projectRoot) && mayRunProjectWide()) {
          const r = execArgvCapture('mypy', [fileAbs, '--no-error-summary'], {
            timeout: TOOL_TIMEOUT,
            cwd: projectRoot,
          });
          if (r.exitCode !== 0) out.push(section('Python', 'mypy', fileAbs, captured(r.stdout, r.stderr)));
        }
        break;
      }
      case 'ts': case 'tsx': case 'mts': case 'cts':
        if (tscCommand(projectRoot) && mayRunProjectWide()) out.push(checkTypeScript(fileAbs, projectRoot));
        break;
      case 'js': case 'jsx': case 'mjs': case 'cjs': {
        const tsconfigPath = join(projectRoot, 'tsconfig.json');
        let allowsJs = false;
        try {
          allowsJs = existsSync(tsconfigPath) && tsconfigAllowsJs(readFileSync(tsconfigPath, 'utf-8'));
        } catch {
          /* unreadable tsconfig — nothing to check against */
        }
        if (allowsJs && tscCommand(projectRoot) && mayRunProjectWide()) {
          out.push(checkTypeScript(fileAbs, projectRoot));
        }
        break;
      }
      case 'tf': {
        const tfDir = dirname(fileAbs);
        if (commandExists('tflint')) {
          const r = execArgvCapture('tflint', [`--filter=${basename(fileAbs)}`], {
            timeout: TOOL_TIMEOUT,
            cwd: tfDir,
          });
          if (r.exitCode !== 0) out.push(section('Terraform', 'tflint', fileAbs, captured(r.stdout, r.stderr)));
        }
        // `terraform validate` needs an initialised directory; uninitialised, it reports a
        // missing-provider error that says nothing about the file just written.
        if (existsSync(join(tfDir, '.terraform')) && commandExists('terraform') && mayRunProjectWide()) {
          const r = execArgvCapture('terraform', ['validate', '-no-color'], { timeout: TOOL_TIMEOUT, cwd: tfDir });
          if (r.exitCode !== 0) {
            out.push(section('Terraform', 'terraform validate', fileAbs, captured(r.stdout, r.stderr)));
          }
        }
        break;
      }
    }
  } catch {
    // A broken checker must never look like a failed edit.
  }
  return out.filter((s): s is string => s !== null);
}
