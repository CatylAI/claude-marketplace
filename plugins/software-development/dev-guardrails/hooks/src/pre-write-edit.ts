// PreToolUse hook: Write | Edit | NotebookEdit secret hygiene and the plugin-cache gate.
//
// The write-side sibling of Gate A. Gate A stops a secret reaching the TRANSCRIPT; this
// stops one reaching a FILE, where it goes on to reach git history and everyone with a
// clone. Both directions matter and neither covers the other.
//
// Exit codes: 0 = allow, 2 = block (stderr becomes the deny reason Claude reads). There is
// no advisory exit here. Exit 1 is a "non-blocking error" in Claude Code: the user sees a
// hook-error notice and Claude sees nothing, so a warning sent that way reached no one who
// could act on it. The one advisory this hook used to carry (the hardcoded-shebang nit) now
// lives in post-write-edit.ts, which reports through additionalContext.
//
// FAIL DIRECTION: OPEN. Unparseable stdin reads as `{}` and is allowed, and an uncaught
// throw exits 1, which Claude Code treats as a non-blocking error (the write proceeds and
// the user sees the first stderr line). A false block here stops every file write in the
// session, which is not a cheap failure, so the gate only blocks on a positive finding.
//
// ORDERING: both gates block, and the credential gate runs first so its message is the one
// read. The plugin-cache gate judges the PATH, so it must not sit behind an "empty content"
// early return (a pure-deletion Edit carries no text but still targets the doomed copy).

import { readStdin } from './lib/stdin.ts';
import { block, allow } from './lib/output.ts';
import type { HookInput } from './lib/types.ts';
import { fileURLToPath } from 'node:url';
import { resolve, posix } from 'node:path';
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { CONTENT_PATTERNS, TOKEN_PATTERNS, findSecrets, type SecretMatch } from './lib/secrets.ts';

/**
 * Both pattern sets apply here, and only here.
 *
 * TOKEN_PATTERNS are safe on any surface. CONTENT_PATTERNS match the SHAPE of an
 * assignment (`password = "…"`), which is right for file content and wrong for a command
 * line or a review note — see the header of lib/secrets.ts. This is the file-content
 * surface, so both are in scope.
 */
const WRITE_PATTERNS = [...TOKEN_PATTERNS, ...CONTENT_PATTERNS];

/** What the block message should suggest instead, per pattern family. */
const REMEDIES: Record<string, string> = {
  'db-connection-string':
    'read the whole URI from the environment (DATABASE_URL), or compose it from a\n            secret-manager lookup at start-up',
  'private-key-block':
    'keep key material in a secret manager and mount or fetch it at run time;\n            never in the repository',
};

const DEFAULT_REMEDY = `use an environment variable or a secret manager:
            - a secret-manager reference (op://vault/item/field, AWS Secrets Manager,
              SSM Parameter Store, Vault)
            - a .env file that is gitignored and holds references, not values`;

export interface WriteSecretDecision {
  readonly patternName: string;
  readonly message: string;
}

/**
 * Pure decision: the block message for the FIRST credential found in `content`, or null.
 *
 * Placeholder suppression comes from findSecrets(), and it is what keeps this gate usable:
 * without it, the file documenting the gate cannot be written — a rule doc, a test fixture
 * or a README that shows what a token looks like would all be refused, and the gate that
 * blocks its own documentation is the gate that gets switched off.
 */
export function evaluateWriteSecrets(content: string): WriteSecretDecision | null {
  if (!content) return null;
  return secretDecision(findSecrets(content, WRITE_PATTERNS));
}

