#!/usr/bin/env bash
# validate-hook-registration.test.sh
#
#   bash validate-hook-registration.test.sh
#   zsh  validate-hook-registration.test.sh
#
# WHY THIS SUITE EXISTS
#
# The donor of this script, plugin-dev's `validate-hook-schema.sh`, read event names from the
# document ROOT. A plugin hooks.json is wrapped — `{"hooks": {...}}` — so the only key it ever
# saw was the literal string `hooks`. Against `{"hooks": {}}` it printed "All checks passed!"
# and exited 0; against any non-empty wrapped document it died on a jq indexing error. Either
# way it inspected zero registrations while presenting itself as a validator.
#
# That is the failure this repo keeps finding: a gate that is green because it never looked.
# A suite that only asserts "a bad file exits non-zero" would NOT have caught it — the donor
# exits 5 on a correct file, which is non-zero for entirely the wrong reason. So every
# rejection case here asserts BOTH a non-zero exit AND that the message names the planted
# defect, and every acceptance case asserts BOTH exit 0 AND a non-zero count of inspected
# registrations.
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
SUT="$SELF_DIR/validate-hook-registration.sh"
REPO_ROOT="$(cd "$SELF_DIR/../../../../.." && pwd)"
DG="$REPO_ROOT/plugins/software-development/dev-guardrails"

BASH_BIN="$(command -v bash || true)"
PASS=0; FAIL=0; SKIP=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/validate-hook-reg-test.XXXXXX")"
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP %s\n' "$1"; }

printf 'validate-hook-registration tests (shell: %s)\n' "${ZSH_VERSION:+zsh $ZSH_VERSION}${BASH_VERSION:+bash $BASH_VERSION}"

if [ ! -f "$SUT" ]; then
  printf '  FAIL subject under test not found: %s\n' "$SUT"
  exit 1
fi

# A missing dependency is reported as SKIPPED, never as a pass. A suite that goes green
# because the tool it tests could not run is the same defect one level up.
if ! command -v jq >/dev/null 2>&1; then
  skip "jq is not installed — the whole suite needs it"
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

n=0
write_fixture() { # <json> -> echoes path
  n=$((n + 1))
  p="$TMP_ROOT/fixture-$n.json"
  printf '%s\n' "$1" > "$p"
  printf '%s' "$p"
}

# Runs the subject, capturing merged output and the exit code.
run_sut() { # <args...>
  OUT="$(bash "$SUT" "$@" 2>&1)"
  RC=$?
}

# An acceptance case: exit 0 AND proof it descended into the document.
expect_clean() { # <label> <file> [extra args...]
  label="$1"; shift
  run_sut "$@"
  if [ "$RC" -ne 0 ]; then
    fail "$label — rejected a valid document (rc=$RC): $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
    return
  fi
  inspected="$(printf '%s\n' "$OUT" | sed -n 's/.*inspected \([0-9][0-9]*\) event.*/\1/p' | head -1)"
  hooks="$(printf '%s\n' "$OUT" | sed -n 's/.*inspected [0-9]* event(s), [0-9]* entry(ies), \([0-9][0-9]*\) hook.*/\1/p' | head -1)"
  if [ -z "$inspected" ] || [ "$inspected" -eq 0 ] || [ -z "$hooks" ] || [ "$hooks" -eq 0 ]; then
    fail "$label — exited 0 but inspected nothing (events='$inspected' hooks='$hooks'). This is the donor's defect."
    return
  fi
  pass "$label (inspected $inspected event(s), $hooks hook(s))"
}

# A rejection case: non-zero AND the message names the defect. The second half is what
# distinguishes a real detection from an incidental crash.
expect_reject() { # <label> <needle> <args...>
  label="$1"; needle="$2"; shift 2
  run_sut "$@"
  if [ "$RC" -eq 0 ]; then
    fail "$label — ACCEPTED a document with a planted defect (rc=0)"
    return
  fi
  if printf '%s' "$OUT" | grep -Fq -- "$needle"; then
    pass "$label"
  else
    fail "$label — rejected (rc=$RC) but never named the defect ('$needle' absent). Output: $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------------------
# 1. The wrapper. The defect, directly.
# ---------------------------------------------------------------------------------------

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"^Bash$","hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/x.sh"}]}]}}')"
expect_clean "a correct WRAPPED {\"hooks\":{...}} document is descended into, not skipped" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"^Bash$","hooks":[{"type":"bogus-type","command":"x"}]}]}}')"
expect_reject "a defect INSIDE the wrapper is found and named" "bogus-type" "$F"

