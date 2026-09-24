// A small, quote-aware scanner for Bash command lines.
//
// Every pre-bash gate asks a question about the SIMPLE COMMANDS a line will run: "is any
// of them `git push` with a force flag?", "does an unsafe expansion of a secret reach a
// command that prints?". Answering with a regex over the whole line fails both ways at
// once. It misses `git -C repo push --force`, `sudo rm -rf`, `bash -c '…'` and a second
// command on the next line, and it fires on `echo "git push --force"` and on a `-f` that
// belongs to a different command. A missed command is a bypass. A false block gets the
// hook switched off, which takes every other guard with it.
//
// So this module splits a line into simple commands and resolves each one's real head word
// (skipping assignments, redirections, keywords and wrappers such as `sudo`/`env`/`xargs`).
// It also recurses into the places a command can hide:
//   - `$( … )` and backticks
//   - `bash -c '…'`, `sh -c`, `su -c`, `eval '…'`
//   - a script fed to a shell on stdin (`bash <<EOF`, `echo '…' | sh`)
//   - `find -exec … ;`
//   - `alias name='…'`
// It is deliberately not a full Bash grammar. It covers the constructs agent-issued
// commands actually use. When it cannot tell, it reports the command rather than hiding it.

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

  const name = opMatch[1]!.replace(/\[[^\]]*\]/, '');
  const rest = opMatch[2]!;

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
 * `text` with every span Bash does NOT expand blanked out: single-quoted strings and ANSI-C
 * `$'…'` strings. What remains is where a `$VAR` really is an expansion.
 *
 * Without this, `echo 'Export $GITHUB_TOKEN first'` read as printing the token, though the
 * shell prints those characters literally. A single quote inside double quotes is an ordinary
 * character, so double-quote state is tracked too.
 */
export function expandableText(text: string): string {
  let out = '';
  let inDouble = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (c === '\\') { out += c + (text[i + 1] ?? ''); i++; continue; }
    if (c === '"') { inDouble = !inDouble; out += c; continue; }
    if (!inDouble && (c === "'" || (c === '$' && text[i + 1] === "'"))) {
      // Skip to the closing quote. In $'…' a backslash escapes the next character.
      const ansi = c === '$';
      let j = ansi ? i + 2 : i + 1;
      for (; j < text.length && text[j] !== "'"; j++) if (ansi && text[j] === '\\') j++;
      out += ' ';
      i = j;
      continue;
    }
    out += c;
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
      const prev = i === 0 ? ' ' : line[i - 1]!;
      if (/\s/.test(prev) || i === 0) return line.slice(0, i);
    }
  }
  return line;
}

/**
 * Blank the spans of `text` that perform NO parameter expansion — single-quoted `'…'` and
 * ANSI-C `$'…'` — leaving everything else (including double-quoted spans) in place. The
 * removed characters become spaces so indices and word boundaries are preserved.
 *
 * Expansion analysis runs on the result, so `echo 'Export $GITHUB_TOKEN now'` is seen to
 * contain no expansion — the `$GITHUB_TOKEN` is literal text bash never expands — while
 * `echo "$GITHUB_TOKEN"` still shows the reference.
 */
export function blankUnexpanded(text: string): string {
  let out = '';
  let inDouble = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (c === '\\' && !inDouble) { out += c + (text[i + 1] ?? ''); i++; continue; }
    if (inDouble) { if (c === '"') inDouble = false; out += c; continue; }
    if (c === '"') { inDouble = true; out += c; continue; }
    if (c === '$' && text[i + 1] === "'") {
      out += '  ';
      let j = i + 2;
      for (; j < text.length && text[j] !== "'"; j++) { if (text[j] === '\\') { out += ' '; j++; } out += ' '; }
      out += ' ';
      i = j;
      continue;
    }
    if (c === "'") {
      out += ' ';
      let j = i + 1;
      for (; j < text.length && text[j] !== "'"; j++) out += ' ';
      out += ' ';
      i = j;
      continue;
    }
    out += c;
  }
  return out;
}

/**
 * Shell quote removal for ONE word: strip quotes and process backslash escapes, as Bash
 * does before handing the word to the program. Expansions (`$VAR`, `$(…)`) are left as
 * literal text, because their values are unknown here.
 */
