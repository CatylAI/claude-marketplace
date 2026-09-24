// Gate A: never PRINT a secret into the transcript.
//
// The incident this exists for, run to check whether a token was configured:
//
//   echo "TF_TOKEN set: ${TF_TOKEN_example_com:+yes}${TF_TOKEN_example_com:-no}"
//
// It printed `yes` followed by the full token, into the transcript and into task-output
// files on disk. The token had to be rotated. `${VAR:-fallback}` yields VAR'S VALUE when
// VAR is set — only `${VAR:+literal}` is safe. Half the command was right, which is exactly
// why it passed review.
//
// Secret scanners see staged FILES; this secret never touched one. This gate is the
// enforcement point for secrets in flight.
//
// Scoping is deliberately NARROW: it fires only when an unsafe expansion reaches the
// resolved head word of a command that prints to the transcript. A broad "any unsafe
// expansion anywhere" rule would fire on `export TOKEN="$X"` and on
// `curl -H "Authorization: Bearer $TOKEN"` — ordinary work. A gate that fires on ordinary
// work gets deleted, and that would take the rm -rf and force-push guards down with it.
// Narrow-and-kept beats broad-and-removed.
//
// Fail direction: CLOSED on a match (a printed secret is irreversible and must be
// rotated; a false block costs one rewrite). If the parser itself throws, the hook's main()
// fails open with a visible hook-error notice, because blocking every Bash call is worse.

import {
  blankUnexpanded, classifyExpansions, extractHeredocs, parseCommand, type SimpleCommand,
} from '../lib/bash-parse.ts';
import { isSecretVarName } from '../lib/secrets.ts';
import { SECRET_PRINT_ALLOW_MARKER, escapeLine, waived } from './config.ts';

// Commands that put their arguments in front of the model.
const PRINTING_HEADS = new Set([
  'echo', 'printf', 'print', 'cat', 'tac', 'tee', 'less', 'more', 'head', 'tail', 'od',
  'xxd', 'hexdump', 'base64', 'strings', 'jq', 'yq', 'awk', 'sed', 'tr', 'rev',
  'nl', 'pr', 'fmt', 'column', 'logger', 'banner', 'say', 'sort', 'uniq', 'paste',
  'fold', 'expand', 'unexpand', 'diff',
]);

// --- Retrieval commands --------------------------------------------------------------------
//
// Commands whose whole purpose is to hand back a plaintext credential. Matched on argv, so
// global options in front of the subcommand (`aws --profile p secretsmanager …`,
// `kubectl -n ns get secret …`, `op --account a read …`) do not hide it.

/** Non-option words, in order. Option VALUES stay in the list; `hasRun` tolerates them. */
function positionals(argv: readonly string[]): string[] {
  return argv.filter((w) => !w.startsWith('-'));
}

/** True when `seq` appears as a contiguous run in `words`. Strings match exactly. */
function hasRun(words: readonly string[], seq: ReadonlyArray<string | RegExp>): boolean {
  for (let i = 0; i + seq.length <= words.length; i++) {
    if (seq.every((s, k) => (typeof s === 'string' ? words[i + k] === s : s.test(words[i + k]!)))) return true;
  }
  return false;
}

const DATA_FORMAT = /^(json|yaml|jsonpath|go-template)/;
function kubectlPrintsData(argv: readonly string[]): boolean {
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    let value = '';
    if (a === '-o' || a === '--output') value = argv[i + 1] ?? '';
    else if (a.startsWith('--output=')) value = a.slice('--output='.length);
    else if (a.startsWith('-o')) {
      // Attached form `-ojson` / `-ojsonpath={…}`: the format is the part after `-o`, up to
      // any `=`. Splitting on `=` first read the jsonpath EXPRESSION as the format and missed.
      value = a.slice(2).split('=', 1)[0]!;
    } else continue;
    if (DATA_FORMAT.test(value)) return true;
  }
  return false;
}

// `pass` subcommands that do NOT print a password. Any other first word is a store path,
// and `pass <path>` is `pass show <path>`.
const PASS_NON_SHOW = new Set([
  'init', 'ls', 'list', 'find', 'search', 'grep', 'insert', 'add', 'edit', 'generate', 'rm',
  'remove', 'delete', 'mv', 'rename', 'cp', 'copy', 'git', 'help', 'version',
]);

