// A small, quote-aware scanner for Bash command lines.
//
// Gate A needs to answer one question precisely: "does an unsafe expansion of a
// secret-named variable reach a command that PRINTS?" Answering it with a bare regex
// over the whole line produces both failure modes at once — it fires on
// `export TF_TOKEN_gitlab_com="$X"` (an assignment, prints nothing) and misses
// `echo "$(printf %s "$SECRET")"` (nested, prints). Both are unacceptable: the first
// gets the hook switched off, the second is the leak.
//
// So this module segments a line into simple commands, resolves each one's head word,
// and tracks the three contexts that change the answer: pipelines, stdout redirection,
// and command substitution. It is deliberately not a full Bash grammar — it covers the
// constructs that actually appear in agent-issued commands, and errs toward reporting a
// command as printing when it cannot tell.

/** How a `${...}` / `$VAR` reference behaves when the variable IS set. */
export type ExpansionForm =
  | 'plain' // $VAR, ${VAR}                 -> the value
  | 'default' // ${VAR:-x}, ${VAR-x}        -> the value  (THE INCIDENT)
  | 'assign' // ${VAR:=x}                   -> the value
  | 'error' // ${VAR:?msg}                  -> the value
  | 'alt' // ${VAR:+x}, ${VAR+x}            -> x, never the value      SAFE
  | 'length' // ${#VAR}                     -> a number                SAFE
  | 'substring' // ${VAR:off:len}           -> a slice   SAFE only at the head, short
  | 'transform' // ${VAR#p} ${VAR^^} ${VAR@Q} -> a derived value; may be the whole value
  | 'indirect'; // ${!REF}, ${!PRE*}        -> the value of a NAMED variable

export interface Expansion {
  readonly raw: string;
  /** The variable name referenced. For `indirect`, the name of the *pointer*. */
  readonly name: string;
  readonly form: ExpansionForm;
  readonly safe: boolean;
  readonly index: number;
}

/**
 * A prefix slice is safe enough to identify a key type without disclosing it — four
 * characters tells you "this is a glpat- token", eight does not meaningfully help an
 * attacker. Beyond that it is disclosure.
 */
const MAX_SAFE_SUBSTRING_LEN = 8;

function classifyBraced(inner: string): { name: string; form: ExpansionForm } {
  // ${#VAR} — length. ${#} / ${#*} / ${#@} are argument counts, not a variable.
  if (inner.startsWith('#')) {
    return { name: inner.slice(1), form: 'length' };
  }
  // ${!REF} — indirect. Also ${!PREFIX*} / ${!PREFIX@} (name listing) and ${!ARR[@]}.
  if (inner.startsWith('!')) {
    return { name: inner.slice(1).replace(/[*@[\]]/g, ''), form: 'indirect' };
  }

  const opMatch = inner.match(/^([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?)(.*)$/s);
  if (!opMatch) return { name: inner, form: 'plain' };

  const name = opMatch[1].replace(/\[[^\]]*\]/, '');
  const rest = opMatch[2];

  if (rest === '') return { name, form: 'plain' };
  if (rest.startsWith(':+') || rest.startsWith('+')) return { name, form: 'alt' };
  if (rest.startsWith(':-') || rest.startsWith('-')) return { name, form: 'default' };
  if (rest.startsWith(':=') || rest.startsWith('=')) return { name, form: 'assign' };
  if (rest.startsWith(':?') || rest.startsWith('?')) return { name, form: 'error' };
  // ${VAR:off} / ${VAR:off:len} — a leading ':' not followed by an operator char.
  if (/^:\s*-?\d/.test(rest) || /^:[^-+=?]/.test(rest)) return { name, form: 'substring' };
  // ${VAR#p} ${VAR##p} ${VAR%s} ${VAR/a/b} ${VAR^^} ${VAR,,} ${VAR@Q} ${VAR:offset}
  return { name, form: 'transform' };
}

function substringIsSafe(inner: string): boolean {
  // Expect ${NAME:offset} or ${NAME:offset:length}.
  const m = inner.match(/^[A-Za-z_][A-Za-z0-9_]*:\s*(-?\d+)\s*(?::\s*(-?\d+)\s*)?$/);
  if (!m) return false; // arithmetic or a variable bound — cannot prove it is short
  const offset = Number(m[1]);
  if (offset !== 0) return false; // a tail slice can be the entire secret
  if (m[2] === undefined) return false; // ${VAR:0} is the whole value
  const length = Number(m[2]);
  return length > 0 && length <= MAX_SAFE_SUBSTRING_LEN;
}

