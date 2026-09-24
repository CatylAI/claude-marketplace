#!/usr/bin/env bash
# shell.sh — shellcheck over the changed shell scripts.
#
# Worth its own detector because this repo's own portability rule (bash 3.2+ AND zsh) is exactly
# the class of bug shellcheck catches mechanically: unquoted expansions that word-split differently
# between the two shells, bash-4-only constructs, and `cd` without a guard. Every one of those has
# been hit by hand in this codebase.
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"
SH="$RAW/.sh-files"

# Extension first, then shebang for extensionless scripts. `hooks/pre-commit` and friends have no
# suffix, and skipping them would silently exempt the scripts most likely to be hand-written.
filter_ext "$LIST" .sh .bash .zsh > "$SH"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  # Any file with a recognised extension is either already in the list or deliberately not a shell
  # script; only extensionless files need the shebang sniff.
  case "$f" in *.*) continue ;; esac
  # FIRST LINE ONLY, and the interpreter matched as a whole word. Reading a fixed byte count instead
  # spans into the file body, and a `*sh*` glob then matches any early prose containing "sh" — which
  # is how a python file with a docstring got handed to shellcheck and came back as a MAJOR SC1071
  # "only supports sh/bash/dash/ksh scripts".
  case "$(head -n 1 "$f" 2>/dev/null)" in
    '#!'*/sh|'#!'*/sh\ *|'#!'*/bash|'#!'*/bash\ *|'#!'*/zsh|'#!'*/zsh\ *|'#!'*/dash|'#!'*/dash\ *|'#!'*/ksh|'#!'*/ksh\ *|'#!'*env\ sh*|'#!'*env\ bash*|'#!'*env\ zsh*)
      grep -qxF "$f" "$SH" 2>/dev/null || printf '%s\n' "$f" >> "$SH" ;;
  esac
done < "$LIST"

if ! any_lines "$SH"; then
  skip "shellcheck" "no shell scripts in the diff"
  exit 0
fi

if need shellcheck; then
  set --
  while IFS= read -r f; do
    [ -n "$f" ] && set -- "$@" "$f"
  done < "$SH"
  # format=json1 is the object form ({comments:[...]}); plain `json` is a bare array. Both exist and
  # they are NOT interchangeable — normalize.py reads json1.
  # -x follows `source`d files so a sourced _lib.sh does not produce phantom "not assigned" noise.
  shellcheck --format=json1 -x "$@" > "$RAW/shellcheck.json" 2> "$RAW/.sc.err"
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$RAW/shellcheck.json" 2>/dev/null; then
    skip "shellcheck" "unparseable output: $(excerpt "$RAW/.sc.err")"
    rm -f "$RAW/shellcheck.json"
  else
    note shellcheck "ok"
  fi
fi

rm -f "$RAW/.sc.err" "$SH" 2>/dev/null
exit 0
