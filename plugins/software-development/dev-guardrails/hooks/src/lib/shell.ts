// Shell execution helpers — execSync/execFileSync wrappers with a timeout. None of them throw.
//
// TWO functions, and the difference between them is a security boundary rather than a style
// preference:
//
//   exec(cmd)             — `cmd` is handed to `/bin/sh -c`. Pipes, redirections and
//                           `command -v` work, and so do `$(…)`, backticks and `$VAR`
//                           ANYWHERE in the string, INCLUDING inside double quotes. Quoting an
//                           interpolated value is therefore not a defence: `JSON.stringify(path)`
//                           yields a double-quoted string and the shell still substitutes inside it.
//   execArgv(file, args)  — argv, no shell at all. Every element of `args` reaches the program as
//                           one literal argument whatever it contains.
//
// Use `execArgv` whenever any part of the command comes from the filesystem, the environment, or
// anything else the caller did not write literally. Reach for `exec` only when a shell FEATURE is
// actually needed.
//
// Two axes to watch when reviewing a call site that builds a shell string:
//
//   - a QUOTED interpolation — `git -C "${somePath}"` — needs a quote-break or a substitution to
//     escape the argument.
//   - an UNQUOTED one — `rev-list --count ${someBranch}..HEAD` — needs neither: whitespace alone
//     adds arguments. Branch names reach these sites from a remote, so this axis is both easier to
//     exploit and easier to miss when reading, since there are no quotes to notice the absence of.
//
// A shell feature in the string (`&&`, a pipe, a redirect) is not a reason a site is safe — only a
// reason its conversion to `execArgv` is more than a one-liner.

import { execFileSync, execSync } from 'node:child_process';

export interface ExecOptions {
  timeout?: number;
  cwd?: string;
}

/**
 * Run a command through a SHELL, returning stdout or null on failure. Never throws.
 *
 * `cmd` is a shell string: anything interpolated into it is code, not data. See the header.
 */
export function exec(cmd: string, opts?: ExecOptions): string | null {
  try {
    return execSync(cmd, {
      encoding: 'utf-8',
      timeout: opts?.timeout ?? 10_000,
      cwd: opts?.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch {
    return null;
  }
}

/**
 * Run a command with an ARGV array — no shell — returning stdout or null on failure. Never throws.
 *
 * The sibling of `exec` for "run this program with these arguments", where the arguments are paths
 * or other data. `file` is still resolved from PATH (deliberately: a hardcoded `/usr/bin/git`
 * breaks across macOS, Linux and CI images alike), so it must stay a literal — the guarantee here
 * is about the ARGUMENTS.
 */
export function execArgv(file: string, args: string[], opts?: ExecOptions): string | null {
  try {
    return execFileSync(file, args, {
      encoding: 'utf-8',
      timeout: opts?.timeout ?? 10_000,
      cwd: opts?.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: false,
    }).trim();
  } catch {
    return null;
  }
}

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

/** Run a shell command, capturing stdout, stderr and exit code. Never throws. */
export function execCapture(cmd: string, opts?: ExecOptions): ExecResult {
  try {
    const stdout = execSync(cmd, {
      encoding: 'utf-8',
      timeout: opts?.timeout ?? 10_000,
      cwd: opts?.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    return { stdout, stderr: '', exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string | Buffer; stderr?: string | Buffer; status?: number };
    return {
      stdout: String(e.stdout ?? '').trim(),
      stderr: String(e.stderr ?? '').trim(),
      exitCode: e.status ?? 1,
    };
  }
}

/**
 * `execCapture`'s argv sibling: run a program with an argument array and capture stdout, stderr
 * and exit code. Never throws, and never involves a shell.
 *
 * This is the one to use for "run this checker over this file", where the file path is data.
 * `execCapture` would need the path interpolated into a shell string, and double quotes do not
 * stop `$(…)` from substituting inside them.
 */
export function execArgvCapture(file: string, args: string[], opts?: ExecOptions): ExecResult {
  try {
    const stdout = execFileSync(file, args, {
      encoding: 'utf-8',
      timeout: opts?.timeout ?? 10_000,
      cwd: opts?.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: false,
    }).trim();
    return { stdout, stderr: '', exitCode: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string | Buffer; stderr?: string | Buffer; status?: number };
    return {
      stdout: String(e.stdout ?? '').trim(),
      stderr: String(e.stderr ?? '').trim(),
      exitCode: e.status ?? 1,
    };
  }
}

/** True when `name` resolves on PATH. */
export function commandExists(name: string): boolean {
  return exec(`command -v ${name}`) !== null;
}