/**
 * Every parameter expansion in `text`, classified.
 *
 * `safe` is the load-bearing field. The truth table it encodes, for VAR set to a secret:
 *
 *   $VAR ${VAR}      -> the secret        UNSAFE
 *   ${VAR:-fallback} -> the secret        UNSAFE  <- the incident
 *   ${VAR-fallback}  -> the secret        UNSAFE
 *   ${VAR:=fallback} -> the secret        UNSAFE
 *   ${VAR:?message}  -> the secret        UNSAFE
 *   ${VAR:+literal}  -> "literal"         SAFE
 *   ${VAR+literal}   -> "literal"         SAFE
 *   ${#VAR}          -> a length          SAFE
 *   ${VAR:0:4}       -> a 4-char prefix   SAFE  (offset 0, length <= 8)
 *   ${VAR:8:4}       -> mid-secret slice  UNSAFE
 *   ${VAR#x} ${VAR^^} ${VAR@Q}            UNSAFE (can yield the whole value)
 *   ${!POINTER}      -> the secret        UNSAFE, and the allowlist does NOT apply:
 *                                         the pointer's own name says nothing about
 *                                         what it points at, so `${!CFG_NAME}` must be
 *                                         treated as a secret reference regardless.
 */
export function classifyExpansions(text: string): Expansion[] {
  const out: Expansion[] = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== '$') continue;
    // A literal `\$` is not an expansion.
    if (i > 0 && text[i - 1] === '\\') continue;

    if (text[i + 1] === '{') {
      // Find the matching brace, tolerating one level of nesting (${VAR:-${OTHER}}).
      let depth = 1;
      let j = i + 2;
      for (; j < text.length && depth > 0; j++) {
        if (text[j] === '{') depth++;
        else if (text[j] === '}') depth--;
      }
      if (depth !== 0) continue; // unterminated — nothing reliable to say
      const inner = text.slice(i + 2, j - 1);
      const { name, form } = classifyBraced(inner);
      const safe =
        form === 'alt' ||
        form === 'length' ||
        (form === 'substring' && substringIsSafe(inner));
      out.push({ raw: text.slice(i, j), name, form, safe, index: i });
      i = j - 1;
      continue;
    }

    const bare = text.slice(i + 1).match(/^[A-Za-z_][A-Za-z0-9_]*/);
    if (bare) {
      out.push({
        raw: '$' + bare[0],
        name: bare[0],
        form: 'plain',
        safe: false,
        index: i,
      });
      i += bare[0].length;
    }
  }
  return out;
}

/**
 * Drop an unquoted `#` comment. Only a `#` that starts a word is a comment, so
 * `curl host/#anchor` and `echo "a # b"` survive intact.
 */
export function stripUnquotedComment(line: string): string {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '\\' && !inSingle) {
      i++;
      continue;
    }
    if (c === "'" && !inDouble) inSingle = !inSingle;
    else if (c === '"' && !inSingle) inDouble = !inDouble;
    else if (c === '#' && !inSingle && !inDouble) {
      const prev = i === 0 ? ' ' : line[i - 1];
      if (/\s/.test(prev) || i === 0) return line.slice(0, i);
    }
  }
  return line;
}

export interface Heredoc {
  readonly delimiter: string;
  /** A quoted delimiter (<<'EOF') disables expansion inside the body. */
  readonly quoted: boolean;
  readonly body: string;
}

/**
 * Pull heredoc bodies out of a command so the tokenizer sees only real syntax.
 * Returns the command with bodies removed plus the bodies themselves.
 */
export function extractHeredocs(command: string): { command: string; heredocs: Heredoc[] } {
  const heredocs: Heredoc[] = [];
  const lines = command.split('\n');
  const kept: string[] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    kept.push(line);
    // Collect every heredoc opened on this line, in order.
    const opens = [...line.matchAll(/<<-?\s*(?:'([^']+)'|"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))/g)];
    for (const open of opens) {
      const quoted = open[1] !== undefined || open[2] !== undefined;
      const delimiter = open[1] ?? open[2] ?? open[3];
      const body: string[] = [];
      i++;
      while (i < lines.length && lines[i].trim() !== delimiter) {
        body.push(lines[i]);
        i++;
      }
      heredocs.push({ delimiter, quoted, body: body.join('\n') });
    }
  }

  return { command: kept.join('\n'), heredocs };
}

