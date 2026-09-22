---
name: subprocess-patterns
license: MIT
description: Safe subprocess invocation — shell headers and strict modes, stdout/stderr separation, parsing JSON that may contain user text, exit-code semantics, timeouts, ANSI stripping and portable quoting. Use when writing a shell script or hook, shelling out from application code, or debugging a pipeline that fails only on certain inputs.
---

# Subprocess Patterns

## Shell headers

Scripts should run under both bash 3.2 and zsh — macOS still ships bash 3.2, so bash-4
features (associative arrays, `${var,,}`, `mapfile`) are not portable there.

```sh
#!/usr/bin/env bash     # default; never a hardcoded /bin/bash
set -euo pipefail       # scripts: fail fast on any error or unset variable
set -uo pipefail        # hooks: they need to control their own exit codes
```

`#!/usr/bin/env zsh` only when zsh features are deliberate.

## Stdout and stderr

Keep them separate. Data goes to stdout; diagnostics go to stderr. A script that prints a
progress message to stdout has corrupted its own output for every caller that parses it.

```sh
output=$(cmd 2>/dev/null)   # capture data only
output=$(cmd 2>&1)          # capture both — only when you are about to show a human
cmd >/dev/null 2>&1         # discard both
```

## Parsing JSON that may contain user text

**Do not pipe an API response straight into `jq`.** Any JSON field that carries
user-authored text — a commit title, a description, a comment body — may contain raw
control characters (U+0000–U+001F) and multibyte glyphs. `jq` 1.7 and later reject
unescaped control characters *at parse time*, so the whole pipeline fails before it can
select the clean field you wanted. Worse, it is input-dependent: the same command succeeds
on one record and fails on the next.

Stripping with `tr -d '\000-\010\013\014\016-\037'` only removes single-byte control
characters, not the multibyte glyphs. Python's `json.load` tolerates all of it.

Canonical pattern — write the raw response to a temp file, parse with `python3`:

```sh
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
some-api-client get /resource/123 > "$TMP"
VALUE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("field",""))' "$TMP")
```

For several fields at once, emit shell-quoted assignments and `eval` them:

```sh
eval "$(python3 - "$TMP" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
for k, v in (("URL", d.get("web_url", "")), ("BRANCH", d.get("source_branch", ""))):
    print(f"{k}={shlex.quote(v)}")
PY
)"
```

Reserve `jq` for JSON you produced yourself, where no field can carry arbitrary text.

## Exit code semantics

| Code | Meaning | Used by |
| --- | --- | --- |
| 0 | Success / allow | Scripts, hooks |
| 1 | Error / failure | Scripts |
| 2 | Hard block | Pre-tool-use hooks, and `grep` on a malformed pattern |

Hook shape:

```sh
if [[ "$violation" == "true" ]]; then
    echo "REJECT: <reason>" >&2
    exit 2      # block the call
fi
exit 0          # allow
```

Beware the `A && B || C` idiom. It is `(A && B) || C`: when `A` succeeds and `B` *fails*,
`C` runs anyway and the whole expression exits 0. Written as a tool-presence check —
`command -v scanner && scanner … || echo "not installed"` — a scanner that runs and **finds
a problem** is reported as a missing tool, and the caller proceeds. Use an explicit
if/else whenever the success branch can itself fail:

```sh
if command -v scanner >/dev/null 2>&1; then
    scanner --exit-code 1 .
else
    echo "scanner not installed — scan SKIPPED" >&2
fi
```

## Timeouts

Every call to something that talks to a network or another process gets a timeout.

```sh
if ! output=$(timeout 30s long_running_cmd 2>&1); then
    echo "command failed or timed out" >&2
    exit 1
fi
```

`timeout` exits 124 when it fires — distinguish that from a real failure if the caller
cares.

## ANSI stripping

Tools detect a TTY and colorize. Captured output then carries escape sequences that break
every downstream comparison.

```sh
clean=$(cmd | sed 's/\x1b\[[0-9;]*m//g')
```

Better, where the tool supports it: pass `--no-color`, or set `NO_COLOR=1` / `TERM=dumb`.

## Never build a shell string from untrusted input

From application code, pass an argument vector; do not interpolate into a command line.

```python
subprocess.run(["git", "log", "--oneline", ref], check=True, capture_output=True, text=True)
# not: subprocess.run(f"git log --oneline {ref}", shell=True)
```

`shell=True` with any interpolated value is a command-injection hole, and it is the single
most common finding a Python security linter reports.

## Quoting and portability

```sh
echo "$MY_VAR"                   # always quote expansions
result="$(some_cmd)"             # quote command substitution
for f in "${files[@]}"; do       # quote array expansion
    printf '%s\n' "$f"
done
```

| Do | Don't |
| --- | --- |
| `grep -oE 'pattern'` | `${BASH_REMATCH[1]}` (bash-only) |
| `[[ -n "$VAR" ]]` | `[ -n $VAR ]` (unquoted — breaks on empty) |
| `[[ "$a" == "$b" ]]` | `[ $a = $b ]` |
| `command -v tool` | `which tool` (non-POSIX, inconsistent exit codes) |
| `printf '%s\n' "$x"` | `echo "$x"` for arbitrary values (`-n`, backslashes) |
| `sh -c 'portable cmd'` | Assuming bash 4+ builtins are present |