# The donor's exact silent pass. `{"hooks": {}}` has one root key, no valid events, and the
# donor printed "All checks passed!".
F="$(write_fixture '{"hooks":{}}')"
expect_reject "an EMPTY wrapper is a failure, not 'all checks passed'" "registers no hooks" "$F"

# The bare event map (a settings "hooks" value) still works, with a nudge.
F="$(write_fixture '{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}')"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'no top-level "hooks" wrapper'; then
  pass "an UNWRAPPED event map is accepted and the missing wrapper is named"
else
  fail "an unwrapped event map should pass with a wrapper warning (rc=$RC)"
fi

# ---------------------------------------------------------------------------------------
# 2. The donor's other false positive: a required matcher.
#
# dev-guardrails registers SessionStart, UserPromptSubmit, PreCompact and Stop with no
# matcher, correctly — an omitted matcher matches everything. The donor called that a hard
# error, which would have failed four correct registrations.
# ---------------------------------------------------------------------------------------

F="$(write_fixture '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}')"
expect_clean "a SessionStart entry with NO matcher is accepted (omitted == matches all)" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"^(Write|Edit)$","hooks":[{"type":"command","command":"echo hi"}]}]}}')"
expect_clean "a regex matcher '^(Write|Edit)\$' is accepted" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":42,"hooks":[{"type":"command","command":"echo hi"}]}]}}')"
expect_reject "a non-string matcher is rejected" "matcher must be a string" "$F"

# The literal-vs-regex switch: a matcher that reads as a literal but contains one '.' is an
# unanchored regex, so `Notebook.Edit` also matches `NotebookXEdit`.
F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"Notebook.Edit","hooks":[{"type":"command","command":"echo hi"}]}]}}')"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'UNANCHORED regex'; then
  pass "a literal-looking matcher containing '.' is warned about, not failed"
else
  fail "'Notebook.Edit' should warn about the literal/regex switch and still pass (rc=$RC)"
fi

# A matcher on an event that carries no tool is silently ignored by the platform.
F="$(write_fixture '{"hooks":{"SessionStart":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}}')"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'carries no tool name'; then
  pass "a matcher on a non-tool event is flagged as an ignored no-op"
else
  fail "a matcher on SessionStart should warn (rc=$RC)"
fi

# ---------------------------------------------------------------------------------------
# 3. Event names and structure.
# ---------------------------------------------------------------------------------------

F="$(write_fixture '{"hooks":{"PreToolUze":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}')"
expect_reject "a typo'd event name is an error, not a warning" "unrecognised event name" "$F"

F="$(write_fixture '{"hooks":{"PreToolUze":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}')"
run_sut "$F" --allow-unknown-events
if [ "$RC" -eq 0 ]; then pass "--allow-unknown-events downgrades it to a warning"
else fail "--allow-unknown-events should let an unknown event pass (rc=$RC)"; fi

# Events the donor did not know. PostCompact and SubagentStart must not be rejected.
F="$(write_fixture '{"hooks":{"PostCompact":[{"hooks":[{"type":"command","command":"echo hi"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}')"
expect_clean "events outside the donor's nine (PostCompact, SubagentStart) are recognised" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":{"matcher":"Bash"}}}')"
expect_reject "an event whose value is an object, not an array, is rejected" "must be an array" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"Bash"}]}}')"
expect_reject "an entry with no 'hooks' array is rejected" "missing or malformed 'hooks' array" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}]}}')"
expect_reject "an empty 'hooks' array is rejected" "registers nothing" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"echo hi"}]}]}}')"
expect_reject "a hook with no 'type' is rejected" "missing 'type'" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command"}]}]}}')"
expect_reject "a command hook with no 'command' is rejected" "non-empty 'command'" "$F"

F="$(write_fixture '{"hooks":{"Stop":[{"hooks":[{"type":"prompt"}]}]}}')"
expect_reject "a prompt hook with no 'prompt' is rejected" "non-empty 'prompt'" "$F"

# The five types from deterministic-enforcement §4; the donor knew two.
F="$(write_fixture '{"hooks":{"Stop":[{"hooks":[{"type":"agent"},{"type":"mcp_tool"},{"type":"http"}]}]}}')"
expect_clean "the agent / mcp_tool / http types are recognised, not rejected as invalid" "$F"

# ---------------------------------------------------------------------------------------
# 4. Command shape and timeouts.
# ---------------------------------------------------------------------------------------