/** Build the block message from a list of hits, or null when there are none. */
function secretDecision(hits: readonly SecretMatch[]): WriteSecretDecision | null {
  const first = hits[0];
  if (!first) return null;

  const remedy = REMEDIES[first.patternName] ?? DEFAULT_REMEDY;
  const kinds = [...new Set(hits.map((h) => h.patternName))].sort().join(', ');

  return {
    patternName: first.patternName,
    message: `❌ BLOCKED: credential-shaped content in this write

  Found:    ${hits.length} match(es) — ${kinds}
  Why:      a credential written to a file reaches git history, and history is forever.
            Removing it in a later commit does not remove it from the clones people
            already have; the only remedy after the fact is ROTATION.
  Instead:  ${remedy}

  If this is documentation or a fixture, make the value obviously fake — a value
  containing "example", "placeholder", "test" or "changeme" is recognised as such
  and passes.`,
  };
}

/**
 * The file as it will read after an Edit, or null when that cannot be computed (no
 * old_string, or old_string not found — the Edit tool itself will then refuse the call).
 *
 * Splice by index rather than String.replace: a replacement string containing `$&` or `$1`
 * would otherwise be expanded as a regex back-reference and the simulation would lie.
 */
export function applyEdit(
  before: string,
  oldString: string,
  newString: string,
  replaceAll: boolean,
): string | null {
  if (!oldString) return null;
  const at = before.indexOf(oldString);
  if (at === -1) return null;
  if (replaceAll) return before.split(oldString).join(newString);
  return before.slice(0, at) + newString + before.slice(at + oldString.length);
}

/**
 * Credentials present in `after` that `before` did not already contain, counted as a
 * multiset so a second copy of an existing value still counts as new.
 */
export function introducedSecrets(before: string, after: string): SecretMatch[] {
  const key = (m: SecretMatch): string => `${m.patternName}\u0000${m.value}`;
  const existing = new Map<string, number>();
  for (const m of findSecrets(before, WRITE_PATTERNS)) {
    existing.set(key(m), (existing.get(key(m)) ?? 0) + 1);
  }
  return findSecrets(after, WRITE_PATTERNS).filter((m) => {
    const left = existing.get(key(m)) ?? 0;
    if (left === 0) return true;
    existing.set(key(m), left - 1);
    return false;
  });
}

/**
 * Judge an Edit IN CONTEXT, not just its replacement text.
 *
 * Scanning `new_string` alone misses the realistic case for the assignment-shaped patterns:
 * an Edit that swaps `os.environ["DB_PASSWORD"]` for a literal leaves `password = ` in the
 * unchanged text, so the replacement on its own has no assignment shape to match. So the
 * edit is applied to the current file in memory and only credentials the edit INTRODUCES are
 * reported. Pre-existing matches stay out of it: they were judged when they were written,
 * and blocking an unrelated edit to a file that already holds a fixture would be noise.
 *
 * `before` is null when the file cannot be read; the replacement text is still scanned, so
 * the gate never gets weaker than it was.
 */
export function evaluateEditSecrets(
  before: string | null,
  oldString: string,
  newString: string,
  replaceAll: boolean,
): WriteSecretDecision | null {
  const hits: SecretMatch[] = findSecrets(newString, WRITE_PATTERNS);
  const after = before === null ? null : applyEdit(before, oldString, newString, replaceAll);
  if (before !== null && after !== null) {
    const seen = new Set(hits.map((h) => `${h.patternName}\u0000${h.value}`));
    for (const m of introducedSecrets(before, after)) {
      if (!seen.has(`${m.patternName}\u0000${m.value}`)) hits.push(m);
    }
  }
  return secretDecision(hits);
}

/** Largest file the Edit simulation will read. Beyond it, only new_string is scanned. */
const MAX_EDIT_CONTEXT_BYTES = 2 * 1024 * 1024;

function readForEdit(filePath: string): string | null {
  try {
    if (!filePath || statSync(filePath).size > MAX_EDIT_CONTEXT_BYTES) return null;
    return readFileSync(filePath, 'utf-8');
  } catch {
    return null;
  }
}