export function unquote(word: string): string {
  let out = '';
  for (let i = 0; i < word.length; i++) {
    const c = word[i]!;
    if (c === '\\') {
      if (word[i + 1] === '\n') { i++; continue; } // line continuation
      if (i + 1 < word.length) out += word[++i];
      continue;
    }
    if (c === "'") {
      const end = word.indexOf("'", i + 1);
      if (end < 0) { out += word.slice(i + 1); break; }
      out += word.slice(i + 1, end);
      i = end;
      continue;
    }
    if (c === '$' && word[i + 1] === "'") {
      // ANSI-C quoting: $'…' with the common escapes.
      let j = i + 2;
      for (; j < word.length && word[j] !== "'"; j++) {
        if (word[j] === '\\' && j + 1 < word.length) {
          const e = word[++j]!;
          out += e === 'n' ? '\n' : e === 't' ? '\t' : e;
        } else {
          out += word[j];
        }
      }
      i = j;
      continue;
    }
    if (c === '"') {
      let j = i + 1;
      for (; j < word.length && word[j] !== '"'; j++) {
        // Inside double quotes a backslash only escapes $ ` " \ and newline.
        if (word[j] === '\\' && j + 1 < word.length && '$`"\\\n'.includes(word[j + 1]!)) {
          j++;
          if (word[j] !== '\n') out += word[j];
          continue;
        }
        out += word[j];
      }
      i = j;
      continue;
    }
    out += c;
  }
  return out;
}

/**
 * Comma brace expansion for ONE word, still quoted as written: `{-f,origin}` → `-f`, `origin`
 * and `push{,-mirror}` → `push`, `push-mirror`. Bash does this before the program sees argv,
 * so `git push {-f,origin} x` really does run a force push; a gate reading the literal word
 * `{-f,origin}` would miss it.
 *
 * Deliberately narrow: only unquoted top-level `{…,…}` groups with a literal comma expand.
 * Numeric/alpha ranges (`{1..9}`) are left alone — they are not how a flag gets hidden — and a
 * word with no expandable group comes back unchanged, so the common case pays almost nothing.
 * The result is capped so a pathological `{a,b}{c,d}…` cannot blow up.
 */
export function expandBraces(word: string): string[] {
  if (!word.includes('{') || !word.includes(',')) return [word];
  const group = findBraceGroup(word);
  if (!group) return [word];
  const prefix = word.slice(0, group.start);
  const suffix = word.slice(group.end + 1);
  const out: string[] = [];
  for (const alt of group.alternatives) {
    for (const tail of expandBraces(suffix)) {
      out.push(prefix + alt + tail);
      if (out.length > 64) return out; // guard against combinatorial blow-up
    }
  }
  return out;
}

/** Find the first unquoted, comma-bearing `{…}` group at the top level of `word`. */
function findBraceGroup(word: string): { start: number; end: number; alternatives: string[] } | null {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < word.length; i++) {
    const c = word[i]!;
    if (c === '\\') { i++; continue; }
    if (c === "'" && !inDouble) { inSingle = !inSingle; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; continue; }
    if (inSingle || inDouble) continue;
    if (c !== '{') continue;
    // Collect the comma-separated top-level members up to the matching `}`.
    const alternatives: string[] = [];
    let cur = '';
    let depth = 1;
    let hasComma = false;
    let j = i + 1;
    for (; j < word.length && depth > 0; j++) {
      const d = word[j]!;
      if (d === '\\') { cur += d + (word[j + 1] ?? ''); j++; continue; }
      if (d === '{') { depth++; cur += d; continue; }
      if (d === '}') { depth--; if (depth === 0) break; cur += d; continue; }
      if (d === ',' && depth === 1) { alternatives.push(cur); cur = ''; hasComma = true; continue; }
      cur += d;
    }
    if (depth === 0 && hasComma) {
      alternatives.push(cur);
      return { start: i, end: j, alternatives };
    }
  }
  return null;
}