interface RetrievalRule {
  readonly rule: string;
  readonly head: string;
  readonly match: (argv: readonly string[]) => boolean;
}

const VARIABLES_PATH = /\/variables(\/|$|\?)/;
const GL_TOKEN_PATH = /\/(access_tokens|personal_access_tokens|deploy_tokens|runners)(\/|$|\?)/;
const GH_TOKEN_PATH = /\/(access_tokens|personal_access_tokens)(\/|$|\?)/;

const RETRIEVAL_RULES: readonly RetrievalRule[] = [
  { rule: 'op read', head: 'op', match: (a) => hasRun(positionals(a), ['read']) || hasRun(positionals(a), ['item', 'get']) },
  { rule: 'gh auth token', head: 'gh', match: (a) => a[0] === 'auth' && a[1] === 'token' },
  { rule: 'glab auth token', head: 'glab', match: (a) => a[0] === 'auth' && a[1] === 'token' },
  // `gh auth status --show-token` / `-t` prints the stored token in its status output.
  { rule: 'gh auth status --show-token', head: 'gh', match: (a) => a[0] === 'auth' && a[1] === 'status' && a.some((w) => w === '--show-token' || w === '-t') },
  { rule: 'glab auth status --show-token', head: 'glab', match: (a) => a[0] === 'auth' && a[1] === 'status' && a.some((w) => w === '--show-token' || w === '-t') },
  // `aws configure get <secret key>` and `export-credentials` both hand back the value.
  { rule: 'aws configure get', head: 'aws', match: (a) => hasRun(positionals(a), ['configure', 'get']) && a.some((w) => /secret|token|password|session/i.test(w)) },
  { rule: 'aws configure export-credentials', head: 'aws', match: (a) => hasRun(positionals(a), ['configure', 'export-credentials']) },
  { rule: 'aws secretsmanager get-secret-value', head: 'aws', match: (a) => hasRun(positionals(a), ['secretsmanager', 'get-secret-value']) },
  {
    rule: 'aws ssm get-parameter --with-decryption', head: 'aws',
    match: (a) => hasRun(positionals(a), ['ssm', /^get-parameters?(-by-path)?$/]) && a.includes('--with-decryption'),
  },
  { rule: 'aws ecr get-login-password', head: 'aws', match: (a) => hasRun(positionals(a), ['ecr', 'get-login-password']) },
  { rule: 'aws sts get-session-token / assume-role', head: 'aws', match: (a) => hasRun(positionals(a), ['sts', /^(get-session-token|assume-role|get-federation-token|assume-role-with-web-identity)$/]) },
  { rule: 'gcloud auth print-*-token', head: 'gcloud', match: (a) => hasRun(positionals(a), ['auth', /^print-(access|identity)-token$/]) },
  { rule: 'gcloud secrets versions access', head: 'gcloud', match: (a) => hasRun(positionals(a), ['secrets', 'versions', 'access']) },
  { rule: 'vault kv get', head: 'vault', match: (a) => a[0] === 'read' || hasRun(positionals(a), ['kv', 'get']) },
  { rule: 'security find-generic-password', head: 'security', match: (a) => /^find-(generic|internet)-password$/.test(a[0] ?? '') },
  {
    rule: 'pass show', head: 'pass',
    match: (a) => { const p = positionals(a); return p[0] === 'show' || (p.length > 0 && !PASS_NON_SHOW.has(p[0]!)); },
  },
  { rule: 'kubectl get secret -o', head: 'kubectl', match: (a) => hasRun(positionals(a), ['get', /^secrets?(\/|$)/]) && kubectlPrintsData(a) },
  { rule: 'az keyvault secret show', head: 'az', match: (a) => hasRun(positionals(a), ['keyvault', 'secret', /^(show|download)$/]) },
  { rule: 'doppler secrets', head: 'doppler', match: (a) => hasRun(positionals(a), ['secrets', /^(get|download)$/]) },

  // --- CI/CD variable stores -------------------------------------------------------
  // These read a variable STORE, not one named secret, so a single call hands back every
  // credential the project holds. Both forges return the value in plaintext for masked
  // variables too — masking governs job-log display, not the API. A substring filter over
  // the response does not help: the filter matches on the KEY and prints the whole
  // {"key":…,"value":…} object.
  //
  // Matched on the path, not the verb, and deliberately so: a GET is the leak, and the
  // POST/PUT that SETS a variable also carries the value on the command line unless it
  // comes from a heredoc or --input. Both want the same treatment.
  { rule: 'glab api …/variables', head: 'glab', match: (a) => a[0] === 'api' && a.some((w) => VARIABLES_PATH.test(w)) },
  { rule: 'gh api …/variables', head: 'gh', match: (a) => a[0] === 'api' && a.some((w) => VARIABLES_PATH.test(w)) },
  { rule: 'glab variable get', head: 'glab', match: (a) => a[0] === 'variable' && /^(get|list|export)$/.test(a[1] ?? '') },
  { rule: 'gh variable get', head: 'gh', match: (a) => a[0] === 'variable' && /^(get|list)$/.test(a[1] ?? '') },

  // Token MINTING returns the only copy of the token that will ever exist — the API never
  // shows it again. Printing it is therefore worse than printing a re-readable secret.
  { rule: 'glab api …/access_tokens', head: 'glab', match: (a) => a[0] === 'api' && a.some((w) => GL_TOKEN_PATH.test(w)) },
  { rule: 'gh api …/tokens', head: 'gh', match: (a) => a[0] === 'api' && a.some((w) => GH_TOKEN_PATH.test(w)) },
];

