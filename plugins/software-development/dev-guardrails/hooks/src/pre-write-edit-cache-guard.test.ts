// A plugin installed from a marketplace is a COPY. Editing the copy is silently undone.
//
// The install path is `.claude/plugins/cache/<marketplace>/<plugin>/<version>/…`, and that
// directory is what Claude Code actually loads. So an edit there works — immediately,
// convincingly — until the next `claude plugin update` overwrites it. Nothing errors at
// any point. The change is simply gone days later, and because it never reached the
// source repository the bug is still shipped to everyone, the author included.
//
// Two invariants are pinned here, and neither is visible in a pure function:
//
//   1. PLACEMENT. The gate is a judgement on the PATH, so it must run ABOVE main()'s
//      `if (!content) allow()`. An Edit with an empty `new_string` — a pure deletion —
//      would otherwise return early and be written to the doomed copy unchallenged. The
//      empty-new_string test below is the whole reason the placement is testable at all.
//   2. RANK. A credential still outranks this gate. Both block, so only the MESSAGE is at
//      stake; telling an operator "edit the source repo instead" while a live key sits in
//      the payload would relocate that key INTO the source repo, which is worse.
//
// The false positive that matters more than any true positive is the plugin's own source
// tree: `…/<repo>/plugins/<category>/<plugin>/…` is the correct place to edit, and a gate
// that blocked it would make every one of these plugins unmaintainable. It is asserted
// ALLOWED below, alongside a repository with an ordinary directory named `cache`.
//
// Fake credential shapes are assembled at runtime, for the reason given at the top of
// pre-write-edit-gate-order.test.ts: a contiguous literal would be caught by the very
// gate under test when this file is written.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { EXIT_ALLOW, EXIT_BLOCK } from './lib/types.ts';
import {
  PLUGIN_CACHE_ALLOW_MARKER,
  evaluatePluginCacheWrite,
  parsePluginCachePath,
} from './pre-write-edit.ts';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), 'pre-write-edit.ts');

/** Run the hook exactly as Claude Code does. `env` lets one test set the off-switch. */
function runHook(
  payload: unknown,
  extraEnv: Record<string, string> = {},
): { code: number; stderr: string } {
  const env = { ...process.env, ...extraEnv };
  // Unless a test asks for it, the global off-switch would make every assertion vacuous.
  if (!('CLAUDE_GUARDRAILS_OFF' in extraEnv)) delete env.CLAUDE_GUARDRAILS_OFF;
  const r = spawnSync(
    process.execPath,
    ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', HOOK],
    { input: JSON.stringify(payload), encoding: 'utf-8', env },
  );
  return { code: r.status ?? -1, stderr: r.stderr ?? '' };
}

const write = (file_path: string, content: string) => ({
  tool_name: 'Write',
  tool_input: { file_path, content },
});
const edit = (file_path: string, new_string: string) => ({
  tool_name: 'Edit',
  tool_input: { file_path, old_string: 'something', new_string },
});

// An installed copy, on each of the three path shapes a hook actually receives.
const CACHED_ABS_MAC =
  '/Users/example/.claude/plugins/cache/private-marketplace/dev-guardrails/0.4.0/hooks/src/pre-bash.ts';
const CACHED_ABS_LINUX =
  '/home/dev/.claude/plugins/cache/private-marketplace/dev-guardrails/0.4.0/hooks/src/pre-bash.ts';
const CACHED_TILDE =
  '~/.claude/plugins/cache/private-marketplace/dev-guardrails/0.4.0/hooks/src/pre-bash.ts';
const CACHED_RELATIVE =
  '.claude/plugins/cache/private-marketplace/dev-guardrails/0.4.0/SKILL.md';

// The SOURCE tree — the correct place to edit, and the false positive that would make
// this gate intolerable. Note it contains the segment `plugins` and the word `cache`
// nowhere adjacent to it.
const SOURCE_TREE =
  '/home/dev/code/marketplaces/private-marketplace/plugins/software-development/dev-guardrails/SKILL.md';
