#!/usr/bin/env bash
# run-hook-event.test.sh
#
#   bash run-hook-event.test.sh
#   zsh  run-hook-event.test.sh
#
# WHY THIS SUITE EXISTS
#
# A synthetic payload is only worth anything if the field names are the real ones. A fixture
# that says `tool_result` where the platform says `tool_response` produces a hook that passes
# every local test and reads `undefined` in production — which is why dev-guardrails pins the
# name in three separate files and in its own tests. The donor of this runner got that field
# wrong, got `prompt` wrong, and labelled its SessionEnd sample `SessionStart`. All three are
# asserted here, negatively as well as positively: it is not enough that the right key is
# present if the wrong one is present too.
#
# The rest plants defects in a hook and asserts the runner reports them: a timeout, an
# out-of-protocol exit code, and a half-written decision object.
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
SUT="$SELF_DIR/run-hook-event.sh"
REPO_ROOT="$(cd "$SELF_DIR/../../../../.." && pwd)"
DG="$REPO_ROOT/plugins/software-development/dev-guardrails"

BASH_BIN="$(command -v bash || true)"
PASS=0; FAIL=0; SKIP=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-hook-event-test.XXXXXX")"
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP %s\n' "$1"; }

printf 'run-hook-event tests (shell: %s)\n' "${ZSH_VERSION:+zsh $ZSH_VERSION}${BASH_VERSION:+bash $BASH_VERSION}"

