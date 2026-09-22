// Project Claude Code setup health check — called from session-start.ts.
//
// Two things a repository should carry independently of whatever is installed at user level:
//
//   1. CLAUDE.md — project-specific instructions. Without it every session starts from zero.
//   2. `.claude/settings.json` that does not silently disable the safety gates.
//
// The second is the one with teeth. A project settings file that defines its own `PreToolUse`
// entries is fine; one that defines them AND names none of this plugin's guards AND references
// no plugin root at all is the shape that quietly replaces a working guard set with a narrower
// one. Everything else is left alone — the check warns on that single shape and stays silent
// otherwise, because a session-start warning that fires on healthy repos gets trained out.

import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { context } from './output.ts';

/** The guards whose absence from an explicit PreToolUse set is worth naming. */
const CRITICAL_HOOK_SCRIPTS = ['pre-bash.ts', 'pre-write-edit.ts'];

export interface ProjectHooksResult {
  claudeMdPresent: boolean;
  claudeMdLocation: 'root' | '.claude' | null;
  projectSettingsPresent: boolean;
  projectSettingsPath: string | null;
  settingsHasHooksBlock: boolean;
  settingsMissingCritical: string[];
}

export function parseProjectSettings(raw: string): {
  hasHooks: boolean;
  missingCritical: string[];
} {
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { hasHooks: false, missingCritical: [] };
  }

  const hooks = parsed['hooks'];
  if (!hooks || typeof hooks !== 'object') return { hasHooks: false, missingCritical: [] };

  const preToolUse = (hooks as Record<string, unknown>)['PreToolUse'];
  // No PreToolUse block at all: whatever is installed at user or plugin level still applies.
  if (!Array.isArray(preToolUse)) return { hasHooks: true, missingCritical: [] };

  const allCommands: string[] = [];
  for (const entry of preToolUse) {
    if (entry && typeof entry === 'object' && Array.isArray((entry as Record<string, unknown>)['hooks'])) {
      for (const h of (entry as { hooks: unknown[] }).hooks) {
        if (h && typeof h === 'object' && typeof (h as Record<string, unknown>)['command'] === 'string') {
          allCommands.push((h as { command: string }).command);
        }
      }
    }
  }

  // A command that references a plugin root (the `${CLAUDE_PLUGIN_ROOT}` template, an absolute
  // path through a `plugins/` directory, or a user-level `.claude/hooks/` path) is wired through
  // a plugin — the guards are present under a path this check cannot spell, so do not warn.
  const hasPluginRef = allCommands.some(
    (cmd) =>
      cmd.includes('${CLAUDE_PLUGIN_ROOT}') ||
      /(?:^|["'\s=])\/[^"']*\/plugins\//.test(cmd) ||
      cmd.includes('/.claude/hooks/') ||
      cmd.includes('~/.claude/hooks/'),
  );
  if (hasPluginRef) return { hasHooks: true, missingCritical: [] };

  const missing = CRITICAL_HOOK_SCRIPTS.filter(
    (script) => !allCommands.some((cmd) => cmd.includes(script)),
  );
  return { hasHooks: true, missingCritical: missing };
}

export function checkProjectHooks(repoRoot: string): ProjectHooksResult {
  const rootClaudeMd = join(repoRoot, 'CLAUDE.md');
  const dotClaudeMd = join(repoRoot, '.claude', 'CLAUDE.md');
  const claudeMdLocation = existsSync(rootClaudeMd)
    ? 'root'
    : existsSync(dotClaudeMd)
      ? '.claude'
      : null;

  const settingsPaths = [
    join(repoRoot, '.claude', 'settings.json'),
    join(repoRoot, '.claude', 'settings.local.json'),
  ];
  const foundSettings = settingsPaths.find((p) => existsSync(p)) ?? null;

  let settingsHasHooksBlock = false;
  let settingsMissingCritical: string[] = [];

  if (foundSettings) {
    let raw = '';
    try {
      raw = readFileSync(foundSettings, 'utf-8');
    } catch {
      raw = '';
    }
    const parsed = parseProjectSettings(raw);
    settingsHasHooksBlock = parsed.hasHooks;
    settingsMissingCritical = parsed.missingCritical;
  }

  return {
    claudeMdPresent: claudeMdLocation !== null,
    claudeMdLocation,
    projectSettingsPresent: foundSettings !== null,
    projectSettingsPath: foundSettings,
    settingsHasHooksBlock,
    settingsMissingCritical,
  };
}

/** Run the check and emit context lines. Silent when the project is set up. */
export function runProjectHooksCheck(repoRoot: string): void {
  const result = checkProjectHooks(repoRoot);
  const issues: string[] = [];

  if (!result.claudeMdPresent) {
    issues.push(
      'No CLAUDE.md — this project carries no instructions of its own, so every session starts ' +
        'from a blank slate.',
    );
  }

  if (result.projectSettingsPresent && result.settingsMissingCritical.length > 0) {
    issues.push(
      `${result.projectSettingsPath} defines its own PreToolUse hooks and names none of ` +
        `${result.settingsMissingCritical.join(', ')}. If that was not deliberate, the safety ` +
        'gates are not running in this project.',
    );
  }

  if (issues.length > 0) {
    context('PROJECT SETUP:');
    for (const issue of issues) context(`   - ${issue}`);
  }
}
