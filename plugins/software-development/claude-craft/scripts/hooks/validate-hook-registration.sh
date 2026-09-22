#!/usr/bin/env bash
# validate-hook-registration.sh — validate a plugin `hooks.json` (or a settings hook block).
#
# Checks event names, entry shape, matcher syntax, hook type, command shape, and timeouts,
# and — with --plugin-root — that every registered command actually points at a file that
# exists.
#
#   bash validate-hook-registration.sh <hooks.json> [--plugin-root DIR] [--allow-unknown-events]
#
# Exit: 0 clean (warnings allowed) · 1 errors found · 2 misconfigured.
#
# ---------------------------------------------------------------------------------------
# THE DEFECT THIS SCRIPT EXISTS TO NOT HAVE
#
# The donor script (plugin-dev's `validate-hook-schema.sh`) read event names from the
# DOCUMENT ROOT:
#
#     for event in $(jq -r 'keys[]' "$HOOKS_FILE"); do
#
# A plugin `hooks.json` is wrapped: `{"hooks": {"PreToolUse": [...]}}`. Against that shape
# the only key at the root is the literal string `hooks`, which the donor downgraded to
# `⚠️  Unknown event type: hooks` and then tried to index as an array. Measured against
# this repo's own dev-guardrails package:
#
#     $ bash validate-hook-schema.sh dev-guardrails/hooks/hooks.json
#     ⚠️  Unknown event type: hooks
#     ✅ Root structure valid
#     jq: error: Cannot index object with number        <- exit 5
#
# and against `{"hooks": {}}` it printed `✅ All checks passed!` and exited 0. Either way
# it inspected zero registrations. A validator that reports on nothing is worse than no
# validator, because it is counted as coverage — so this one reports the number of events,
# entries and hooks it actually descended into, and its test suite asserts that number is
# non-zero on a document it passes.
#
# Both shapes are accepted here: the wrapped form that plugin `hooks.json` uses, and the
# bare event map that a settings `"hooks"` VALUE is. The wrapper is detected, never assumed.
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
Usage: validate-hook-registration.sh <hooks.json> [options]

Options:
  --plugin-root DIR        Resolve ${CLAUDE_PLUGIN_ROOT} in command strings against DIR and
                           check the target file exists. Without it, command targets are
                           not resolved (shape is still checked).
  --allow-unknown-events   Downgrade an unrecognised event name from error to warning. The
                           hook event surface varies by SDK and version; use this when
                           registering an event newer than this script.
  -h, --help               This message.

Exit: 0 clean (warnings allowed) · 1 errors found · 2 misconfigured.
USAGE
}

HOOKS_FILE=""
PLUGIN_ROOT=""
ALLOW_UNKNOWN=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --plugin-root)
      [ $# -ge 2 ] || hl_die "--plugin-root needs a directory"
      PLUGIN_ROOT="$2"; shift 2 ;;
    --allow-unknown-events) ALLOW_UNKNOWN=1; shift ;;
    --) shift ;;
    -*) hl_die "unknown option: $1" ;;
    *)
      [ -z "$HOOKS_FILE" ] || hl_die "only one hooks file at a time (got '$HOOKS_FILE' and '$1')"
      HOOKS_FILE="$1"; shift ;;
  esac
done

[ -n "$HOOKS_FILE" ] || { usage >&2; exit 2; }
[ -f "$HOOKS_FILE" ] || hl_die "file not found: $HOOKS_FILE"
[ -z "$PLUGIN_ROOT" ] || [ -d "$PLUGIN_ROOT" ] || hl_die "--plugin-root is not a directory: $PLUGIN_ROOT"

hl_require_jq

jq empty "$HOOKS_FILE" >/dev/null 2>&1 || hl_die "not valid JSON: $HOOKS_FILE"

# --- Locate the event map ------------------------------------------------------------------
# `.hooks` when the document is wrapped, the root otherwise. This is the fix.

ROOT_KIND="$(jq -r 'type' "$HOOKS_FILE")"
[ "$ROOT_KIND" = "object" ] || hl_die "the document root must be a JSON object, got: $ROOT_KIND"

if jq -e 'has("hooks") and (.hooks | type == "object")' "$HOOKS_FILE" >/dev/null 2>&1; then
  BASE='.hooks'
  WRAPPED=1
else
  BASE='.'
  WRAPPED=0
fi