// Consumers that take a credential on stdin and do not echo it. Piping a retrieval into
// one of these is the SANCTIONED pattern, not a leak.
const SANCTIONED_CONSUMERS = new Set([
  'docker', 'podman', 'buildah', 'skopeo', 'crane', 'glab', 'gh', 'helm', 'kubectl',
  'npm', 'yarn', 'pnpm', 'pip', 'pip3', 'twine', 'vault', 'aws', 'gcloud', 'az',
  'op', 'gpg', 'ssh-add', 'keyring',
]);

/**
 * Is a retrieval's output consumed rather than printed?
 *
 * Captured into a variable, written to a file, piped into a consumer, or substituted as an
 * ARGUMENT of a command that does not print (`curl -H "…$(op read …)"`,
 * `docker login -p "$(gh auth token)"`). Substituted into a PRINTER, or into head position
 * where it would be executed and echoed back as "command not found", it is not.
 */
function consumed(c: SimpleCommand): boolean {
  if (c.captured || c.redirectsStdout) return true;
  if (c.pipeTo.some((h) => SANCTIONED_CONSUMERS.has(h))) return true;
  if (c.pipeTo.length === 0 && c.depth > 0 && c.substitutedInto !== null) {
    return !PRINTING_HEADS.has(c.substitutedInto);
  }
  return false;
}

// --- Environment dumps -----------------------------------------------------------------------

// Consumers that cannot pass a VALUE through to the transcript, so `env | …` is a safe way
// to inspect WHICH variables exist. `grep` qualifies only with -c/-q/-l, because a plain
// `env | grep AWS` prints whole NAME=value lines.
//
// `wc` counts and cannot emit input. `cut` only qualifies in FIELD mode with an `=`
// delimiter — the `env | cut -d= -f1` idiom this rule exists to permit. Bare `cut` must not
// qualify unconditionally: `env | cut -c1-200` prints whole NAME=value lines straight past
// the guard. Character mode and any `-f` range reaching past field 1 both carry the value.
const VALUE_STRIPPING_HEADS = new Set(['wc']);
function stripsValues(head: string, words: string[]): boolean {
  if (VALUE_STRIPPING_HEADS.has(head)) return true;
  if (head === 'cut') {
    const joined = words.join(' ');
    const fieldsOnEquals = /-d[\s=]?'?"?=/.test(joined) || /--delimiter[\s=]'?"?=/.test(joined);
    const firstFieldOnly = /-f[\s=]?'?"?1'?"?(\s|$)/.test(joined) || /--fields[\s=]'?"?1'?"?(\s|$)/.test(joined);
    return fieldsOnEquals && firstFieldOnly;
  }
  if (head === 'grep' || head === 'egrep' || head === 'rg') {
    return words.some((w) => /^-[a-zA-Z]*[cql]/.test(w));
  }
  return false;
}

