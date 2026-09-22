// Where this plugin is allowed to keep scratch state on disk.
//
// THE RULE: a hook never writes into the user's home Claude directory and never drops files
// into the repository it is watching. Both are somebody else's space — one is configuration a
// user curates by hand, the other is a working tree whose `git status` must not acquire
// surprise entries because a hook ran. Everything this plugin persists is a cache or a
// counter; it is regenerable, so it belongs in a scratch location.
//
// The default is an OS temp subdirectory. `CLAUDE_GUARDRAILS_STATE_DIR` overrides it for anyone
// who wants the state to survive a reboot, or wants it somewhere auditable.

import { mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

/** Root of this plugin's scratch state. Does not create anything. */
export function stateRoot(env: NodeJS.ProcessEnv = process.env): string {
  const override = (env.CLAUDE_GUARDRAILS_STATE_DIR ?? '').trim();
  return override || join(tmpdir(), 'claude-dev-guardrails');
}

/**
 * Path to a file inside the state root, creating the directory if needed.
 * Returns null when the directory cannot be created — every caller treats that as
 * "no persistence available" and carries on without caching.
 */
export function stateFile(name: string, env: NodeJS.ProcessEnv = process.env): string | null {
  const root = stateRoot(env);
  try {
    mkdirSync(root, { recursive: true });
  } catch {
    return null;
  }
  return join(root, name);
}