/** What a governed tool call writes, and where. */
export interface WriteTarget {
  readonly tool: 'Write' | 'Edit' | 'NotebookEdit';
  readonly filePath: string;
  /** The text this call puts on disk: content, new_string, or new_source. */
  readonly written: string;
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

/**
 * The tools that write files, and the field each uses. NotebookEdit is included because it
 * writes arbitrary cell source to disk exactly as Write does; leaving it out made a notebook
 * cell the one way past both gates. (MultiEdit is not a current Claude Code tool.)
 */
export function extractWriteTarget(input: HookInput): WriteTarget | null {
  const ti = input.tool_input ?? {};
  switch (input.tool_name) {
    case 'Write':
      return { tool: 'Write', filePath: str(ti.file_path), written: str(ti.content) };
    case 'Edit':
      return { tool: 'Edit', filePath: str(ti.file_path), written: str(ti.new_string) };
    case 'NotebookEdit':
      return {
        tool: 'NotebookEdit',
        filePath: str(ti.notebook_path) || str(ti.file_path),
        written: str(ti.new_source),
      };
    default:
      return null;
  }
}

/**
 * The per-rule escape marker for the plugin-cache gate, in the family documented under
 * "Bypassing a block" in README.md (`# claude-allow`, `# claude-allow-rm-rf`, …).
 *
 * The literal is duplicated from pre-bash.ts rather than imported: pre-bash is a thousand-line
 * Bash parser and importing it here would pull the whole thing into every Write and Edit,
 * for one string.
 */
export const PLUGIN_CACHE_ALLOW_MARKER = '# claude-allow-plugin-cache';
/** The generic waiver, honoured here exactly as pre-bash's waived() honours it. */
export const GENERIC_ALLOW_MARKER = '# claude-allow';

/**
 * A marker counts only as a line of its OWN, after trimming.
 *
 * pre-bash learned this the hard way (see lib/bash-parse.ts, hasAllowMarker): a substring
 * test against text that DOCUMENTS the marker turns the documentation into an override.
 * This plugin's own README and SKILL.md describe this marker, and both of them live inside
 * the cache directory once the plugin is installed — so a substring test would make the
 * cached copy of the file explaining the gate the one file the gate cannot protect.
 * Prose mentions the marker inline, wrapped in backticks; a deliberate waiver is a line
 * that contains nothing else.
 *
 * Fail direction: this marker ALLOWS, so every ambiguous case must resolve to "no marker".
 */
function hasCacheAllowMarker(content: string): boolean {
  return content.split('\n').some((line) => {
    const trimmed = line.trim();
    return trimmed === PLUGIN_CACHE_ALLOW_MARKER || trimmed === GENERIC_ALLOW_MARKER;
  });
}

/** Where an installed plugin's files live, as path SEGMENTS. Never as a substring. */
const CACHE_SEGMENTS = ['.claude', 'plugins', 'cache'] as const;

/**
 * A version directory looks like a version. Used only to decide whether the segment after
 * the plugin name is the version or already part of the in-plugin path, so a cache layout
 * without a version level still yields a sane "edit this file in the source" pointer.
 */
const VERSION_SEGMENT = /^v?\d+(\.\d+)*/;

export interface PluginCacheTarget {
  readonly marketplace: string;
  readonly plugin: string;
  /** null when the segment after the plugin name is not version-shaped. */
  readonly version: string | null;
  /** Path of the file WITHIN the plugin, e.g. `hooks/src/pre-bash.ts`. '' at the root. */
  readonly inPlugin: string;
}

/**
 * Parse `.claude/plugins/cache/<marketplace>/<plugin>/<version>/<rest>` out of a path, or
 * return null.
 *
 * SEGMENT matching, not substring matching, and the distinction is the whole gate. The
 * source tree this user actually edits is `…/marketplaces/<repo>/plugins/<category>/<name>`
 * — it contains the segment `plugins`, and a repository is perfectly entitled to a
 * directory named `cache`. Only the three segments above, ADJACENT and IN ORDER, identify
 * an installed copy. Blocking the real source would make the plugin unusable, so that is
 * the false positive this shape is chosen to exclude.
 *
 * Absolute, relative and `~`-prefixed paths all work: the scan looks for the triple
 * anywhere in the segment list, so whatever precedes it is irrelevant.
 *
 * The path is NORMALISED first, and each step closes a bypass:
 *   - backslashes become `/` (Windows delivers native separators);
 *   - `..` and `.` are collapsed, so `.claude/plugins/x/../cache/…` cannot hide the triple;
 *   - segments compare case-insensitively, because macOS and Windows filesystems do.
 *
 * Besides the default `.claude/plugins` location, the plugin directories Claude Code can be
 * pointed elsewhere by environment are honoured too: `$CLAUDE_CONFIG_DIR/plugins`,
 * `$CLAUDE_CODE_PLUGIN_CACHE_DIR`, and each entry of `$CLAUDE_CODE_PLUGIN_SEED_DIR`. Each
 * of those holds `cache/<marketplace>/<plugin>/<version>/…`.
 */
export function parsePluginCachePath(
  filePath: string,
  env: NodeJS.ProcessEnv = process.env,
): PluginCacheTarget | null {
  if (!filePath) return null;
  const normal = normalizeToolPath(filePath);
  const segments = normal.split('/').filter((s) => s !== '' && s !== '.');
  const lower = segments.map((s) => s.toLowerCase());

  // i + 4 must be a real index: a cache path names at least a marketplace and a plugin.
  for (let i = 0; i + 4 < segments.length; i++) {
    if (CACHE_SEGMENTS.every((want, k) => lower[i + k] === want)) {
      return targetFrom(segments.slice(i + 3));
    }
  }

  // A relocated plugins directory: match by prefix, again case-insensitively.
  const lowerNormal = normal.toLowerCase();
  for (const root of pluginDirsFromEnv(env)) {
    const prefix = (root.endsWith('/') ? root : root + '/') + 'cache/';
    if (!lowerNormal.startsWith(prefix.toLowerCase())) continue;
    const rest = normal.slice(prefix.length).split('/').filter((s) => s !== '');
    if (rest.length >= 2) return targetFrom(rest);
  }
  return null;
}

/** `rest` starts at the marketplace segment. */
function targetFrom(rest: readonly string[]): PluginCacheTarget {
  const maybeVersion = rest[2];
  const versioned = maybeVersion !== undefined && VERSION_SEGMENT.test(maybeVersion);
  return {
    marketplace: rest[0] as string,
    plugin: rest[1] as string,
    version: versioned ? (maybeVersion as string) : null,
    inPlugin: rest.slice(versioned ? 3 : 2).join('/'),
  };
}

/** Forward slashes, `.` and `..` collapsed. Relative paths stay relative. */
export function normalizeToolPath(filePath: string): string {
  return posix.normalize(filePath.replace(/\\/g, '/'));
}

/** Plugin directories relocated by environment, normalised. Never includes the default. */
function pluginDirsFromEnv(env: NodeJS.ProcessEnv): string[] {
  const dirs: string[] = [];
  const configDir = (env.CLAUDE_CONFIG_DIR ?? '').trim();
  if (configDir) dirs.push(posix.join(normalizeToolPath(configDir), 'plugins'));
  const cacheDir = (env.CLAUDE_CODE_PLUGIN_CACHE_DIR ?? '').trim();
  if (cacheDir) dirs.push(normalizeToolPath(cacheDir));
  for (const seed of (env.CLAUDE_CODE_PLUGIN_SEED_DIR ?? '').split(/[:;]/)) {
    if (seed.trim()) dirs.push(normalizeToolPath(seed.trim()));
  }
  return dirs;
}

/**
 * The path with symlinks resolved, or null when nothing changes.
 *
 * A symlink in the working tree that points into the cache (`vendor/guardrails ->
 * ~/.claude/plugins/cache/…`) otherwise writes into the installed copy under a path that
 * names no cache at all. The target file may not exist yet (a Write creates it), so the
 * deepest EXISTING ancestor is resolved and the remainder appended.
 */
export function resolveThroughSymlinks(filePath: string): string | null {
  if (!filePath) return null;
  let probe = resolve(filePath);
  const tail: string[] = [];
  while (!existsSync(probe)) {
    const parent = resolve(probe, '..');
    if (parent === probe) return null;
    tail.unshift(probe.slice(parent.length).replace(/^[\\/]/, ''));
    probe = parent;
  }
  try {
    const real = posix.join(realpathSync(probe), ...tail);
    return real === resolve(filePath) ? null : real;
  } catch {
    return null;
  }
}

/**
 * Block message for a write into an installed plugin copy, or null.
 *
 * WHY THIS IS A HOOK AND NOT A WRITTEN RULE. Editing the cached copy appears to work:
 * the cache IS what Claude Code loads, so the fix takes effect immediately. The next
 * `claude plugin update` overwrites the directory and the change is gone, with no error
 * at any point, and the source repository never saw it — so the bug is still shipped to
 * everyone, the author included. The feedback arrives days later, attached to nothing.
 * Prose cannot compete with a mistake that is invisible at the moment it is made.
 */
export function evaluatePluginCacheWrite(filePath: string, content: string): string | null {
  const target = parsePluginCachePath(filePath);
  if (target === null) return null;
  if (hasCacheAllowMarker(content)) return null;

  const version = target.version ?? '(unversioned)';
  const where = target.inPlugin === '' ? '(the plugin root)' : target.inPlugin;

  return `❌ BLOCKED: this path is an INSTALLED COPY of a plugin, not its source

  Path:      ${filePath}
  Plugin:    ${target.plugin}  (marketplace ${target.marketplace}, version ${version})
  In plugin: ${where}

  Why:      everything under .claude/plugins/cache/ is a copy the installer wrote. The
            edit will LOOK like it worked, because the cache is what gets loaded — and
            the next \`claude plugin update\` overwrites it. No error is ever raised; the
            work is simply gone later, and it never reached the source repository, so
            the bug is still there for everyone else including you.
  Instead:  edit ${where} in the plugin's SOURCE repository — the checkout of the
            ${target.marketplace} marketplace, under its own plugins/ directory — then
            reinstall the copy:

              claude plugin update ${target.plugin}@${target.marketplace}

  To patch the installed copy anyway (a throwaway experiment against the loaded code),
  put \`${PLUGIN_CACHE_ALLOW_MARKER}\` on a line of its own in the content you write. It
  is the same visible marker convention the Bash guard uses, and it stays in the
  transcript so a reviewer can see what was waived.`;
}

async function main(): Promise<void> {
  const input = await readStdin();
  const target = extractWriteTarget(input);
  if (target === null) allow();

  if ((process.env.CLAUDE_GUARDRAILS_OFF ?? '') === '1') allow();

  // Write and NotebookEdit carry the text they put on disk, so that text is judged whole. An
  // Edit is judged in the context of the file it lands in (see evaluateEditSecrets).
  const ti = input.tool_input ?? {};
  const secrets = target.tool === 'Edit'
    ? evaluateEditSecrets(
        readForEdit(target.filePath),
        str(ti.old_string),
        target.written,
        ti.replace_all === true,
      )
    : evaluateWriteSecrets(target.written);
  // A credential outranks the cache gate. Both block, so the choice is only about WHICH
  // message is read, and "edit the source repo instead" while a live key sits in the
  // payload would move that key into the source repo.
  if (secrets) block(secrets.message);

  // Judge the path as given and, when different, the path with symlinks resolved.
  const cacheBlock =
    evaluatePluginCacheWrite(target.filePath, target.written) ??
    evaluatePluginCacheWrite(resolveThroughSymlinks(target.filePath) ?? '', target.written);
  if (cacheBlock !== null) block(cacheBlock);

  allow();
}

// Run main only when invoked directly (not when imported by tests).
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
