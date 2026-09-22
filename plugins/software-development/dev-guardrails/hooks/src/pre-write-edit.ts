// PreToolUse hook: Write|Edit secret hygiene.
//
// The write-side sibling of Gate A. Gate A stops a secret reaching the TRANSCRIPT; this
// stops one reaching a FILE, where it goes on to reach git history and everyone with a
// clone. Both directions matter and neither covers the other.
//
// Exit codes: 0 = allow, 1 = warn (advisory, non-blocking), 2 = block.
//
// ORDERING IS LOAD-BEARING, and it has been wrong before. `warn()` is `never`-typed and
// calls process.exit(1), so calling it before the credential checks returns from the hook
// ahead of every security gate: a `.sh` file containing a hardcoded shebang AND a live key
// was written unchallenged, because a STYLE nit terminated the hook in front of a SECURITY
// one. The warning is therefore COLLECTED and emitted after the blocks.
//
// The invariant to preserve when editing this file: nothing that exits may run before the
// last block(). Advisory output goes at the bottom.
//
// A SECOND ordering constraint now lives in main(), and it points the other way. The
// plugin-cache gate judges the PATH, not the content, so it must sit ABOVE the
// `if (!content) allow()` early return — see the comment at its call site.

import { readStdin } from './lib/stdin.ts';
import { block, warn, allow } from './lib/output.ts';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { HARDCODED_BASH_PATH } from './lib/patterns.ts';
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
  const hits: SecretMatch[] = findSecrets(content, WRITE_PATTERNS);
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
 * anywhere in the segment list, so whatever precedes it is irrelevant. Empty and `.`
 * segments are dropped first so `./x` and `a//b` do not shift the window.
 */
export function parsePluginCachePath(filePath: string): PluginCacheTarget | null {
  if (!filePath) return null;
  const segments = filePath.split('/').filter((s) => s !== '' && s !== '.');

  // i + 4 must be a real index: a cache path names at least a marketplace and a plugin.
  for (let i = 0; i + 4 < segments.length; i++) {
    if (!CACHE_SEGMENTS.every((want, k) => segments[i + k] === want)) continue;

    const maybeVersion = segments[i + 5];
    const versioned = maybeVersion !== undefined && VERSION_SEGMENT.test(maybeVersion);
    return {
      marketplace: segments[i + 3] as string,
      plugin: segments[i + 4] as string,
      version: versioned ? (maybeVersion as string) : null,
      inPlugin: segments.slice(versioned ? i + 6 : i + 5).join('/'),
    };
  }
  return null;
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

/** The portability nit. Advisory only, and deliberately emitted after every block. */
export function evaluateShebang(filePath: string, content: string): string | null {
  if (!filePath.endsWith('.sh')) return null;
  if (!HARDCODED_BASH_PATH.test(content)) return null;
  return `⚠️  SHEBANG: hardcoded interpreter path in ${filePath}

  Found:    #!/bin/bash or #!/usr/bin/bash
  Prefer:   #!/usr/bin/env bash  — portable across macOS and Linux
            (/bin/bash is 3.2 on macOS; /usr/bin/bash does not exist there at all)
  Also OK:  #!/usr/bin/env zsh   — when zsh features are intentional`;
}

async function main(): Promise<void> {
  const input = await readStdin();
  const toolName = input.tool_name ?? '';
  if (toolName !== 'Write' && toolName !== 'Edit') allow();

  if ((process.env.CLAUDE_GUARDRAILS_OFF ?? '') === '1') allow();

  const filePath = input.tool_input?.file_path ?? '';
  // Write carries the whole file; Edit carries only the replacement text. Judging the
  // replacement is the right scope for an Edit: the rest of the file was judged when it
  // was written, and re-judging it would block an unrelated edit to a file that already
  // (legitimately) contains a fixture.
  const content = toolName === 'Write'
    ? (input.tool_input?.content ?? '')
    : (input.tool_input?.new_string ?? '');
  // A credential outranks the cache gate. Both block, so the choice is only about WHICH
  // message the operator reads — and being told "edit the source repo instead" while a
  // live key sits in the payload would move that key into the source repo, which is the
  // worse of the two outcomes. Security first, exactly as the header requires.
  const decision = evaluateWriteSecrets(content);
  if (decision) block(decision.message);

  // The plugin-cache gate judges the PATH, so it must sit ABOVE the `if (!content)` early
  // return below — and the ordering is load-bearing in the same way the advisory's is at
  // the bottom of this function. An Edit whose new_string is the empty string (a pure
  // deletion) carries nothing to judge, but it still targets a file the next
  // `claude plugin update` will overwrite, and returning early would let it through.
  const cacheBlock = evaluatePluginCacheWrite(filePath, content);
  if (cacheBlock !== null) block(cacheBlock);

  if (!content) allow();

  // Advisory output goes LAST, after every block() above.
  const shebang = evaluateShebang(filePath, content);
  if (shebang !== null) warn(shebang);

  allow();
}

// Run main only when invoked directly (not when imported by tests).
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
