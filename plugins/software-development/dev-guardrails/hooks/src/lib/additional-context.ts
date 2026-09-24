// The one output channel a non-blocking hook has to reach Claude: JSON `additionalContext`.
//
// Why this exists: stderr from a hook that exits 0 goes to the debug log only, and plain stdout
// is shown to Claude only for UserPromptSubmit / SessionStart (code.claude.com/docs/en/hooks,
// "Exit code 0"). Every advisory hook here used to write to stderr and exit 0, so none of its
// findings ever reached the model. Exit 1 is no better: the user sees a "hook error" notice and
// Claude still sees nothing. `hookSpecificOutput.additionalContext` on exit 0 is the documented
// way to add a note next to the tool result, on PreToolUse, PostToolUse and PostToolUseFailure.
//
// The docs cap each additionalContext string at 10,000 characters; anything longer is spilled
// to a file Claude is not asked to read. We cap far below that because every character here is
// paid for in the context window on every matching tool call.

export type ContextEvent = 'PreToolUse' | 'PostToolUse' | 'PostToolUseFailure';

/** Hard ceiling on what one hook invocation may inject. */
export const MAX_CONTEXT_CHARS = 4000;

/** The exact stdout payload for `text`. Pure, so the shape is assertable. */
export function contextJson(event: ContextEvent, text: string): string {
  const body = text.length <= MAX_CONTEXT_CHARS
    ? text
    : text.slice(0, MAX_CONTEXT_CHARS) + '\n... (truncated)';
  return JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: body } });
}

/** Write the payload to stdout. Emits nothing for empty text, so a clean run stays silent. */
export function emitContext(event: ContextEvent, text: string): void {
  if (text.trim() === '') return;
  process.stdout.write(contextJson(event, text) + '\n');
}