/** Quote a literal so it survives one round of shell parsing unchanged. */
export function shellQuote(word: string): string {
  if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(word)) return word;
  return `'${word.replace(/'/g, `'\\''`)}'`;
}

export interface Heredoc {
  readonly delimiter: string;
  /** A quoted delimiter (<<'EOF') disables expansion inside the body. */
  readonly quoted: boolean;
  readonly body: string;
}

/**
 * Pull heredoc bodies out of a command so the tokenizer sees only real syntax.
 * Returns the command with bodies (and terminator lines) removed, plus the bodies.
 *
 * Quote-aware on purpose. A `<<` inside a quoted string is text, not an operator:
 * `git commit -m "use a << b"` followed by a second line must not have that second line
 * swallowed as a heredoc body, or whatever it runs is invisible to every gate. A `<<`
 * inside `$( … )` IS an operator even when the substitution is itself in double quotes,
 * which is the normal `-m "$(cat <<'EOF' … EOF)"` commit form. So quoting is tracked as a
 * stack: a substitution opens a fresh unquoted context.
 */
export function extractHeredocs(command: string): { command: string; heredocs: Heredoc[] } {
  const heredocs: Heredoc[] = [];
  const lines = command.split('\n');
  const kept: string[] = [];
  // Context stack. 'c' = code (top level or inside $( ) / backticks), 's' = single quotes,
  // 'd' = double quotes. `$(` and backticks push a fresh 'c'.
  const stack: Array<'c' | 's' | 'd' | 'b'> = ['c'];

  for (let li = 0; li < lines.length; li++) {
    const line = lines[li]!;
    kept.push(line);
    const pending: Array<{ delimiter: string; quoted: boolean }> = [];
    for (let i = 0; i < line.length; i++) {
      const c = line[i]!;
      const top = stack[stack.length - 1]!;
      if (top === 's') {
        if (c === "'") stack.pop();
        continue;
      }
      if (c === '\\') { i++; continue; }
      if (top === 'd') {
        if (c === '"') stack.pop();
        else if (c === '$' && line[i + 1] === '(') { stack.push('c'); i++; }
        else if (c === '`') stack.push('b');
        continue;
      }
      // Code context ('c' or 'b').
      if (c === '#' && (i === 0 || /\s/.test(line[i - 1]!))) break; // comment to end of line
      if (c === "'") { stack.push('s'); continue; }
      if (c === '"') { stack.push('d'); continue; }
      if (c === '`') {
        if (top === 'b') stack.pop();
        else stack.push('b');
        continue;
      }
      if (c === '$' && line[i + 1] === '(') { stack.push('c'); i++; continue; }
      if (c === ')' && stack.length > 1 && top === 'c') { stack.pop(); continue; }
      if (c === '<' && line[i + 1] === '<' && line[i + 2] !== '<' && line[i - 1] !== '<') {
        const m = line.slice(i + 2).match(/^-?\s*(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))/);
        if (m) {
          pending.push({
            delimiter: (m[1] ?? m[2] ?? m[3])!,
            quoted: m[1] !== undefined || m[2] !== undefined || m[0].includes('\\'),
          });
          i += 1 + m[0].length;
        }
      }
    }
    // Bodies start on the line after the opener, in the order the openers appeared.
    for (const p of pending) {
      const body: string[] = [];
      li++;
      while (li < lines.length && lines[li]!.replace(/^\t+/, '').trimEnd() !== p.delimiter) {
        body.push(lines[li]!);
        li++;
      }
      heredocs.push({ delimiter: p.delimiter, quoted: p.quoted, body: body.join('\n') });
    }
  }

  return { command: kept.join('\n'), heredocs };
}

/**
 * The real (unquoted) trailing comment on the LAST non-empty line of `command`, or null.
 *
 * Quote state is carried ACROSS newlines. A per-line scan resets it at every newline, so the
 * second line of `-m 'feat: x\n# claude-allow'` looked like an unquoted comment and a commit
 * message could waive a force push on the same command line.
 *
 * Returns null when the command ends inside an open quote: nothing about it can be trusted.
 */
export function trailingComment(command: string): string | null {
  let inSingle = false;
  let inDouble = false;
  let inAnsi = false; // $'…'
  let commentStart = -1;
  let lineStart = 0;
  let lastLine: { start: number; end: number; comment: number } | null = null;

  const endLine = (end: number): void => {
    if (command.slice(lineStart, end).trim() !== '') lastLine = { start: lineStart, end, comment: commentStart };
    lineStart = end + 1;
    commentStart = -1;
  };

  for (let i = 0; i < command.length; i++) {
    const c = command[i]!;
    if (c === '\n' && !inSingle && !inDouble && !inAnsi) { endLine(i); continue; }
    if (commentStart >= 0) continue; // inside a comment, quotes mean nothing
    if (inSingle) { if (c === "'") inSingle = false; continue; }
    if (inAnsi) {
      if (c === '\\') i++;
      else if (c === "'") inAnsi = false;
      continue;
    }
    if (c === '\\') { i++; continue; }
    if (inDouble) { if (c === '"') inDouble = false; continue; }
    if (c === "'") { inSingle = true; continue; }
    if (c === '"') { inDouble = true; continue; }
    if (c === '$' && command[i + 1] === "'") { inAnsi = true; i++; continue; }
    if (c === '#' && (i === lineStart || /\s/.test(command[i - 1]!))) commentStart = i;
  }
  if (inSingle || inDouble || inAnsi) return null;
  endLine(command.length);

  const line = lastLine as { start: number; end: number; comment: number } | null;
  if (!line || line.comment < 0) return null;
  return command.slice(line.comment, line.end).trim();
}

