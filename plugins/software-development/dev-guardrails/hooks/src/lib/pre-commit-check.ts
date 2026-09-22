// Pre-commit health check — is this repo's pre-commit setup capable of blocking anything?
//
// Called from session-start.ts. It reports only; nothing here installs, rewrites or runs a hook.
// A session-start check that mutates the repository is a check people turn off.
//
// The three findings it exists for, in descending order of how badly they mislead a reader:
//
//   1. A hook whose `entry` swallows its own failure. The config asserts coverage that does not
//      exist, and nobody re-reads an entry line. Worse than a missing hook.
//   2. `stages: [pre-push]` hooks declared with no pre-push shim installed — configured, inert,
//      and invisible until the thing they were meant to catch lands on the remote.
//   3. Required hooks absent altogether.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { execArgv } from './shell.ts';
import { context } from './output.ts';

/**
 * Hooks a repo with a pre-commit config should carry. Deliberately short: each one catches a
 * class of defect that is cheap to detect and expensive to land.
 */
const REQUIRED_HOOK_IDS = new Set([
  'detect-private-key',
  'check-merge-conflict',
  'end-of-file-fixer',
  'trailing-whitespace',
]);

/** Shim types a converged repo has in its hooks directory. */
const REQUIRED_SHIMS = ['pre-commit', 'commit-msg'] as const;

export interface PreCommitResult {
  configPresent: boolean;
  hooksInstalled: boolean;
  /** Which of REQUIRED_SHIMS are absent from the hooks directory. */
  missingShims: string[];
  missingRequired: string[];
  /** Local hooks whose `entry` swallows its own failure, so the hook can never fail. */
  cannotFail: string[];
  /** Config declares `stages: [pre-push]` hooks but no pre-push shim is installed. */
  declaresPrePushWithoutShim: boolean;
  /** `default_install_hook_types` absent while pre-push hooks are declared — the root cause. */
  missingInstallHookTypes: boolean;
}

/**
 * Absolute path to the repo's hooks directory, or null if it cannot be determined.
 *
 * NOT `join(repoRoot, '.git', 'hooks')`. Inside a git worktree `.git` is a FILE containing
 * `gitdir: …`, so that path does not exist and the caller concludes "hooks not installed" — for
 * EVERY worktree. Feature work happens in worktrees often enough that this turns the warning into
 * noise, which is how a real warning gets trained out.
 *
 * `git rev-parse --git-path hooks` is the correct query: it resolves worktrees (returning the
 * MAIN repo's shared hooks dir, where pre-commit installs) and honours `core.hooksPath`. It
 * returns a repo-relative path in a normal checkout and an absolute one from a worktree.
 *
 * `execArgv`, not `exec`: `repoRoot` is a filesystem path this process did not author, and a
 * directory whose NAME contains a command substitution would otherwise run at session start.
 */
function resolveHooksDir(repoRoot: string): string | null {
  const out = execArgv('git', ['-C', repoRoot, 'rev-parse', '--git-path', 'hooks'], {
    timeout: 10_000,
  });
  if (out === null) return null;
  const p = out.trim();
  if (!p) return null;
  return p.startsWith('/') ? p : join(repoRoot, p);
}

/** Active (non-commented) hook ids in a `.pre-commit-config.yaml`. */
export function parseHookIds(content: string): Set<string> {
  const ids = new Set<string>();
  for (const line of content.split('\n')) {
    if (line.trimStart().startsWith('#')) continue;
    const m = line.match(/^\s+-\s+id:\s*(\S+)/);
    if (m) ids.add(m[1].trim());
  }
  return ids;
}

/**
 * Ids of `- repo: local` hooks whose `entry` discards its own non-zero exit, so the hook can
 * never fail. Two shapes, both observed in the wild:
 *
 *     entry: sh -c '... --exit-code 1 . || true'
 *     entry: sh -c 'command -v trivy >/dev/null && trivy ... --exit-code 1 . || echo "not installed"'
 *
 * The second is the worse one: `(A && B) || C`, so a tool that runs and FINDS something takes the
 * `||` branch, prints "not installed", and exits 0. A found secret is reported as a missing tool
 * and the commit proceeds.
 *
 * Only local hooks are considered: an upstream hook's entry is not in this file, and a `||` inside
 * a legitimately multi-command upstream entry is not ours to judge.
 */
export function parseCannotFailHooks(content: string): string[] {
  const offenders: string[] = [];
  const lines = content.split('\n');
  let inLocalRepo = false;
  let currentId = '';
  // Accumulate an entry that may be folded (`entry: >`) across several lines.
  let entryBuf: string | null = null;

  const swallowsFailure = (entry: string): boolean => {
    // `|| true`, `|| :`, `|| exit 0`, or `|| echo …` as the LAST alternative all discard the
    // command's own failure. `|| exit 1` is fine — it propagates.
    if (/\|\|\s*(true|:)\b/.test(entry)) return true;
    if (/\|\|\s*exit\s+0\b/.test(entry)) return true;
    if (/\|\|\s*echo\b/.test(entry) && !/\bexit\s+[1-9]/.test(entry.split('||').pop() ?? '')) {
      return true;
    }
    return false;
  };
  const flush = () => {
    if (currentId && entryBuf !== null && swallowsFailure(entryBuf)) offenders.push(currentId);
    entryBuf = null;
  };

  for (const line of lines) {
    if (line.trimStart().startsWith('#')) continue;
    const repoMatch = line.match(/^\s*-?\s*repo:\s*(.+)$/);
    if (repoMatch) {
      flush();
      inLocalRepo = repoMatch[1].trim() === 'local';
      currentId = '';
      continue;
    }
    const idMatch = line.match(/^\s+-\s+id:\s*(\S+)/);
    if (idMatch) {
      flush();
      currentId = idMatch[1].trim();
      continue;
    }
    if (!inLocalRepo || !currentId) continue;

    const entryStart = line.match(/^\s+entry:\s*(.*)$/);
    if (entryStart) {
      const rest = entryStart[1].trim();
      // `entry: >` / `entry: |` fold the value onto the following lines.
      entryBuf = rest === '>' || rest === '|' || rest === '>-' || rest === '|-' ? '' : rest;
      continue;
    }
    if (entryBuf !== null && /^\s{6,}\S/.test(line) && !/^\s+[a-z_]+:\s/.test(line)) {
      entryBuf += ' ' + line.trim();
      continue;
    }
    if (entryBuf !== null) flush();
  }
  flush();
  return offenders;
}

