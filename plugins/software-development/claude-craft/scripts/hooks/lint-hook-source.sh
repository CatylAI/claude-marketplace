#!/usr/bin/env bash
# lint-hook-source.sh — static checks on hook SOURCE files.
#
#   bash lint-hook-source.sh hooks/src/pre-bash.ts hooks/validate.sh
#   bash lint-hook-source.sh --dir plugins/software-development/dev-guardrails/hooks/src
#
# Exit: 0 clean (warnings allowed) · 1 errors found · 2 misconfigured.
#
# ---------------------------------------------------------------------------------------
# CALIBRATION
#
# This repo's reference hook package is dev-guardrails: 14 hooks, 376 passing tests, and
# written in TypeScript rather than shell. The donor linter assumed every hook is a bash
# script, which meant five of its twelve checks fired on all fourteen of them. A linter
# whose output against known-good code is fourteen findings is not a linter; it is a thing
# people turn off.
#
# So the checks below are split. Shell-only checks run on files that are shell (shebang or
# extension); the rest are language-agnostic and phrased in terms of the hook protocol.
#
# Checks DROPPED from the donor, each with the reason:
#
#   * "unquoted variable" heuristic `\$[A-Za-z_][A-Za-z0-9_]*[^"]` — matches `"$dir/x"`,
#     `$1 `, and every other correct use of a variable. It is a warning generator, not a
#     check. Replaced by a narrow one that looks for the actual injection site: a variable
#     interpolated into `eval` or `bash -c`.
#   * hardcoded `/usr/` and `/opt/` paths — this repo's own pre-write-edit gate REQUIRES
#     `#!/usr/bin/env bash` as the portable shebang, so flagging `/usr/` contradicts the
#     most mature hook package here. Narrowed to machine-local home directories, which are
#     unambiguously wrong.
#   * "uses CLAUDE_PLUGIN_ROOT" — a hook SOURCE has no reason to mention it; the plugin
#     root belongs in the `command` string in hooks.json, which is where all fourteen
#     dev-guardrails hooks correctly put it and where validate-hook-registration.sh checks
#     for it. Flagging its absence in the source flags correct code.
#   * "PreToolUse/Stop hooks should output decision JSON" — flatly contradicts this repo.
#     dev-guardrails' PreToolUse hooks block with exit 2 + stderr and emit no decision JSON
#     at all, which deterministic-enforcement §3 confirms is a correct mechanism. The check
#     would flag four correct blocking gates.
#   * the executable-bit check, for non-shell sources — dev-guardrails' hooks are mode 0644
#     and invoked as `node <file>`; requiring +x on them is wrong. Kept for shell.
#
# Checks ADDED, each grounded in this repo:
#
#   * `tool_result` read as a hook-input field. The real field is `tool_response`
#     (dev-guardrails hooks/src/lib/types.ts, restated in post-agent.ts:253 and
#     post-mcp-tool.ts:162). Reading the wrong one "yields undefined forever while looking
#     like it works" — which is precisely a defect a static check can catch and a test
#     usually cannot.
#   * a machine-local home directory anywhere in the source.
#   * non-portable shebang (`#!/bin/bash`, `#!/usr/bin/bash`), matching the rule
#     dev-guardrails' own pre-write-edit.ts enforces on every shell script written here.
#   * `eval` / `bash -c` on interpolated text.
#   * an external CLI invoked with no `command -v` guard — review-hooks Lens 4, made
#     mechanical: "a hook that fails because a tool is not installed blocks work for a
#     reason unrelated to the work".
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
Usage: lint-hook-source.sh [--dir DIR] [file ...]

Options:
  --dir DIR    Lint every hook source directly under DIR. Test files (*.test.*, *.spec.*)
               and type/library-only files are skipped; pass them explicitly to include one.
  -h, --help   This message.

Exit: 0 clean (warnings allowed) · 1 errors found · 2 misconfigured.
USAGE
}

