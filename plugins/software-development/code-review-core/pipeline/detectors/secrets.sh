#!/usr/bin/env bash
# secrets.sh — gitleaks + trivy over the changed files.
#
# Both are kept even though they overlap, because they demonstrably do not overlap completely: on
# the probe file used during planning, gitleaks allowlisted an AWS access key that trivy caught.
# Two engines is the cheapest possible redundancy for the one finding class where a miss is a real
# incident.
#
# --redact IS MANDATORY, on both tools. Without it gitleaks puts the live credential in `Secret`
# and trivy puts it in `Match`, and those land in a JSON file that Claude reads and may quote into a
# review note — leaking the secret further than the commit did. normalize.py additionally refuses to
# use the source line as `evidence` for any secret finding. Belt and braces, deliberately.
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

if need gitleaks; then
  # ONE FILE PER INVOCATION, on purpose. `gitleaks dir` takes a single path; handing it several
  # paths makes it ignore all but the first and scan that path's whole tree instead — measured
  # during planning as an 8.16 MB scan where the intended target was 99 bytes. Looping is slower per
  # call and vastly cheaper in total.
  #
  # `gitleaks detect` no longer exists in 8.x — the subcommands are `dir`, `git`, `stdin`. And `dir`
  # rather than `git` because the scan must cover the working tree as it stands, not commit history
  # (history scanning is the secret-rotation job's problem, not the reviewer's).
  : > "$RAW/.gl.parts"
  gl_rc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rpt="$RAW/.gl.one.json"
    rm -f "$rpt"
    # --no-banner keeps stderr clean; --exit-code 0 stops a hit from looking like a tool crash.
    gitleaks dir "$f" --redact --no-banner --report-format json --report-path "$rpt" \
      --exit-code 0 >/dev/null 2>&1 || gl_rc=$?
    [ -s "$rpt" ] && cat "$rpt" >> "$RAW/.gl.parts"
  done < "$FILES"
  if python3 - "$RAW/.gl.parts" "$RAW/gitleaks.json" <<'PY'
import json, sys
# Each per-file report is its own JSON array; concatenating them gives a stream of arrays.
try:
    buf = open(sys.argv[1]).read()
except OSError:
    buf = ""
dec, idx, findings = json.JSONDecoder(), 0, []
while idx < len(buf):
    while idx < len(buf) and buf[idx] in " \t\r\n":
        idx += 1
    if idx >= len(buf):
        break
    try:
        doc, idx = dec.raw_decode(buf, idx)
    except ValueError:
        break
    if isinstance(doc, list):
        findings.extend(doc)
    elif isinstance(doc, dict):
        findings.append(doc)
json.dump(findings, open(sys.argv[2], "w"))
PY
  then
    note gitleaks "ok"
  else
    skip "gitleaks" "could not merge per-file reports (last rc $gl_rc)"
  fi
  rm -f "$RAW/.gl.parts" "$RAW/.gl.one.json"
fi

if need trivy; then
  # `trivy fs --scanners secret` takes a directory or a file. Unlike gitleaks it accepts one target
  # per run too, so loop — but only over files trivy will actually inspect, and scan the repo root
  # once instead when the file count is large enough that per-file startup dominates.
  # No `|| printf 0` fallback: grep -c prints its own 0 and also exits 1, so the fallback would make
  # this "0\n0" and the numeric comparison below would error out.
  n=$(grep -c '[^[:space:]]' "$FILES" 2>/dev/null)
  n=${n:-0}
  : > "$RAW/.trivy.parts"
  if [ "$n" -gt 40 ]; then
    # Above ~40 files, per-file trivy startup (it initialises its rule DB each run) costs more than
    # scanning the tree once and letting the diff filter drop the out-of-hunk results.
    trivy fs --scanners secret --format json --quiet --no-progress . >> "$RAW/.trivy.parts" 2>/dev/null
    note trivy "whole-tree scan ($n changed files; per-file startup would cost more)"
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      trivy fs --scanners secret --format json --quiet --no-progress "$f" \
        >> "$RAW/.trivy.parts" 2>/dev/null
    done < "$FILES"
    note trivy "ok"
  fi
  if ! python3 - "$RAW/.trivy.parts" "$RAW/trivy.json" <<'PY'
import json, sys
try:
    buf = open(sys.argv[1]).read()
except OSError:
    buf = ""
dec, idx, results = json.JSONDecoder(), 0, []
while idx < len(buf):
    while idx < len(buf) and buf[idx] in " \t\r\n":
        idx += 1
    if idx >= len(buf):
        break
    try:
        doc, idx = dec.raw_decode(buf, idx)
    except ValueError:
        break
    results.extend(doc.get("Results") or [])
json.dump({"Results": results}, open(sys.argv[2], "w"))
PY
  then
    skip "trivy" "could not merge per-file output"
    rm -f "$RAW/trivy.json"
  fi
  rm -f "$RAW/.trivy.parts"
fi

rm -f "$FILES" 2>/dev/null
exit 0
