// rm -rf: block catastrophic targets everywhere, block other recursive force deletes on
// macOS (where `trash` exists), and warn elsewhere.
//
// Fail direction: decided from argv alone, so there is no I/O to fail. A target the parser
// cannot classify (a `$VAR`, a `{}` from find -exec, nothing at all from xargs) is treated
// as unknown, never as ephemeral.

import { homedir } from 'node:os';
import { parseCommand, type SimpleCommand } from '../lib/bash-parse.ts';
import { RMRF_ALLOW_MARKER, escapeLine, waived } from './config.ts';

/**
 * Is this command's head word `rm`, allowing for globbing in the command word? The shell
 * expands `/bin/r?` and `r[m]` to `rm` before running it, so a head that is a glob pattern
 * matching `rm` is an `rm` invocation. A plain, non-glob head must equal `rm`.
 */
function headIsRm(c: SimpleCommand): boolean {
  const h = c.head;
  if (h === 'rm') return true;
  if (h === null || !/[?*[]/.test(h)) return false;
  // Translate the glob to a regex and test it against `rm`.
  let re = '';
  for (let i = 0; i < h.length; i++) {
    const ch = h[i]!;
    if (ch === '?') re += '.';
    else if (ch === '*') re += '.*';
    else if (ch === '[') {
      const end = h.indexOf(']', i + 1);
      if (end < 0) { re += '\\['; continue; }
      re += h.slice(i, end + 1);
      i = end;
    } else re += ch.replace(/[.+^${}()|\\]/g, '\\$&');
  }
  try {
    return new RegExp('^' + re + '$').test('rm');
  } catch {
    return false;
  }
}

// Ephemeral directories that tooling churns on every run. A target is ephemeral when one of
// its path SEGMENTS is one of these names (so `packages/app/node_modules` counts and
// `src/foo-dist` does not) and it never climbs out with `..`. A command that mixes an
// ephemeral target with any other falls back to the block: unanimous match required.
export const RMRF_WHITELIST_PREFIXES = [
  'node_modules/',
  'dist/',
  'build/',
  'coverage/',
  '.next/',
  '.turbo/',
  '.cache/',
  '__pycache__/',
  '.pytest_cache/',
  '.mypy_cache/',
  '.worktrees/',
  '.claude/worktrees/',
] as const;

const EPHEMERAL_SEGMENTS: ReadonlyArray<readonly string[]> = RMRF_WHITELIST_PREFIXES.map((p) =>
  p.split('/').filter(Boolean),
);

export type RmRfDecision =
  | { kind: 'allow' }
  | { kind: 'allow-with-warning'; message: string }
  | { kind: 'block'; reason: string };

interface RmCommand {
  recursive: boolean;
  force: boolean;
  noPreserveRoot: boolean;
  targets: string[];
}

// rm's long options, so an unambiguous abbreviation (`--recur`, `--forc`) resolves the way
// GNU rm's getopt_long does.
const RM_LONG_OPTIONS = [
  '--recursive', '--force', '--interactive', '--dir', '--verbose', '--one-file-system',
  '--no-preserve-root', '--preserve-root', '--help', '--version',
];

function resolveRmLong(token: string): string {
  if (RM_LONG_OPTIONS.includes(token)) return token;
  const matches = RM_LONG_OPTIONS.filter((o) => o.startsWith(token));
  return matches.length === 1 ? matches[0]! : token;
}

function readRm(argv: readonly string[]): RmCommand {
  const out: RmCommand = { recursive: false, force: false, noPreserveRoot: false, targets: [] };
  let optionsDone = false;
  for (const a of argv) {
    if (!optionsDone && a === '--') { optionsDone = true; continue; }
    if (!optionsDone && a.startsWith('--')) {
      const name = resolveRmLong(a.split('=', 1)[0]!);
      if (name === '--recursive') out.recursive = true;
      if (name === '--force') out.force = true;
      if (name === '--no-preserve-root') out.noPreserveRoot = true;
      continue;
    }
    if (!optionsDone && a.startsWith('-') && a.length > 1) {
      // Short flags may be bundled (`-rf`, `-Rf`) or separate (`-r -f`).
      if (/[rR]/.test(a)) out.recursive = true;
      if (a.includes('f')) out.force = true;
      continue;
    }
    out.targets.push(a);
  }
  return out;
}

/** A path with trailing slashes removed (but `/` kept). */
function trimSlashes(t: string): string {
  const s = t.replace(/\/+$/, '');
  return s === '' ? '/' : s;
}

/**
 * Targets whose deletion is never an agent task: the filesystem root, a top-level system
 * directory, the home directory, the current or parent directory, or everything in it.
 */
export function isCatastrophicTarget(target: string): boolean {
  const t = trimSlashes(target);
  if (/^\/[^/]*$/.test(t)) return true; // `/`, `/*`, `/etc`, `/usr`
  if (/^\/[^/]+\/\*?$/.test(t)) return true; // `/usr/`, `/usr/*` — wipes a top-level dir
  // The home directory in every spelling: `~`, `$HOME`, `${HOME}`, `${HOME:-x}`/`${HOME:?}`,
  // and the literal expansion of $HOME for this process. A trailing `/`, `/*` or `/.*` still
  // targets the whole tree.
  const TAIL = String.raw`(\/|\/\.|\/\*|\/\.\*)?`;
  if (new RegExp(String.raw`^(~|\$HOME|\$\{HOME([:.\-?+=][^}]*)?\})${TAIL}$`).test(t)) return true;
  const home = trimSlashes(homedir());
  if (home && (t === home || t === home + '/*' || t === home + '/.*')) return true;
  // The current directory in every spelling, including `$PWD`, `$(pwd)` and `` `pwd` ``.
  if (/^(\.|\.\.|\*|\.\*|\.\/\*|\.\.\/\*)$/.test(t)) return true;
  if (/^(\$PWD|\$\{PWD\}|\$\(pwd\)|`pwd`|\$CWD|\$\{CWD\})(\/\*|\/\.\*)?$/.test(t)) return true;
  return false;
}

function isEphemeral(target: string): boolean {
  const segs = target.split('/').filter((s) => s !== '' && s !== '.');
  if (segs.includes('..')) return false;
  return EPHEMERAL_SEGMENTS.some((pattern) =>
    segs.some((_, i) => pattern.every((p, k) => segs[i + k] === p)),
  );
}

/**
 * Pure decision for `rm -rf`.
 *
 * `platform` is injectable so BOTH arms are testable; it defaults to the real platform.
 * The macOS arm blocks and names `trash`; every other platform must NOT, because `trash`
 * is a macOS-only Homebrew binary. Emitted unconditionally, the block refuses a working
 * command on Linux and substitutes one that does not exist — which is worse than no guard:
 * it stops the work and offers no route through.
 */
export function evaluateRmRf(
  command: string,
  platform: string = process.platform,
): RmRfDecision {
  const allRm = parseCommand(command)
    .filter(headIsRm)
    .map((c) => readRm(c.argv));

  // Catastrophic targets need only the RECURSIVE flag: `rm -r ~` destroys the home directory
  // whether or not `-f` is given. Force is required only for the recoverability arms below.
  const recursive = allRm.filter((r) => r.recursive);
  const catastrophic = recursive.flatMap((r) => r.targets).filter(isCatastrophicTarget);
  if (catastrophic.length > 0 || recursive.some((r) => r.noPreserveRoot)) {
    return {
      kind: 'block',
      reason: `❌ BLOCKED: rm -rf on ${catastrophic.length > 0 ? catastrophic.join(', ') : 'a --no-preserve-root target'}

  Why:      this deletes the filesystem root, a system directory, the home directory, or
            the whole current directory. None of those is recoverable.
  Instead:  name the specific subdirectory to remove, e.g. rm -rf ./build
            If a variable was meant to fill in the path, check it is set first:
              : "\${DIR:?DIR is unset}" && rm -rf "\$DIR/build"

  No escape: there is no agent task that needs this.`,
    };
  }

  // The recoverability arms (macOS block, elsewhere warn) are about `rm -rf` specifically:
  // a recursive delete that also suppresses prompts. `rm -r` alone still prompts, so it is
  // not treated as an unrecoverable sweep here once the catastrophic check has passed.
  const destructive = allRm.filter((r) => r.recursive && r.force);
  if (destructive.length === 0) return { kind: 'allow' };
  const targets = destructive.flatMap((r) => r.targets);

  if (waived(command, RMRF_ALLOW_MARKER)) {
    return {
      kind: 'allow-with-warning',
      message: `⚠️  rm -rf allowed via the ${RMRF_ALLOW_MARKER} marker.`,
    };
  }

  if (targets.length > 0 && targets.every(isEphemeral)) {
    return {
      kind: 'allow-with-warning',
      message: `⚠️  rm -rf allowed — every target is under a build/ephemeral directory.
  Targets:   ${targets.join(', ')}`,
    };
  }

  // Off macOS there is no `trash`, so this degrades to a loud warning rather than a block.
  // The deliberate trade: the destructive command still runs, and Claude is told it is
  // unrecoverable. `trash-put` (trash-cli) and `gio trash` are named as POSSIBILITIES, not
  // instructions — neither is probed for, so neither is asserted to exist.
  if (platform !== 'darwin') {
    return {
      kind: 'allow-with-warning',
      message: `⚠️  rm -rf is unrecoverable — allowed because this is not macOS (platform: ${platform}).

  Targets:  ${targets.length > 0 ? targets.join(', ') : '(unparsed)'}
  Note:     the \`trash\` remediation is macOS-only, so it is NOT suggested here.
            If your system has trash-cli (\`trash-put\`) or GIO (\`gio trash\`), prefer one.`,
    };
  }

  return {
    kind: 'block',
    reason: `❌ BLOCKED: rm -rf is unrecoverable — use trash instead

  Tried:    rm -rf (or rm -fr, rm -Rf, rm --recursive --force)
  Why:      rm -rf is permanent; trash moves to the recycle bin, which is recoverable
  Instead:  trash <path>
            trash src/old-module/

  Build/ephemeral directories (allowed with a warning if EVERY target is inside one):
    ${RMRF_WHITELIST_PREFIXES.join(', ')}
${escapeLine(RMRF_ALLOW_MARKER)}`,
  };
}
