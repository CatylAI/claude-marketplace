// Turning a command line into the git invocations it runs.
//
// Every git gate needs the same three things: the SUBCOMMAND (after global options such as
// `-C dir`, `-c k=v`, `--no-pager`), its ARGUMENTS as git receives them, and the DIRECTORY
// it runs in. Matching `git\s+push` on the raw line gets all three wrong: it misses
// `git -C repo push`, reads a sibling command's `-f` as a push flag, and judges a
// `reset --hard` against the wrong working tree.

import { parseCommand, unquote, type SimpleCommand } from '../lib/bash-parse.ts';
import { commandDir } from './config.ts';

export interface GitInvocation {
  readonly cmd: SimpleCommand;
  /** The subcommand after global options and alias expansion, e.g. `push`. */
  readonly sub: string;
  /** Arguments after the subcommand, unquoted. */
  readonly args: string[];
  /** Directory it runs in; `null` when it cannot be resolved (see commandDir). */
  readonly dir: string | undefined | null;
}

/** Looks up `alias.<name>` in git config for `dir`; null when there is none. */
export type GitAliasLookup = (name: string, cwd?: string) => string | null;

// Global options that take a separate value (`-C dir`). The `=` forms need no entry.
const GLOBAL_OPTS_WITH_VALUE = new Set([
  '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--super-prefix', '--config-env', '--exec-path',
]);

/**
 * Subcommands git ships with. Anything else may be an alias, and only then is git config
 * consulted — one extra process for an unusual subcommand, none for the everyday ones.
 */
const GIT_BUILTINS = new Set([
  'add', 'am', 'annotate', 'apply', 'archive', 'bisect', 'blame', 'branch', 'bundle', 'cat-file',
  'check-attr', 'check-ignore', 'checkout', 'cherry', 'cherry-pick', 'clean', 'clone', 'commit',
  'config', 'count-objects', 'credential', 'describe', 'diff', 'difftool', 'fetch', 'for-each-ref',
  'format-patch', 'fsck', 'gc', 'grep', 'hash-object', 'help', 'init', 'log', 'ls-files',
  'ls-remote', 'ls-tree', 'maintenance', 'merge', 'merge-base', 'mergetool', 'mv', 'name-rev',
  'notes', 'prune', 'pull', 'push', 'range-diff', 'rebase', 'reflog', 'remote', 'repack',
  'checkout-index', 'read-tree', 'replace', 'request-pull', 'reset', 'restore', 'rev-list', 'rev-parse', 'revert', 'rm',
  'send-pack', 'shortlog', 'show', 'show-branch', 'show-ref', 'sparse-checkout', 'stash', 'status',
  'submodule', 'switch', 'symbolic-ref', 'tag', 'update-index', 'update-ref', 'var', 'version',
  'whatchanged', 'worktree', 'lfs',
]);

/** Alias chains deeper than this are not followed. Git itself refuses loops. */
const MAX_ALIAS_DEPTH = 3;

/**
 * Aliases defined on the command itself, name → body, from two sources git honours before it
 * reads any config file:
 *   - `-c alias.NAME=BODY` (repeatable) among the global options.
 *   - the environment form `GIT_CONFIG_COUNT=n` with `GIT_CONFIG_KEY_i` / `GIT_CONFIG_VALUE_i`
 *     pairs, which set config entries for that one invocation.
 */
function collectInlineAliases(argv: readonly string[], assignments: readonly string[]): Map<string, string> {
  const out = new Map<string, string>();

  for (let i = 0; i < argv.length; i++) {
    const w = argv[i]!;
    let kv: string | undefined;
    if (w === '-c') kv = argv[++i];
    else if (w.startsWith('-c') && w.length > 2 && w[2] !== '-') kv = w.slice(2);
    if (!kv) continue;
    const eq = kv.indexOf('=');
    if (eq < 0) continue;
    const key = kv.slice(0, eq).toLowerCase();
    const m = key.match(/^alias\.(.+)$/);
    if (m) out.set(m[1]!, kv.slice(eq + 1));
  }

  // Environment form: pair KEY_i with VALUE_i.
  const keys = new Map<string, string>();
  const values = new Map<string, string>();
  for (const a of assignments) {
    const eq = a.indexOf('=');
    if (eq < 0) continue;
    const name = a.slice(0, eq);
    const val = a.slice(eq + 1);
    const km = name.match(/^GIT_CONFIG_KEY_(\d+)$/);
    const vm = name.match(/^GIT_CONFIG_VALUE_(\d+)$/);
    if (km) keys.set(km[1]!, val);
    else if (vm) values.set(vm[1]!, val);
  }
  for (const [idx, key] of keys) {
    const am = key.toLowerCase().match(/^alias\.(.+)$/);
    const val = values.get(idx);
    if (am && val !== undefined) out.set(am[1]!, val);
  }

  return out;
}