// An ordinary repository directory that happens to be called `cache`.
const ORDINARY_CACHE_DIR = '/home/dev/code/some-service/src/cache/store.ts';

const CLEAN = 'export const PORT = 8080;\n';
const FAKE_AWS_KEY = 'AKIA' + 'JH3QW9TR6MXP2VKD';

describe('parsePluginCachePath', () => {
  it('pulls marketplace, plugin, version and the in-plugin path out of a cache path', () => {
    const t = parsePluginCachePath(CACHED_ABS_MAC);
    assert.ok(t, 'expected a cache path to parse');
    assert.equal(t.marketplace, 'private-marketplace');
    assert.equal(t.plugin, 'dev-guardrails');
    assert.equal(t.version, '0.4.0');
    assert.equal(t.inPlugin, 'hooks/src/pre-bash.ts');
  });

  it('parses the same path absolute (mac and linux), relative, and tilde-prefixed', () => {
    for (const p of [CACHED_ABS_MAC, CACHED_ABS_LINUX, CACHED_TILDE, CACHED_RELATIVE]) {
      const t = parsePluginCachePath(p);
      assert.ok(t, `expected ${p} to parse as a cache path`);
      assert.equal(t.plugin, 'dev-guardrails');
    }
    // Nothing about the prefix may leak into the in-plugin pointer.
    assert.equal(parsePluginCachePath(CACHED_TILDE)?.inPlugin, 'hooks/src/pre-bash.ts');
    assert.equal(parsePluginCachePath(CACHED_RELATIVE)?.inPlugin, 'SKILL.md');
  });

  it('survives redundant separators and leading ./ without shifting the segment window', () => {
    const t = parsePluginCachePath('./.claude/plugins//cache/mp/some-plugin/1.2.3/README.md');
    assert.ok(t);
    assert.equal(t.marketplace, 'mp');
    assert.equal(t.plugin, 'some-plugin');
    assert.equal(t.inPlugin, 'README.md');
  });

  it('treats a non-version-shaped segment as part of the in-plugin path, not a version', () => {
    const t = parsePluginCachePath('~/.claude/plugins/cache/mp/some-plugin/hooks/src/x.ts');
    assert.ok(t);
    assert.equal(t.version, null);
    assert.equal(t.inPlugin, 'hooks/src/x.ts');
  });

  it('does NOT parse a source tree, an ordinary cache directory, or a plain path', () => {
    assert.equal(parsePluginCachePath(SOURCE_TREE), null);
    assert.equal(parsePluginCachePath(ORDINARY_CACHE_DIR), null);
    assert.equal(parsePluginCachePath('/home/dev/code/app/plugins/cache/thing.ts'), null);
    assert.equal(parsePluginCachePath('src/index.ts'), null);
    assert.equal(parsePluginCachePath(''), null);
  });

  it('is not fooled by a directory whose NAME merely contains the cache segments', () => {
    // The defect a substring matcher would have: `.claude-plugins-cache` and
    // `my.claude/plugins/cache-of-things` both contain the letters, in order, and neither
    // is an install path.
    assert.equal(
      parsePluginCachePath('/home/dev/.claude-plugins-cache/mp/plug/1.0.0/a.ts'),
      null,
    );
    assert.equal(
      parsePluginCachePath('/home/dev/notes/.claude/plugins/cache-of-things/a/b/c.ts'),
      null,
    );
  });

  it('collapses `..` before matching, so traversal cannot hide the cache triple', () => {
    const t = parsePluginCachePath('/home/dev/.claude/plugins/x/../cache/mp/plug/1.0.0/a.ts');
    assert.ok(t);
    assert.equal(t.plugin, 'plug');
    assert.equal(parsePluginCachePath('/home/dev/.claude/plugins/cache/../../src/a.ts'), null);
  });

  it('matches case-insensitively and across Windows separators', () => {
    assert.equal(parsePluginCachePath('/Users/x/.Claude/Plugins/Cache/mp/plug/1.0.0/a.ts')?.plugin, 'plug');
    assert.equal(parsePluginCachePath('C:\\Users\\x\\.claude\\plugins\\cache\\mp\\plug\\1.0.0\\a.ts')?.plugin, 'plug');
  });

  it('honours a plugins directory relocated by CLAUDE_CONFIG_DIR or the cache/seed env vars', () => {
    const p = '/opt/cfg/plugins/cache/mp/plug/2.1.0/hooks/x.ts';
    assert.equal(parsePluginCachePath(p, {}), null);
    const t = parsePluginCachePath(p, { CLAUDE_CONFIG_DIR: '/opt/cfg' });
    assert.ok(t);
    assert.equal(t.version, '2.1.0');
    assert.equal(t.inPlugin, 'hooks/x.ts');
    assert.equal(
      parsePluginCachePath('/seed/cache/mp/plug/1.0.0/a.ts', { CLAUDE_CODE_PLUGIN_SEED_DIR: '/a:/seed' })?.plugin,
      'plug',
    );
    assert.equal(
      parsePluginCachePath('/build/cache/mp/plug/1.0.0/a.ts', { CLAUDE_CODE_PLUGIN_CACHE_DIR: '/build' })?.plugin,
      'plug',
    );
  });
});

