#!/usr/bin/env bash
# secrets.sh — gitleaks + trivy over the changed files.
#
# Both are kept even though they overlap, because they demonstrably do not overlap completely: on
# the probe file used during planning, gitleaks allowlisted an AWS access key that trivy caught.
# Two engines is the cheapest possible redundancy for the one finding class where a miss is a real
# incident.
#
# REDACTION. gitleaks runs with --redact; without it the live credential lands in `Secret` and
# `Match` in a JSON file that Claude reads and may quote into a review note, leaking the secret further
# than the commit did. trivy has no --redact flag; it masks the matched value with asterisks in its
# own `Match`/`Code` output. Re-check that on a trivy upgrade. normalize.py never copies `Match`,
# `Secret` or the source line into SCAN.json for a secret finding, so the value stays out of the
# review artifacts even if a tool's masking fails.
#
# A TOOL FAILURE IS NOT A CLEAN RESULT. A run that exits non-zero is counted per file with its stderr
# kept. If every file failed, the tool is recorded as skipped with that stderr and no raw JSON is
# written. If only some failed, the findings from the rest are kept and `<tool>-partial.skipped` names
# the unscanned files, so the gap appears in SCAN-SUMMARY.md's coverage list.
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"
FILES="$RAW/.secret-files"

# Every changed file that still exists, whatever the extension: a credential is as likely in a
# .tfvars, a .env.example, a notebook or a README as in source. Skip only what cannot hold text.
: > "$FILES"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  case "$f" in
    *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.zip|*.gz|*.tar|*.whl|*.ico|*.woff|*.woff2|*.mp4) continue ;;
  esac
  printf '%s\n' "$f" >> "$FILES"
done < "$LIST"

if ! any_lines "$FILES"; then
  skip "gitleaks" "no scannable files in the diff"
  skip "trivy" "no scannable files in the diff"
  exit 0
fi

# merge_json_stream <in> <out> <kind> — concatenated per-file JSON documents into one document.
# kind=list: each document is a gitleaks array. kind=trivy: each is a trivy object with `Results`.
# Exits non-zero on a document it cannot parse, so a corrupt report is a failure, not zero findings.
merge_json_stream() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
src, dst, kind = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    buf = open(src).read()
except OSError:
    buf = ""
dec, idx, items = json.JSONDecoder(), 0, []
while idx < len(buf):
    while idx < len(buf) and buf[idx] in " \t\r\n":
        idx += 1
    if idx >= len(buf):
        break
    doc, idx = dec.raw_decode(buf, idx)          # ValueError -> non-zero exit, by design
    if kind == "trivy":
        items.extend((doc or {}).get("Results") or [])
    elif isinstance(doc, list):
        items.extend(doc)
    elif isinstance(doc, dict):
        items.append(doc)
with open(dst, "w") as fh:
    json.dump({"Results": items} if kind == "trivy" else items, fh)
PY
}

# record_failures <tool> <n-total> <n-failed> <failed-list> <err-file> — apply the failure policy above.
# Returns 0 when at least one file was scanned (raw JSON should be kept), 1 when none were.
record_failures() {
  local tool="$1" total="$2" failed="$3" list="$4" err="$5" why
  [ "$failed" -eq 0 ] && return 0
  why="$(excerpt "$err")"
  if [ "$failed" -ge "$total" ]; then
    skip "$tool" "failed on every file ($failed of $total): ${why:-no stderr}"
    return 1
  fi
  skip "$tool-partial" "failed on $failed of $total file(s), which are UNSCANNED for secrets: $(excerpt "$list")— ${why:-no stderr}"
  return 0
}

N_FILES=$(grep -c '[^[:space:]]' "$FILES" 2>/dev/null)
N_FILES=${N_FILES:-0}

