#!/usr/bin/env bash
# guard-review-writes.test.sh — pipes hook-input JSON into guard-review-writes.py and checks the
# decision. Covers deny (judge writing outside .code-review), allow (judge writing inside it), and
# the cases that must never be touched: the main session, other agents, and unparseable input.
#
#   bash hooks/guard-review-writes.test.sh
#
# Nothing is touched outside $TMP_ROOT, which the trap removes on any exit.

set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOK="$SELF_DIR/guard-review-writes.py"
PASS=0; FAIL=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/code-review-guard-test.XXXXXX")"
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || { printf 'SKIPPED: python3 not on PATH\n'; exit 0; }

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/.code-review" "$REPO/src"
ln -s "$REPO/src" "$REPO/.code-review/escape"

# input <agent_type or ""> <tool> <path key> <path>
input() {
  python3 - "$1" "$2" "$3" "$4" "$REPO" <<'PY'
import json, sys
agent, tool, key, path, cwd = sys.argv[1:6]
d = {"hook_event_name": "PreToolUse", "cwd": cwd, "tool_name": tool, "tool_input": {key: path}}
if agent:
    d["agent_type"] = agent
print(json.dumps(d))
PY
}

# expect <label> <deny|allow> <json>
expect() {
  out="$(printf '%s' "$3" | python3 "$HOOK" 2>"$TMP_ROOT/err")"; rc=$?
  if [ "$rc" -ne 0 ]; then fail "$1 (exit $rc)"; return; fi
  case "$2" in
    deny)  case "$out" in *'"permissionDecision": "deny"'*) pass "$1" ;; *) fail "$1 (no deny: '$out')" ;; esac ;;
    allow) [ -z "$out" ] && pass "$1" || fail "$1 (unexpected output: '$out')" ;;
  esac
}

printf 'guard-review-writes tests\n'
J=code-review-core:review-semantic

expect "deny: judge Write to a source file"       deny  "$(input "$J" Write file_path "$REPO/src/app.py")"
expect "deny: judge Edit to a relative path"      deny  "$(input "$J" Edit file_path "src/app.py")"
expect "deny: judge NotebookEdit outside"         deny  "$(input code-review-core:review-testing NotebookEdit notebook_path "$REPO/nb.ipynb")"
expect "deny: .. walks out of .code-review"       deny  "$(input "$J" Write file_path "$REPO/.code-review/../src/app.py")"
expect "deny: symlink inside .code-review"        deny  "$(input "$J" Write file_path "$REPO/.code-review/escape/app.py")"
expect "deny: validator writes outside"           deny  "$(input code-review-core:review-validator Write file_path "$REPO/VALIDATED.json")"
expect "allow: judge writes its artifact"         allow "$(input "$J" Write file_path "$REPO/.code-review/SEMANTIC.json")"
expect "allow: relative artifact path"            allow "$(input "$J" Write file_path ".code-review/SEMANTIC.md")"
expect "allow: main session (no agent_type)"      allow "$(input "" Write file_path "$REPO/src/app.py")"
expect "allow: another plugin's agent"            allow "$(input other-plugin:review-bot Write file_path "$REPO/src/app.py")"
expect "allow: built-in agent"                    allow "$(input general-purpose Edit file_path "$REPO/src/app.py")"
expect "allow: unparseable input fails open"      allow "not json"
if grep -q 'could not parse' "$TMP_ROOT/err"; then pass "fail-open writes a stderr note"; else fail "fail-open wrote no stderr note"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