/** Builtins that print every variable WITH its value when given these arguments. */
function isBuiltinDump(c: SimpleCommand): boolean {
  const a = c.argv;
  if (c.head === 'set') return a.length === 0;
  if (c.head === 'export') return a.length === 0 || (a.length === 1 && a[0] === '-p');
  if (c.head === 'declare' || c.head === 'typeset') {
    return a.length === 0 || a.every((w) => /^-[xp]+$/.test(w));
  }
  return false;
}

// --- Credential files ------------------------------------------------------------------------

// Files that exist to hold credentials.
//
// The suffixed arm matters as much as the exact-name arm. With only a complete-filename
// match, `~/.aws/credentials` is caught and `~/.config/credentials-backup-2026.json` is
// not — and the second is just as live. `.md` is absent from the extension list on
// purpose: a document named `credentials-standards.md` is prose ABOUT credentials, and
// blocking it trains people around the gate.
//
// Template env files (`.env.example`, `.env.sample`, `.env.template`, `.env.dist`) are
// committed placeholders by convention, and reading them is how a project documents its
// configuration, so they are exempt. A bare `config.json` is not a credential file: that
// name is everywhere; only `~/.docker/config.json` is, and CREDENTIAL_FILE_PATHS has it.
const CREDENTIAL_FILE_EXTS = 'json|yaml|yml|txt|csv|env|ini|conf|toml|xml|properties';
const ENV_TEMPLATE = '(?!\\.(?:example|sample|template|dist|defaults?)(?:[\'"\\s;|&]|$))';
const CREDENTIAL_FILES = new RegExp(
  `(?:^|[\\s'"=/])(?:` +
  `\\.env${ENV_TEMPLATE}(?:\\.[\\w.-]+)?|\\.terraformrc|\\.netrc|\\.pgpass|credentials` +
  `)(?:['"\\s;|&]|$)` +
  `|[\\w.-]*credentials[\\w.-]*\\.(?:${CREDENTIAL_FILE_EXTS})(?:['"\\s;|&]|$)`);

// A PKCS#8 private key (`snowflake_key.p8`, `~/.snowflake/keys/*.p8`, `KEY.P8`), and the
// Snowflake CLI connection file by its basename, because `$SNOWFLAKE_HOME` can move it out of
// `~/.snowflake/`. The name part of a key may be a glob, so `*` and `?` are allowed before the
// extension; `key.p8.pub` does not match because the extension must end the word.
// A separate regex so the `i` flag applies here only: extending it to CREDENTIAL_FILES would
// also change how `.env` and `credentials` match.
const SNOWFLAKE_CREDENTIAL_FILES = new RegExp(
  `(?:^|[\\s'"=/])(?:[\\w.*?-]*\\.p8|connections\\.toml)(?:['"\\s;|&]|$)`, 'i');
// `/proc/<pid>/environ` is the whole environment of a process: an env dump by another name.
// The Snowflake CLI keeps connections, including a password, token or key passphrase when
// one is configured, in `connections.toml` (above) or the `[connections]` section of
// `~/.snowflake/config.toml`. config.toml is matched by directory because the name alone is
// everywhere.
const CREDENTIAL_FILE_PATHS =
  /(?:\.aws\/credentials|\.docker\/config\.json|\.netrc|\.terraformrc|\.pgpass|\.npmrc|\.snowflake\/config\.toml|\/proc\/[^/\s]+\/environ)/;

// openssl subcommands that read or make a PRIVATE key and, by default, write it (PEM, or
// with `-text` its numbers) to stdout. `openssl pkey -in key.p8` prints the decrypted key
// even though it never names a printing head, so Rule 4 cannot see it.
const OPENSSL_PRIVATE_KEY_SUBCOMMANDS = new Set(['pkey', 'rsa', 'ec', 'pkcs8', 'genrsa', 'genpkey']);

