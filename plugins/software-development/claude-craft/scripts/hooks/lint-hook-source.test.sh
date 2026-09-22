#!/usr/bin/env bash
# lint-hook-source.test.sh
#
#   bash lint-hook-source.test.sh
#   zsh  lint-hook-source.test.sh
#
# WHY THIS SUITE EXISTS
#
# A linter is judged in two directions and the second one is the one that gets skipped. The
# planted-defect cases below prove it still refuses; the calibration cases prove it does not
# refuse correct code. The donor of this linter passed the first kind and failed the second:
# five of its twelve checks fired on every one of dev-guardrails' fourteen hooks, because it
# assumed a hook is a bash script and they are TypeScript.
#
# So the last case here is the load-bearing one — dev-guardrails must come back with ZERO
# findings, not merely exit 0 — and several cases in the middle exist only to pin behaviours
# that were removed for producing false positives, so they cannot quietly come back.
#
# Fixtures live under $TMPDIR and are removed by the trap. No network.
# Portable bash 3.2 / zsh, like the code it tests.

set -uo pipefail

# Resolve our own directory WITHOUT `dirname`. The missing-jq test strips PATH to
# prove these tools degrade cleanly, and an external dirname would die first — the
# script would fail for a reason that has nothing to do with the dependency it is
# reporting on. `cd` and `pwd` are builtins and survive an empty PATH.
__self="${BASH_SOURCE[0]:-$0}"
case "$__self" in */*) __self_dir="${__self%/*}" ;; *) __self_dir="." ;; esac
SELF_DIR="$(cd "$__self_dir" && pwd)"
unset __self __self_dir
SUT="$SELF_DIR/lint-hook-source.sh"
REPO_ROOT="$(cd "$SELF_DIR/../../../../.." && pwd)"
DG="$REPO_ROOT/plugins/software-development/dev-guardrails"

PASS=0; FAIL=0; SKIP=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lint-hook-source-test.XXXXXX")"
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP %s\n' "$1"; }

printf 'lint-hook-source tests (shell: %s)\n' "${ZSH_VERSION:+zsh $ZSH_VERSION}${BASH_VERSION:+bash $BASH_VERSION}"

[ -f "$SUT" ] || { printf '  FAIL subject under test not found: %s\n' "$SUT"; exit 1; }

run_sut() { OUT="$(bash "$SUT" "$@" 2>&1)"; RC=$?; }

n=0
fixture() { # <basename-suffix> <ext> <body> -> path
  n=$((n + 1))
  p="$TMP_ROOT/hook-$n-$1.$2"
  printf '%s' "$3" > "$p"
  printf '%s' "$p"
}

# A clean shell hook: everything the linter asks for, nothing it objects to. Every
# planted-defect fixture below is this file plus one defect, so a failure points at the
# defect and not at the scaffolding.
CLEAN_SH='#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat)"
tool_name="$(printf "%s" "$payload" | jq -r ".tool_name // empty")"
if [ "$tool_name" = "Bash" ]; then
  printf "blocked\n" >&2
  exit 2
fi
exit 0
'

expect_error() { # <label> <needle> <file>
  label="$1"; needle="$2"; f="$3"
  run_sut "$f"
  if [ "$RC" -eq 0 ]; then
    fail "$label — ACCEPTED a file with a planted defect (rc=0)"
  elif printf '%s' "$OUT" | grep -Fq -- "$needle"; then
    pass "$label"
  else
    fail "$label — failed (rc=$RC) but never named the defect ('$needle' absent): $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -2 | tr '\n' ' ')"
  fi
}

expect_clean() { # <label> <args...>
  label="$1"; shift
  run_sut "$@"
  if [ "$RC" -ne 0 ]; then
    fail "$label — rejected correct code (rc=$RC): $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -3 | tr '\n' ' ')"
  elif printf '%s' "$OUT" | grep -qE '^(ERROR|WARN)'; then
    fail "$label — passed but reported findings against correct code: $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -3 | tr '\n' ' ')"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------------------
# 1. The baseline must be clean, or nothing below means anything.
# ---------------------------------------------------------------------------------------

F="$(fixture clean sh "$CLEAN_SH")"; chmod +x "$F"
expect_clean "a correct shell hook produces no findings at all" "$F"

# ---------------------------------------------------------------------------------------
# 2. Planted defects.
# ---------------------------------------------------------------------------------------

F="$(fixture toolresult sh "${CLEAN_SH}result=\$(printf '%s' \"\$payload\" | jq -r .tool_result)
")"; chmod +x "$F"
expect_error "reading .tool_result (the field that is never there) is an error" "tool_response" "$F"

F="$(fixture homedir sh "${CLEAN_SH}source /home/someone/lib/helpers.sh
")"; chmod +x "$F"
expect_error "a machine-local home directory is an error" "machine-local home directory" "$F"

F="$(fixture evil sh "${CLEAN_SH}eval \"\$tool_name\"
")"; chmod +x "$F"
expect_error "'eval' on hook input is an error" "uses 'eval'" "$F"

F="$(fixture shc sh "${CLEAN_SH}bash -c \"run \$tool_name --now\"
")"; chmod +x "$F"
expect_error "CONCATENATING a variable into a re-evaluated shell string is an error" "re-evaluated shell string" "$F"

# The other side of that distinction, and the reason it exists: passing a variable as the
# ENTIRE program is how Claude Code runs a command hook, and how run-hook-event.sh in this
# directory runs one. Flagging it would make the check unusable by its own neighbours.
F="$(fixture wholecmd sh "${CLEAN_SH}bash -c \"\$tool_name\" </dev/null
")"; chmod +x "$F"
run_sut "$F"
if printf '%s' "$OUT" | grep -Fq 're-evaluated shell string'; then
  fail "'bash -c \"\$var\"' — the variable as the whole program — must not be flagged"
else
  pass "passing a variable as the ENTIRE program is not flagged as concatenation"
fi

F="$(fixture noshebang sh "set -euo pipefail
payload=\"\$(cat)\"
exit 0
")"; chmod +x "$F"
expect_error "a shell hook with no shebang is an error" "no shebang" "$F"

# The one every hook author hits: field names read without ever reading stdin.
F="$(fixture nostdin ts 'const t = input.tool_name; if (t === "Bash") process.exit(2); process.exit(0);
')"
expect_error "naming hook-input fields without reading stdin is an error" "never reads stdin" "$F"

# ---------------------------------------------------------------------------------------
# 3. Warnings that must stay warnings — a warning that becomes an error blocks correct work.
# ---------------------------------------------------------------------------------------

BINBASH="$(printf '%s' "$CLEAN_SH" | sed '1s|.*|#!/bin/bash|')"
F="$(fixture binbash sh "$BINBASH")"; chmod +x "$F"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'non-portable shebang'; then
  pass "'#!/bin/bash' warns (macOS ships bash 3.2 there) and does not fail the run"
else
  fail "'#!/bin/bash' should warn, not fail (rc=$RC)"
fi

F="$(fixture noexec sh "$CLEAN_SH")"; chmod -x "$F"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'not executable'; then
  pass "a non-executable SHELL hook warns"
else
  fail "a non-executable shell hook should warn (rc=$RC)"
fi

F="$(fixture noset sh "$(printf '%s' "$CLEAN_SH" | grep -v 'set -euo')")"; chmod +x "$F"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'set -euo pipefail'; then
  pass "a missing 'set -euo pipefail' warns"
else
  fail "a missing 'set -euo pipefail' should warn (rc=$RC)"
fi

F="$(fixture noguard sh '#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
name="$(printf "%s" "$payload" | jq -r .tool_name)"
printf "%s\n" "$name" >&2
exit 0
')"; chmod +x "$F"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'no availability guard'; then
  pass "calling jq with no 'command -v jq' guard warns"
else
  fail "an unguarded CLI call should warn (rc=$RC)"
fi

F="$(fixture silentblock sh '#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat)"
exit 2
')"; chmod +x "$F"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'never writes to stderr'; then
  pass "exiting 2 with nothing on stderr warns — a block with no reason"
else
  fail "exit 2 with no stderr should warn (rc=$RC)"
fi

# ---------------------------------------------------------------------------------------
# 4. False positives that were removed and must not return.
#
# Each of these is a shape the donor linter flagged and dev-guardrails actually uses.
# ---------------------------------------------------------------------------------------

# A TypeScript hook at mode 0644, invoked as `node <file>`. The donor required +x.
F="$(fixture tsmode ts 'import { readStdin } from "./lib/stdin.ts";
const input = await readStdin();
if (input.tool_name === "Bash") process.exit(2);
process.exit(0);
')"; chmod 644 "$F"
expect_clean "a mode-0644 TypeScript hook is not flagged for the executable bit" "$F"

# The `tool_result` trap DOCUMENTED in a comment, exactly as three dev-guardrails files do.
F="$(fixture tscomment ts '// The field is `tool_response`, NOT `tool_result` — `tool_result` is the content-block
// name and is never a hook-input field.
import { readStdin } from "./lib/stdin.ts";
const input = await readStdin();
const r = input.tool_response ?? {};
process.exit(0);
')"
expect_clean "documenting the tool_result trap in a comment is not itself the trap" "$F"

# A session-lifecycle hook that deliberately reads nothing and emits context. The broader
# "does it read stdin at all" check flagged three of these.
F="$(fixture nopayload ts 'process.stdout.write("=== Session Context ===\n");
process.exit(0);
')"
expect_clean "a session hook that reads no payload and names no fields is not flagged" "$F"

# A shell script whose variables are all correctly quoted. The donor flagged this shape on
# essentially every script through a catch-everything quoting heuristic.
F="$(fixture quoted sh '#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat)"
dir="${CLAUDE_PROJECT_DIR:-.}"
printf "%s\n" "$dir/sub" >&2
exit 0
')"; chmod +x "$F"
expect_clean "correctly quoted variables are not flagged as an injection risk" "$F"

# `#!/usr/bin/env bash` is this repo's REQUIRED shebang. Flagging /usr/ would contradict it.
F="$(fixture envshebang sh "$CLEAN_SH")"; chmod +x "$F"
run_sut "$F"
if printf '%s' "$OUT" | grep -Fq '/usr/'; then
  fail "'#!/usr/bin/env bash' must not be flagged — it is the shebang this repo requires"
else
  pass "'#!/usr/bin/env bash' is not flagged as a hardcoded path"
fi

# ---------------------------------------------------------------------------------------
# 5. Misconfiguration is exit 2, and a missing file is a finding.
# ---------------------------------------------------------------------------------------

run_sut
if [ "$RC" -eq 2 ]; then pass "no arguments is exit 2 (misconfigured), not a pass"
else fail "no arguments should be exit 2, got $RC"; fi

EMPTYDIR="$TMP_ROOT/empty"; mkdir -p "$EMPTYDIR"
run_sut --dir "$EMPTYDIR"
if [ "$RC" -eq 2 ]; then pass "a directory with no hook sources is exit 2, not 'OK: no findings'"
else fail "an empty --dir should be exit 2, got $RC"; fi

run_sut "$TMP_ROOT/does-not-exist.sh"
if [ "$RC" -ne 0 ]; then pass "a named file that does not exist is an error"
else fail "a missing file should be an error, got $RC"; fi

# ---------------------------------------------------------------------------------------
# 6. Calibration. The whole point.
# ---------------------------------------------------------------------------------------

if [ ! -d "$DG/hooks/src" ]; then
  skip "dev-guardrails hooks not found — cannot run the calibration case"
else
  run_sut --dir "$DG/hooks/src"
  linted="$(printf '%s\n' "$OUT" | sed -n 's/^linted \([0-9][0-9]*\) file.*/\1/p' | head -1)"
  if [ "$RC" -ne 0 ]; then
    fail "dev-guardrails hooks/src — known-correct code was rejected: $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -3 | tr '\n' ' ')"
  elif printf '%s' "$OUT" | grep -qE '^(ERROR|WARN)'; then
    fail "dev-guardrails hooks/src — $(printf '%s' "$OUT" | grep -cE '^(ERROR|WARN)') finding(s) against known-correct code: $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -3 | tr '\n' ' ')"
  elif [ -z "$linted" ] || [ "$linted" -lt 14 ]; then
    fail "dev-guardrails hooks/src — clean but only linted '$linted' file(s); the package has 14 hooks"
  else
    pass "dev-guardrails hooks/src: $linted files linted, zero findings"
  fi

  run_sut --dir "$DG/hooks/src/lib"
  if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qE '^(ERROR|WARN)'; then
    pass "dev-guardrails hooks/src/lib: zero findings"
  else
    fail "dev-guardrails hooks/src/lib produced findings: $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -3 | tr '\n' ' ')"
  fi
fi

# This directory's own scripts must survive their own linter's shell checks. They are not
# hooks, but every shell rule it enforces applies to them, and a tool that cannot pass its
# own bar has no standing to enforce it.
run_sut "$SELF_DIR/run-hook-event.sh" "$SELF_DIR/lint-hook-source.sh" "$SELF_DIR/validate-hook-registration.sh"
if [ "$RC" -eq 0 ]; then
  pass "the three tools in this directory pass their own linter"
else
  fail "the tools in this directory fail their own linter: $(printf '%s' "$OUT" | grep -E '^ERROR' | head -3 | tr '\n' ' ')"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
