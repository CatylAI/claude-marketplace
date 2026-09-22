// Plugin staleness detector — compares the plugin versions THIS session loaded
// (installed_plugins.json) against the latest available in each marketplace checkout
// (marketplaces/<name>/plugins/<plugin>/.claude-plugin/plugin.json).
//
// READ-ONLY. It opens files under the user's plugin directory and writes nothing anywhere.
//
// Why this can only DETECT, never fix: Claude Code loads plugin content at session start, BEFORE
// SessionStart hooks fire, and `/plugin update` only affects the NEXT session. So the most a
// session-start hook can do is say which loaded plugins are behind their marketplace checkout and
// that a restart is what picks them up. There is no in-session reload.

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

export interface StalePlugin {
  name: string;         // plugin key, e.g. "dev-guardrails@my-marketplace"
  installed: string;    // version loaded by this session
  latest: string;       // version available in the marketplace checkout
}

const PLUGINS_ROOT = join(homedir(), '.claude', 'plugins');

function readJson(path: string): unknown | null {
  try {
    return JSON.parse(readFileSync(path, 'utf-8'));
  } catch {
    return null;
  }
}

// Compare two dotted version strings numerically (semver-ish). Returns true when `latest`
// is strictly greater than `installed`. Non-numeric or malformed versions (e.g. git SHAs)
// compare unequal → treated as NOT newer, so we never false-alarm on a SHA-versioned plugin.
function isNewer(latest: string, installed: string): boolean {
  const l = latest.split('.').map(n => parseInt(n, 10));
  const i = installed.split('.').map(n => parseInt(n, 10));
  if (l.some(Number.isNaN) || i.some(Number.isNaN)) return false;
  const len = Math.max(l.length, i.length);
  for (let k = 0; k < len; k++) {
    const a = l[k] ?? 0;
    const b = i[k] ?? 0;
    if (a !== b) return a > b;
  }
  return false;
}

// Map an installed-plugins key ("dev-guardrails@my-marketplace") to the marketplace plugin.json
// path: marketplaces/<marketplace>/plugins/<plugin>/.claude-plugin/plugin.json.
function marketplacePluginJson(key: string): string | null {
  const at = key.lastIndexOf('@');
  if (at < 0) return null;
  const plugin = key.slice(0, at);
  const marketplace = key.slice(at + 1);
  return join(PLUGINS_ROOT, 'marketplaces', marketplace, 'plugins', plugin, '.claude-plugin', 'plugin.json');
}

/**
 * Return the list of installed plugins whose marketplace checkout carries a newer version than
 * the one this session loaded. Empty list = everything current (or nothing measurable).
 * Never throws — a missing/corrupt file yields fewer findings, not an error.
 */
export function findStalePlugins(): StalePlugin[] {
  const installedPath = join(PLUGINS_ROOT, 'installed_plugins.json');
  if (!existsSync(installedPath)) return [];
  const installed = readJson(installedPath) as { plugins?: Record<string, Array<{ version?: string }>> } | null;
  if (!installed?.plugins) return [];

  const stale: StalePlugin[] = [];
  for (const [key, entries] of Object.entries(installed.plugins)) {
    const installedVersion = entries?.[0]?.version;
    if (!installedVersion) continue;
    const mpJsonPath = marketplacePluginJson(key);
    if (!mpJsonPath || !existsSync(mpJsonPath)) continue;
    const mp = readJson(mpJsonPath) as { version?: string } | null;
    const latest = mp?.version;
    if (!latest) continue;
    if (isNewer(latest, installedVersion)) {
      stale.push({ name: key, installed: installedVersion, latest });
    }
  }
  return stale;
}
