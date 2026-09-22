#!/usr/bin/env bash
# _lib.sh — shared helpers for detectors/*.sh. Sourced, never executed.
#
# THE DETECTOR CONTRACT (all of it):
#   invocation : detectors/<name>.sh <changed-files-list-file> <outdir>
#   output     : <outdir>/raw/<tool>.json          — the tool's native JSON
#                <outdir>/raw/<tool>.skipped       — one line saying WHY, when it could not run
#   exit code  : ALWAYS 0
#
# The always-zero rule is the important one. A scan is an advisory input to a review; a missing
# binary, an unconfigured venv, or a tool that segfaults must degrade to a recorded skip, never
# fail the review. The flip side is that silence would be indistinguishable from a clean result,
# so every non-run writes a `.skipped` with a reason, and those reasons are surfaced in
# SCAN-SUMMARY.md and in the verdict ("scanned with 6 of 9 detectors").
#
# Portable bash 3.2+ / zsh.

# have <bin> — is this tool usable at all?
have() { command -v "$1" >/dev/null 2>&1; }

# skip <tool> <reason> — record a non-run.
skip() {
  printf '%s\n' "$2" > "$RAW/$1.skipped"
  printf '  skip %-11s %s\n' "$1" "$2" >&2
}

# need <tool> — skip-and-return-1 when the binary is absent. Usage:
#   need ruff || return 0     (inside a function)
#   need ruff && run_ruff     (at top level)
need() {
  if have "$1"; then
    return 0
  fi
  skip "$1" "binary not found on PATH"
  return 1
}

# note <tool> <n> — log how many raw records a tool produced. Counting happens in normalize.py;
# this is only progress output for a human watching a slow scan.
note() { printf '  ran  %-11s %s\n' "$1" "$2" >&2; }

# filter_ext <list-file> <ext> [<ext>...] — print the subset of changed files with these
# extensions, one per line, skipping any that no longer exist on disk (a deleted file is in the
# diff but cannot be linted).
filter_ext() {
  local list="$1"; shift
  local f e keep
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    keep=false
    for e in "$@"; do
      case "$f" in *"$e") keep=true; break ;; esac
    done
    $keep && printf '%s\n' "$f"
  done < "$list"
}

# any_lines <file> — true when the file has at least one non-empty line. `[ -s ]` is not enough:
# filter_ext legitimately produces an empty file, and running a linter with zero path arguments
# makes most of them scan the ENTIRE tree, which is exactly the unbounded cost being removed.
any_lines() { [ -s "$1" ] && grep -q '[^[:space:]]' "$1"; }