/**
 * True when an openssl call would write private key material to the transcript.
 * Allowed: `-pubin`/`-pubout` (public half only), `-out <file>`, and `-noout` without
 * `-text` (a `-check` prints "RSA key ok"; `-text -noout` still prints the key's numbers).
 */
function opensslPrintsPrivateKey(cmd: SimpleCommand): boolean {
  if (cmd.head !== 'openssl') return false;
  const sub = cmd.argv.find((w) => !w.startsWith('-'));
  if (sub === undefined || !OPENSSL_PRIVATE_KEY_SUBCOMMANDS.has(sub)) return false;
  if (cmd.redirectsStdout) return false;
  const a = cmd.argv;
  if (a.includes('-pubin') || a.includes('-pubout')) return false;
  if (a.includes('-noout') && !a.includes('-text')) return false;
  const outAt = a.indexOf('-out');
  const outTo = outAt >= 0 ? a[outAt + 1] : undefined;
  const outIsStdout = outTo === undefined || outTo === '-' || /^\/dev\/(?:stdout|stderr|tty)$/.test(outTo);
  if (outAt >= 0 && !outIsStdout) return false;
  // Piped into another program (`openssl genrsa 2048 | openssl pkcs8 … -out f`): the key
  // reaches the transcript only if something downstream prints it.
  if (cmd.pipeTo.length > 0) return cmd.pipeTo.some((h) => PRINTING_HEADS.has(h));
  return true;
}

// grep and friends read a file and print the matching lines, which is the same disclosure
// `cat` makes. They are a SEPARATE set rather than an addition to PRINTING_HEADS: that set
// also drives Rule 1, and adding grep there would start blocking `grep "$TOKEN" file`,
// which is a behaviour change nobody asked for. This rule is narrow already — it fires only
// when the ARGUMENTS name a credential file.
const CONTENT_SEARCH_HEADS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ripgrep', 'ag', 'ack']);

// Flags that make a search emit counts, filenames or nothing instead of file content.
// These MUST stay allowed, because this rule's own block message recommends
// `grep -c . .env` as the safe alternative. A gate that blocks the remediation it prints
// teaches people to reach for the escape marker instead.
//
// `[cqlL]` and not `[cqlLC]`: lowercase -l is files-with-matches and -L is
// files-without-match, both of which suppress content, while uppercase -C is context
// lines, which prints more of it.
const CONTENT_SUPPRESSING_FLAGS =
  /(?:^|\s)-[a-zA-Z]*[cqlL][a-zA-Z]*(?:\s|$)|--(?:count|quiet|silent|files-with-matches|files-without-match)\b/;

