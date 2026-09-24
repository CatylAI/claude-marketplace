// PreToolUse hook (Bash): policy enforcement.
//
// One process runs every gate, because each hook process adds latency to every Bash call.
// The gates live one per module under ./pre-bash/. main() runs them in this order:
//   Gate A  never PRINT a secret into the transcript           (secret-print.ts)
//   Gate C  never PUBLISH a secret through a forge CLI         (outbound.ts)
//   then the reversible-damage guards: rm -rf, forge policy, TTY, terraform backend,
//   destructive git, commit-message shape. Last come two non-blocking notes: a commit on a
//   protected branch, and a nudge to sync before creating a branch.
//
// Every gate reads the command through lib/bash-parse.ts, not with a regex over the raw
// line, so `git -C x push -f`, `sudo rm -rf`, `bash -c '…'` and a second command on the
// next line are all judged, and `echo "git push --force"` is not.
//
// Output (code.claude.com/docs/en/hooks):
//   block   exit 2, reason on stderr. Claude reads it as the deny reason. The reason is
//           passed through the secret redactor first, so a deny never repeats a token
//           that appeared in the command.
//   notes   exit 0 with `hookSpecificOutput.additionalContext` JSON. Plain stdout on a
//           PreToolUse exit 0 reaches only the debug log.
//   crash   exit 1 with a one-line stderr note: Claude Code shows a hook-error notice and
//           the command proceeds. Fail OPEN here on purpose: a parser bug must not block
//           every Bash call in the session. The gates themselves fail closed where a false
//           block is cheap; each module says which.

import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readStdin } from './lib/stdin.ts';
import { block, allow } from './lib/output.ts';
import { emitContext } from './lib/additional-context.ts';
import { getBranch, isWorkingTreeClean, resolveGitAlias } from './lib/git.ts';
import { redactSecrets } from './lib/secrets.ts';
import { resolveForge } from './pre-bash/config.ts';
import { evaluateSecretPrint } from './pre-bash/secret-print.ts';
import { evaluateOutboundBash } from './pre-bash/outbound.ts';
import { evaluateRmRf } from './pre-bash/rm-rf.ts';
import { evaluateForgePolicy, evaluateNoTty } from './pre-bash/forge.ts';
import { evaluateTerraformBackend } from './pre-bash/terraform.ts';
import { evaluateGitForce } from './pre-bash/git-destructive.ts';
import {
  commitDirs, evaluateBranchCreation, evaluateCommitMsg, evaluateCommitOnProtected,
} from './pre-bash/commit.ts';

// Re-exports: the public surface tests and other hooks import from this file.
export {
  ALLOW_MARKER, RMRF_ALLOW_MARKER, FORCE_PUSH_ALLOW_MARKER, SECRET_PRINT_ALLOW_MARKER,
  DEFAULT_FORGE, DEFAULT_PROTECTED_BRANCHES, protectedBranches, resolveForge, type Forge,
} from './pre-bash/config.ts';
// Kept for hooks that still import these from here; the home is lib/ticket.ts.
export { DEFAULT_TICKET_PATTERN, extractTicket, ticketPattern } from './lib/ticket.ts';
export { evaluateSecretPrint, type SecretPrintDecision } from './pre-bash/secret-print.ts';
export { evaluateOutboundBash } from './pre-bash/outbound.ts';
export { evaluateRmRf, RMRF_WHITELIST_PREFIXES, type RmRfDecision } from './pre-bash/rm-rf.ts';
export { evaluateForgePolicy, evaluateNoTty } from './pre-bash/forge.ts';
export { evaluateTerraformBackend, type TerraformDeps } from './pre-bash/terraform.ts';
export { evaluateGitForce, targetsProtectedBranch, type GitForceDeps } from './pre-bash/git-destructive.ts';
export {
  evaluateBranchCreation, evaluateCommitMsg, evaluateCommitOnProtected, extractCommitMessage,
} from './pre-bash/commit.ts';

/**
 * Longest command the gates will judge. Parsing is roughly linear, but a hook that runs past
 * its `hooks.json` timeout is cancelled and the command PROCEEDS, so an unbounded input is a
 * way around every gate. Nothing an agent types by hand comes near this; a generated script
 * that large belongs in a file, where it can be read and reviewed.
 */
export const MAX_COMMAND_BYTES = 64 * 1024;

export const TOO_LONG_MESSAGE = (bytes: number): string => `❌ BLOCKED: command too long to check (${bytes} bytes; the limit is ${MAX_COMMAND_BYTES})

  Why:      the safety checks cannot finish on a command this size inside the hook's
            timeout, and a timed-out check lets the command run unchecked.
  Instead:  split it into several smaller commands, or write the script to a file,
            review it, and run the file.`;

/** Deny with `reason`, after removing any credential it quotes back from the command. */
function deny(reason: string): never {
  block(redactSecrets(reason).text);
}

async function main(): Promise<void> {
  const input = await readStdin();
  if (input.tool_name !== 'Bash') allow();

  const raw: unknown = input.tool_input?.command;
  // A non-string command is not something Bash will run; nothing to judge.
  if (typeof raw !== 'string' || raw === '') allow();
  const command = raw as string;

  // One switch for the whole engine, for debugging a suspected false positive.
  if ((process.env.CLAUDE_GUARDRAILS_OFF ?? '') === '1') allow();

  const bytes = Buffer.byteLength(command, 'utf-8');
  if (bytes > MAX_COMMAND_BYTES) deny(TOO_LONG_MESSAGE(bytes));

  const cwd = typeof input.cwd === 'string' ? input.cwd : undefined;
  const notes: string[] = [];
  const check = (reason: string | null): void => {
    if (reason) deny(reason);
  };

  // Gates A and C run FIRST. A leak is irreversible once the value is in the transcript or
  // published, so neither may depend on an earlier check allowing the command through.
  check(evaluateSecretPrint(command)?.message ?? null);
  check(evaluateOutboundBash(command));

  // Then the reversible-damage guards: argv-only checks first, git and file reads last.
  const rm = evaluateRmRf(command);
  if (rm.kind === 'block') deny(rm.reason);
  if (rm.kind === 'allow-with-warning') notes.push(rm.message);

  check(evaluateForgePolicy(command, resolveForge()));
  check(evaluateNoTty(command));
  check(evaluateTerraformBackend(command, cwd));
  check(evaluateGitForce(command, cwd, { getBranch, isWorkingTreeClean, gitAlias: resolveGitAlias }));

  const dirs = commitDirs(command, cwd);
  if (dirs.length > 0) {
    const branch = getBranch(dirs[0]);
    check(evaluateCommitMsg(command, branch));
    const note = evaluateCommitOnProtected(command, branch);
    if (note) notes.push(note);
  }

  const nudge = evaluateBranchCreation(command);
  if (nudge) notes.push(nudge);

  emitContext('PreToolUse', notes.join('\n\n'));
  allow();
}

// Run main only when invoked directly (not when imported by tests).
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (err) {
    process.stderr.write(`dev-guardrails pre-bash: internal error, command not checked: ${(err as Error).message}\n`);
    process.exit(1);
  }
}
