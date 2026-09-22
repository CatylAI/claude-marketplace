// Hook output helpers — standardize exit codes and stderr messaging

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

/** Warn but allow. Writes message to stderr and exits with code 1. */
export function warn(message: string): never {
  process.stderr.write(message + '\n');
  process.exit(EXIT_WARN);
}

/** Write informational output to stderr (non-blocking, for PostToolUse). */
export function info(message: string): void {
  process.stderr.write(message + '\n');
}

/** Write context output to stdout (injected into Claude's context). */
export function context(message: string): void {
  process.stdout.write(message + '\n');
}
