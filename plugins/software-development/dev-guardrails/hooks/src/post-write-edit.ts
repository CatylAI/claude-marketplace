// PostToolUse hook (Write|Edit): the ONE process Claude Code spawns after a file edit. It runs
// three stages and reports them together. Non-blocking: always exits 0.
//
//   1. Smells (this file): security and maintainability patterns, plus the comment-density nudge.
//   2. Type check / lint (post-type-check.ts): the project's own checkers, rate-limited.
//   3. Tests (post-test.ts): the covering test, gated by edit count and cooldown.
//
// ONE PROCESS, NOT THREE. Each stage used to be its own hook entry, so every Write/Edit paid three
// node start-ups and three `git rev-parse` calls, and three hooks each re-derived the same project
// root. Consolidated, the fixed cost is paid once.
//
// OUTPUT GOES TO CLAUDE THROUGH additionalContext. The old stages wrote to stderr and exited 0,
// and Claude Code sends that to the debug log only: none of these findings ever reached the model.
// Everything is now collected and emitted as one JSON object (lib/additional-context.ts).
//
// THE DIVISION OF LABOUR WITH pre-write-edit.ts. That hook BLOCKS, and only on what is
// unrecoverable once written (credentials, writes into an installed plugin copy). Everything here
// is recoverable by editing again, so it only informs. Blocking would be theatre anyway: this
// fires AFTER the write.
//
// FINDINGS ARE ABOUT WHAT THIS CALL CHANGED. A finding that was already in the file before this
// Edit is not repeated: re-reporting the same `innerHTML` on every edit to a file is pure context
// cost and trains the reader to skip the section. For an Edit the previous file is reconstructed
// by reversing the replacement; a Write reports on the whole file, since it wrote all of it.
//
// FORMATTERS ARE DELIBERATELY ABSENT. Running one on every intermediate Edit rewrites the file
// mid-way through a multi-step change and invalidates the `old_string` of the edits still queued.