/**
 * Is `marker` the REAL trailing comment that ends the command?
 *
 * The escape markers are documented as a trailing comment on the command. Three looser
 * readings were each observed opening a gate:
 *
 *   - A HEREDOC BODY that merely *documents* the marker. `git commit -F - <<'EOF'` is the
 *     normal way to write a multi-line message, and a message quoting this plugin's own
 *     documentation opened the gate. Bodies are stripped before the scan.
 *   - A QUOTED span, including one that spans lines: `--body "…\n# claude-allow"`.
 *     trailingComment carries quote state across newlines.
 *   - A marker on ANY line waiving the whole command, and a marker matched as a substring,
 *     so `# claude-allow-force-push-x` counted. Only the last non-empty line counts, and the
 *     comment must be exactly the marker.
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
  const comment = trailingComment(scanned);
  if (comment === null) return false;
  // `#claude-allow` and `#  claude-allow` are the same marker; anything else is not.
  return comment.replace(/^#\s*/, '# ') === marker;
}

export interface SimpleCommand {
  readonly raw: string;
  /** Resolved, unquoted, basename-normalized head word. `null` when there is none. */
  readonly head: string | null;
  /**
   * The head word exactly as written, before quote-stripping and basename normalization,
   * and AFTER assignment prefixes are skipped. Callers checking for an expansion in head
   * position must use this: `raw.split(/\s+/)[0]` would see `FOO="$SECRET"` in
   * `FOO="$SECRET" make deploy` and mistake an assignment for an executed command.
   */
  readonly headRaw: string | null;
  /** Words after the head, still quoted as written. Redirections are removed. */
  readonly words: string[];
  /** `words` after shell quote removal — what the program receives as argv[1..]. */
  readonly argv: string[];
  /** Heads of commands downstream of this one in the same pipeline. */
  readonly pipeTo: string[];
  /** stdout goes to a FILE. `/dev/stdout`, `/dev/stderr` and `/dev/tty` do not count. */
  readonly redirectsStdout: boolean;
  /** This command sits inside a substitution whose value is assigned to a variable. */
  readonly captured: boolean;
  /**
   * For a command inside `$( )` or backticks: the head of the command that receives the
   * substituted text as an ARGUMENT. `null` at top level, and `null` when the substitution
   * is itself in head position (its output is then executed, and echoed on failure).
   */
  readonly substitutedInto: string | null;
  /** 0 at top level; >0 inside `$( )` or backticks. */
  readonly depth: number;
  /**
   * `cd`/`pushd` targets that run before this command in the same sequence, unquoted, in
   * order. Resolve them against the hook's `cwd` to find the directory the command runs in.
   */
  readonly cdArgs: readonly string[];
  /** Text fed to this command on stdin by a heredoc or here-string, when there is one. */
  readonly stdin: string | null;
  /**
   * Here-string operands (`<<< word`) exactly as written, quotes included. `stdin` has had
   * quote removal applied, which erases the difference between `<<< '$X'` (literal) and
   * `<<< "$X"` (the value); a check for expansions needs the raw form.
   */
  readonly hereStrings: readonly string[];
  /** Files redirected into stdin (`< file`), unquoted. */
  readonly stdinFiles: readonly string[];
  /** How this command was reached when it is nested inside another: e.g. `bash -c`. */
  readonly via: string | null;
  /**
   * Leading `NAME=value` assignment prefixes, unquoted, in order. `GIT_CONFIG_KEY_0=alias.p
   * GIT_CONFIG_VALUE_0='push -f' git p` carries an alias definition here, so a git gate that
   * ignored these would miss a force push defined entirely in the environment.
   */
  readonly assignments: readonly string[];
}

/** Leading `NAME=value` words before the head, unquoted. */
function leadingAssignments(words: readonly string[]): string[] {
  const out: string[] = [];
  for (const w of words) {
    if (LEADING_KEYWORDS.has(w)) continue;
    if (/^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/.test(w)) { out.push(unquote(w)); continue; }
    break;
  }
  return out;
}

// --- tokenizing one simple command ------------------------------------------------------

interface Redirect {
  readonly fd: string; // '' (default), a digit, or '&' for &> / &>>
  readonly op: string; // >, >>, >|, >&, <, <<, <<<, <&, <>
  readonly target: string; // as written
}

interface Tokens {
  readonly words: string[];
  readonly redirects: Redirect[];
}

/**
 * Split a simple command into words and redirections, respecting quotes. Redirection
 * operators are recognised wherever they appear, including glued to a word (`echo x>f`).
 */