FILES=""
DIRS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dir) [ $# -ge 2 ] || hl_die "--dir needs a directory"
           [ -d "$2" ] || hl_die "not a directory: $2"
           DIRS="${DIRS}$2
"; shift 2 ;;
    --) shift ;;
    -*) hl_die "unknown option: $1" ;;
    *)  FILES="${FILES}$1
"; shift ;;
  esac
done

if [ -n "$DIRS" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    found="$(find "$d" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.zsh' -o -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.py' \) \
      ! -name '*.test.*' ! -name '*.spec.*' ! -name 'types.*' | sort)"
    FILES="${FILES}${found}
"
  done <<EOF
$DIRS
EOF
fi

if [ -z "$(printf '%s' "$FILES" | tr -d '[:space:]')" ]; then
  printf 'nothing to lint.\n' >&2
  usage >&2
  exit 2
fi

N_FILES=0

# Strip comment lines before content checks. A hook that documents the `tool_result` trap in
# a comment — as three dev-guardrails files do, verbatim — must not be flagged for the trap
# it is warning about.
strip_comments() { # <file>
  sed -e 's#//.*$##' -e 's/^[[:space:]]*\*.*$//' -e 's/^[[:space:]]*#.*$//' "$1"
}

is_shell() { # <file>
  case "$1" in
    *.sh|*.bash|*.zsh) return 0 ;;
  esac
  head -1 "$1" 2>/dev/null | grep -Eq '^#!.*(\bsh\b|bash|zsh|dash|ksh)' && return 0
  return 1
}