// Credential filenames a glob might expand onto. A word that globs (`.e*`, `.en?`, `.env.*`)
// and whose literal prefix is a prefix of one of these could resolve to the real file, so it
// is treated as naming it. Kept short and specific so an ordinary glob does not trip it.
const GLOBBABLE_CREDENTIAL_NAMES = ['.env', '.netrc', '.pgpass', '.npmrc', '.terraformrc', 'credentials'];
function globMatchesCredential(word: string): boolean {
  const at = word.search(/[?*[]/);
  if (at < 0) return false;
  const base = word.slice(0, at).split('/').pop() ?? '';
  if (base === '') return false;
  return GLOBBABLE_CREDENTIAL_NAMES.some((name) => name.startsWith(base) || base.startsWith(name));
}

/** The words of a search command with its PATTERN removed, leaving the paths. */
function dropSearchPattern(words: readonly string[]): string[] {
  const out: string[] = [];
  let droppedPattern = false;
  for (const w of words) {
    if (!droppedPattern && !w.startsWith('-')) {
      droppedPattern = true; // this is the pattern; omit it
      continue;
    }
    out.push(w);
  }
  return out;
}

// --- Messages --------------------------------------------------------------------------------

const SAFE_IDIOMS = `  Instead:  [ -n "\${VAR:-}" ] && echo "VAR: set" || echo "VAR: unset"   # preferred
            echo "VAR: \${VAR:+set}"                                      # empty when unset
            echo "VAR length: \${#VAR}"                                   # length only
            echo "VAR prefix: \${VAR:0:4}…"                               # identify key type`;

const EXPANSION_TRUTH_TABLE = `  Why:      \`\${VAR:-x}\` prints VAR'S VALUE when VAR is set — it only yields \`x\` when VAR is
            UNSET. You want \`\${VAR:+x}\`. That one character is the whole bug.

              \${VAR}      \${VAR:-x}  \${VAR:=x}  \${VAR:?x}   → the value    UNSAFE
              \${VAR:+x}   \${VAR+x}   \${#VAR}    \${VAR:0:4}  → not the value SAFE`;

export interface SecretPrintDecision {
  /** Short rule id, used in tests and in the block message. */
  readonly rule: string;
  readonly message: string;
}

/**
 * Pure decision for Gate A: the block message, or null to allow.
 *
 * Allowed by construction, because none of these puts a secret in front of the model:
 *   - a safe expansion form (`${V:+x}`, `${V+x}`, `${#V}`, `${V:0:4}`)
 *   - assignment or pass-through: `FOO="$SECRET" cmd`, `export TOKEN="$Y"`
 *   - a header or request body: `curl -H "Authorization: Bearer $TOKEN"`
 *   - stdout redirected to a file — it never reaches the transcript, and this is how
 *     `~/.terraformrc` and `.npmrc` are legitimately generated
 *   - a retrieval captured into a variable, piped to a sanctioned consumer, or substituted
 *     into the arguments of a command that does not print
 */
export function evaluateSecretPrint(command: string): SecretPrintDecision | null {
  if (!command) return null;

  // The marker opts a single deliberate line out. Applied per-rule, NOT globally: the
  // env-dump rule has no escape, because there is always a targeted alternative and a full
  // dump is unbounded disclosure.
  const marked = waived(command, SECRET_PRINT_ALLOW_MARKER);

  // Every simple command, nested ones included. Heredoc BODIES are not commands (the
  // parser strips them), so writing a doc that merely MENTIONS `op read` does not trip the
  // retrieval rule — the gate obstructing the documentation of itself is how gates get
  // switched off. A body fed to a SHELL is a script, and the parser does include that.
  const commands = parseCommand(command);
  const { heredocs } = extractHeredocs(command);
  const anyRedirect = commands.some((c) => c.redirectsStdout);

  // --- Rule 1: an unsafe expansion of a secret-named variable reaches a printer -----
  for (const cmd of commands) {
    if (marked) break;
    if (cmd.redirectsStdout) continue; // goes to a file, not the transcript
    const headIsPrinter = cmd.head !== null && PRINTING_HEADS.has(cmd.head);

    // An expansion in HEAD position is executed; "command not found: <token>" echoes it.
    // headRaw skips assignment prefixes, so `FOO="$SECRET" make deploy` is not a print.
    // Single-quoted and $'…' spans are blanked first: `echo 'set $TOKEN first'` is literal
    // text bash never expands, so it must not read as a printed secret.
    const headExpansions = classifyExpansions(blankUnexpanded(cmd.headRaw ?? ''));
    const printerArgs = [
      ...(headIsPrinter ? cmd.words : []),
      // A here-string feeds the command's stdin, and `cat <<< "$TOKEN"` prints it. The RAW
      // operand is used (quotes intact) so `<<< '$TOKEN'` stays literal.
      ...(headIsPrinter ? cmd.hereStrings : []),
    ];
    const argExpansions = classifyExpansions(blankUnexpanded(printerArgs.join(' ')));

    for (const e of [...headExpansions, ...argExpansions]) {
      if (e.safe) continue;
      // For indirect expansion the pointer's own name says nothing about its target, so
      // the allowlist must not apply — `${!CFG}` may well dereference a token.
      const isSecret = e.form === 'indirect' ? true : isSecretVarName(e.name);
      if (!isSecret) continue;

      const where = headExpansions.includes(e) ? 'as the command itself' : `as an argument to \`${cmd.head}\``;
      return {
        rule: 'unsafe-expansion',
        message: `❌ BLOCKED: this would print the value of ${e.name}

  Tried:    ${e.raw}  ${where}
${EXPANSION_TRUTH_TABLE}

${SAFE_IDIOMS}

            Writing it to a file instead of stdout is also fine — a redirect never
            reaches the transcript.

${escapeLine(SECRET_PRINT_ALLOW_MARKER)}`,
      };
    }
  }

  // --- Rule 1a: `printenv NAME` / `declare -p NAME` print that variable's value --------
  for (const cmd of commands) {
    if (marked) break;
    if (cmd.redirectsStdout) continue;
    // `declare -p NAME` / `typeset -p NAME` / `export -p NAME` print `NAME=<value>`.
    const isNamedPrint =
      cmd.head === 'printenv' ||
      ((cmd.head === 'declare' || cmd.head === 'typeset' || cmd.head === 'export') &&
        cmd.argv.some((w) => w.startsWith('-') && w.slice(1).includes('p')));
    if (!isNamedPrint) continue;
    const name = cmd.argv.find((w) => !w.startsWith('-') && isSecretVarName(w));
    if (!name) continue;
    return {
      rule: 'unsafe-expansion',
      message: `❌ BLOCKED: \`${cmd.head} … ${name}\` prints the value of ${name}

  Why:      reading ${name} back by name is \`echo "$${name}"\` by another spelling.
${SAFE_IDIOMS}

${escapeLine(SECRET_PRINT_ALLOW_MARKER)}`,
    };
  }

  // --- Rule 1b: an expansion-enabled heredoc body carrying a secret ------------------
  if (!anyRedirect && !marked) {
    for (const doc of heredocs) {
      if (doc.quoted) continue; // <<'EOF' performs no expansion at all
      for (const e of classifyExpansions(doc.body)) {
        if (e.safe) continue;
        if (!(e.form === 'indirect' || isSecretVarName(e.name))) continue;
        return {
          rule: 'unsafe-expansion-heredoc',
          message: `❌ BLOCKED: an unquoted heredoc would expand ${e.name} into its body

  Tried:    ${e.raw} inside <<${doc.delimiter}
  Why:      an unquoted heredoc delimiter performs expansion. Quote it — <<'${doc.delimiter}' —
            and the body is passed through literally.
${EXPANSION_TRUTH_TABLE}

${escapeLine(SECRET_PRINT_ALLOW_MARKER)}`,
        };
      }
    }
  }

  // --- Rule 2: a retrieval command whose plaintext output is not consumed ------------
  for (const owner of commands) {
    if (marked) break;
    const hit = RETRIEVAL_RULES.find((r) => r.head === owner.head && r.match(owner.argv));
    if (!hit || consumed(owner)) continue;
    const rule = hit.rule;
    return {
      rule: 'secret-retrieval-print',
      message: `❌ BLOCKED: \`${rule}\` returns a plaintext credential and nothing consumes it

  Tried:    ${owner.raw.slice(0, 160)}
  Why:      retrieving a secret is the sanctioned pattern; PRINTING the result is the
            defect. With no capture, no redirect and no consumer on the other side of a
            pipe, the value lands in the transcript and in the task-output file on disk.

  Instead:  TOKEN="$(${rule} …)"                     # capture into a variable
            ${rule} … | docker login --password-stdin  # hand straight to a consumer
            ${rule} … > "$HOME/.config/…"             # write to a file
            echo "retrieved: \${TOKEN:+yes}"           # confirm without disclosing

${escapeLine(SECRET_PRINT_ALLOW_MARKER)}`,
    };
  }

  // --- Rule 3: unfiltered environment dumps -----------------------------------------
  // No allow-marker on this rule: there is always a targeted alternative, and a full dump
  // in a session that has ever exported a token is an unbounded disclosure.
  const envDump = commands.find((c) => {
    if (c.redirectsStdout) return false;
    if (isBuiltinDump(c)) return true;
    if (c.head === 'env' || c.head === 'printenv') {
      // `printenv NAME` reads named variables (Rule 1a judged them). `env` still has
      // `env` as its head only when no command follows its options and assignments,
      // which is exactly the case where it prints the environment.
      if (c.head === 'printenv' && c.argv.some((w) => !w.startsWith('-'))) return false;
      if (c.argv.some((w) => w === '--help' || w === '--version')) return false;
      // `env | cut -d= -f1` and `env | grep -c AWS` cannot pass a value through.
      const next = commands.find((o) => o.depth === c.depth && c.pipeTo[0] === o.head);
      if (c.pipeTo.length > 0 && next && stripsValues(next.head ?? '', next.words)) return false;
      return true;
    }
    return false;
  });

  if (envDump) {
    return {
      rule: 'env-dump',
      message: `❌ BLOCKED: an unfiltered environment dump discloses every exported secret

  Tried:    ${envDump.raw.slice(0, 160)}
  Why:      this session's environment may hold AWS_SESSION_TOKEN, GITHUB_TOKEN,
            TF_TOKEN_* and more. A dump prints all of them at once.

  Instead:  echo "VAR: \${VAR:+set}"                       # one variable, no value
            env | cut -d= -f1                             # names only, never values
            env | grep -c AWS                             # a count, not the values

  No escape: there is always a targeted alternative to a full dump.`,
    };
  }

  // --- Rule 4: printing a credential file --------------------------------------------
  for (const cmd of commands) {
    if (marked) break;
    if (cmd.head === null) continue;
    const isPrinter = PRINTING_HEADS.has(cmd.head);
    const isSearch = CONTENT_SEARCH_HEADS.has(cmd.head);
    if (!isPrinter && !isSearch) continue;
    // A search invoked with a content-suppressing flag reports counts or filenames.
    if (isSearch && CONTENT_SUPPRESSING_FLAGS.test(cmd.words.join(' '))) continue;
    if (cmd.redirectsStdout) continue;
    // For a SEARCH the first non-flag word is the PATTERN, not a path, so it must not be
    // tested against the credential-file names: without this, `grep -rn credentials docs/`
    // is blocked for searching FOR the word.
    // argv is used (quote-stripped) so `cat .\env` and `cat "$X/.env"` read as `.env`. stdin
    // redirects (`cat < .env`, `< .env cat`) name the file just as an argument does.
    const words = [...(isSearch ? dropSearchPattern(cmd.argv) : cmd.argv), ...cmd.stdinFiles];
    const args = words.join(' ');
    const glob = words.some(globMatchesCredential);
    if (!CREDENTIAL_FILES.test(args) && !SNOWFLAKE_CREDENTIAL_FILES.test(args) &&
        !CREDENTIAL_FILE_PATHS.test(args) && !glob) continue;
    return {
      rule: 'credential-file-print',
      message: `❌ BLOCKED: \`${cmd.head}\` on a credential file exposes its contents

  Tried:    ${cmd.raw.slice(0, 160)}
  Why:      .env, ~/.terraformrc, ~/.aws/credentials, ~/.netrc, ~/.npmrc,
            ~/.docker/config.json, Snowflake's connections.toml and
            ~/.snowflake/config.toml, and *.p8 private keys exist to hold live
            credentials.

  Instead:  grep -c . .env                    # how many entries, no values
            cut -d= -f1 .env                  # key names only
            grep -q '^TF_TOKEN' ~/.terraformrc && echo present

${escapeLine(SECRET_PRINT_ALLOW_MARKER)}`,
    };
  }

  // --- Rule 5: openssl writing a private key to stdout ------------------------------
  for (const cmd of commands) {
    if (marked) break;
    if (!opensslPrintsPrivateKey(cmd)) continue;
    return {
      rule: 'private-key-print',
      message: `❌ BLOCKED: \`openssl\` would print a private key into the transcript

  Tried:    ${cmd.raw.slice(0, 160)}
  Why:      without -out, -pubout or -noout, openssl ${cmd.argv.find((w) => !w.startsWith('-')) ?? ''} writes the
            (decrypted) private key to stdout.

  Instead:  openssl pkey -in key.p8 -pubout             # the public half only
            openssl rsa -in key.p8 -check -noout        # validate without printing
            openssl pkey -in key.p8 -out new.pem        # write to a file

${escapeLine(SECRET_PRINT_ALLOW_MARKER)}`,
    };
  }

  return null;
}