# A wrapped document with keys BESIDE `hooks` is a settings-shaped file, not a hooks.json.
# Those extra keys are not events and must not be walked as if they were.
if [ "$WRAPPED" -eq 1 ]; then
  EXTRA="$(jq -r 'keys_unsorted[] | select(. != "hooks")' "$HOOKS_FILE" | tr '\n' ' ')"
  if [ -n "$(printf '%s' "$EXTRA" | tr -d ' ')" ]; then
    hl_note "$HOOKS_FILE" "reading the .hooks block; ignoring sibling keys: $EXTRA"
  fi
else
  hl_warn "$HOOKS_FILE" "no top-level \"hooks\" wrapper — reading the root as an event map. A plugin hooks.json should be {\"hooks\": {...}}."
fi

EVENTS="$(jq -r "$BASE | keys_unsorted[]" "$HOOKS_FILE")"
if [ -z "$EVENTS" ]; then
  hl_err "$HOOKS_FILE" "the event map is empty — this file registers no hooks at all"
fi

N_EVENTS=0
N_ENTRIES=0
N_HOOKS=0

# Characters that keep a matcher in LITERAL mode, per deterministic-enforcement §4:
# letters, digits, underscore, hyphen, space, comma, pipe. Anything else silently turns
# the matcher into an unanchored JavaScript regex.
LITERAL_MATCHER_RE='^[A-Za-z0-9_ ,|-]*$'