lint_file() { # <file>
  f="$1"
  if [ ! -f "$f" ]; then
    hl_err "$f" "file not found"
    return 0
  fi
  N_FILES=$((N_FILES + 1))
  body="$(strip_comments "$f")"

  # ---- language-agnostic -----------------------------------------------------------------

  # 1. `tool_result` used as an input field. ERROR: it is always undefined.
  if printf '%s' "$body" | grep -Eq '(\.|\[["'"'"']|\bget\(["'"'"']|"|'"'"')tool_result\b'; then
    hl_err "$f" "reads \`tool_result\` as a hook-input field. The field is \`tool_response\`; \`tool_result\` is the model-facing content-block name and is never present on hook input, so the read returns undefined forever while looking like it works."
  fi

  # 2. Machine-local paths. ERROR: the hook runs on exactly one computer.
  hits="$(printf '%s' "$body" | grep -nE '/(Users|home)/[A-Za-z0-9._-]+/' | head -3 || true)"
  if [ -n "$hits" ]; then
    hl_err "$f" "contains a machine-local home directory: $(printf '%s' "$hits" | head -1 | cut -c1-120)"
  fi

  # 3. Reads event fields it never obtained.
  #
  # NOT "does it read stdin at all". That broader form flagged three correct dev-guardrails
  # hooks — session-start.ts, post-compact.ts and stop.ts — which deliberately read nothing,
  # because SessionStart, PreCompact and Stop carry no payload those hooks need and all
  # three compute their context from the repository instead. Their own tests feed them `{}`.
  #
  # What IS always a bug is naming an input field and never obtaining the input: the field
  # is then undefined on every invocation and the hook's condition silently never fires.
  if printf '%s' "$body" | grep -Eq '\b(tool_name|tool_input|tool_response|hook_event_name|session_id|permission_mode)\b'; then
    if ! printf '%s' "$body" | grep -Eq '(process\.stdin|readStdin|/dev/stdin|sys\.stdin|\$\(cat\)|<&0|\bread -r\b|\bcat\b)'; then
      hl_err "$f" "reads hook-input field names but never reads stdin — those fields are undefined on every invocation, so whatever they gate never fires"
    fi
  fi

  # 4. Long-running patterns. Every hook in a batch must return before the turn continues.
  if printf '%s' "$body" | grep -Eq '(while[[:space:]]+true|sleep[[:space:]]+[0-9]{3,})'; then
    hl_warn "$f" "contains an unbounded loop or a multi-minute sleep — the turn does not continue until every hook in the batch returns"
  fi

  # ---- shell only ---------------------------------------------------------------------------
  if is_shell "$f"; then
    first="$(head -1 "$f")"
    case "$first" in
      '#!'*) ;;
      *) hl_err "$f" "shell hook with no shebang" ;;
    esac

    # Matches the rule dev-guardrails' pre-write-edit.ts enforces on shell scripts written
    # in this repo: /bin/bash is 3.2 on macOS and /usr/bin/bash does not exist there.
    case "$first" in
      '#!/bin/bash'*|'#!/usr/bin/bash'*)
        hl_warn "$f" "non-portable shebang '$first' — prefer '#!/usr/bin/env bash'" ;;
    esac

    [ -x "$f" ] || hl_warn "$f" "shell hook is not executable (chmod +x), and a command hook is invoked directly"

    printf '%s' "$body" | grep -Eq 'set[[:space:]]+-[a-z]*e[a-z]*[uo]*' \
      || hl_warn "$f" "no 'set -euo pipefail' — an unset variable or a failed command in a hook fails silently and the hook looks like it passed"

    # The real injection site, in place of the donor's catch-everything quoting heuristic.
    if printf '%s' "$body" | grep -Eq '(^|[^A-Za-z0-9_])eval[[:space:]]'; then
      hl_err "$f" "uses 'eval'. Hook input is attacker-influenced text; re-evaluating it as shell is arbitrary code execution from a tool argument."
    fi
    # The distinction that matters, and the reason this is two greps rather than one:
    #
    #   bash -c "$cmd"           <- the variable IS the whole program. This is how Claude Code
    #                               itself runs a command hook, and how run-hook-event.sh in
    #                               this directory runs one. Not a finding.
    #   bash -c "run $cmd --now" <- the variable is CONCATENATED into a program. The value
    #                               decides where the quoting ends. This is the finding.
    #
    # The first version of this check made no such distinction and flagged run-hook-event.sh,
    # which is how the distinction got written down.
    if printf '%s' "$body" \
        | grep -E '(bash|sh|zsh)[[:space:]]+-c[[:space:]]+"[^"]*\$' \
        | grep -Evq '(bash|sh|zsh)[[:space:]]+-c[[:space:]]+"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"'; then
      hl_err "$f" "concatenates a variable into a re-evaluated shell string ('sh -c \"... \$x ...\"'). The value then decides where the quoting ends. Pass it as a separate argv element, or make the variable the entire program."
    fi

    printf '%s' "$body" | grep -Eq 'exit[[:space:]]+[0-9]' \
      || hl_warn "$f" "no explicit exit code — the hook's decision is whatever the last command happened to return"

    if printf '%s' "$body" | grep -Eq 'exit[[:space:]]+2' && ! printf '%s' "$body" | grep -Fq '>&2'; then
      hl_warn "$f" "exits 2 (block) but never writes to stderr — exit 2 feeds STDERR back to the model as the reason, so a blocked call would arrive with no explanation"
    fi

    if printf '%s' "$body" | grep -Eq 'tool_(input|name|response)' && ! printf '%s' "$body" | grep -Fq 'jq'; then
      hl_warn "$f" "reads hook-input fields without jq — a JSON payload matched with sed or grep breaks on the first embedded newline or quote"
    fi

    # review-hooks Lens 4, made mechanical.
    for bin in jq git gh glab node python3; do
      if printf '%s' "$body" | grep -Eq "(^|[^A-Za-z0-9_./-])${bin}[[:space:]]" \
         && ! printf '%s' "$body" | grep -Eq "command -v ${bin}|which ${bin}|type ${bin}"; then
        hl_warn "$f" "invokes '$bin' with no availability guard — a hook that fails because a CLI is missing blocks work for a reason unrelated to the work"
      fi
    done
  fi
}

printf 'lint-hook-source (shell: %s)\n\n' "${ZSH_VERSION:+zsh ${ZSH_VERSION}}${BASH_VERSION:+bash ${BASH_VERSION}}"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  lint_file "$f"
done <<EOF
$FILES
EOF

printf '\nlinted %d file(s)\n' "$N_FILES"
if [ "$N_FILES" -eq 0 ]; then
  printf 'no files matched — that is a misconfiguration, not a pass.\n' >&2
  exit 2
fi
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