function tokenize(segment: string): Tokens {
  const words: string[] = [];
  const redirects: Redirect[] = [];
  let cur = '';
  let inSingle = false;
  let inDouble = false;
  let pendingRedirect: { fd: string; op: string } | null = null;

  const push = (): void => {
    if (!cur) return;
    if (pendingRedirect) {
      redirects.push({ ...pendingRedirect, target: cur });
      pendingRedirect = null;
    } else {
      words.push(cur);
    }
    cur = '';
  };

  for (let i = 0; i < segment.length; i++) {
    const c = segment[i]!;
    if (c === '\\' && !inSingle) {
      if (segment[i + 1] === '\n') { i++; continue; } // line continuation joins words
      cur += c + (segment[i + 1] ?? '');
      i++;
      continue;
    }
    if (c === "'" && !inDouble) { inSingle = !inSingle; cur += c; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; cur += c; continue; }
    if (inSingle || inDouble) { cur += c; continue; }

    if (c === '$' && segment[i + 1] === '(') {
      // Keep a substitution in one word even when it contains spaces or operators.
      let d = 1;
      let j = i + 2;
      for (; j < segment.length && d > 0; j++) {
        if (segment[j] === '(') d++;
        else if (segment[j] === ')') d--;
      }
      cur += segment.slice(i, j);
      i = j - 1;
      continue;
    }
    if (c === '`') {
      const end = segment.indexOf('`', i + 1);
      const stop = end < 0 ? segment.length : end + 1;
      cur += segment.slice(i, stop);
      i = stop - 1;
      continue;
    }

    const isRedirStart =
      c === '>' || c === '<' || (c === '&' && segment[i + 1] === '>');
    if (isRedirStart) {
      // A word made only of digits right before the operator is its fd (`2>`).
      let fd = '';
      if (/^\d+$/.test(cur)) { fd = cur; cur = ''; }
      push();
      let op = '';
      if (c === '&') { fd = '&'; i++; }
      const opMatch = segment.slice(i).match(/^(<<<|<<-?|<>|<&|<|>>|>\||>&|>)/)!;
      op = opMatch[1]!.replace('<<-', '<<');
      i += opMatch[1]!.length - 1;
      pendingRedirect = { fd, op };
      // `>&2` / `<&0`: the target follows immediately.
      continue;
    }

    if (/\s/.test(c)) { push(); continue; }
    cur += c;
  }
  push();
  return { words, redirects };
}

/** Output destinations that still reach the transcript. */
const TRANSCRIPT_DEVICES = new Set([
  '/dev/stdout', '/dev/stderr', '/dev/tty', '/dev/fd/1', '/dev/fd/2', '/proc/self/fd/1', '/proc/self/fd/2',
]);

function redirectsStdoutToFile(redirects: readonly Redirect[]): boolean {
  return redirects.some((r) => {
    if (!(r.op === '>' || r.op === '>>' || r.op === '>|' || r.op === '>&')) return false;
    if (!(r.fd === '' || r.fd === '1' || r.fd === '&')) return false;
    const target = unquote(r.target);
    if (r.op === '>&' && /^\d+$|^-$/.test(target)) return false; // fd duplication, not a file
    return !TRANSCRIPT_DEVICES.has(target);
  });
}

// --- resolving the head word -----------------------------------------------------------

/**
 * Wrappers that run the NEXT word as the command, and how many following words each of
 * their options consumes. Without the arity, `xargs -I {} git push -f` would read `{}` as
 * the head and `timeout -s KILL 30 rm -rf x` would read `KILL`.
 */
const WRAPPER_OPTION_ARITY: Readonly<Record<string, Readonly<Record<string, number>>>> = {
  sudo: { '-u': 1, '-g': 1, '-C': 1, '-D': 1, '-h': 1, '-p': 1, '-r': 1, '-t': 1, '-U': 1, '-T': 1 },
  doas: { '-u': 1, '-C': 1 },
  env: { '-u': 1, '--unset': 1, '-C': 1, '--chdir': 1, '-S': 1, '--split-string': 1 },
  nice: { '-n': 1, '--adjustment': 1 },
  ionice: { '-c': 1, '-n': 1, '-p': 1 },
  timeout: { '-s': 1, '--signal': 1, '-k': 1, '--kill-after': 1 },
  xargs: { '-I': 1, '-n': 1, '-P': 1, '-L': 1, '-s': 1, '-d': 1, '-E': 1, '-a': 1, '--arg-file': 1, '--delimiter': 1, '--max-args': 1, '--max-procs': 1 },
  stdbuf: { '-i': 1, '-o': 1, '-e': 1 },
  exec: { '-a': 1 },
  command: {},
  builtin: {},
  nohup: {},
  time: {},
};

/** Wrappers that take ONE positional before the command (`timeout 30 cmd`). */
const WRAPPER_POSITIONALS: Readonly<Record<string, number>> = { timeout: 1 };

/** Reserved words and grouping tokens that can precede a command word. */
const LEADING_KEYWORDS = new Set([
  '!', '{', '}', '(', ')', 'if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'while', 'until',
  'function', 'coproc',
]);