[ -f "$SUT" ] || { printf '  FAIL subject under test not found: %s\n' "$SUT"; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  skip "jq is not installed — the whole suite needs it"
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

payload() { # <event> [args...] -> the generated payload on stdout
  bash "$SUT" --event "$1" "${@:2}" --print-payload 2>/dev/null
}

run_sut() { # <args...>
  OUT="$(bash "$SUT" "$@" 2>&1)"
  RC=$?
}

has_field() { # <json> <jq-path-key>
  printf '%s' "$1" | jq -e --arg k "$2" 'has($k)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------------------
# 1. Payload field names — the three the donor got wrong.
# ---------------------------------------------------------------------------------------

P="$(payload PostToolUse --tool Bash)"
if has_field "$P" tool_response && ! has_field "$P" tool_result; then
  pass "PostToolUse carries tool_response and NOT tool_result"
else
  fail "PostToolUse must carry tool_response and must not carry tool_result: $P"
fi

P="$(payload UserPromptSubmit)"
if has_field "$P" prompt && ! has_field "$P" user_prompt; then
  pass "UserPromptSubmit carries prompt and NOT user_prompt"
else
  fail "UserPromptSubmit must carry prompt and must not carry user_prompt: $P"
fi

P="$(payload SessionEnd)"
if [ "$(printf '%s' "$P" | jq -r '.hook_event_name')" = "SessionEnd" ]; then
  pass "the SessionEnd payload says hook_event_name=SessionEnd"
else
  fail "SessionEnd payload is mislabelled: $(printf '%s' "$P" | jq -r '.hook_event_name')"
fi

# Bash's tool_response shape is exact. dev-guardrails asserts the key set is exactly these
# four, because an off-schema updatedToolOutput is discarded in silence.
P="$(payload PostToolUse --tool Bash)"
KEYS="$(printf '%s' "$P" | jq -r '.tool_response | keys | join(",")')"
if [ "$KEYS" = "interrupted,isImage,stderr,stdout" ]; then
  pass "the Bash tool_response fixture is exactly {stdout,stderr,interrupted,isImage}"
else
  fail "Bash tool_response keys are '$KEYS', not the exact shape Claude Code accepts"
fi

# Every event dev-guardrails registers must generate a payload with the five common fields.
for ev in PreToolUse PostToolUse SessionStart UserPromptSubmit PreCompact Stop; do
  P="$(payload "$ev")"
  if [ -z "$P" ]; then
    fail "$ev: no payload generated"
    continue
  fi
  missing=""
  for k in session_id transcript_path cwd permission_mode hook_event_name; do
    has_field "$P" "$k" || missing="$missing $k"
  done
  if [ -n "$missing" ]; then
    fail "$ev: payload is missing common field(s):$missing"
  elif [ "$(printf '%s' "$P" | jq -r '.hook_event_name')" != "$ev" ]; then
    fail "$ev: hook_event_name says $(printf '%s' "$P" | jq -r '.hook_event_name')"
  else
    pass "$ev: valid payload with all five common fields"
  fi
done

# Tool shapes the fixtures claim to know.
P="$(payload PreToolUse --tool Write)"
if [ "$(printf '%s' "$P" | jq -r '.tool_input | has("file_path") and has("content")')" = "true" ]; then
  pass "PreToolUse --tool Write produces {file_path, content}"
else fail "PreToolUse --tool Write tool_input is wrong: $P"; fi

P="$(payload PreToolUse --tool Edit)"
if [ "$(printf '%s' "$P" | jq -r '.tool_input | has("old_string") and has("new_string")')" = "true" ]; then
  pass "PreToolUse --tool Edit produces {file_path, old_string, new_string}"
else fail "PreToolUse --tool Edit tool_input is wrong: $P"; fi

P="$(payload PreToolUse --tool TodoWrite)"
if [ "$(printf '%s' "$P" | jq -r '.tool_input.todos | length')" -ge 1 ]; then
  pass "PreToolUse --tool TodoWrite produces a non-empty todos array"
else fail "TodoWrite tool_input is wrong: $P"; fi

# --set overrides, parsed as JSON when it is JSON.
P="$(payload PreToolUse --tool Bash --set 'tool_input={"command":"rm -rf /"}')"
if [ "$(printf '%s' "$P" | jq -r '.tool_input.command')" = "rm -rf /" ]; then
  pass "--set replaces a field with parsed JSON"
else fail "--set did not apply: $P"; fi

P="$(payload PreToolUse --set 'permission_mode=plan')"
if [ "$(printf '%s' "$P" | jq -r '.permission_mode')" = "plan" ]; then
  pass "--set falls back to a string for a non-JSON value"
else fail "--set string fallback did not apply: $P"; fi

run_sut --event NoSuchEvent --print-payload
if [ "$RC" -eq 2 ]; then pass "an unknown --event is exit 2 (misconfigured)"
else fail "an unknown --event should be exit 2, got $RC"; fi

# ---------------------------------------------------------------------------------------
# 2. The payload actually reaches the hook, and the channels stay apart.
# ---------------------------------------------------------------------------------------

if [ -z "$BASH_BIN" ]; then
  skip "bash not on PATH — cannot build hook fixtures"
else
  H="$TMP_ROOT/hooks"; mkdir -p "$H"

  cat > "$H/echo-event.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf '%s' "$payload" | jq -e 'has("hook_event_name") and has("tool_response")' >/dev/null || {
  printf 'payload did not reach the hook intact\n' >&2
  exit 2
}
printf 'EVENT=%s TOOL=%s\n' "$(printf '%s' "$payload" | jq -r .hook_event_name)" "$(printf '%s' "$payload" | jq -r .tool_name)"
exit 0
EOF
  chmod +x "$H/echo-event.sh"
  run_sut --event PostToolUse --tool Bash -- bash "$H/echo-event.sh"
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'EVENT=PostToolUse TOOL=Bash'; then
    pass "the generated payload arrives on the hook's stdin, intact"
  else
    fail "the hook did not receive the payload (rc=$RC): $(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
  fi

  # stdout and stderr must not be merged. The donor captured `2>&1` into one buffer, which
  # destroys the only distinction the hook protocol has: stdout is the decision channel and
  # stderr is what gets fed back to the model on exit 2.
  cat > "$H/two-channels.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'DECISION_CHANNEL_TEXT\n'
printf 'FEEDBACK_CHANNEL_TEXT\n' >&2
exit 2
EOF
  chmod +x "$H/two-channels.sh"
  run_sut --event PreToolUse -- bash "$H/two-channels.sh"
  stdout_sec="$(printf '%s\n' "$OUT" | sed -n '/--- stdout/,/--- stderr/p')"
  stderr_sec="$(printf '%s\n' "$OUT" | sed -n '/--- stderr/,$p')"
  if printf '%s' "$stdout_sec" | grep -Fq 'DECISION_CHANNEL_TEXT' \
     && printf '%s' "$stderr_sec" | grep -Fq 'FEEDBACK_CHANNEL_TEXT' \
     && ! printf '%s' "$stdout_sec" | grep -Fq 'FEEDBACK_CHANNEL_TEXT'; then
    pass "stdout and stderr are reported separately, not merged"
  else
    fail "the two channels were merged or mislabelled: $OUT"
  fi

  if printf '%s' "$OUT" | grep -Fq 'exit code  2' && printf '%s' "$OUT" | grep -Fq 'block'; then
    pass "exit 2 on PreToolUse is reported as a block"
  else
    fail "exit 2 was not reported as a block: $(printf '%s' "$OUT" | head -8 | tr '\n' ' ')"
  fi

  # Exit 2 on PostToolUse does NOT block, and saying otherwise is the single most common
  # hook antipattern. The legend must say so.
  run_sut --event PostToolUse -- bash "$H/two-channels.sh"
  if printf '%s' "$OUT" | grep -Fq 'does NOT block'; then
    pass "exit 2 on PostToolUse is reported as non-blocking"
  else
    fail "the PostToolUse legend must state that exit 2 does not block: $(printf '%s' "$OUT" | head -8 | tr '\n' ' ')"
  fi

  # The Claude environment must be exported, including CLAUDE_ENV_FILE.
  cat > "$H/env-probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
: "${CLAUDE_PLUGIN_ROOT:?missing}" "${CLAUDE_PROJECT_DIR:?missing}" "${CLAUDE_ENV_FILE:?missing}"
printf 'export PROBE_RAN=1\n' >> "$CLAUDE_ENV_FILE"
exit 0
EOF
  chmod +x "$H/env-probe.sh"
  run_sut --event SessionStart --plugin-root "$TMP_ROOT" --project-dir "$TMP_ROOT" -- bash "$H/env-probe.sh"
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'export PROBE_RAN=1'; then
    pass "CLAUDE_PLUGIN_ROOT / CLAUDE_PROJECT_DIR / CLAUDE_ENV_FILE are exported, and the env file is shown"
  else
    fail "the Claude environment was not set up (rc=$RC): $(printf '%s' "$OUT" | tail -6 | tr '\n' ' ')"
  fi

  # --- planted defects -------------------------------------------------------------------

  cat > "$H/slow.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
sleep 20
exit 0
EOF
  chmod +x "$H/slow.sh"
  run_sut --event PreToolUse --timeout 1 -- bash "$H/slow.sh"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -Fq 'TIMED OUT'; then
    pass "a hook that overruns its timeout is reported as timed out and fails the run"
  else
    fail "a 20s hook under --timeout 1 must time out (rc=$RC): $(printf '%s' "$OUT" | head -8 | tr '\n' ' ')"
  fi

  cat > "$H/wrong-code.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 3
EOF
  chmod +x "$H/wrong-code.sh"
  run_sut --event PreToolUse -- bash "$H/wrong-code.sh"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -Fq 'outside the protocol'; then
    pass "an exit code outside {0,1,2} fails the run and is named"
  else
    fail "exit 3 must fail the run (rc=$RC): $(printf '%s' "$OUT" | head -8 | tr '\n' ' ')"
  fi

  # The nastiest of the three: a decision object that does not parse is not an error at
  # runtime, it is ignored. The hook silently decides nothing.
  cat > "$H/half-json.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput": {"permissionDecision": "deny"\n'
exit 0
EOF
  chmod +x "$H/half-json.sh"
  run_sut --event PreToolUse -- bash "$H/half-json.sh"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -Fq 'does not parse'; then
    pass "unparseable JSON on the decision channel fails the run"
  else
    fail "a malformed decision object must fail the run (rc=$RC): $(printf '%s' "$OUT" | tail -8 | tr '\n' ' ')"
  fi

  # A well-formed decision is read back and its permissionDecision surfaced.
  cat > "$H/deny.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}\n'
exit 0
EOF
  chmod +x "$H/deny.sh"
  run_sut --event PreToolUse -- bash "$H/deny.sh"
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'permissionDecision: deny'; then
    pass "a well-formed decision object is parsed and its permissionDecision reported"
  else
    fail "the decision object was not surfaced (rc=$RC): $(printf '%s' "$OUT" | tail -8 | tr '\n' ' ')"
  fi

  # --command goes through a shell, the way Claude Code runs a command hook.
  run_sut --event PreToolUse --command 'cat >/dev/null; printf "via-shell\n"; exit 0'
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'via-shell'; then
    pass "--command runs the hook string through a shell"
  else
    fail "--command did not run (rc=$RC): $(printf '%s' "$OUT" | tail -5 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------------------
# 3. Missing dependency is a skip, never a pass.
# ---------------------------------------------------------------------------------------

EMPTY_BIN="$TMP_ROOT/emptybin"; mkdir -p "$EMPTY_BIN"
if [ -z "$BASH_BIN" ]; then
  skip "bash not on PATH — cannot run the stripped-PATH case"
else
  OUT="$(PATH="$EMPTY_BIN" "$BASH_BIN" "$SUT" --event PreToolUse --print-payload 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -Fq 'jq is required'; then
    pass "without jq the runner refuses (exit 2) rather than emitting a hand-built payload"
  else
    fail "a missing jq must exit 2 with a clear message (rc=$RC): $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"
  fi
fi

# ---------------------------------------------------------------------------------------
# 4. Calibration: drive the real dev-guardrails hooks, one per event they register.
#
# These are correct and well-tested. If the runner cannot drive them cleanly, the runner is
# wrong — not the hooks.
# ---------------------------------------------------------------------------------------

if ! command -v node >/dev/null 2>&1; then
  skip "node is not installed — cannot drive the dev-guardrails hooks"
elif [ ! -d "$DG/hooks/src" ]; then
  skip "dev-guardrails hooks not found — cannot run the calibration cases"
else
  drive() { # <event> <file> [extra...]
    ev="$1"; hookfile="$2"; shift 2
    if [ ! -f "$DG/hooks/src/$hookfile" ]; then
      skip "$ev -> $hookfile (not found)"
      return
    fi
    run_sut --event "$ev" "$@" --plugin-root "$DG" -- \
      node --experimental-strip-types --disable-warning=ExperimentalWarning "$DG/hooks/src/$hookfile"
    if [ "$RC" -eq 0 ]; then
      pass "drives dev-guardrails $hookfile on $ev"
    else
      fail "dev-guardrails $hookfile on $ev came back non-zero (rc=$RC): $(printf '%s' "$OUT" | sed -n '6,12p' | tr '\n' ' ')"
    fi
  }
  drive SessionStart      session-start.ts
  drive UserPromptSubmit  user-prompt-submit.ts
  drive PreCompact        post-compact.ts
  drive Stop              stop.ts
  drive PreToolUse        pre-bash.ts --tool Bash
  drive PostToolUse       post-bash.ts --tool Bash

  # And the gate actually fires on the payload the runner builds — proof the fixture is
  # realistic enough to exercise real logic, not just to survive it.
  #
  # `rm -rf /` is a catastrophic target, which dev-guardrails blocks (exit 2) on every
  # platform with no escape marker (see pre-bash/rm-rf.ts). A silent exit 0 would mean the
  # payload never reached the gate.
  run_sut --event PreToolUse --tool Bash --set 'tool_input={"command":"rm -rf /"}' --plugin-root "$DG" -- \
    node --experimental-strip-types --disable-warning=ExperimentalWarning "$DG/hooks/src/pre-bash.ts"
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Fq 'exit code  2'; then
    pass "a --set payload drives dev-guardrails' rm -rf gate to an actual block"
  else
    fail "pre-bash.ts should have blocked 'rm -rf /' (rc=$RC): $(printf '%s' "$OUT" | sed -n '6,12p' | tr '\n' ' ')"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