while IFS= read -r event; do
  [ -n "$event" ] || continue
  N_EVENTS=$((N_EVENTS + 1))

  if ! hl_in_list "$event" "$HL_EVENTS"; then
    if [ "$ALLOW_UNKNOWN" -eq 1 ]; then
      hl_warn "$HOOKS_FILE [$event]" "unrecognised event name (allowed by --allow-unknown-events)"
    else
      hl_err "$HOOKS_FILE [$event]" "unrecognised event name. An event key Claude Code does not know is ignored in silence, so the hook never runs and nothing reports it. Pass --allow-unknown-events if this event is newer than this script."
    fi
  fi

  etype="$(jq -r --arg e "$event" "$BASE[\$e] | type" "$HOOKS_FILE")"
  if [ "$etype" != "array" ]; then
    hl_err "$HOOKS_FILE [$event]" "must be an array of entries, got: $etype"
    continue
  fi

  n_entries="$(jq -r --arg e "$event" "$BASE[\$e] | length" "$HOOKS_FILE")"
  if [ "$n_entries" -eq 0 ]; then
    hl_warn "$HOOKS_FILE [$event]" "registered with an empty array — the event key is dead weight"
    continue
  fi

  i=0
  while [ "$i" -lt "$n_entries" ]; do
    loc="$HOOKS_FILE [$event][$i]"
    N_ENTRIES=$((N_ENTRIES + 1))

    entry_type="$(jq -r --arg e "$event" --argjson i "$i" "$BASE[\$e][\$i] | type" "$HOOKS_FILE")"
    if [ "$entry_type" != "object" ]; then
      hl_err "$loc" "entry must be an object, got: $entry_type"
      i=$((i + 1)); continue
    fi

    # --- matcher ---------------------------------------------------------------------------
    # The donor treated a MISSING matcher as a hard error. That is wrong, and this repo has
    # four counter-examples: dev-guardrails registers SessionStart, UserPromptSubmit,
    # PreCompact and Stop with no matcher, correctly — an omitted, empty, or "*" matcher
    # matches everything.
    has_matcher="$(jq -r --arg e "$event" --argjson i "$i" "$BASE[\$e][\$i] | has(\"matcher\")" "$HOOKS_FILE")"
    if [ "$has_matcher" = "true" ]; then
      m_type="$(jq -r --arg e "$event" --argjson i "$i" "$BASE[\$e][\$i].matcher | type" "$HOOKS_FILE")"
      if [ "$m_type" != "string" ]; then
        hl_err "$loc" "matcher must be a string, got: $m_type"
      else
        matcher="$(jq -r --arg e "$event" --argjson i "$i" "$BASE[\$e][\$i].matcher" "$HOOKS_FILE")"
        if ! hl_in_list "$event" "$HL_TOOL_EVENTS"; then
          hl_warn "$loc" "matcher \"$matcher\" set on $event, which carries no tool name — it is accepted and then ignored, which reads as a filter that is not there"
        fi
        if [ -n "$matcher" ] && [ "$matcher" != "*" ]; then
          if printf '%s' "$matcher" | grep -Eq "$LITERAL_MATCHER_RE"; then
            : # literal mode: exact match, split on pipes and commas. Nothing to check.
          else
            # Regex mode. Confirm it at least compiles. Reported as a WARNING and not an
            # error on purpose: the platform compiles the matcher as a JavaScript regex and
            # this check is a POSIX ERE approximation, so constructs that are valid in JS
            # and not in ERE (`\d`, `(?:...)`) would otherwise be failed here wrongly. A
            # flagged matcher is worth a human look; it is not proof of a defect.
            if ! printf 'x' | grep -Eq -- "$matcher" 2>/dev/null; then
              if ! printf 'x' | grep -Eqv -- "$matcher" 2>/dev/null; then
                hl_warn "$loc" "matcher \"$matcher\" is in regex mode (it contains a character outside the literal set) and does not compile as a POSIX regex. Verify it is valid JavaScript regex syntax — an uncompilable matcher is a hook that never fires."
              fi
            fi
            # The trap deterministic-enforcement §4 names: a matcher that LOOKS literal but
            # contains one stray metacharacter, so `Notebook.Edit` quietly matches
            # `NotebookXEdit` too.
            if printf '%s' "$matcher" | grep -Eq '^[A-Za-z0-9_.-]+$' && printf '%s' "$matcher" | grep -Fq '.'; then
              hl_warn "$loc" "matcher \"$matcher\" contains '.' and nothing else regex-like, so it is an UNANCHORED regex where a literal was probably meant. Escape it or anchor it."
            fi
          fi
        fi
      fi
    fi

    # --- hooks array -----------------------------------------------------------------------
    h_type="$(jq -r --arg e "$event" --argjson i "$i" "$BASE[\$e][\$i].hooks | type" "$HOOKS_FILE")"
    if [ "$h_type" != "array" ]; then
      hl_err "$loc" "missing or malformed 'hooks' array (got: $h_type)"
      i=$((i + 1)); continue
    fi
    n_hooks="$(jq -r --arg e "$event" --argjson i "$i" "$BASE[\$e][\$i].hooks | length" "$HOOKS_FILE")"
    if [ "$n_hooks" -eq 0 ]; then
      hl_err "$loc" "'hooks' array is empty — this entry registers nothing"
      i=$((i + 1)); continue
    fi

    j=0
    while [ "$j" -lt "$n_hooks" ]; do
      hloc="$HOOKS_FILE [$event][$i].hooks[$j]"
      N_HOOKS=$((N_HOOKS + 1))
      q="$BASE[\$e][\$i].hooks[\$j]"

      htype="$(jq -r --arg e "$event" --argjson i "$i" --argjson j "$j" "$q.type // \"\"" "$HOOKS_FILE")"
      if [ -z "$htype" ]; then
        hl_err "$hloc" "missing 'type'"
      elif ! hl_in_list "$htype" "$HL_HOOK_TYPES"; then
        hl_err "$hloc" "invalid type '$htype' — must be one of: $(printf '%s' "$HL_HOOK_TYPES" | tr '\n' ' ')"
      fi

      case "$htype" in
        command)
          cmd="$(jq -r --arg e "$event" --argjson i "$i" --argjson j "$j" "$q.command // \"\"" "$HOOKS_FILE")"
          if [ -z "$cmd" ]; then
            hl_err "$hloc" "a command hook must carry a non-empty 'command'"
          else
            # A machine-local path in a shipped registration is a hook that runs on exactly
            # one laptop. Error, not warning.
            if printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9])/(Users|home)/[A-Za-z0-9._-]+/'; then
              hl_err "$hloc" "command contains a machine-local home directory — it will not resolve for anyone else"
            elif printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])/' && ! printf '%s' "$cmd" | grep -Fq 'CLAUDE_PLUGIN_ROOT' && ! printf '%s' "$cmd" | grep -Fq 'CLAUDE_PROJECT_DIR'; then
              hl_warn "$hloc" "command uses an absolute path but neither \${CLAUDE_PLUGIN_ROOT} nor \${CLAUDE_PROJECT_DIR}"
            fi
            if [ -n "$PLUGIN_ROOT" ] && printf '%s' "$cmd" | grep -Fq 'CLAUDE_PLUGIN_ROOT'; then
              # Resolve the plugin-root reference and confirm the target exists. This is the
              # "wired in settings, points at a missing script" finding, made mechanical.
              #
              # Substitution is done by the shell's own parameter expansion on a value we
              # control, never by re-evaluating the command string.
              resolved="$cmd"
              resolved="$(printf '%s' "$resolved" | sed -e "s#\${CLAUDE_PLUGIN_ROOT}#${PLUGIN_ROOT}#g" -e "s#\$CLAUDE_PLUGIN_ROOT#${PLUGIN_ROOT}#g")"
              target=""
              for word in $resolved; do
                case "$word" in
                  "$PLUGIN_ROOT"/*) target="$word"; break ;;
                esac
              done
              if [ -n "$target" ] && [ ! -e "$target" ]; then
                hl_err "$hloc" "command points at a file that does not exist: $target"
              fi
            fi
          fi
          ;;
        prompt)
          prompt="$(jq -r --arg e "$event" --argjson i "$i" --argjson j "$j" "$q.prompt // \"\"" "$HOOKS_FILE")"
          [ -n "$prompt" ] || hl_err "$hloc" "a prompt hook must carry a non-empty 'prompt'"
          ;;
        http|mcp_tool|agent)
          # Recognised types whose per-type required fields this script deliberately does not
          # assert. Inventing a required-field list is how the donor ended up documenting a
          # WebSocket MCP transport that does not exist; a validator that guesses is worse
          # than one that says it did not look.
          hl_note "$hloc" "type '$htype' recognised; its type-specific fields are not validated here"
          ;;
      esac

      # --- timeout -------------------------------------------------------------------------
      t_type="$(jq -r --arg e "$event" --argjson i "$i" --argjson j "$j" "$q.timeout | type" "$HOOKS_FILE")"
      if [ "$t_type" != "null" ]; then
        if [ "$t_type" != "number" ]; then
          hl_err "$hloc" "timeout must be a number, got: $t_type"
        else
          timeout_v="$(jq -r --arg e "$event" --argjson i "$i" --argjson j "$j" "$q.timeout" "$HOOKS_FILE")"
          whole="${timeout_v%%.*}"
          case "$whole" in
            ''|*[!0-9-]*) hl_err "$hloc" "timeout is not a whole number of seconds: $timeout_v" ;;
            *)
              if [ "$whole" -le 0 ]; then
                hl_err "$hloc" "timeout must be positive, got: $timeout_v"
              elif [ "$whole" -gt 600 ]; then
                hl_warn "$hloc" "timeout ${timeout_v}s exceeds the 600s ceiling — every hook in the batch must return before the turn continues"
              elif [ "$whole" -lt 5 ]; then
                hl_warn "$hloc" "timeout ${timeout_v}s is very short; a hook that spawns an interpreter rarely starts in under 5s, and a timed-out hook looks exactly like a hook that passed"
              fi
              ;;
          esac
        fi
      fi

      j=$((j + 1))
    done
    i=$((i + 1))
  done
done <<EOF
$EVENTS
EOF

# --- Duplicate registrations ----------------------------------------------------------------
# The same command wired twice on one event pays interpreter startup twice for one decision.
DUPES="$(jq -r "$BASE | to_entries[] | .key as \$e | .value[]? | .hooks[]? | select(.type == \"command\") | \"\(\$e)\t\(.command)\"" "$HOOKS_FILE" 2>/dev/null | sort | uniq -d || true)"
if [ -n "$DUPES" ]; then
  while IFS= read -r dupe; do
    [ -n "$dupe" ] || continue
    hl_warn "$HOOKS_FILE" "the same command is registered twice on one event: $(printf '%s' "$dupe" | tr '\t' ' ')"
  done <<EOF
$DUPES
EOF
fi

# --- Verdict ----------------------------------------------------------------------------------
# The counts are printed unconditionally and on purpose: "0 events, 0 hooks inspected" is the
# signature of the defect described at the top of this file, and it must be visible in the
# output rather than inferable from silence.
printf '\n%s: inspected %d event(s), %d entry(ies), %d hook(s)\n' "$HOOKS_FILE" "$N_EVENTS" "$N_ENTRIES" "$N_HOOKS"

if [ "$HL_ERRORS" -gt 0 ]; then
  printf 'FAIL: %d error(s), %d warning(s)\n' "$HL_ERRORS" "$HL_WARNINGS"
  exit 1
fi
if [ "$HL_WARNINGS" -gt 0 ]; then
  printf 'OK with %d warning(s)\n' "$HL_WARNINGS"
  exit 0
fi
printf 'OK: no findings\n'
exit 0
