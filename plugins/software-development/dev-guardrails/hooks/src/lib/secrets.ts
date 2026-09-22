// Secret detection data — the single source of truth for the secret gates:
//   Gate A (pre-bash.ts)      blocks a command that would PRINT a secret
//   Gate C (pre-bash.ts)      blocks a secret heading OUT through a forge CLI
//
// Why the two pattern sets are separate, and must stay separate
// -------------------------------------------------------------
// TOKEN_PATTERNS are structurally unambiguous: a known vendor prefix plus a body of
// known shape. A hit is a credential with near-certainty, so these are safe to use on
// *any* surface, including blocking an outbound pull-request description.
//
// CONTENT_PATTERNS match the *shape of an assignment* — an identifier such as "password"
// followed by a separator and a quoted value. They are right for scanning file content
// and badly wrong anywhere else, because a command line or a code-review note
// legitimately contains that shape. Three cases, all ordinary work:
//
//   1. a psql/redis/mongo URI whose password comes from the environment
//   2. a sed expression that REMEDIATES a hardcoded credential by replacing it
//   3. a review note reporting "this credential is hardcoded at config.py:12"
//
// The second is a fix and the third is the reviewer doing its job. Firing on any of them
// would get the whole hook disabled — which would take the destructive-git guards down
// with it. So:
//
//   CONTENT_PATTERNS are for FILE CONTENT ONLY. Never wire them to Bash.
//
// Bare `sk-` is deliberately absent. Two letters plus a hyphen occurs in ordinary prose
// and in real filenames; the specific vendor forms below cover the actual credentials
// without that cost.

// Literal fragments are assembled at runtime so this file never contains a contiguous
// credential-shaped string. Secret scanners run over this repo, and the write-side gate
// blocks the Write outright — a security module that cannot be committed is not a
// security module. Do not "simplify" these into one literal.
const PEM_BEGIN = '-----BEGIN' + String.raw`\s+(?:[A-Z][A-Z ]*\s+)?PRIVATE KEY` + '-----';

/** Nothing matches unless preceded by a non-identifier character. */
const LEFT_EDGE = String.raw`(?<![A-Za-z0-9_-])`;

export interface SecretPattern {
  /** Short label used in the block message. */
  readonly name: string;
  readonly re: RegExp;
}

/**
 * High-confidence credentials: vendor prefix + fixed-shape body.
 * Safe on every surface — command text, tool output, outbound payloads, file content.
 */
export const TOKEN_PATTERNS: readonly SecretPattern[] = [
  { name: 'gitlab-pat', re: new RegExp(LEFT_EDGE + String.raw`glpat-[A-Za-z0-9_-]{20,}`, 'g') },
  { name: 'gitlab-runner-token', re: new RegExp(LEFT_EDGE + String.raw`glrt-[A-Za-z0-9_-]{20,}`, 'g') },
  { name: 'gitlab-deploy-token', re: new RegExp(LEFT_EDGE + String.raw`gldt-[A-Za-z0-9_-]{20,}`, 'g') },
  { name: 'aws-access-key-id', re: new RegExp(LEFT_EDGE + String.raw`(?:AKIA|ASIA)[0-9A-Z]{16}`, 'g') },
  { name: 'github-token', re: new RegExp(LEFT_EDGE + String.raw`gh[pousr]_[A-Za-z0-9]{36,}`, 'g') },
  { name: 'github-fine-grained-pat', re: new RegExp(LEFT_EDGE + String.raw`github_pat_[A-Za-z0-9_]{22,}`, 'g') },
  { name: 'slack-token', re: new RegExp(LEFT_EDGE + String.raw`xox[abposr]-[A-Za-z0-9-]{10,}`, 'g') },
  { name: 'slack-app-token', re: new RegExp(LEFT_EDGE + String.raw`xapp-[0-9]-[A-Za-z0-9-]{10,}`, 'g') },
  { name: 'digitalocean-token', re: new RegExp(LEFT_EDGE + String.raw`dop_v1_[a-f0-9]{64}`, 'g') },
  { name: 'anthropic-api-key', re: new RegExp(LEFT_EDGE + String.raw`sk-ant-(?:api|admin)[0-9]{2}-[A-Za-z0-9_-]{40,}`, 'g') },
  { name: 'openai-project-key', re: new RegExp(LEFT_EDGE + String.raw`sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}`, 'g') },
  { name: 'openai-api-key', re: new RegExp(LEFT_EDGE + String.raw`sk-[A-Za-z0-9]{48}`, 'g') },
  { name: 'google-api-key', re: new RegExp(LEFT_EDGE + String.raw`AIza[A-Za-z0-9_-]{35}`, 'g') },
  { name: 'private-key-block', re: new RegExp(PEM_BEGIN, 'g') },
];

/**
 * Assignment-shaped credential matches. FILE CONTENT ONLY — see the header comment.
 */