/** Hook ids declared with `stages: [pre-push]` (or `stages: [push]`, the older spelling). */
export function parsePrePushHookIds(content: string): Set<string> {
  const ids = new Set<string>();
  let currentId = '';
  for (const line of content.split('\n')) {
    if (line.trimStart().startsWith('#')) continue;
    const idMatch = line.match(/^\s+-\s+id:\s*(\S+)/);
    if (idMatch) {
      currentId = idMatch[1].trim();
      continue;
    }
    if (/^\s*-?\s*repo:\s*/.test(line)) {
      currentId = '';
      continue;
    }
    if (currentId && /^\s+stages:.*\b(pre-push|push)\b/.test(line)) ids.add(currentId);
  }
  return ids;
}

export function checkPreCommit(repoRoot: string): PreCommitResult {
  const result: PreCommitResult = {
    configPresent: false,
    hooksInstalled: false,
    missingShims: [],
    missingRequired: [],
    cannotFail: [],
    declaresPrePushWithoutShim: false,
    missingInstallHookTypes: false,
  };

  const configPath = join(repoRoot, '.pre-commit-config.yaml');
  result.configPresent = existsSync(configPath);

  const hooksDir = resolveHooksDir(repoRoot);
  for (const shim of REQUIRED_SHIMS) {
    if (!hooksDir || !existsSync(join(hooksDir, shim))) result.missingShims.push(shim);
  }
  result.hooksInstalled = result.missingShims.length === 0;

  if (!result.configPresent) return result;

  let content: string;
  try {
    content = readFileSync(configPath, 'utf-8');
  } catch {
    return result;
  }

  const hookIds = parseHookIds(content);
  for (const required of REQUIRED_HOOK_IDS) {
    if (!hookIds.has(required)) result.missingRequired.push(required);
  }

  result.cannotFail = parseCannotFailHooks(content);

  // Only warn when the config actually declares pre-push hooks — a repo with none needs no
  // pre-push shim, and warning there would be noise.
  if (parsePrePushHookIds(content).size > 0) {
    result.declaresPrePushWithoutShim = !hooksDir || !existsSync(join(hooksDir, 'pre-push'));
    // The root cause: without this key `pre-commit install` writes only the pre-commit shim, so
    // the declared pre-push hooks can never run however often it is re-run.
    result.missingInstallHookTypes = !/^\s*default_install_hook_types\s*:/m.test(content);
  }

  return result;
}

/** Run the check and emit context lines. Silent when the repo is healthy. */
export function runPreCommitCheck(repoRoot: string): void {
  const result = checkPreCommit(repoRoot);

  // No config at all is a matter of taste, not a defect — say it once, quietly, and stop.
  if (!result.configPresent) return;

  const issues: string[] = [];

  if (!result.hooksInstalled) {
    issues.push(
      `Shims missing (${result.missingShims.join(', ')}) — the config cannot run. ` +
        'Fix: pre-commit install --install-hooks',
    );
  }

  if (result.missingRequired.length > 0) {
    issues.push(`Missing baseline hooks: ${result.missingRequired.join(', ')}`);
  }

  if (result.cannotFail.length > 0) {
    issues.push(
      `Hook(s) that CANNOT FAIL: ${result.cannotFail.join(', ')}. The entry ends in ` +
        '`|| true` / `|| echo` / `|| exit 0`, so the tool\'s non-zero exit is discarded and the ' +
        'hook always passes. Worse than absent — the config claims coverage it does not have. ' +
        'Put the tool-absent case in its own if/else branch instead.',
    );
  }

  if (result.declaresPrePushWithoutShim) {
    issues.push(
      'Config declares stages: [pre-push] hooks but no pre-push shim is installed — those hooks ' +
        'are configured and CANNOT run. Fix: pre-commit install --hook-type pre-push',
    );
  }

  if (result.missingInstallHookTypes) {
    issues.push(
      'Config declares pre-push hooks but has no `default_install_hook_types:` — so ' +
        '`pre-commit install` writes only the pre-commit shim and the pre-push hooks stay inert ' +
        'for the next person who clones. Add: ' +
        'default_install_hook_types: [pre-commit, commit-msg, pre-push]',
    );
  }

  if (issues.length > 0) {
    context('PRE-COMMIT WARNING — this repo\'s pre-commit config cannot do what it claims:');
    for (const issue of issues) context(`   - ${issue}`);
  }
}
