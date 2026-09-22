#!/usr/bin/env bash
# run-hook-event.sh — run a hook against a synthetic event, the way Claude Code would.
#
# Builds a realistic stdin payload for a named hook event, exports the Claude environment
# variables, pipes the payload to the hook under a wall-clock timeout, and reports the exit
# code alongside whatever the hook put on stdout (the decision channel) and stderr (the
# feedback channel) — kept apart, because the whole protocol lives in that distinction.
#
#   bash run-hook-event.sh --event PreToolUse --tool Bash -- node hooks/src/pre-bash.ts
#   bash run-hook-event.sh --event PostToolUse --tool Write --command 'node "$X/post.ts"'
#   bash run-hook-event.sh --event UserPromptSubmit --print-payload
#
# Exit: 0 the hook ran and returned a code the protocol defines (0/1/2)
#       1 the hook timed out, returned an undefined code, or emitted unparseable JSON
#       2 misconfigured (bad usage, missing dependency)
#
# ---------------------------------------------------------------------------------------
# WHERE THE PAYLOAD SHAPES COME FROM
#
# Not from the donor script. Its field names are wrong in two places that matter, and both
# are the silent kind:
#
#   * it emits `tool_result` on PostToolUse. The real hook-input field is `tool_response`.
#     dev-guardrails states this twice in its own source — hooks/src/lib/types.ts and
#     hooks/src/post-mcp-tool.ts:162 — for the reason that reading `tool_result` "yields
#     undefined forever while looking like it works". A fixture carrying the wrong name
#     tests a hook against input it will never see.
#   * it emits `user_prompt` on UserPromptSubmit. The real field is `prompt`
#     (hooks/src/user-prompt-submit.ts:39, exercised by session-start.test.ts:88).
#
# It also mislabels its own SessionEnd sample as `"hook_event_name": "SessionStart"`, and
# has no PreCompact branch at all while its sibling validator accepts the event.
#
# Every field below is grounded, in order of preference, in: this repo's dev-guardrails
# hooks and their 376 passing tests; then claude-craft's own deterministic-enforcement
# skill. Fields carrying neither grounding are marked `[docs only]` in the comments and can
# be overridden with --set.
# ---------------------------------------------------------------------------------------

set -euo pipefail