function resolveHead(words: string[]): { head: string | null; headRaw: string | null; rest: string[] } {
  let idx = 0;
  while (idx < words.length) {
    let w = words[idx]!;
    // `(git push -f)` and `{ git push -f; }`: strip grouping glued to the first word.
    if (w.startsWith('(') && !w.startsWith('((')) {
      w = w.replace(/^\(+/, '');
      if (!w) { idx++; continue; }
      words = [...words.slice(0, idx), w, ...words.slice(idx + 1)];
    }
    if (LEADING_KEYWORDS.has(w)) {
      // `function name` — skip the name as well.
      idx += w === 'function' ? 2 : 1;
      continue;
    }
    if (/^[A-Za-z_][\w-]*\(\)\{?$/.test(w)) { idx++; continue; } // `name()` function header
    if (/^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/.test(w)) { idx++; continue; } // VAR=value
    break;
  }
  if (idx >= words.length) return { head: null, headRaw: null, rest: [] };

  const headRaw = words[idx]!;
  const unq = unquote(headRaw).replace(/\)+$/, '');
  const head = unq.split('/').pop() || unq;
  // A trailing `)` closes a subshell, not part of the last argument.
  const rest = words.slice(idx + 1);
  if (rest.length > 0) rest[rest.length - 1] = rest[rest.length - 1]!.replace(/(?<!\()\)+$/, '');

  const arity = WRAPPER_OPTION_ARITY[head];
  if (arity) {
    // `command -v x` / `command -V x` looks a name up; it does not run it.
    if (head === 'command' && rest.some((w) => w === '-v' || w === '-V')) {
      return { head, headRaw, rest };
    }
    let k = 0;
    let positionals = WRAPPER_POSITIONALS[head] ?? 0;
    while (k < rest.length) {
      const w = unquote(rest[k]!);
      if (w === '--') { k++; break; }
      if (w.startsWith('-') && w.length > 1) {
        const [flag] = w.split('=', 1);
        k += w.includes('=') ? 1 : 1 + (arity[flag!] ?? 0);
        continue;
      }
      // `env FOO=1 cmd` and `sudo VAR=x cmd`: assignments before the command.
      if ((head === 'env' || head === 'sudo') && /^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) { k++; continue; }
      // `nice -10 cmd` is handled above; `timeout 30 cmd` consumes one positional.
      if (positionals > 0) { positionals--; k++; continue; }
      break;
    }
    if (k < rest.length) {
      const inner = resolveHead(rest.slice(k));
      if (inner.head) return inner;
    }
  }

  return { head, headRaw, rest };
}

// --- segmenting a line --------------------------------------------------------------------

const SEPARATORS = [';;', '&&', '||', '|&', ';', '|', '\n', '&'];
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh', 'mksh', 'ash', 'busybox']);
/** Nesting limit for scripts inside scripts. Deeper than this is not an agent command. */
const MAX_NESTING = 6;

interface RawSegment {
  text: string;
  sepBefore: string;
  depth: number;
  captured: boolean;
  substitutedInto: string | null;
}

/** How much of a segment is tokenized to find its head word. Wrappers and assignments fit. */
const HEAD_PREFIX_CHARS = 2048;

/** Does `text` end in `NAME=` (so a substitution starting here is assigned, not printed)? */
function endsWithAssignment(text: string): boolean {
  if (!text.endsWith('=')) return false;
  let i = text.length - 2;
  while (i >= 0 && /[A-Za-z0-9_]/.test(text[i]!)) i--;
  const name = text.slice(i + 1, text.length - 1);
  if (!/^[A-Za-z_]/.test(name)) return false;
  return i < 0 || /\s/.test(text[i]!);
}

function scan(text: string, depth: number, captured: boolean, substitutedInto: string | null, out: RawSegment[]): void {
  let cur = '';
  let sepBefore = '';
  let inSingle = false;
  let inDouble = false;

  const flush = (sep: string): void => {
    if (cur.trim()) out.push({ text: cur, sepBefore, depth, captured, substitutedInto });
    cur = '';
    sepBefore = sep;
  };

  // What receives a substitution that starts here: the head of the text so far, or
  // null when the substitution itself would be the head.
  //
  // Called once per substitution with the whole segment so far, so it must not cost time
  // proportional to that text: a line with thousands of `$(…)` once took 20 s, past the
  // hook timeout, and a timed-out hook lets the command through. The head is decided by the
  // first few words, so only a bounded prefix is tokenized, and the assignment test looks
  // only at the tail.
  const receiverOf = (before: string): { captured: boolean; into: string | null } => {
    const stripped = before.replace(/"$/, '');
    if (endsWithAssignment(stripped)) return { captured: true, into: null };
    const { words } = tokenize(stripped.length > HEAD_PREFIX_CHARS ? stripped.slice(0, HEAD_PREFIX_CHARS) : stripped);
    return { captured: false, into: resolveHead(words).head };
  };

  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;

    if (c === '\\' && !inSingle) {
      if (text[i + 1] === '\n') { i++; continue; } // line continuation: not a separator
      cur += c + (text[i + 1] ?? '');
      i++;
      continue;
    }
    if (c === "'" && !inDouble) { inSingle = !inSingle; cur += c; continue; }
    if (c === '"' && !inSingle) { inDouble = !inDouble; cur += c; continue; }
    if (inSingle) { cur += c; continue; }

    // Command substitution: $( ... ) — recurse, and remember who receives the output.
    if (c === '$' && text[i + 1] === '(' && text[i + 2] !== '(') {
      let d = 1;
      let j = i + 2;
      for (; j < text.length && d > 0; j++) {
        if (text[j] === '(') d++;
        else if (text[j] === ')') d--;
      }
      const r = receiverOf(cur);
      scan(text.slice(i + 2, j - 1), depth + 1, r.captured, r.into, out);
      cur += text.slice(i, j);
      i = j - 1;
      continue;
    }

    // Backtick substitution.
    if (c === '`') {
      const end = text.indexOf('`', i + 1);
      if (end > i) {
        const r = receiverOf(cur);
        scan(text.slice(i + 1, end), depth + 1, r.captured, r.into, out);
        cur += text.slice(i, end + 1);
        i = end;
        continue;
      }
    }

    if (!inDouble) {
      // `&>`, `>&`, `<&` and `>|` are redirections, not separators.
      const prev = text[i - 1];
      const isRedirAmp = c === '&' && (text[i + 1] === '>' || prev === '>' || prev === '<');
      const isClobber = c === '|' && prev === '>';
      if (!isRedirAmp && !isClobber) {
        const sep = SEPARATORS.find((s) => text.startsWith(s, i));
        if (sep) {
          flush(sep);
          i += sep.length - 1;
          continue;
        }
      }
    }

    cur += c;
  }
  flush('');
}

/** A nested script found inside a command, with how it was reached. */
interface NestedScript {
  readonly script: string;
  readonly via: string;
}

/** Scripts a command runs that the outer line does not show as commands. */
function nestedScripts(head: string, argv: string[], stdin: string | null, pipeTo: string[]): NestedScript[] {
  const out: NestedScript[] = [];

  if (SHELLS.has(head) || head === 'su') {
    // `bash -c 'script'`, `bash -lc`, `bash -o pipefail -c`, `su -c 'script' user`.
    let sawC = false;
    let script: string | null = null;
    let sawPositional = false;
    for (let k = 0; k < argv.length; k++) {
      const w = argv[k]!;
      if (w === '--') { sawPositional = true; script = sawC ? argv[k + 1] ?? null : null; break; }
      if (head === 'busybox' && k === 0) continue; // `busybox sh -c`
      if ((w.startsWith('-') || w.startsWith('+')) && w.length > 1 && !w.startsWith('--')) {
        if (w === '-o' || w === '+o' || w === '-O' || w === '+O') { k++; continue; }
        if (w.slice(1).includes('c')) sawC = true;
        continue;
      }
      if (w === '--command' && head === 'su') { script = argv[k + 1] ?? null; break; }
      if (w.startsWith('--')) continue;
      sawPositional = true;
      if (sawC) script = w;
      break;
    }
    if (script !== null) out.push({ script, via: `${head} -c` });
    else if (!sawPositional && stdin !== null) out.push({ script: stdin, via: `${head} stdin` });
  }

  if (head === 'eval' && argv.length > 0) out.push({ script: argv.join(' '), via: 'eval' });

  if (head === 'watch') {
    // `watch -n 5 'cmd'`: everything after watch's own options is the command.
    let k = 0;
    while (k < argv.length && argv[k]!.startsWith('-')) k += /^-[nd]$|^--interval$/.test(argv[k]!) ? 2 : 1;
    if (k < argv.length) out.push({ script: argv.slice(k).join(' '), via: 'watch' });
  }

  if (head === 'find') {
    for (let k = 0; k < argv.length; k++) {
      if (!/^-(exec|execdir|ok|okdir)$/.test(argv[k]!)) continue;
      const parts: string[] = [];
      let j = k + 1;
      for (; j < argv.length && argv[j] !== ';' && argv[j] !== '+'; j++) parts.push(argv[j]!);
      if (parts.length > 0) out.push({ script: parts.map(shellQuote).join(' '), via: `find ${argv[k]}` });
      k = j;
    }
  }

  if (head === 'alias') {
    for (const w of argv) {
      const eq = w.indexOf('=');
      if (eq > 0) out.push({ script: w.slice(eq + 1), via: 'alias' });
    }
  }

  // `echo 'git push -f' | sh`: the text becomes a script.
  if ((head === 'echo' || head === 'printf') && pipeTo.length > 0 && SHELLS.has(pipeTo[0]!)) {
    const text = argv.filter((w, k) => !(head === 'echo' && k === 0 && /^-[neE]+$/.test(w))).join(' ');
    out.push({ script: text.replace(/\\n/g, '\n'), via: `${head} | ${pipeTo[0]}` });
  }

  return out;
}

const parseCache = new Map<string, SimpleCommand[]>();

/**
 * Segment a command line into simple commands, including every command nested in a
 * substitution, a `-c` script, `eval`, `find -exec`, an alias body, or a script piped or
 * heredoc'd into a shell. Nested commands follow the command that contains them.
 *
 * Memoised on the exact string: every gate parses the same line, and the hook is a
 * one-shot process, so the cache never grows past a handful of entries.
 */
export function parseCommand(command: string): SimpleCommand[] {
  const hit = parseCache.get(command);
  if (hit) return hit;
  const result = parseInternal(command, 0, []);
  if (parseCache.size > 32) parseCache.clear();
  parseCache.set(command, result);
  return result;
}

function parseInternal(command: string, level: number, baseCd: readonly string[]): SimpleCommand[] {
  if (level > MAX_NESTING) return [];
  const { command: stripped, heredocs } = extractHeredocs(command);
  const raws: RawSegment[] = [];
  scan(stripped, 0, false, null, raws);

  // Heredoc bodies are matched to the command whose text opens them, in order.
  let nextHeredoc = 0;
  const cd: string[] = [...baseCd];
  const out: SimpleCommand[] = [];

  const tokenized = raws.map((r) => tokenize(stripUnquotedComment(r.text).trim()));
  const heads = tokenized.map((t) => resolveHead(t.words).head);

  for (let i = 0; i < raws.length; i++) {
    const raw = raws[i]!;
    const { words: allWords, redirects } = tokenized[i]!;
    const { head, headRaw, rest } = resolveHead(allWords);

    // Downstream pipeline members: consecutive following segments joined by `|`.
    const pipeTo: string[] = [];
    for (let k = i + 1; k < raws.length; k++) {
      if ((raws[k]!.sepBefore !== '|' && raws[k]!.sepBefore !== '|&') || raws[k]!.depth !== raw.depth) break;
      const h = heads[k];
      if (h) pipeTo.push(h);
    }

    let stdin: string | null = null;
    const hereStrings: string[] = [];
    const stdinFiles: string[] = [];
    for (const r of redirects) {
      if (r.op === '<' && (r.fd === '' || r.fd === '0')) stdinFiles.push(unquote(r.target));
      if (r.op === '<<<') { stdin = unquote(r.target); hereStrings.push(r.target); }
      if (r.op === '<<' && nextHeredoc < heredocs.length) stdin = heredocs[nextHeredoc++]!.body;
    }

    const argv = rest.flatMap(expandBraces).map(unquote);
    const cmd: SimpleCommand = {
      raw: raw.text.trim(),
      head,
      headRaw,
      words: rest,
      argv,
      pipeTo,
      redirectsStdout: redirectsStdoutToFile(redirects),
      captured: raw.captured,
      substitutedInto: raw.substitutedInto,
      depth: raw.depth,
      cdArgs: [...cd],
      stdin,
      hereStrings,
      stdinFiles,
      via: null,
      assignments: leadingAssignments(allWords),
    };
    out.push(cmd);

    // A top-level `cd dir` changes where every later command in the sequence runs. A
    // cd inside a pipeline or a substitution runs in a subshell and changes nothing after it.
    if ((head === 'cd' || head === 'pushd') && raw.depth === 0 && pipeTo.length === 0) {
      const target = argv.find((w) => !w.startsWith('-') || w === '-');
      cd.push(target ?? '~');
    }

    if (head === null) continue;
    for (const nested of nestedScripts(head, argv, stdin, pipeTo)) {
      for (const inner of parseInternal(nested.script, level + 1, cmd.cdArgs)) {
        out.push({
          ...inner,
          // A nested script's output goes wherever the wrapper's output goes.
          pipeTo: inner.pipeTo.length > 0 ? inner.pipeTo : pipeTo,
          redirectsStdout: inner.redirectsStdout || cmd.redirectsStdout,
          captured: inner.captured || cmd.captured,
          substitutedInto: inner.depth > 0 ? inner.substitutedInto : cmd.substitutedInto,
          depth: cmd.depth + inner.depth,
          via: inner.via ?? nested.via,
        });
      }
    }
  }

  return out;
}

/** Every heredoc in a command line, in order of appearance. */
export function heredocsOf(command: string): Heredoc[] {
  return extractHeredocs(command).heredocs;
}