describe('evaluatePluginCacheWrite', () => {
  it('names the plugin, the marketplace and the in-plugin relative path', () => {
    const m = evaluatePluginCacheWrite(CACHED_ABS_MAC, CLEAN);
    assert.ok(m, 'expected a block message');
    assert.match(m, /dev-guardrails/);
    assert.match(m, /private-marketplace/);
    assert.match(m, /hooks\/src\/pre-bash\.ts/, 'must name the file to edit in the source');
  });

  it('says the edit is destroyed by the next update, and gives the reinstall command', () => {
    const m = evaluatePluginCacheWrite(CACHED_ABS_MAC, CLEAN);
    assert.ok(m);
    assert.match(m, /claude plugin update dev-guardrails@private-marketplace/);
    assert.match(m, /overwrites/i);
  });

  it('says nothing for a source tree or an ordinary cache directory', () => {
    assert.equal(evaluatePluginCacheWrite(SOURCE_TREE, CLEAN), null);
    assert.equal(evaluatePluginCacheWrite(ORDINARY_CACHE_DIR, CLEAN), null);
  });

  it('is waived by the marker on a line of its own', () => {
    assert.equal(
      evaluatePluginCacheWrite(CACHED_ABS_MAC, `${PLUGIN_CACHE_ALLOW_MARKER}\n${CLEAN}`),
      null,
    );
    assert.equal(evaluatePluginCacheWrite(CACHED_ABS_MAC, `  ${PLUGIN_CACHE_ALLOW_MARKER}  `), null);
  });

  it('is NOT waived by prose that merely documents the marker', () => {
    // The failure pre-bash already hit: a substring test turns the file explaining the
    // gate into a universal override — and this plugin's own README lives in the cache.
    const prose = `Append \`${PLUGIN_CACHE_ALLOW_MARKER}\` to waive this rule.\n`;
    assert.ok(
      evaluatePluginCacheWrite(CACHED_ABS_MAC, prose),
      'documentation of the marker must not act as the marker',
    );
  });
});

