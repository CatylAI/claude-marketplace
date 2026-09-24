// Ticket keys in branch names and task text.
//
// Its own module because every lifecycle hook needs it. Importing it from pre-bash.ts pulled
// the whole Bash policy engine into hooks that never look at a command.

type Env = Record<string, string | undefined>;

/** Ticket-key shape used for branch-name and commit-scope guidance. */
export const DEFAULT_TICKET_PATTERN = '[A-Z][A-Z0-9]+-[0-9]+';

export function ticketPattern(env: Env = process.env): string {
  return (env.CLAUDE_TICKET_PATTERN ?? '').trim() || DEFAULT_TICKET_PATTERN;
}

/**
 * The ticket key carried by a branch name (or any text), or null.
 *
 * An unparseable CLAUDE_TICKET_PATTERN falls back to the default rather than throwing:
 * a bad regex in someone's shell profile must not take every hook down with it.
 */
export function extractTicket(text: string, pattern: string = ticketPattern()): string | null {
  let re: RegExp;
  try {
    re = new RegExp(pattern);
  } catch {
    re = new RegExp(DEFAULT_TICKET_PATTERN);
  }
  const m = text.match(re);
  return m ? m[0] : null;
}