F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash /home/someone/hooks/x.sh"}]}]}}')"
expect_reject "a machine-local home directory in a command is an error" "machine-local home directory" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash /opt/tools/x.sh"}]}]}}')"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'CLAUDE_PLUGIN_ROOT'; then
  pass "an absolute command path with no plugin-root variable warns"
else
  fail "an absolute path should warn about CLAUDE_PLUGIN_ROOT (rc=$RC)"
fi

F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi","timeout":"sixty"}]}]}}')"
expect_reject "a non-numeric timeout is rejected" "timeout must be a number" "$F"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi","timeout":900}]}]}}')"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq '600s ceiling'; then
  pass "a 900s timeout warns and still passes"
else fail "a 900s timeout should warn (rc=$RC)"; fi

F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi","timeout":2}]}]}}')"
run_sut "$F"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'very short'; then
  pass "a 2s timeout warns and still passes"
else fail "a 2s timeout should warn (rc=$RC)"; fi

# ---------------------------------------------------------------------------------------
# 5. --plugin-root: the "wired in settings, points at nothing" finding.
# ---------------------------------------------------------------------------------------

PR="$TMP_ROOT/plugin"
mkdir -p "$PR/hooks"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PR/hooks/real.sh"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/hooks/real.sh"}]}]}}')"
expect_clean "a command resolving to an existing file passes with --plugin-root" "$F" --plugin-root "$PR"

F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/hooks/gone.sh"}]}]}}')"
expect_reject "a command resolving to a MISSING file is an error" "does not exist" "$F" --plugin-root "$PR"

# ---------------------------------------------------------------------------------------
# 6. Misconfiguration is exit 2, distinct from a finding.
# ---------------------------------------------------------------------------------------

printf 'not json at all\n' > "$TMP_ROOT/bad.json"
run_sut "$TMP_ROOT/bad.json"
if [ "$RC" -eq 2 ]; then pass "invalid JSON is exit 2 (misconfigured), not exit 1"
else fail "invalid JSON should be exit 2, got $RC"; fi

run_sut "$TMP_ROOT/nope.json"
if [ "$RC" -eq 2 ]; then pass "a missing file is exit 2"
else fail "a missing file should be exit 2, got $RC"; fi

# Missing jq must fail loudly rather than degrading to line matching.
EMPTY_BIN="$TMP_ROOT/emptybin"; mkdir -p "$EMPTY_BIN"
F="$(write_fixture '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}')"
if [ -z "$BASH_BIN" ]; then
  skip "bash not on PATH — cannot run the stripped-PATH case"
else
  # PATH is emptied so `command -v jq` fails; bash itself is invoked by absolute path so the
  # case tests the missing dependency and not a missing shell.
  OUT="$(PATH="$EMPTY_BIN" "$BASH_BIN" "$SUT" "$F" 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -Fq 'jq is required'; then
    pass "without jq the tool refuses (exit 2), rather than falling back to sed"
  else
    fail "a missing jq must exit 2 with a clear message (rc=$RC): $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------------------
# 7. The calibration case: this repo's own 14-hook package must come back clean.
#
# dev-guardrails is correct and well-tested. Any finding against it is a false positive in
# this tool unless demonstrated otherwise, so it is asserted rather than eyeballed.
# ---------------------------------------------------------------------------------------

if [ -f "$DG/hooks/hooks.json" ]; then
  run_sut "$DG/hooks/hooks.json" --plugin-root "$DG"
  if [ "$RC" -ne 0 ]; then
    fail "dev-guardrails/hooks/hooks.json — a known-correct registration was rejected: $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -3 | tr '\n' ' ')"
  elif printf '%s' "$OUT" | grep -qE '^(ERROR|WARN)'; then
    fail "dev-guardrails/hooks/hooks.json — passed but reported findings against known-correct code: $(printf '%s' "$OUT" | grep -E '^(ERROR|WARN)' | head -3 | tr '\n' ' ')"
  else
    inspected="$(printf '%s\n' "$OUT" | sed -n 's/.*inspected [0-9]* event(s), [0-9]* entry(ies), \([0-9][0-9]*\) hook.*/\1/p' | head -1)"
    if [ -n "$inspected" ] && [ "$inspected" -ge 15 ]; then
      pass "dev-guardrails/hooks/hooks.json: clean, and all $inspected registered hooks were inspected"
    else
      fail "dev-guardrails/hooks/hooks.json: clean but only inspected '$inspected' hooks — the file registers 15"
    fi
  fi
else
  skip "dev-guardrails/hooks/hooks.json not found — cannot run the calibration case"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