describe('pre-write-edit plugin-cache gate, as Claude Code runs it', () => {
  it('BLOCKS a Write into a plugin cache directory', () => {
    const r = runHook(write(CACHED_ABS_MAC, CLEAN));
    assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /INSTALLED COPY/);
  });

  it('BLOCKS an Edit with an EMPTY new_string — the early return must not pre-empt it', () => {
    // THE PLACEMENT ASSERTION. main() returns via `if (!content) allow()`; a path gate
    // placed below it never sees a pure deletion, and the deletion lands in the copy the
    // next update overwrites. Move the gate down and only this test goes red.
    const r = runHook(edit(CACHED_ABS_MAC, ''));
    assert.equal(
      r.code,
      EXIT_BLOCK,
      `an empty-replacement Edit into the cache must still BLOCK, got ${r.code}: ${r.stderr}`,
    );
    assert.match(r.stderr, /INSTALLED COPY/);
  });

  it('BLOCKS a tilde-prefixed and a relative cache path too', () => {
    assert.equal(runHook(write(CACHED_TILDE, CLEAN)).code, EXIT_BLOCK);
    assert.equal(runHook(write(CACHED_RELATIVE, '# notes\n')).code, EXIT_BLOCK);
  });

  it('ALLOWS a normal repository path that merely contains a directory named `cache`', () => {
    const r = runHook(write(ORDINARY_CACHE_DIR, CLEAN));
    assert.equal(r.code, EXIT_ALLOW, `expected ALLOW, got ${r.code}: ${r.stderr}`);
    assert.equal(r.stderr, '');
  });

  it('ALLOWS a write to the plugin SOURCE tree — the one false positive that cannot happen', () => {
    const r = runHook(write(SOURCE_TREE, '---\nname: dev-guardrails\n---\n'));
    assert.equal(r.code, EXIT_ALLOW, `the source tree must stay writable, got ${r.code}: ${r.stderr}`);
    assert.equal(r.stderr, '');
  });

  it('names the plugin and the in-plugin relative path in the block message', () => {
    const r = runHook(write(CACHED_ABS_MAC, CLEAN));
    assert.match(r.stderr, /dev-guardrails/);
    assert.match(r.stderr, /hooks\/src\/pre-bash\.ts/);
    assert.match(r.stderr, /claude plugin update dev-guardrails@private-marketplace/);
  });

  it('is disabled by CLAUDE_GUARDRAILS_OFF=1', () => {
    const r = runHook(write(CACHED_ABS_MAC, CLEAN), { CLAUDE_GUARDRAILS_OFF: '1' });
    assert.equal(r.code, EXIT_ALLOW, `expected ALLOW with the off-switch, got ${r.code}`);
  });

  it('is waived by the marker on its own line, end to end', () => {
    const r = runHook(write(CACHED_ABS_MAC, `${PLUGIN_CACHE_ALLOW_MARKER}\n${CLEAN}`));
    assert.equal(r.code, EXIT_ALLOW, `expected the marker to waive, got ${r.code}: ${r.stderr}`);
  });

  it('reports the CREDENTIAL, not the cache path, when a write has both', () => {
    // THE RANK ASSERTION. Both gates block, so the code alone proves nothing; what is at
    // stake is which message the operator reads. "Edit the source repo instead" applied to
    // a payload carrying a live key would move the key into the source repo.
    const r = runHook(write(CACHED_ABS_MAC, `AWS_ACCESS_KEY_ID=${FAKE_AWS_KEY}\n`));
    assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /BLOCKED: credential-shaped content/);
    assert.doesNotMatch(
      r.stderr,
      /INSTALLED COPY/,
      'the credential must be what gets reported when both gates fire',
    );
  });

  it('BLOCKS a write that reaches the cache through a symlink in the working tree', () => {
    const root = mkdtempSync(join(tmpdir(), 'pwe-cache-'));
    try {
      const installed = join(root, 'home', '.claude', 'plugins', 'cache', 'mp', 'plug', '1.0.0');
      mkdirSync(installed, { recursive: true });
      const repo = join(root, 'repo');
      mkdirSync(repo);
      symlinkSync(installed, join(repo, 'vendored'));
      const r = runHook(write(join(repo, 'vendored', 'hooks', 'new.ts'), CLEAN));
      assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
      assert.match(r.stderr, /INSTALLED COPY/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('still BLOCKS a credential written to an ordinary path', () => {
    // Control for the test above: proves the credential block is a property of the
    // content, not an artefact of the cache path being present.
    const r = runHook(write(ORDINARY_CACHE_DIR, `AWS_ACCESS_KEY_ID=${FAKE_AWS_KEY}\n`));
    assert.equal(r.code, EXIT_BLOCK, `expected a BLOCK, got ${r.code}: ${r.stderr}`);
    assert.match(r.stderr, /BLOCKED: credential-shaped content/);
  });
});