/**
 * Is `marker` present as a REAL unquoted trailing comment on the command line?
 *
 * The escape markers are documented as trailing comments. Detecting one with a bare
 * `command.includes(MARKER)` against the RAW command is wrong in two ways, and both were
 * observed in practice:
 *
 *   - A HEREDOC BODY that merely *documents* the marker acted as an override.
 *     `git commit -F - <<'EOF'` is the normal way to write a multi-line message, and a
 *     message that quotes this plugin's own documentation would open the gate.
 *   - A QUOTED span containing the marker did the same, so
 *     `--body "... # claude-allow"` opened the gate.
 *
 * "The marker string is long, so prose will not hit it by accident" is mitigation by
 * obscurity, and it stops working the moment the marker is documented anywhere.
 *
 * Fail direction: these markers ALLOW, so the safe failure is to find no marker. Every
 * failure path here returns false, which denies the exemption and leaves the block in place.
 */
export function hasAllowMarker(command: string, marker: string): boolean {
  let scanned: string;
  try {
    scanned = extractHeredocs(command).command;
  } catch {
    return false; // cannot sanitize -> refuse the exemption
  }
  return scanned.split('\n').some((line) => {
    // stripUnquotedComment returns the line up to a real (unquoted, word-starting) `#`, so
    // whatever follows IS the comment. A marker inside quotes leaves no comment to match.
    const comment = line.slice(stripUnquotedComment(line).length);
    return comment.includes(marker);
  });
}

export interface SimpleCommand {
  readonly raw: string;
  /** Resolved, basename-normalized head word. `null` when it cannot be determined. */
  readonly head: string | null;
  /**
   * The head word exactly as written, before quote-stripping and basename normalization,
   * and AFTER assignment prefixes are skipped. Callers checking for an expansion in head
   * position must use this: `raw.split(/\s+/)[0]` would see `FOO="$SECRET"` in
   * `FOO="$SECRET" make deploy` and mistake an assignment for an executed command.
   */
  readonly headRaw: string | null;
  /** Words after the head, still quoted as written. */
  readonly words: string[];
  /** Heads of commands downstream of this one in the same pipeline. */
  readonly pipeTo: string[];
  /** `>` or `>>` sends this command's stdout to a file. */
  readonly redirectsStdout: boolean;
  /** This command sits inside a substitution whose value is assigned to a variable. */
  readonly captured: boolean;
  /** 0 at top level; >0 inside `$( )` or backticks. */
  readonly depth: number;
}

/** Wrappers that delegate to the next word; the real head is behind them. */
const PASSTHROUGH_HEADS = new Set([
  'env', 'sudo', 'command', 'nohup', 'nice', 'exec', 'stdbuf', 'time', 'timeout',
  'xargs', 'builtin', 'eval',
]);

function splitWords(segment: string): string[] {
  const words: string[] = [];
  let cur = '';
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < segment.length; i++) {
    const c = segment[i];
    if (c === '\\' && !inSingle) {
      cur += c + (segment[i + 1] ?? '');
      i++;
      continue;
    }
    if (c === "'" && !inDouble) {
      inSingle = !inSingle;
      cur += c;
      continue;
    }
    if (c === '"' && !inSingle) {
      inDouble = !inDouble;
      cur += c;
      continue;
    }
    if (/\s/.test(c) && !inSingle && !inDouble) {
      if (cur) words.push(cur);
      cur = '';
      continue;
    }
    cur += c;
  }
  if (cur) words.push(cur);
  return words;
}

