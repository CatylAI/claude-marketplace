// PostToolUse hook (TodoWrite): todo-list hygiene.
//
// Two failure modes, both of which leave a task list that reads as truth and is not:
//
//   1. A COMPLETED ITEM THAT NOBODY CLOSED UPSTREAM. The list says done; the tracker still says
//      in progress. The next session reads the tracker, not this list.
//   2. AN ITEM LEFT `in_progress` AFTER THE WORK ENDED. Stale in-progress state is worse than no
//      state: a later agent reads it as "someone is on this" and skips it.
//
// Non-blocking, always exits 0. It reminds; it does not decide. It also names no tracker: the
// mechanics of transitioning an issue belong to whatever issue-tracker plugin is installed, and
// naming one here would be a dangling reference in every project that uses a different one.

import { readStdin } from './lib/stdin.ts';
import { info } from './lib/output.ts';
import type { TodoItem } from './lib/types.ts';
import { extractTicket } from './pre-bash.ts';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * The advisory lines for a todo list, or [] when it is healthy. Pure, so the thresholds are
 * assertable without spawning the hook.
 */
export function evaluateTodos(todos: TodoItem[]): string[] {
  const lines: string[] = [];

  const completed = todos.filter((t) => t.status === 'completed').length;
  if (completed > 0) {
    lines.push(
      `TODO SYNC: ${completed} item(s) marked completed. If any maps to a tracked issue, ` +
        'transition it there too — this list is not visible to anyone outside the session.',
    );
  }

  // More than one in-progress item is the shape of a list that stopped being maintained.
  const inProgress = todos.filter((t) => t.status === 'in_progress');
  if (inProgress.length > 1) {
    lines.push(
      `TODO HYGIENE: ${inProgress.length} items are in_progress at once. Exactly one should be ` +
        'in flight; the rest read as abandoned work to whoever picks this up next.',
    );
  }

  // An in-progress item with no ticket key is fine for housekeeping and a gap for real work.
  const untracked = inProgress.filter((t) => extractTicket(t.content) === null).length;
  if (untracked > 0) {
    lines.push(
      `TODO TRACKING: ${untracked} in-progress item(s) carry no ticket key. Fine for ` +
        'housekeeping; for anything a reviewer would want a record of, open an issue first.',
    );
  }

  return lines;
}

async function run(): Promise<void> {
  try {
    const input = await readStdin();
    if (input.tool_name !== 'TodoWrite') process.exit(0);

    const todos: TodoItem[] = (input.tool_input?.todos as TodoItem[] | undefined) ?? [];
    for (const line of evaluateTodos(todos)) info(line);
  } catch {
    // Never surface a hook fault as a tool failure.
  }
  process.exit(0);
}

// Only run as the hook entrypoint — importing (e.g. from tests) must not block on stdin.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await run();
}