if need gitleaks; then
  # ONE FILE PER INVOCATION, on purpose. `gitleaks dir` takes a single path; handing it several
  # paths makes it ignore all but the first and scan that path's whole tree instead — measured
  # during planning as an 8.16 MB scan where the intended target was 99 bytes. Looping is slower per
  # call and vastly cheaper in total.
  #
  # `gitleaks detect` no longer exists in 8.x — the subcommands are `dir`, `git`, `stdin`. And `dir`
  # rather than `git` because the scan must cover the working tree as it stands, not commit history
  # (history scanning is the secret-rotation job's problem, not the reviewer's).
  : > "$RAW/.gl.parts"; : > "$RAW/.gl.err"; : > "$RAW/.gl.failed"
  gl_failed=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rpt="$RAW/.gl.one.json"
    rm -f "$rpt"
    # --exit-code 0 makes a HIT exit 0, so any non-zero status here is the tool failing.
    if gitleaks dir "$f" --redact --no-banner --report-format json --report-path "$rpt" \
         --exit-code 0 >/dev/null 2>>"$RAW/.gl.err"; then
      [ -s "$rpt" ] && cat "$rpt" >> "$RAW/.gl.parts"
    else
      gl_failed=$((gl_failed + 1))
      printf '%s\n' "$f" >> "$RAW/.gl.failed"
    fi
  done < "$FILES"
  if record_failures gitleaks "$N_FILES" "$gl_failed" "$RAW/.gl.failed" "$RAW/.gl.err"; then
    if merge_json_stream "$RAW/.gl.parts" "$RAW/gitleaks.json" list 2>>"$RAW/.gl.err"; then
      note gitleaks "ok"
    else
      skip "gitleaks" "could not parse its report: $(tail -c 200 "$RAW/.gl.err" | tr '\n' ' ')"
      rm -f "$RAW/gitleaks.json"
    fi
  fi
  rm -f "$RAW/.gl.parts" "$RAW/.gl.one.json" "$RAW/.gl.err" "$RAW/.gl.failed"
fi

if need trivy; then
  # `trivy fs --scanners secret` takes one directory or file per run. Loop over the changed files,
  # but scan the repo root once instead when the file count is large enough that per-file startup
  # dominates.
  : > "$RAW/.trivy.parts"; : > "$RAW/.trivy.err"; : > "$RAW/.trivy.failed"
  tv_failed=0 tv_total="$N_FILES"
  # TRIVY_TREE_SCAN_AT: past this many files, one whole-tree scan is cheaper than per-file runs,
  # because trivy initialises its rule set on every invocation (a second or so each). The diff filter
  # then drops the out-of-hunk results. A cost trade-off, not a correctness one; tune freely.
  TRIVY_TREE_SCAN_AT=40
  if [ "$N_FILES" -gt "$TRIVY_TREE_SCAN_AT" ]; then
    tv_total=1
    if ! trivy fs --scanners secret --format json --quiet --no-progress . \
         >> "$RAW/.trivy.parts" 2>>"$RAW/.trivy.err"; then
      tv_failed=1
      printf '.\n' >> "$RAW/.trivy.failed"
    fi
    tv_note="whole-tree scan ($N_FILES changed files; per-file startup would cost more)"
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! trivy fs --scanners secret --format json --quiet --no-progress "$f" \
           >> "$RAW/.trivy.parts" 2>>"$RAW/.trivy.err"; then
        tv_failed=$((tv_failed + 1))
        printf '%s\n' "$f" >> "$RAW/.trivy.failed"
      fi
    done < "$FILES"
    tv_note="ok"
  fi
  if record_failures trivy "$tv_total" "$tv_failed" "$RAW/.trivy.failed" "$RAW/.trivy.err"; then
    if merge_json_stream "$RAW/.trivy.parts" "$RAW/trivy.json" trivy 2>>"$RAW/.trivy.err"; then
      note trivy "$tv_note"
    else
      skip "trivy" "could not parse its output: $(tail -c 200 "$RAW/.trivy.err" | tr '\n' ' ')"
      rm -f "$RAW/trivy.json"
    fi
  fi
  rm -f "$RAW/.trivy.parts" "$RAW/.trivy.err" "$RAW/.trivy.failed"
fi

rm -f "$FILES" 2>/dev/null
exit 0
