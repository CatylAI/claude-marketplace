#!/usr/bin/env bash
# _hooklib.sh — shared helpers for the three hook-tooling scripts in this directory.
#
# Sourced, never executed. Portable bash 3.2 (the macOS default) and zsh 5:
#   - no `mapfile`/`readarray`, no `declare -A`, no `${var^^}`
#   - no indexed array reads (zsh arrays are 1-based; bash arrays are 0-based, and code
#     that reads `${a[0]}` is silently wrong in one of the two shells)
#   - no `[[ =~ ]]` (the regex dialects differ); `grep -E` or `case` globs instead
#   - no bare `((n++))` as a statement — it returns 1 when the result is 0, which kills
#     the script under `set -e`. Always `n=$((n + 1))`.
#
# Exit-code convention, shared by all three scripts and matching scripts/check-*.sh at the
# repo root:  0 = clean · 1 = findings · 2 = misconfigured (bad usage, missing dependency).

# ---------------------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------------------

HL_ERRORS=0
HL_WARNINGS=0

hl_err() {  # <location> <message>
  HL_ERRORS=$((HL_ERRORS + 1))
  printf 'ERROR  %s: %s\n' "$1" "$2" >&2
}

hl_warn() { # <location> <message>
  HL_WARNINGS=$((HL_WARNINGS + 1))
  printf 'WARN   %s: %s\n' "$1" "$2" >&2
}

hl_note() { # <location> <message>
  printf 'note   %s: %s\n' "$1" "$2"
}

hl_die() { # <message> — misconfiguration, not a finding
  printf '%s\n' "$1" >&2
  exit 2
}

# ---------------------------------------------------------------------------------------
# Dependencies
#
# `jq` is required, not optional. Parsing JSON with sed/grep is how a validator ends up
# reporting success on a document it never understood — which is the exact defect this
# directory exists to have fixed. Fail loudly instead.
# ---------------------------------------------------------------------------------------

hl_require_jq() {
  command -v jq >/dev/null 2>&1 || hl_die \
"jq is required and was not found on PATH.

  macOS:  brew install jq
  Debian: apt-get install jq

This tool will not fall back to parsing JSON with sed or grep: a JSON \"validator\"
built on line matching reports success on documents it never understood, which is
the class of defect this tool exists to catch."
}

# ---------------------------------------------------------------------------------------
# Portable timeout
#
# `timeout` is a GNU coreutils program. macOS ships without it unless coreutils is
# installed, so a hook runner that assumes it works on the maintainer's Linux box and
# silently does not exist on the reviewer's laptop is not a runner. Prefer the real thing,
# fall back to a poll loop.
#
# Usage: hl_run_with_timeout <seconds> <stdin-file> <stdout-file> <stderr-file> <cmd> [args...]
# Echoes the exit status on stdout. 124 means "timed out", matching coreutils.
# ---------------------------------------------------------------------------------------

hl_run_with_timeout() {
  hl_to_secs="$1"; hl_to_in="$2"; hl_to_out="$3"; hl_to_errf="$4"
  shift 4

  if command -v timeout >/dev/null 2>&1; then
    hl_to_rc=0
    timeout "$hl_to_secs" "$@" <"$hl_to_in" >"$hl_to_out" 2>"$hl_to_errf" || hl_to_rc=$?
    printf '%s\n' "$hl_to_rc"
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    hl_to_rc=0
    gtimeout "$hl_to_secs" "$@" <"$hl_to_in" >"$hl_to_out" 2>"$hl_to_errf" || hl_to_rc=$?
    printf '%s\n' "$hl_to_rc"
    return 0
  fi

  # Fallback: background the child, poll, kill on deadline. Deliberately coarse (0.2s);
  # this measures a wall-clock ceiling, not a benchmark.
  "$@" <"$hl_to_in" >"$hl_to_out" 2>"$hl_to_errf" &
  hl_to_pid=$!
  hl_to_waited=0
  hl_to_limit=$(( hl_to_secs * 5 ))   # 0.2s ticks
  while [ "$hl_to_waited" -lt "$hl_to_limit" ]; do
    kill -0 "$hl_to_pid" 2>/dev/null || break
    sleep 0.2
    hl_to_waited=$((hl_to_waited + 1))
  done
  if kill -0 "$hl_to_pid" 2>/dev/null; then
    kill -TERM "$hl_to_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$hl_to_pid" 2>/dev/null || true
    wait "$hl_to_pid" 2>/dev/null || true
    printf '124\n'
    return 0
  fi
  hl_to_rc=0
  wait "$hl_to_pid" || hl_to_rc=$?
  printf '%s\n' "$hl_to_rc"
}

# ---------------------------------------------------------------------------------------
# The event surface.
#
# Sourced from claude-craft's own `deterministic-enforcement` skill (§4), which is the
# in-repo authority and lists roughly thirty events. The donor script this one replaces
# knew nine, so a correct registration for `PostCompact` or `SubagentStart` was reported
# as an unknown event.
#
# `deterministic-enforcement` also notes availability varies by SDK and version — hence
# --allow-unknown-events on the validator rather than pretending this list is closed.
# ---------------------------------------------------------------------------------------

HL_EVENTS='SessionStart
Setup
SessionEnd
UserPromptSubmit
UserPromptExpansion
PreToolUse
PermissionRequest
PermissionDenied
PostToolUse
PostToolUseFailure
PostToolBatch
SubagentStart
SubagentStop
TaskCreated
TaskCompleted
Stop
StopFailure
TeammateIdle
ConfigChange
CwdChanged
DirectoryAdded
FileChanged
PreCompact
PostCompact
Notification'

# Events that carry a tool and therefore take a matcher. A matcher on any other event is
# accepted by the platform and ignored, which makes it a silent no-op worth naming.
HL_TOOL_EVENTS='PreToolUse
PostToolUse
PermissionRequest
PermissionDenied
PostToolUseFailure
PostToolBatch'

# Events the hooks reference documents as having NO matcher support: a matcher there is
# accepted and ignored. Every other event filters on something — a tool name, or a
# per-event field such as SessionStart's source (startup|resume|clear|compact|fork) or
# PreCompact's trigger (manual|auto) — so a matcher on those is a real filter.
HL_NO_MATCHER_EVENTS='UserPromptSubmit
PostToolBatch
Stop
TeammateIdle
TaskCreated
TaskCompleted
WorktreeCreate
WorktreeRemove
MessageDisplay
CwdChanged'

# `deterministic-enforcement` §4: five hook types, where the donor knew two.
HL_HOOK_TYPES='command
http
mcp_tool
prompt
agent'

# Exact whole-line membership. `grep -Fxq` and not a loop: a loop inside a pipeline runs in
# a subshell in bash, so a flag set inside it is lost on the way out — a portability trap
# that reads as working code.
hl_in_list() { # <needle> <newline-separated-haystack>
  printf '%s\n' "$2" | grep -Fxq -- "$1"
}