import { readStdin } from './lib/stdin.ts';
import type { HookInput } from './lib/types.ts';
import { emitContext } from './lib/additional-context.ts';
import { analyzeCommentDensity, commentDensityMessage } from './lib/comment-density.ts';
import { execArgv } from './lib/shell.ts';
import { runTypeChecks } from './post-type-check.ts';
import { maybeRunTests } from './post-test.ts';
import {
  SHELL_TRUE, FSTRING_SQL, AWS_KEY,
  INNER_HTML, DANGEROUS_SET_INNER_HTML, V_HTML, EVAL_CALL,
  TF_PUBLICLY_ACCESSIBLE, TF_OPEN_CIDR, TF_IAM_USER,
  TF_UNENCRYPTED, TF_PUBLIC_S3, TF_WILDCARD_IAM, TF_WILDCARD_RESOURCE,
  HARDCODED_BASH_PATH,
} from './lib/patterns.ts';
import { readFileSync, existsSync, realpathSync } from 'node:fs';
import { extname, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Which language family an extension belongs to.
 *
 * Exported so the extension list is assertable in a unit test instead of living only in `case`
 * labels, where a missing `mts` / `cts` goes unnoticed indefinitely — the checks simply never run
 * on those files and nothing says so.
 */
export function extLanguage(ext: string): 'py' | 'js' | 'tf' | 'shell' | 'other' {
  switch (ext) {
    case 'py':
      return 'py';
    case 'ts': case 'tsx': case 'mts': case 'cts':
    case 'js': case 'jsx': case 'mjs': case 'cjs':
      return 'js';
    case 'tf': case 'tfvars':
      return 'tf';
    case 'sh': case 'bash': case 'zsh':
      return 'shell';
    default:
      return 'other';
  }
}

// --- Per-language checks. Each returns its findings rather than printing, so each is testable
//     on its own and the caller decides how they are surfaced. -------------------------------

export function checkPython(content: string, filePath: string): string[] {
  const warnings: string[] = [];
  if (SHELL_TRUE.test(content)) {
    warnings.push('SECURITY: shell=True — the argument string is parsed by a shell (injection risk)');
  }
  if (FSTRING_SQL.test(content)) {
    warnings.push('SECURITY: SQL built with an f-string — use bound parameters (injection risk)');
  }

  // Test doubles under a source tree are a maintainability smell with teeth: a mock that ships in
  // src/ can be imported by production code, and then the fake is what runs.
  if (/(^|\/)src\//.test(filePath)) {
    if (/from unittest\.mock import|from unittest import mock|from mock import/.test(content)) {
      warnings.push('STRUCTURE: mock import under src/ — test doubles belong in the test tree');
    }
    if (/Mock\(|MagicMock\(|patch\(|@patch|@mock\./.test(content)) {
      warnings.push('STRUCTURE: mock/patch usage under src/ — test doubles belong in the test tree');
    }
  }

  if (/raise Exception\(/.test(content)) {
    warnings.push('QUALITY: bare Exception() — raise a specific type so callers can catch it');
  }
  const printCount = (content.match(/print\(/g) ?? []).length;
  if (printCount > 2) {
    warnings.push(`QUALITY: ${printCount} print() calls — use the logging module`);
  }

  return warnings;
}

export function checkJavaScript(content: string, filePath: string): string[] {
  const warnings: string[] = [];
  if (INNER_HTML.test(content)) warnings.push('SECURITY: innerHTML assignment (XSS risk)');
  if (DANGEROUS_SET_INNER_HTML.test(content)) {
    warnings.push('SECURITY: dangerouslySetInnerHTML (XSS risk)');
  }
  if (V_HTML.test(content)) warnings.push('SECURITY: v-html directive (XSS risk)');
  if (EVAL_CALL.test(content)) warnings.push('SECURITY: eval() (code injection risk)');

  if (/(^|\/)src\//.test(filePath)) {
    if (/jest\.mock\(|vi\.mock\(|sinon\./.test(content)) {
      warnings.push('STRUCTURE: mock framework used under src/ — test doubles belong in the test tree');
    }
    if (/class (Mock|Stub|Fake)[A-Z]/.test(content)) {
      warnings.push('STRUCTURE: Mock/Stub/Fake class under src/ — test doubles belong in the test tree');
    }
  }

  const isTest = /\.(test|spec)\./.test(filePath);
  if (!isTest) {
    const consoleCount = (content.match(/console\./g) ?? []).length;
    if (consoleCount > 3) {
      warnings.push(`QUALITY: ${consoleCount} console statements — use a logger`);
    }
  }
  if (/throw new Error\(\);/.test(content)) {
    warnings.push('QUALITY: Error() with no message — the stack alone will not say what happened');
  }

  return warnings;
}

export function checkTerraform(content: string): string[] {
  const warnings: string[] = [];
  if (TF_PUBLICLY_ACCESSIBLE.test(content)) {
    warnings.push('CRITICAL: publicly_accessible = true — this exposes the resource to the internet');
  }
  if (TF_OPEN_CIDR.test(content)) warnings.push('SECURITY: 0.0.0.0/0 CIDR — open to the internet');
  if (TF_IAM_USER.test(content)) {
    warnings.push('SECURITY: aws_iam_user — long-lived keys; prefer a role assumed through SSO/OIDC');
  }
  if (TF_UNENCRYPTED.test(content)) warnings.push('SECURITY: storage_encrypted = false');
  if (TF_PUBLIC_S3.test(content)) warnings.push('SECURITY: block_public_acls = false');
  // Reported only TOGETHER — either alone is how most real policies are written.
  if (TF_WILDCARD_IAM.test(content) && TF_WILDCARD_RESOURCE.test(content)) {
    warnings.push('SECURITY: wildcard Action AND Resource in one policy — this is an admin grant');
  }
  if (AWS_KEY.test(content)) {
    warnings.push('CRITICAL: an AWS access key id appears in this file');
  }
  return warnings;
}

export function checkShellScript(content: string, filePath: string): string[] {
  const warnings: string[] = [];
  if (HARDCODED_BASH_PATH.test(content)) {
    warnings.push(
      'PORTABILITY: hardcoded interpreter path — prefer #!/usr/bin/env bash ' +
        '(/bin/bash is 3.2 on macOS and /usr/bin/bash does not exist there)',
    );
  }
  // `set -e` in a hook is the specific footgun: the hook exits mid-way with a non-zero status and
  // Claude Code reads that as a deny decision, from a script that was only doing cleanup.
  if (
    /^set\s+-[a-zA-Z]*e[a-zA-Z]*(?:\s|$)/m.test(content) &&
    !/pipefail/.test(content.slice(0, 200)) &&
    /(^|\/)hooks\//.test(filePath)
  ) {
    warnings.push("ERROR HANDLING: `set -e` in a hook exits silently mid-script — use `set -uo pipefail`");
  }
  if (/terraform init[^-]|terraform init$/.test(content) && !/terraform init.*-backend-config/.test(content)) {
    warnings.push('TERRAFORM: `terraform init` with no -backend-config — this can target the wrong state');
  }
  return warnings;
}

const LABELS: Record<'py' | 'js' | 'tf' | 'shell', string> = {
  py: 'Python check',
  js: 'JS/TS check',
  tf: 'Terraform check',
  shell: 'Shell script check',
};

/** The smell findings for `content`, by language. [] for a language with no checks. */
export function smellFindings(content: string, ext: string, fileAbs: string): string[] {
  switch (extLanguage(ext)) {
    case 'py': return checkPython(content, fileAbs);
    case 'js': return checkJavaScript(content, fileAbs);
    case 'tf': return checkTerraform(content);
    case 'shell': return checkShellScript(content, fileAbs);
    case 'other': return [];
  }
}

/**
 * The file as it was before an Edit, reconstructed from the file now on disk, or null when that
 * is not possible (an empty new_string leaves nothing to locate).
 */
export function reverseEdit(after: string, oldString: string, newString: string, replaceAll: boolean): string | null {
  if (!newString) return null;
  const at = after.indexOf(newString);
  if (at === -1) return null;
  if (replaceAll) return after.split(newString).join(oldString);
  return after.slice(0, at) + oldString + after.slice(at + newString.length);
}

/**
 * Findings present after the call and not before. Counts are ignored when comparing, so "5
 * console statements" after "4 console statements" is the same finding and is not repeated.
 */
export function introducedFindings(before: readonly string[], after: readonly string[]): string[] {
  const shape = (f: string): string => f.replace(/\d+/g, '#');
  const had = new Set(before.map(shape));
  return after.filter((f) => !had.has(shape(f)));
}

/**
 * Stage 1 for one call. `current` is the file on disk now. Pure apart from its inputs.
 */
export function smellReport(input: HookInput, current: string, ext: string, fileAbs: string): string | null {
  const ti = input.tool_input ?? {};
  const written = typeof ti.content === 'string' ? ti.content : (ti.new_string ?? '');
  let findings: string[];
  if (input.tool_name === 'Edit') {
    const before = reverseEdit(current, ti.old_string ?? '', ti.new_string ?? '', ti.replace_all === true);
    findings = before === null
      ? smellFindings(written, ext, fileAbs) // cannot reconstruct: judge the fragment alone
      : introducedFindings(smellFindings(before, ext, fileAbs), smellFindings(current, ext, fileAbs));
  } else {
    findings = smellFindings(current, ext, fileAbs);
  }

  const parts: string[] = [];
  const lang = extLanguage(ext);
  if (findings.length > 0 && lang !== 'other') parts.push(`${LABELS[lang]}:\n- ${findings.join('\n- ')}`);
  // Density measures what THIS call wrote, never the whole file (see lib/comment-density.ts).
  const density = analyzeCommentDensity(written, ext, fileAbs);
  if (density) parts.push(commentDensityMessage(density));
  return parts.length > 0 ? parts.join('\n\n') : null;
}

// --- Main --------------------------------------------------------------------------------------

const SKIP_DIRS = ['/node_modules/', '/dist/', '/build/', '/__pycache__/', '/.git/'];

/**
 * The test stage starts only if the earlier stages finished inside this budget. The hook's
 * registered timeout is 60 s and a timed-out hook's output is discarded whole, so a slow type
 * check followed by a 30 s test run must not be allowed to lose both reports.
 */
export const TEST_STAGE_START_BUDGET_MS = 25_000;

async function run(): Promise<void> {
  const started = Date.now();
  try {
    const input = await readStdin();
    if (input.tool_name !== 'Write' && input.tool_name !== 'Edit') process.exit(0);

    const filePath = input.tool_input?.file_path ?? '';
    if (!filePath) process.exit(0);

    const resolved = resolve(filePath);
    if (!existsSync(resolved)) process.exit(0);

    // Through realpath BEFORE the containment check below. `git rev-parse --show-toplevel` answers
    // with symlinks resolved, so an unresolved path fails containment for every repo reached
    // through a symlinked parent, and the hook then reports nothing.
    const fileAbs = realpathSync(resolved);
    if (SKIP_DIRS.some((d) => fileAbs.includes(d))) process.exit(0);

    // argv, not a shell string: the path is tool input, and a directory whose NAME contains a
    // command substitution would otherwise execute here.
    const projectRoot =
      execArgv('git', ['-C', dirname(fileAbs), 'rev-parse', '--show-toplevel'], { timeout: 5000 }) ??
      process.cwd();

    // Never report on, or run a project's tooling against, a file outside the project.
    if (!fileAbs.startsWith(projectRoot + '/') && fileAbs !== projectRoot) process.exit(0);

    const ext = extname(fileAbs).slice(1).toLowerCase();
    const sections: string[] = [];

    let current = '';
    try {
      current = readFileSync(fileAbs, 'utf-8');
    } catch {
      /* unreadable: the smell stage has nothing to judge, the others may still apply */
    }
    const smells = current ? smellReport(input, current, ext, fileAbs) : null;
    if (smells) sections.push(smells);

    sections.push(...runTypeChecks(fileAbs, projectRoot, ext));

    if (Date.now() - started < TEST_STAGE_START_BUDGET_MS) {
      const tests = maybeRunTests(fileAbs, projectRoot);
      if (tests) sections.push(tests);
    }

    emitContext('PostToolUse', sections.join('\n\n'));
  } catch {
    // Fail open and silent: a broken check must never look like a failed edit.
  }

  process.exit(0);
}

// Only run as the hook entrypoint. Without this guard, importing the module (as the tests do)
// would block on stdin during module evaluation and the runner would never reach an assertion.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
