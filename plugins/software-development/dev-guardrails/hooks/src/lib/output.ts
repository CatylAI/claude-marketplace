// Hook output helpers: exit codes, and the channel each kind of message actually reaches.
//
// WHERE OUTPUT GOES (code.claude.com/docs/en/hooks, "Exit code output" and "JSON output"):
//
//   exit 2 + stderr          PreToolUse: the call is denied and Claude reads stderr as the reason.
//                            PostToolUse: Claude reads stderr, but the tool has already run.
//   exit 0 + plain stdout    Added to Claude's context ONLY on SessionStart and UserPromptSubmit.
//                            On every other event it goes to the debug log and nobody sees it.
//   exit 0 + stderr          Debug log only, on every event. Claude never sees it.
//   exit 1 (any other code)  A "hook error" notice for the user; Claude does not see it.
//   exit 0 + JSON on stdout  `hookSpecificOutput.additionalContext` reaches Claude on
//                            SessionStart, UserPromptSubmit, PreToolUse, PostToolUse and Stop;
//                            `systemMessage` is shown to the user.
//
// So a non-blocking note meant for Claude from a tool event goes through `emitContext` in
// lib/additional-context.ts, not `info()` or `context()`, and a note meant for the user is
// `emitSystemMessage` below.

import { EXIT_ALLOW, EXIT_BLOCK, EXIT_WARN } from './types.ts';

/** Block the tool call. Writes message to stderr and exits with code 2. */
export function block(message: string): never {
  process.stderr.write(message + '\n');
  process.exit(EXIT_BLOCK);
}

/** Allow the tool call. Exits with code 0. */
export function allow(): never {
  process.exit(EXIT_ALLOW);
}

/**
 * Exit 1 with a stderr message. Claude Code shows the user a "hook error" notice with the first
 * stderr line; Claude does not see it. For an advisory Claude should act on, use
 * `emitContext` (lib/additional-context.ts) and exit 0 instead.
 */
export function warn(message: string): never {
  process.stderr.write(message + '\n');
  process.exit(EXIT_WARN);
}

/**
 * Write to stderr. On exit 0 this reaches only the debug log, so it is for diagnostics, not for
 * anything Claude or the user needs to read.
 */
export function info(message: string): void {
  process.stderr.write(message + '\n');
}

/**
 * Write a plain line to stdout. Claude reads it on SessionStart and UserPromptSubmit only; on
 * any other event use `emitContext` (lib/additional-context.ts).
 */
export function context(message: string): void {
  process.stdout.write(message + '\n');
}

/** The JSON object that shows `text` to the user as a warning line. Claude does not see it. */
export function systemMessageJson(text: string): string {
  return JSON.stringify({ systemMessage: text });
}

/**
 * Print the system-message JSON. Print nothing else on stdout: Claude Code parses stdout as one
 * JSON object, and a second line breaks the parse.
 */
export function emitSystemMessage(text: string): void {
  process.stdout.write(systemMessageJson(text) + '\n');
}
