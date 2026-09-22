// PostToolUse hook (Write/Edit): security and maintainability smells in the file just written.
// Non-blocking — always exits 0.
//
// THE DIVISION OF LABOUR WITH pre-write-edit.ts MATTERS. That hook BLOCKS, and it blocks exactly
// one class: credential-shaped content, which is unrecoverable once written (the bytes are on
// disk, and on a shared branch they are in history). Everything here is recoverable by editing
// the file again, so none of it blocks. A PostToolUse hook that blocked would be theatre anyway:
// it fires AFTER the write, so it can only stop the next step while leaving the file as written.
//
// TWO DIFFERENT INPUTS, deliberately:
//
//   - The SECURITY checks read the file from DISK. They are about the state of the file that now
//     exists, and an Edit's `new_string` shows only a fragment of it.
//   - The COMMENT-DENSITY check reads what THIS CALL WROTE (`content` / `new_string`). A
//     whole-file metric would charge an agent for comments it did not write, which is the fastest
//     way to make a style nudge worthless.
//
// FORMATTERS ARE DELIBERATELY ABSENT. Running one on every intermediate Edit rewrites the file
// mid-way through a multi-step change and invalidates the `old_string` of the edits still queued.

import { readStdin } from './lib/stdin.ts';
import { info } from './lib/output.ts';
import { analyzeCommentDensity, commentDensityMessage } from './lib/comment-density.ts';
import { execArgv } from './lib/shell.ts';
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

function emit(label: string, warnings: string[]): void {
  if (warnings.length > 0) info(`${label}:\n- ${warnings.join('\n- ')}`);
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

    // Through realpath BEFORE the containment check below. `git rev-parse --show-toplevel` always
    // answers with symlinks resolved, so comparing it against an unresolved path fails for every
    // repo reached through a symlinked parent — and the hook then silently reports nothing, which
    // is indistinguishable from a clean file.
    const fileAbs = realpathSync(resolved);

    // argv, not a shell string: the path is tool input, and a directory whose NAME contains a
    // command substitution would otherwise execute here.
    const projectRoot =
      execArgv('git', ['-C', dirname(fileAbs), 'rev-parse', '--show-toplevel'], { timeout: 5000 }) ??
      process.cwd();

    // Never report on a file outside the project being worked in.
    if (!fileAbs.startsWith(projectRoot + '/') && fileAbs !== projectRoot) process.exit(0);

    const ext = extname(fileAbs).slice(1).toLowerCase();

    // The text THIS call wrote, captured before the whole-file read below.
    const written = input.tool_input?.content ?? input.tool_input?.new_string ?? '';

    let content: string;
    try {
      content = readFileSync(fileAbs, 'utf-8');
    } catch {
      process.exit(0);
    }

    switch (extLanguage(ext)) {
      case 'py':
        emit('Python check', checkPython(content, fileAbs));
        break;
      case 'js':
        emit('JS/TS check', checkJavaScript(content, fileAbs));
        break;
      case 'tf':
        emit('Terraform check', checkTerraform(content));
        break;
      case 'shell':
        emit('Shell script check', checkShellScript(content, fileAbs));
        break;
      case 'other':
        break;
    }

    // Outside the switch, so it covers every language comment-density knows about without a
    // duplicate call in four arms.
    const density = analyzeCommentDensity(written, ext, fileAbs);
    if (density) info(commentDensityMessage(density));
  } catch {
    // Silent failure — never surface a hook fault as a failed edit.
  }

  process.exit(0);
}

// Only run as the hook entrypoint — importing (e.g. from tests) must not block on stdin.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
