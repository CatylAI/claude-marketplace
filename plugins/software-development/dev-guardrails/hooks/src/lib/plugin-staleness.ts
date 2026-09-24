// Plugin staleness detector: compares the plugin versions THIS session loaded
// (plugins/installed_plugins.json) against the latest version in each marketplace checkout
// (plugins/marketplaces/<marketplace>/).
//
// READ-ONLY. It opens files under the user's Claude config directory and writes nothing.
//
// Why this can only DETECT, never fix: Claude Code loads plugin content at session start, BEFORE
// SessionStart hooks fire, and an update only affects the NEXT session. So the most a
// session-start hook can do is say which loaded plugins are behind and that a restart picks
// them up.
//
// WHERE A PLUGIN LIVES INSIDE A MARKETPLACE is not a fixed path. The marketplace manifest
// (.claude-plugin/marketplace.json) lists each plugin with a `source`, and a marketplace is free
// to nest plugins (this repo uses plugins/<category>/<name>/). So the manifest is the source of
// truth: its entry `version` wins, else the plugin.json at the entry's relative `source`. The
// old fixed `plugins/<name>/` guess is kept only as a fallback for manifests without a source.

import { readFileSync, existsSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import { homedir } from 'node:os';

export interface StalePlugin {
  name: string;         // plugin key, e.g. "dev-guardrails@my-marketplace"
  installed: string;    // version loaded by this session
  latest: string;       // version available in the marketplace checkout
}

/** `<config dir>/plugins`, honouring CLAUDE_CONFIG_DIR the same way Claude Code does. */
export function pluginsRoot(env: NodeJS.ProcessEnv = process.env): string {
  const configDir = (env.CLAUDE_CONFIG_DIR ?? '').trim() || join(homedir(), '.claude');
  return join(configDir, 'plugins');
}

function readJson(path: string): unknown | null {
  try {
    return JSON.parse(readFileSync(path, 'utf-8'));
  } catch {
    return null;
  }
}

// Compare two dotted version strings numerically (semver-ish). Returns true when `latest`
// is strictly greater than `installed`. Non-numeric or malformed versions (e.g. git SHAs)
// are treated as NOT newer, so a SHA-versioned plugin never raises a false alarm.
export function isNewer(latest: string, installed: string): boolean {
  const l = latest.split('.').map((n) => parseInt(n, 10));
  const i = installed.split('.').map((n) => parseInt(n, 10));
  if (l.some(Number.isNaN) || i.some(Number.isNaN)) return false;
  const len = Math.max(l.length, i.length);
  for (let k = 0; k < len; k++) {
    const a = l[k] ?? 0;
    const b = i[k] ?? 0;
    if (a !== b) return a > b;
  }
  return false;
}

interface MarketplaceEntry {
  name?: string;
  version?: string;
  source?: unknown;
}

/**
 * The latest version of `plugin` in the marketplace checkout at `mpDir`, or null when it cannot
 * be determined. A `source` that escapes the checkout (`../..`) is ignored rather than followed.
 */
export function latestVersionInMarketplace(mpDir: string, plugin: string): string | null {
  const manifest = readJson(join(mpDir, '.claude-plugin', 'marketplace.json')) as
    | { plugins?: MarketplaceEntry[] }
    | null;
  const entry = manifest?.plugins?.find((p) => p?.name === plugin);
  if (entry?.version) return entry.version;

  const candidates: string[] = [];
  if (typeof entry?.source === 'string') {
    const dir = resolve(mpDir, entry.source);
    if (dir === resolve(mpDir) || dir.startsWith(resolve(mpDir) + sep)) candidates.push(dir);
  }
  candidates.push(join(mpDir, 'plugins', plugin));

  for (const dir of candidates) {
    const pj = readJson(join(dir, '.claude-plugin', 'plugin.json')) as { version?: string } | null;
    if (pj?.version) return pj.version;
  }
  return null;
}

/**
 * Installed plugins whose marketplace checkout carries a newer version than the one this session
 * loaded. Empty list = everything current, or nothing measurable. Never throws: a missing or
 * corrupt file yields fewer findings, not an error.
 */
export function findStalePlugins(root: string = pluginsRoot()): StalePlugin[] {
  const installedPath = join(root, 'installed_plugins.json');
  if (!existsSync(installedPath)) return [];
  const installed = readJson(installedPath) as
    | { plugins?: Record<string, Array<{ version?: string }>> }
    | null;
  if (!installed?.plugins) return [];

  const stale: StalePlugin[] = [];
  for (const [key, entries] of Object.entries(installed.plugins)) {
    const installedVersion = Array.isArray(entries) ? entries[0]?.version : undefined;
    if (!installedVersion) continue;
    const at = key.lastIndexOf('@');
    if (at < 0) continue;
    const plugin = key.slice(0, at);
    const marketplace = key.slice(at + 1);
    const latest = latestVersionInMarketplace(join(root, 'marketplaces', marketplace), plugin);
    if (latest && isNewer(latest, installedVersion)) {
      stale.push({ name: key, installed: installedVersion, latest });
    }
  }
  return stale;
}