export const CONTENT_PATTERNS: readonly SecretPattern[] = [
  { name: 'hardcoded-password', re: /(password|passwd|pwd)\s*[:=]\s*['"][^'"]{4,}/gi },
  { name: 'hardcoded-api-key', re: /(api_key|apikey|api_secret)\s*[:=]\s*['"][^'"]{16,}/gi },
  { name: 'api-key-hex32', re: /api[_-]?key['"\s:=]+([a-f0-9]{32})(?![a-f0-9])/gi },
  { name: 'db-connection-string', re: /(?:postgres|mysql|mongodb(?:\+srv)?|redis):\/\/[^:\s]+:[^@\s]+@/gi },
  { name: 'jwt', re: /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g },
];

const PLACEHOLDER_WORDS = [
  'example', 'placeholder', 'redact', 'your', 'dummy', 'sample',
  'fake', 'test', 'xxx', 'todo', 'changeme', 'notreal', 'abcdef',
];

// ---------------------------------------------------------------------------
// Redaction — Gate B (post-bash.ts)
// ---------------------------------------------------------------------------
//
// The placeholder is assembled from pieces so that a redacted transcript fed back through this
// module cannot re-trigger on its own output, and so the marker itself never matches a pattern.
const REDACT_OPEN = '\u00ab' + 'redact' + 'ed:';
const REDACT_CLOSE = '\u00bb';

/** The placeholder that replaces a matched secret. */
export function redactionPlaceholder(patternName: string): string {
  return REDACT_OPEN + patternName + REDACT_CLOSE;
}

/** True when text already carries a redaction placeholder (idempotence guard). */
export function containsPlaceholder(text: string): boolean {
  return text.includes(REDACT_OPEN);
}

/**
 * True when a match is obviously documentation rather than a live credential.
 *
 * Rules files, docs, and these gates' own test fixtures all contain credential-shaped
 * strings on purpose. Suppressing them is what keeps the gates usable: without it, the
 * file documenting a gate cannot be committed.
 */
export function isObviousPlaceholder(match: string): boolean {
  const lower = match.toLowerCase();
  if (PLACEHOLDER_WORDS.some((w) => lower.includes(w))) return true;
  // AWS's own published example key id.
  if (lower.includes('akiaiosfodnn7')) return true;
  // A body of very low character variety is filler (xxxx…, 0000…, ababab…).
  const body = match.replace(/^[^-_]*[-_]/, '');
  const distinct = new Set(body.replace(/[^A-Za-z0-9]/g, '')).size;
  if (body.length >= 8 && distinct <= 4) return true;
  return false;
}

export interface SecretMatch {
  readonly patternName: string;
  readonly value: string;
  readonly index: number;
}

/** Every non-placeholder match of `patterns` in `text`, in order of appearance. */
export function findSecrets(
  text: string,
  patterns: readonly SecretPattern[] = TOKEN_PATTERNS,
): SecretMatch[] {
  if (!text) return [];
  const out: SecretMatch[] = [];
  for (const { name, re } of patterns) {
    // Patterns are module-level and carry /g, so lastIndex must not be shared.
    const flags = re.flags.includes('g') ? re.flags : re.flags + 'g';
    const rx = new RegExp(re.source, flags);
    let m: RegExpExecArray | null;
    while ((m = rx.exec(text)) !== null) {
      if (m[0].length === 0) break; // defensive: a zero-width match would spin forever
      if (!isObviousPlaceholder(m[0])) {
        out.push({ patternName: name, value: m[0], index: m.index });
      }
    }
  }
  return out.sort((a, b) => a.index - b.index);
}

/**
 * Replace every non-placeholder secret in `text`. Returns the rewritten text and what was hit.
 *
 * Longest match first, so a shorter overlapping match cannot corrupt a longer one mid-replace.
 */
export function redactSecrets(
  text: string,
  patterns: readonly SecretPattern[] = TOKEN_PATTERNS,
): { text: string; matches: SecretMatch[] } {
  const matches = findSecrets(text, patterns);
  if (matches.length === 0) return { text, matches };
  let out = text;
  const byLength = [...matches].sort((a, b) => b.value.length - a.value.length);
  for (const m of byLength) {
    out = out.split(m.value).join(redactionPlaceholder(m.patternName));
  }
  return { text: out, matches };
}

// ---------------------------------------------------------------------------
// Secret VARIABLE NAME matching — Gate A only
// ---------------------------------------------------------------------------
//
// Matching is case-insensitive, and that is the entire fix for the incident this module
// exists for. The leaked variable was TF_TOKEN_gitlab_com — a lowercase suffix on an
// uppercase prefix. A case-sensitive TF_TOKEN_* check misses it, and missing it is what
// put a live token into a transcript, into task-output files on disk, and into a rotation.

const SECRET_NAME_SUBSTRINGS = [
  'SECRET', 'TOKEN', 'PASSWORD', 'PASSWD', 'CREDENTIAL', 'PRIVATE_KEY',
  'API_KEY', 'APP_KEY', 'CLIENT_SECRET', 'ACCESS_KEY', 'SESSION_TOKEN',
];

// `PAT` must be preceded by `_`. A bare /PAT$/ matched any name ENDING in those three
// letters, so an ordinary loop variable named `pat` — and real words like COMPAT,
// INCOMPAT — blocked as credentials (observed live). A gate that fires on
// `for pat in …; do echo "$pat"` teaches users to reach for the allow-marker by reflex,
// which is how a false positive becomes a real leak. GITLAB_PAT / MY_PAT still match.
const SECRET_NAME_PATTERNS = [/_PAT$/, /^GLPAT/, /^TF_TOKEN_/];

// The one place case is load-bearing. A STANDALONE `PAT` is checked case-SENSITIVELY,
// because for this name the case is the only signal available and shell convention makes
// it a reliable one: `PAT=<token>` is an exported credential, `for pat in "${patterns[@]}"`
// is a loop variable. Everything else stays case-insensitive — the TF_TOKEN_gitlab_com
// incident proved a case-sensitive check on a PREFIX misses real secrets, and that lesson
// is not weakened here: this applies only to a name that is exactly the three letters.
const SECRET_NAME_EXACT_CASE_SENSITIVE = new Set(['PAT']);

const SECRET_NAME_EXACT = new Set([
  'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'DD_API_KEY', 'DD_APP_KEY',
  'GH_TOKEN', 'GITHUB_TOKEN', 'GL_TOKEN', 'GITLAB_TOKEN',
  'OP_SERVICE_ACCOUNT_TOKEN', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY',
]);

// Names that match a substring above but hold no secret. Every entry is a name that
// would otherwise make the gate fire on ordinary work.
//
// A suffix here must never equal one of SECRET_NAME_SUBSTRINGS — allowing `_TOKEN` would
// silently switch the gate off for most real secrets. assertAllowlistSafe() enforces
// that and a unit test calls it, so the invariant is asserted rather than reviewed.
const ALLOW_EXACT = new Set([
  'TOKEN_URL', 'TOKEN_ENDPOINT', 'TOKEN_PATH', 'TOKEN_TYPE', 'TOKEN_EXPIRY',
  'CSRF_TOKEN_HEADER', 'ACCESS_KEY_ID', 'AWS_ACCESS_KEY_ID',
  'SECRET_NAME', 'SECRET_ARN', 'SECRET_ID', 'SECRET_PATH', 'SECRETS_MANAGER_ARN',
  'API_KEY_HEADER', 'API_KEY_NAME', 'PASSWORD_FILE', 'CREDENTIAL_PROCESS',
  'CREDENTIALS_FILE', 'AWS_SHARED_CREDENTIALS_FILE', 'PRIVATE_KEY_PATH',
]);

const ALLOW_SUFFIXES = [
  '_NAME', '_ARN', '_ID', '_PATH', '_FILE', '_URL', '_ENDPOINT', '_HEADER',
  '_TYPE', '_EXPIRY',
];
const ALLOW_PREFIXES = ['NEXT_PUBLIC_', 'VITE_', 'PUBLIC_', 'REACT_APP_'];

/**
 * Guard against an allowlist entry that would disable the gate wholesale.
 * Exported so a unit test asserts the invariant instead of trusting review.
 */
export function assertAllowlistSafe(): void {
  for (const suffix of ALLOW_SUFFIXES) {
    const bare = suffix.replace(/^_/, '');
    for (const sub of SECRET_NAME_SUBSTRINGS) {
      if (bare === sub) {
        throw new Error(
          `allowlist suffix "${suffix}" cancels secret substring "${sub}" — it would ` +
            'switch the gate off for every variable ending in that word',
        );
      }
    }
  }
}

/**
 * True when `name` looks like it holds a credential. Case-insensitive by design, with one
 * documented exception: SECRET_NAME_EXACT_CASE_SENSITIVE (currently just `PAT`).
 */
export function isSecretVarName(name: string): boolean {
  if (!name) return false;
  const upper = name.toUpperCase();

  // Before the allowlist: an exact uppercase `PAT` is a credential regardless.
  if (SECRET_NAME_EXACT_CASE_SENSITIVE.has(name)) return true;

  if (ALLOW_EXACT.has(upper)) return false;
  if (ALLOW_PREFIXES.some((p) => upper.startsWith(p))) return false;
  if (ALLOW_SUFFIXES.some((s) => upper.endsWith(s))) return false;

  if (SECRET_NAME_EXACT.has(upper)) return true;
  if (SECRET_NAME_PATTERNS.some((re) => re.test(upper))) return true;
  if (SECRET_NAME_SUBSTRINGS.some((s) => upper.includes(s))) return true;

  return false;
}