# Resolve our own directory WITHOUT `dirname`. The missing-jq test strips PATH to
# prove these tools degrade cleanly, and an external dirname would die first — the
# script would fail for a reason that has nothing to do with the dependency it is
# reporting on. `cd` and `pwd` are builtins and survive an empty PATH.
__self="${BASH_SOURCE[0]:-$0}"
case "$__self" in */*) __self_dir="${__self%/*}" ;; *) __self_dir="." ;; esac
SELF_DIR="$(cd "$__self_dir" && pwd)"
unset __self __self_dir
# shellcheck source=_hooklib.sh
. "$SELF_DIR/_hooklib.sh"

usage() {
  cat <<'USAGE'
Usage: run-hook-event.sh --event <Event> [options] (-- <argv...> | --command '<shell string>')

Events with a generated payload:
  PreToolUse  PostToolUse  UserPromptSubmit  SessionStart  SessionEnd
  PreCompact  PostCompact  Stop  SubagentStop  Notification

Options:
  --event NAME         Hook event to simulate. Required.
  --tool NAME          Tool name for the Pre/PostToolUse payload (default: Bash).
                       Known shapes: Bash, Write, Edit, Read, TodoWrite, Agent, mcp__*.
  --set key=json       Override or add one top-level payload field. The value is parsed as
                       JSON, falling back to a string. Repeatable.
  --payload FILE       Use FILE as the stdin payload verbatim instead of generating one.
  --print-payload      Print the payload and exit without running anything.
  --timeout N          Wall-clock ceiling in seconds (default: 60, the platform default for
                       command hooks).
  --plugin-root DIR    Value for CLAUDE_PLUGIN_ROOT (default: the current directory).
  --project-dir DIR    Value for CLAUDE_PROJECT_DIR (default: the current directory).
  --command 'STR'      Run STR through `bash -c`, the way Claude Code runs a command hook.
                       Mutually exclusive with `-- argv...`.
  -h, --help           This message.

Everything after `--` is the hook's argv, executed directly with no shell in between.
USAGE
}

EVENT=""
TOOL="Bash"
TIMEOUT=60
PAYLOAD_FILE=""
PRINT_ONLY=0
PLUGIN_ROOT=""
PROJECT_DIR=""
SHELL_COMMAND=""
SETS=""            # newline-separated key=json overrides
HAVE_ARGV=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --event)        [ $# -ge 2 ] || hl_die "--event needs a value";        EVENT="$2"; shift 2 ;;
    --tool)         [ $# -ge 2 ] || hl_die "--tool needs a value";         TOOL="$2"; shift 2 ;;
    --timeout)      [ $# -ge 2 ] || hl_die "--timeout needs a value";      TIMEOUT="$2"; shift 2 ;;
    --payload)      [ $# -ge 2 ] || hl_die "--payload needs a file";       PAYLOAD_FILE="$2"; shift 2 ;;
    --plugin-root)  [ $# -ge 2 ] || hl_die "--plugin-root needs a dir";    PLUGIN_ROOT="$2"; shift 2 ;;
    --project-dir)  [ $# -ge 2 ] || hl_die "--project-dir needs a dir";    PROJECT_DIR="$2"; shift 2 ;;
    --command)      [ $# -ge 2 ] || hl_die "--command needs a string";     SHELL_COMMAND="$2"; shift 2 ;;
    --set)
      [ $# -ge 2 ] || hl_die "--set needs key=value"
      case "$2" in *=*) ;; *) hl_die "--set expects key=value, got: $2" ;; esac
      SETS="${SETS}$2
"
      shift 2 ;;
    --print-payload) PRINT_ONLY=1; shift ;;
    --) shift; HAVE_ARGV=1; break ;;
    -*) hl_die "unknown option: $1" ;;
    *)  hl_die "unexpected argument '$1' — the hook command goes after '--'" ;;
  esac
done

[ -n "$EVENT" ] || { usage >&2; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) hl_die "--timeout must be a whole number of seconds" ;; esac
[ "$TIMEOUT" -gt 0 ] || hl_die "--timeout must be positive"

if [ -n "$SHELL_COMMAND" ] && [ "$HAVE_ARGV" -eq 1 ] && [ $# -gt 0 ]; then
  hl_die "use either --command '<shell string>' or '-- <argv...>', not both"
fi

hl_require_jq

PLUGIN_ROOT="${PLUGIN_ROOT:-$(pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-hook-event.XXXXXX")"
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------------------
# Tool-specific `tool_input`.
#
# Shapes taken from dev-guardrails hooks/src/lib/types.ts (the HookInput.tool_input union)
# and from the fixtures its tests actually feed the hooks.
# ---------------------------------------------------------------------------------------
tool_input_json() {
  case "$1" in
    Bash)      printf '{"command":"git status --short","description":"check the tree"}' ;;
    Write)     printf '{"file_path":"src/example.ts","content":"export const PORT = 8080;\\n"}' ;;
    Edit)      printf '{"file_path":"src/example.ts","old_string":"8080","new_string":"9090"}' ;;
    Read)      printf '{"file_path":"src/example.ts"}' ;;
    TodoWrite) printf '{"todos":[{"content":"wire the gate","status":"in_progress"},{"content":"write its test","status":"pending"}]}' ;;
    Agent)     printf '{"description":"Review the diff","subagent_type":"code-reviewer","prompt":"review the staged change"}' ;;
    mcp__*)    printf '{"description":"adds the deploy step"}' ;;
    *)         printf '{}' ;;
  esac
}

# ---------------------------------------------------------------------------------------
# Tool-specific `tool_response` — the PostToolUse result field.
#
# Bash's shape is exact and must stay exact: dev-guardrails' post-bash.test.ts asserts the
# key set is exactly {stdout, stderr, interrupted, isImage} because "an updatedToolOutput
# that does not match it EXACTLY is discarded by Claude Code and the original output is
# kept — silently" (lib/types.ts). A fixture with a looser shape would let a hook pass here
# and be discarded in production.
# ---------------------------------------------------------------------------------------
tool_response_json() {
  case "$1" in
    Bash)   printf '{"stdout":"M  src/example.ts\\n","stderr":"","interrupted":false,"isImage":false}' ;;
    Write|Edit) printf '{"filePath":"src/example.ts","success":true}' ;;
    Agent)  printf '{"output":"reviewed 3 files"}' ;;
    mcp__*) printf '{"web_url":"https://example.com/mr/1"}' ;;
    *)      printf '{"output":"ok"}' ;;
  esac
}

build_payload() {
  ev="$1"
  # The five common fields, present on every event.
  base="$(jq -n \
    --arg sid "test-session-0000" \
    --arg tp "$TMP_ROOT/transcript.jsonl" \
    --arg cwd "$PROJECT_DIR" \
    --arg pm "default" \
    --arg ev "$ev" \
    '{session_id:$sid, transcript_path:$tp, cwd:$cwd, permission_mode:$pm, hook_event_name:$ev}')"

  case "$ev" in
    PreToolUse)
      base="$(printf '%s' "$base" | jq --arg t "$TOOL" --argjson ti "$(tool_input_json "$TOOL")" \
        '. + {tool_name:$t, tool_input:$ti}')" ;;
    PostToolUse)
      # tool_response. NOT tool_result — see the header.
      base="$(printf '%s' "$base" | jq --arg t "$TOOL" \
        --argjson ti "$(tool_input_json "$TOOL")" \
        --argjson tr "$(tool_response_json "$TOOL")" \
        '. + {tool_name:$t, tool_input:$ti, tool_response:$tr}')" ;;
    UserPromptSubmit)
      # `prompt`. NOT user_prompt — see the header.
      base="$(printf '%s' "$base" | jq '. + {prompt:"add a retry around the upload call"}')" ;;
    SessionStart)
      # `source` is [docs only] — no hook in this repo reads it; dev-guardrails' session
      # hooks are fed `{}` by their own tests. Override with --set if your build differs.
      base="$(printf '%s' "$base" | jq '. + {source:"startup"}')" ;;
    SessionEnd)
      # The donor labelled this branch SessionStart. It is SessionEnd.
      base="$(printf '%s' "$base" | jq '. + {reason:"exit"}')" ;;
    PreCompact|PostCompact)
      base="$(printf '%s' "$base" | jq '. + {trigger:"auto", custom_instructions:""}')" ;;
    Stop|SubagentStop)
      # `stop_hook_active` guards the re-entry loop: a Stop hook that blocks is re-entered
      # with this true, and a hook that ignores it can hang a turn indefinitely. [docs only]
      # as a field name, but the behaviour it guards is real, so it belongs in the fixture.
      base="$(printf '%s' "$base" | jq '. + {stop_hook_active:false}')" ;;
    Notification)
      base="$(printf '%s' "$base" | jq '. + {message:"Claude needs your permission to use Bash"}')" ;;
    *)
      printf 'unknown --event: %s\n' "$ev" >&2
      printf 'Known events with a generated payload: PreToolUse PostToolUse UserPromptSubmit SessionStart SessionEnd PreCompact PostCompact Stop SubagentStop Notification\n' >&2
      printf 'For any other event, supply the payload yourself with --payload FILE.\n' >&2
      exit 2 ;;
  esac

  # --set overrides, applied last. The value is parsed as JSON when it parses, and used as a
  # plain string when it does not, so `--set permission_mode=plan` and
  # `--set tool_input={"command":"ls"}` both do what they look like.
  if [ -n "$SETS" ]; then
    while IFS= read -r kv; do
      [ -n "$kv" ] || continue
      k="${kv%%=*}"
      v="${kv#*=}"
      if printf '%s' "$v" | jq empty >/dev/null 2>&1; then
        base="$(printf '%s' "$base" | jq --arg k "$k" --argjson v "$v" '.[$k] = $v')"
      else
        base="$(printf '%s' "$base" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')"
      fi
    done <<EOF
$SETS
EOF
  fi

  printf '%s\n' "$base"
}

PAYLOAD="$TMP_ROOT/payload.json"
if [ -n "$PAYLOAD_FILE" ]; then
  [ -f "$PAYLOAD_FILE" ] || hl_die "payload file not found: $PAYLOAD_FILE"
  jq empty "$PAYLOAD_FILE" >/dev/null 2>&1 || hl_die "payload file is not valid JSON: $PAYLOAD_FILE"
  cat "$PAYLOAD_FILE" > "$PAYLOAD"
else
  build_payload "$EVENT" > "$PAYLOAD"
fi

if [ "$PRINT_ONLY" -eq 1 ]; then
  jq . "$PAYLOAD"
  exit 0
fi

if [ -z "$SHELL_COMMAND" ] && [ $# -eq 0 ]; then
  printf 'nothing to run: pass the hook after `--`, or use --command, or use --print-payload\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------------------
# Environment. CLAUDE_ENV_FILE is SessionStart-only in the platform; it is exported here for
# every event so a hook that writes to it unconditionally is caught rather than crashing on
# an unset variable.
# ---------------------------------------------------------------------------------------
ENV_FILE="$TMP_ROOT/claude-env"
: > "$ENV_FILE"
export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLAUDE_ENV_FILE="$ENV_FILE"

OUT="$TMP_ROOT/stdout"
ERR="$TMP_ROOT/stderr"

printf 'event      %s\n' "$EVENT"
case "$EVENT" in PreToolUse|PostToolUse) printf 'tool       %s\n' "$TOOL" ;; esac
printf 'timeout    %ss\n' "$TIMEOUT"
printf 'plugin     CLAUDE_PLUGIN_ROOT=%s\n' "$CLAUDE_PLUGIN_ROOT"
printf 'project    CLAUDE_PROJECT_DIR=%s\n' "$CLAUDE_PROJECT_DIR"
printf '\n'

START="$(date +%s)"
if [ -n "$SHELL_COMMAND" ]; then
  # A command hook IS a shell string in hooks.json, and Claude Code runs it through a shell.
  # It is passed as one argv element to `bash -c` — never concatenated into a larger string
  # that is then re-evaluated.
  CODE="$(hl_run_with_timeout "$TIMEOUT" "$PAYLOAD" "$OUT" "$ERR" bash -c "$SHELL_COMMAND")"
else
  CODE="$(hl_run_with_timeout "$TIMEOUT" "$PAYLOAD" "$OUT" "$ERR" "$@")"
fi
END="$(date +%s)"

printf 'exit code  %s   (%ss)\n' "$CODE" "$((END - START))"

# ---------------------------------------------------------------------------------------
# Exit-code legend, per deterministic-enforcement §4. The donor's legend said "0 = approved,
# 2 = blocked, other = unexpected", which omits the two facts that decide how a hook is read:
# JSON on stdout is parsed on EVERY exit code, and PostToolUse cannot block on any of them.
# ---------------------------------------------------------------------------------------
case "$CODE" in
  0)   printf '           0 = allow / no objection.\n' ;;
  1)   printf '           1 = non-blocking. stderr is shown to the user, not fed back to the model.\n' ;;
  2)   if [ "$EVENT" = "PostToolUse" ]; then
         printf '           2 on PostToolUse does NOT block — the tool already ran. The reason is attached\n'
         printf '           as feedback beside the result and the model still sees the original output.\n'
       else
         printf '           2 = block. stderr is fed back to the model as the reason.\n'
       fi ;;
  124) printf '           124 = TIMED OUT after %ss. A hook that times out looks, from the outside,\n' "$TIMEOUT"
       printf '           exactly like a hook that passed.\n' ;;
  *)   printf '           %s is outside the protocol: not 0, 1, or 2. Most events treat it as\n' "$CODE"
       printf '           non-blocking and continue, so this is a failure that does not announce itself.\n' ;;
esac

VERDICT=0
[ "$CODE" = "124" ] && VERDICT=1
case "$CODE" in 0|1|2|124) ;; *) VERDICT=1 ;; esac

# --- stdout: the decision channel -----------------------------------------------------------
printf '\n--- stdout (decision channel; JSON here is parsed on every exit code) ---\n'
if [ -s "$OUT" ]; then
  if jq empty "$OUT" >/dev/null 2>&1; then
    jq . "$OUT"
    DEC="$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$OUT")"
    [ -n "$DEC" ] && printf '\n           permissionDecision: %s\n' "$DEC"
    TOP="$(jq -r 'if has("decision") then .decision else empty end' "$OUT")"
    if [ -n "$TOP" ] && [ "$EVENT" = "PreToolUse" ]; then
      printf '           NOTE: top-level `decision` is deprecated for PreToolUse. Use hookSpecificOutput.\n'
    fi
  else
    cat "$OUT"
    # A hook that starts writing JSON and does not finish is the worst case: the platform
    # cannot parse it, so the decision silently does not apply and the text is used as
    # context instead.
    case "$(head -c 1 "$OUT")" in
      '{'|'[')
        printf '\n'
        hl_err "stdout" "output starts like JSON but does not parse. A malformed decision object is not an error at runtime — it is ignored, and the hook silently decides nothing."
        VERDICT=1 ;;
      *) printf '\n           (plain text — treated as context, not as a decision)\n' ;;
    esac
  fi
else
  printf '(empty)\n'
fi

# --- stderr: the feedback channel -----------------------------------------------------------
printf '\n--- stderr (feedback channel; fed back to the model on exit 2) ---\n'
if [ -s "$ERR" ]; then cat "$ERR"; else printf '(empty)\n'; fi

# --- CLAUDE_ENV_FILE --------------------------------------------------------------------------
if [ -s "$ENV_FILE" ]; then
  printf '\n--- CLAUDE_ENV_FILE (exports persisted into the session) ---\n'
  cat "$ENV_FILE"
fi

printf '\n'
exit "$VERDICT"
