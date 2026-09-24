// Configuration shared by the pre-bash gates: escape markers, forge, protected branches,
// and resolving the directory a command runs in.
//
// Everything policy-shaped is read from the environment with a permissive default, so
// installing this plugin with no configuration blocks nothing that a default-configured
// project does.

import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { hasAllowMarker } from '../lib/bash-parse.ts';

export type Env = Record<string, string | undefined>;

/**
 * The generic escape hatch. Appended as a trailing comment it lifts any rule that has an
 * escape at all. Rule-specific markers below are narrower; either one satisfies its own
 * rule, and because the check is a substring test, a specific marker also satisfies the
 * generic one.
 *
 * Deliberately visible: the marker stays in the transcript, so a reviewer can see exactly
 * what was waived and on which command.
 */
export const ALLOW_MARKER = '# claude-allow';
export const RMRF_ALLOW_MARKER = '# claude-allow-rm-rf';
export const FORCE_PUSH_ALLOW_MARKER = '# claude-allow-force-push';
export const SECRET_PRINT_ALLOW_MARKER = '# claude-allow-secret-print';

/** True when `command` carries the rule's own marker, or the generic one. */
export function waived(command: string, specific: string): boolean {
  return hasAllowMarker(command, specific) || hasAllowMarker(command, ALLOW_MARKER);
}

/**
 * The escape line every deny reason ends with.
 *
 * The deny reason is read by Claude, so an unconditional "append this marker" is an
 * instruction to bypass the gate on the next attempt. The marker exists for a person who
 * has decided; the wording routes the decision back to them.
 */
export function escapeLine(marker: string): string {
  return `  Escape:   only if the user explicitly asked for this exact command, append \`${marker}\`.`;
}

/**
 * Which forge this project uses.
 *
 * `both` is the DEFAULT and blocks neither CLI. A hook shipped to an unknown project
 * cannot know which forge it uses, and guessing wrong makes every session unusable —
 * so the unconfigured answer is "do not judge the CLI at all". A project that has
 * actually chosen one opts in by exporting CLAUDE_FORGE, and only then does using the
 * other forge's CLI become a block.
 */
export type Forge = 'github' | 'gitlab' | 'both';
export const DEFAULT_FORGE: Forge = 'both';

export function resolveForge(env: Env = process.env): Forge {
  const raw = (env.CLAUDE_FORGE ?? '').trim().toLowerCase();
  if (raw === 'github' || raw === 'gitlab' || raw === 'both') return raw;
  // Unset, empty, or a value this hook does not understand. An unrecognised value must
  // not be treated as a declaration: the permissive default is the safe reading.
  return DEFAULT_FORGE;
}

/** Branches that may not be force-pushed, and that a commit warns about. */
export const DEFAULT_PROTECTED_BRANCHES = ['main', 'master'] as const;

export function protectedBranches(env: Env = process.env): string[] {
  const raw = (env.CLAUDE_PROTECTED_BRANCHES ?? '').trim();
  if (!raw) return [...DEFAULT_PROTECTED_BRANCHES];
  const list = raw.split(',').map((s) => s.trim()).filter(Boolean);
  return list.length > 0 ? list : [...DEFAULT_PROTECTED_BRANCHES];
}

/**
 * The directory a command runs in: the hook's `cwd`, then each preceding `cd`, then any
 * `-C`-style option the command itself carries.
 *
 * Returns `undefined` when nothing moves the command away from `cwd` and `cwd` itself was
 * not given (callers then let git use the process cwd, as before), and `null` when a step
 * cannot be resolved statically (`cd "$REPO"`, `cd -`). Callers treat `null` as "cannot
 * tell" and pick their own safe answer.
 */
export function commandDir(
  cwd: string | undefined,
  steps: readonly string[],
): string | undefined | null {
  if (steps.length === 0) return cwd;
  let dir = cwd ?? process.cwd();
  for (const step of steps) {
    if (step === '-' || step.includes('$') || step.includes('`')) return null;
    const expanded = step === '~' ? homedir() : step.startsWith('~/') ? homedir() + step.slice(1) : step;
    dir = resolve(dir, expanded);
  }
  return dir;
}