/** Resolve the effective head word: skip assignments and wrappers, then basename it. */
function resolveHead(words: string[]): { head: string | null; headRaw: string | null; rest: string[] } {
  let idx = 0;
  while (idx < words.length) {
    const w = words[idx];
    // Leading VAR=value assignment prefixes.
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) {
      idx++;
      continue;
    }
    // Redirections that appear before the command word.
    if (/^\d*[<>]/.test(w)) {
      idx += w.length > 1 && /[<>]$/.test(w) ? 2 : 1;
      continue;
    }
    break;
  }
  if (idx >= words.length) return { head: null, headRaw: null, rest: [] };

  const headRaw = words[idx];
  let head = headRaw.replace(/^['"]|['"]$/g, '');
  head = head.split('/').pop() ?? head;

  if (PASSTHROUGH_HEADS.has(head)) {
    // `timeout 30 cmd` / `stdbuf -o0 cmd` — step over the wrapper's own options/args.
    let k = idx + 1;
    while (k < words.length && (/^-/.test(words[k]) || /^\d+[a-z]?$/.test(words[k]))) k++;
    if (k < words.length) {
      const inner = resolveHead(words.slice(k));
      if (inner.head) return inner;
    }
  }

  return { head, headRaw, rest: words.slice(idx + 1) };
}

const SEPARATORS = [';;', '&&', '||', '|&', ';', '|', '\n', '&'];

/**
 * Segment a command line into simple commands.
 *
 * Command substitutions are parsed recursively and reported alongside the outer
 * commands, so `echo "$(op read op://v/i/f)"` yields both the `echo` and the `op`.
 */
export function parseCommand(command: string): SimpleCommand[] {
  const { command: stripped } = extractHeredocs(command);
  const out: SimpleCommand[] = [];

  // A pipeline group accumulates so each member can learn its downstream heads.
  interface Raw {
    text: string;
    sepBefore: string;
    depth: number;
    captured: boolean;
  }
  const raws: Raw[] = [];

  function scan(text: string, depth: number, captured: boolean): void {
    let cur = '';
    let sepBefore = '';
    let inSingle = false;
    let inDouble = false;

    const flush = (sep: string) => {
      if (cur.trim()) raws.push({ text: cur, sepBefore, depth, captured });
      cur = '';
      sepBefore = sep;
    };

    for (let i = 0; i < text.length; i++) {
      const c = text[i];

      if (c === '\\' && !inSingle) {
        cur += c + (text[i + 1] ?? '');
        i++;
        continue;
      }
      if (c === "'" && !inDouble) {
        inSingle = !inSingle;
        cur += c;
        continue;
      }
      if (c === '"' && !inSingle) {
        inDouble = !inDouble;
        cur += c;
        continue;
      }
      if (inSingle) {
        cur += c;
        continue;
      }

      // Command substitution: $( ... ) — recurse, and remember whether it is assigned.
      if (c === '$' && text[i + 1] === '(' && text[i + 2] !== '(') {
        let d = 1;
        let j = i + 2;
        for (; j < text.length && d > 0; j++) {
          if (text[j] === '(') d++;
          else if (text[j] === ')') d--;
        }
        const innerText = text.slice(i + 2, j - 1);
        // `VAR=$(...)` or `VAR="$(...)"` captures the value rather than printing it.
        const before = cur.replace(/"$/, '');
        const isAssigned = /(^|\s)[A-Za-z_][A-Za-z0-9_]*=$/.test(before);
        scan(innerText, depth + 1, isAssigned);
        cur += text.slice(i, j);
        i = j - 1;
        continue;
      }

      // Backtick substitution.
      if (c === '`') {
        const end = text.indexOf('`', i + 1);
        if (end > i) {
          const before = cur.replace(/"$/, '');
          const isAssigned = /(^|\s)[A-Za-z_][A-Za-z0-9_]*=$/.test(before);
          scan(text.slice(i + 1, end), depth + 1, isAssigned);
          cur += text.slice(i, end + 1);
          i = end;
          continue;
        }
      }

      if (!inDouble) {
        const sep = SEPARATORS.find((s) => text.startsWith(s, i));
        if (sep) {
          flush(sep);
          i += sep.length - 1;
          continue;
        }
      }

      cur += c;
    }
    flush('');
  }

  scan(stripped, 0, false);

  for (let i = 0; i < raws.length; i++) {
    const raw = raws[i];
    const cleaned = stripUnquotedComment(raw.text);
    const words = splitWords(cleaned.trim());
    const { head, headRaw, rest } = resolveHead(words);

    // Downstream pipeline members: consecutive following segments joined by `|`.
    const pipeTo: string[] = [];
    for (let k = i + 1; k < raws.length; k++) {
      if (raws[k].sepBefore !== '|' || raws[k].depth !== raw.depth) break;
      const h = resolveHead(splitWords(stripUnquotedComment(raws[k].text).trim())).head;
      if (h) pipeTo.push(h);
    }

    out.push({
      raw: raw.text.trim(),
      head,
      headRaw,
      words: rest,
      pipeTo,
      redirectsStdout: /(?:^|[^0-9<>&])>>?\s*[^&\s|]/.test(cleaned),
      captured: raw.captured,
      depth: raw.depth,
    });
  }

  return out;
}