/** Split an alias body into words, honouring quotes. */
function aliasWords(body: string): string[] {
  const out: string[] = [];
  const re = /"(?:[^"\\]|\\.)*"|'[^']*'|\S+/g;
  for (const m of body.matchAll(re)) out.push(unquote(m[0]));
  return out;
}

function fromCommand(
  cmd: SimpleCommand,
  cwd: string | undefined,
  alias: GitAliasLookup | undefined,
  depth: number,
): GitInvocation[] {
  const argv = cmd.argv;
  const steps: string[] = [...cmd.cdArgs];
  // Aliases defined ON THE COMMAND, before any git config lookup: `-c alias.p='push -f'` and
  // the `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` environment form. Both let a force push be
  // defined entirely inline, invisibly to a lookup that only reads the repo's config.
  const inlineAliases = collectInlineAliases(argv, cmd.assignments);
  let i = 0;
  while (i < argv.length) {
    const w = argv[i]!;
    if (!w.startsWith('-')) break;
    if (w === '-C') steps.push(argv[i + 1] ?? '.');
    i += GLOBAL_OPTS_WITH_VALUE.has(w) ? 2 : 1;
  }
  if (i >= argv.length) return [];
  const dir = commandDir(cwd, steps);
  let sub = argv[i]!;
  let args = argv.slice(i + 1);

  // An inline alias resolves before the config-file lookup and needs no I/O.
  const lookup: GitAliasLookup = (name, d) => inlineAliases.get(name) ?? (alias ? alias(name, d) : null);

  // Expand an alias. A `!` alias is a shell command; its git invocations are judged too.
  let hops = 0;
  while (!GIT_BUILTINS.has(sub) && hops < MAX_ALIAS_DEPTH && depth < MAX_ALIAS_DEPTH) {
    hops++;
    const body = lookup(sub, dir ?? undefined);
    if (!body) break;
    if (body.startsWith('!')) {
      const script = [body.slice(1), ...args.map((a) => `'${a.replace(/'/g, `'\\''`)}'`)].join(' ');
      return parseCommand(script)
        .filter((c) => c.head === 'git')
        .flatMap((c) => fromCommand({ ...c, cdArgs: [...steps, ...c.cdArgs] }, cwd, lookup, depth + 1));
    }
    const words = aliasWords(body);
    if (words.length === 0) break;
    sub = words[0]!;
    args = [...words.slice(1), ...args];
  }

  return [{ cmd, sub, args, dir }];
}

/** Every git invocation in `command`, including nested and aliased ones. */
export function gitInvocations(
  command: string,
  cwd: string | undefined,
  alias?: GitAliasLookup,
): GitInvocation[] {
  return parseCommand(command)
    .filter((c) => c.head === 'git')
    .flatMap((c) => fromCommand(c, cwd, alias, 0));
}

/**
 * Resolve a long option token to its canonical name the way git does: an exact match, or the
 * unique option it is an unambiguous prefix of. `--forc` matches nothing (force / force-with-lease
 * / force-if-includes all start with it) and git rejects it too, so nothing is lost; `--force-w`
 * resolves to `--force-with-lease` and `--mirr` to `--mirror`. Returns the token unchanged when it
 * matches nothing, so an unknown option is simply not one of the flags a caller looks for.
 *
 * `token` is the part before any `=`. Pass the full option set of the relevant subcommand so
 * ambiguity is judged against the same names git would.
 */
export function resolveLongOption(token: string, options: readonly string[]): string {
  if (options.includes(token)) return token;
  const matches = options.filter((o) => o.startsWith(token));
  return matches.length === 1 ? matches[0]! : token;
}

/** git push's long options, so prefix resolution judges ambiguity as git does. */
export const PUSH_LONG_OPTIONS = [
  '--all', '--branches', '--mirror', '--tags', '--follow-tags', '--atomic', '--no-atomic',
  '--dry-run', '--receive-pack', '--exec', '--repo', '--force', '--force-with-lease',
  '--no-force-with-lease', '--force-if-includes', '--no-force-if-includes', '--delete', '--prune',
  '--verbose', '--quiet', '--set-upstream', '--thin', '--no-thin', '--push-option', '--signed',
  '--no-signed', '--sign', '--verify', '--no-verify', '--ipv4', '--ipv6', '--recurse-submodules',
  '--progress', '--porcelain',
] as const;

// --- git push -------------------------------------------------------------------------------

export interface PushPlan {
  /** `--force`, `-f` (bundled or not), or a `+refspec`: overwrite unconditionally. */
  readonly bareForce: boolean;
  readonly lease: boolean;
  readonly mirror: boolean;
  /** `--all` / `--branches`: every local branch, protected ones included. */
  readonly allBranches: boolean;
  /** Destination branch names, `refs/heads/` stripped. `HEAD` stays `HEAD`. */
  readonly destinations: string[];
  /** Branches the push deletes (`--delete x`, `:x`). */
  readonly deletes: string[];
  /** No refspec given: git pushes the current branch. */
  readonly implicitCurrent: boolean;
}

const PUSH_OPTS_WITH_VALUE = new Set(['-o', '--push-option', '--repo', '--receive-pack', '--exec']);

function branchName(ref: string): string {
  return ref.replace(/^refs\/heads\//, '');
}

/** Read a `git push` argument list the way git does. */
export function analyzePush(args: readonly string[]): PushPlan {
  let bareForce = false;
  let lease = false;
  let mirror = false;
  let allBranches = false;
  let deleteFlag = false;
  const positionals: string[] = [];

  let optionsDone = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (optionsDone || !a.startsWith('-') || a === '-') { positionals.push(a); continue; }
    if (a === '--') { optionsDone = true; continue; }
    if (a.startsWith('--')) {
      const [token] = a.split('=', 1);
      // git accepts an unambiguous prefix (`--mirr`, `--force-w`), so resolve before matching.
      const name = resolveLongOption(token!, PUSH_LONG_OPTIONS);
      if (name === '--force') bareForce = true;
      else if (name === '--force-with-lease') lease = true;
      else if (name === '--no-force-with-lease') lease = false;
      else if (name === '--mirror') mirror = true;
      else if (name === '--all' || name === '--branches') allBranches = true;
      else if (name === '--delete') deleteFlag = true;
      else if (!a.includes('=') && PUSH_OPTS_WITH_VALUE.has(name)) i++;
      continue;
    }
    // Bundled short flags: `-uf`, `-fd`. `-o` takes a value (attached or next).
    for (let k = 1; k < a.length; k++) {
      const f = a[k];
      if (f === 'f') bareForce = true;
      else if (f === 'd') deleteFlag = true;
      else if (f === 'o') { if (k === a.length - 1) i++; break; }
    }
  }

  const refspecs = positionals.slice(1); // positionals[0] is the remote
  const destinations: string[] = [];
  const deletes: string[] = [];
  for (const spec of refspecs) {
    let s = spec;
    if (s.startsWith('+')) { bareForce = true; s = s.slice(1); }
    if (deleteFlag) { deletes.push(branchName(s)); continue; }
    const colon = s.indexOf(':');
    if (colon === 0) { deletes.push(branchName(s.slice(1))); continue; }
    destinations.push(branchName(colon > 0 ? s.slice(colon + 1) : s));
  }

  return {
    bareForce,
    lease,
    mirror,
    allBranches,
    destinations,
    deletes,
    implicitCurrent: refspecs.length === 0 && !mirror && !allBranches,
  };
}
